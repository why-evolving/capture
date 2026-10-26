#!/usr/bin/env python3
"""Create once, then reuse Capture's local code-signing identity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import sys
import tempfile

SIGNING_DIR = Path.home() / "Library/Application Support/Capture/Signing"
IDENTITY_FILE = SIGNING_DIR / "identity.json"
CERTIFICATE_FILE = SIGNING_DIR / "certificate.pem"
NAME = "Capture Local Code Signing"
DEFAULT_BUNDLE_ID = "local.capture.app"
SECURITY = "/usr/bin/security"
OPENSSL = "/usr/bin/openssl"
CODESIGN = "/usr/bin/codesign"


def run(args, *, env=None, allow_failure=False):
    result = subprocess.run(args, capture_output=True, env=env)
    if result.returncode and not allow_failure:
        # Do not include command arguments: import temporarily uses a random password.
        raise RuntimeError(Path(args[0]).name + ": " + result.stderr.decode(errors="replace").strip())
    return result


def certificate_info():
    der = run([OPENSSL, "x509", "-in", str(CERTIFICATE_FILE), "-outform", "DER"]).stdout
    expiry = run([OPENSSL, "x509", "-in", str(CERTIFICATE_FILE), "-noout", "-enddate"]).stdout.decode().strip()
    return {"sha1": hashlib.sha1(der).hexdigest().upper(),
            "sha256": hashlib.sha256(der).hexdigest().upper(), "expires": expiry.removeprefix("notAfter=")}


def available(sha1, keychain, *, valid=True):
    args = [SECURITY, "find-identity", "-p", "codesigning"]
    if valid:
        args.append("-v")
    result = run(args + [keychain])
    return sha1 in result.stdout.decode().upper()


def load_identity():
    if not IDENTITY_FILE.exists():
        raise RuntimeError("尚未配置固定签名。请先运行 python3 scripts/signing.py setup。")
    identity = json.loads(IDENTITY_FILE.read_text())
    if not re.fullmatch(r"[A-F0-9]{40}", identity.get("sha1", "")):
        raise RuntimeError("签名配置无效；未使用临时签名。")
    info = certificate_info()
    if info["sha1"] != identity["sha1"] or info["sha256"] != identity["sha256"]:
        raise RuntimeError("证书与固定指纹不匹配；请恢复原证书，不要重新生成身份。")
    if not available(identity["sha1"], identity["keychain"]):
        raise RuntimeError("固定证书或其私钥不可用。请解锁钥匙串或恢复原身份；未使用临时签名。")
    return identity


def bundle_identifier(identity=None):
    """Explicit build ID, otherwise this developer's pinned ID; no machine identity in source."""
    value = os.environ.get("CAPTURE_BUNDLE_ID") or (identity or load_identity()).get("bundle_id", DEFAULT_BUNDLE_ID)
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+", value) or len(value) > 200:
        raise RuntimeError("Bundle identifier 无效。")
    return value


def setup():
    os.umask(0o077)
    SIGNING_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    SIGNING_DIR.chmod(0o700)
    if IDENTITY_FILE.exists():
        identity = load_identity()
        print("Reusing fixed identity: " + identity["sha1"])
        return
    keychain = run([SECURITY, "default-keychain", "-d", "user"]).stdout.decode().strip().strip('"')
    if not keychain:
        raise RuntimeError("未找到用户默认钥匙串。")
    # Recover an interrupted setup rather than creating another signing identity.
    if not CERTIFICATE_FILE.exists():
        existing = run([SECURITY, "find-certificate", "-c", NAME, "-p", keychain], allow_failure=True)
        if existing.returncode == 0:
            CERTIFICATE_FILE.write_bytes(existing.stdout)
        else:
            with tempfile.TemporaryDirectory(prefix=".setup-", dir=SIGNING_DIR) as temporary:
                directory = Path(temporary)
                config = directory / "openssl.cnf"
                key, cert, archive = [directory / name for name in ("private.pem", "certificate.pem", "identity.p12")]
                config.write_text("""[req]
distinguished_name = name
x509_extensions = codesign
prompt = no
[name]
CN = Capture Local Code Signing
O = Capture Personal
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
""")
                run([OPENSSL, "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256", "-days", "3650", "-nodes",
                     "-config", str(config), "-keyout", str(key), "-out", str(cert)])
                password = secrets.token_urlsafe(32)
                environment = dict(os.environ, CAPTURE_SETUP_ARCHIVE_PASSWORD=password)
                run([OPENSSL, "pkcs12", "-export", "-in", str(cert), "-inkey", str(key), "-name", NAME,
                     "-out", str(archive), "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
                     "-passout", "env:CAPTURE_SETUP_ARCHIVE_PASSWORD"], env=environment)
                run([SECURITY, "import", str(archive), "-k", keychain, "-f", "pkcs12", "-P", password,
                     "-T", CODESIGN])
                CERTIFICATE_FILE.write_bytes(cert.read_bytes())
            # Raw private key and temporary archive have now been removed.
    info = certificate_info()
    if not available(info["sha1"], keychain, valid=False):
        raise RuntimeError("已保留公钥证书，但钥匙串内缺少对应私钥。请恢复身份，避免更换指纹。")
    # User domain only; constrained to code signing, not TLS or system-wide trust.
    print("Adding code-signing trust for the Capture certificate in the current user domain…", flush=True)
    run([SECURITY, "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", keychain, str(CERTIFICATE_FILE)])
    if not available(info["sha1"], keychain):
        raise RuntimeError("证书已导入，但尚未通过代码签名验证。请在钥匙串中检查该证书。")
    identity = dict(info, name=NAME, keychain=keychain, bundle_id=DEFAULT_BUNDLE_ID, format_version=1)
    with tempfile.NamedTemporaryFile(mode="w", dir=SIGNING_DIR, delete=False) as output:
        json.dump(identity, output, ensure_ascii=False, indent=2)
        output.write("\n")
        temporary_path = Path(output.name)
    temporary_path.replace(IDENTITY_FILE)
    print("Fixed identity configured: " + identity["sha1"])
    print("Private key: user keychain; public certificate and fingerprint: " + str(SIGNING_DIR))


def sign(app):
    identity = load_identity()
    bundle_id = bundle_identifier(identity)
    app = app.resolve(strict=True)
    ensure_not_running(app)
    with (app / "Contents/Info.plist").open("rb") as source:
        if plistlib.load(source).get("CFBundleIdentifier") != bundle_id:
            raise RuntimeError("目标不是 Capture 应用；未签名。")
    run([CODESIGN, "--force", "--sign", identity["sha1"], "--keychain", identity["keychain"],
         "--identifier", bundle_id, "--timestamp=none", str(app)])
    verify(app, identity)


def verify(app, identity=None):
    identity = identity or load_identity()
    # Pin the actual signing certificate in addition to the bundle identifier.
    bundle_id = bundle_identifier(identity)
    requirement = '=identifier "' + bundle_id + '" and certificate leaf = H"' + identity["sha1"] + '"'
    run([CODESIGN, "--verify", "--strict", "-R", requirement, str(app)])
    description = run([CODESIGN, "-d", "-r-", str(app)])
    designated = (description.stdout + description.stderr).decode()
    if "designated =>" not in designated or "cdhash" in designated:
        raise RuntimeError("签名仍依赖构建哈希；已拒绝将其作为固定签名。")
    print("Verified fixed signer: " + identity["sha1"])
    print(designated.strip())


def ensure_not_running(app):
    executable = str(app.resolve() / "Contents/MacOS/Capture")
    processes = run(["/bin/ps", "-axo", "comm="]).stdout.decode().splitlines()
    if any(command.strip() == executable for command in processes):
        raise RuntimeError("目标 Capture 仍在运行；请先退出，或使用其他目录暂存构建。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["setup", "check", "sign", "verify", "bundle-id"])
    parser.add_argument("app", nargs="?", type=Path)
    args = parser.parse_args()
    if args.command == "setup":
        setup()
    elif args.command == "bundle-id":
        print(bundle_identifier())
    elif args.command == "check":
        print("Fixed identity ready: " + load_identity()["sha1"])
        if args.app:
            ensure_not_running(args.app)
    elif args.app is None:
        parser.error("sign/verify requires an app path")
    elif args.command == "sign":
        sign(args.app)
    else:
        verify(args.app)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print("Signing failed: " + str(error), file=sys.stderr)
        sys.exit(1)
