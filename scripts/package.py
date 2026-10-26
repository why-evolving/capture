#!/usr/bin/env python3
"""Package a built public app, then verify the extracted signature and exact files."""
import argparse
import hashlib
import plistlib
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def run(*args): subprocess.run(args, check=True)
def inventory(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest() for p in path.rglob('*') if p.is_file()}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if app.name != 'Capture.app' or info['CFBundleIdentifier'] != 'local.capture.app':
        parser.error('Only the generic public Capture.app may be packaged.')
    run('python3', str(ROOT / 'scripts/check-publication.py'), '--binary', str(app / 'Contents/MacOS/Capture'))
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    name = 'Capture-' + info['CFBundleShortVersionString'] + '-mac-arm64'
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output.resolve() / (name + '.zip')
    if archive.exists(): parser.error('Refusing to overwrite an existing final archive.')
    with tempfile.TemporaryDirectory(prefix='capture-package-') as temporary:
        stage = Path(temporary) / name; stage.mkdir()
        run('/usr/bin/ditto', str(app), str(stage / 'Capture.app'))
        for source, target in [('LICENSE', 'LICENSE'), ('NOTICE', 'NOTICE'), ('LICENSE.zh-CN.md', 'LICENSE.zh-CN.md'), ('THIRD_PARTY_NOTICES.md', 'THIRD_PARTY_NOTICES.md'), ('docs/distribution.md', 'INSTALL.md')]:
            (stage / target).write_bytes((ROOT / source).read_bytes())
        run('/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr', '--noqtn', '--keepParent', str(stage), str(archive))
        extract = Path(temporary) / 'verified'
        run('/usr/bin/ditto', '-x', '-k', str(archive), str(extract))
        restored = extract / name / 'Capture.app'
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(restored))
        if inventory(app) != inventory(restored): raise RuntimeError('App changed during ZIP round trip.')
        if inventory(stage) != inventory(extract / name): raise RuntimeError('Package documents changed during ZIP round trip.')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(digest + '  ' + archive.name + '\n')
    print('Verified public archive: ' + str(archive))
    print('SHA256: ' + digest)

if __name__ == '__main__': main()
