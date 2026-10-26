#!/usr/bin/env python3
"""Read-only publication check. Reports locations/categories, never matched secrets."""
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    'home-directory': re.compile(rb'/Users/(?!<USER>[/ ])[^/\s"\x27<>]+/'),
    'temporary-desktop-path': re.compile(rb'/(?:private/)?var/folders/[a-z0-9]{2}/[a-z0-9_]+/'),
    'private-key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'github-token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b'),
    'aws-key': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'service-token': re.compile(rb'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}\b'),
}
FORBIDDEN_SUFFIXES = {'.p12', '.pfx', '.pem', '.key', '.log', '.mp4', '.mov', '.zip', '.bundle'}

def git(*args, data=None):
    return subprocess.run(['git', '-C', str(ROOT), *args], input=data, capture_output=True, check=True).stdout

def findings(data, name):
    return [{'file': name, 'category': label} for label, pattern in PATTERNS.items() if pattern.search(data)]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', action='store_true', help='Also inspect every reachable Git object; use on the clean publication clone.')
    parser.add_argument('--binary', type=Path, help='Inspect the exact executable intended for distribution.')
    args = parser.parse_args()
    failures = []; count = 0; history = 0
    names = [p.decode() for p in git('ls-files', '-z').split(b'\0') if p]
    for name in names:
        path = ROOT / name
        if not path.is_file(): continue
        count += 1
        if Path(name).suffix.lower() in FORBIDDEN_SUFFIXES or name.startswith(('.build/', 'artifacts/', 'dist/')):
            failures.append({'file': name, 'category': 'private-or-generated-file'})
        failures.extend(findings(path.read_bytes(), name))
    if args.history:
        lines = git('rev-list', '--objects', '--all').splitlines()
        ids = list(dict.fromkeys(row.split(b' ')[0] for row in lines))
        output = git('cat-file', '--batch', data=b'\n'.join(ids) + b'\n'); offset = 0
        for oid in ids:
            end = output.index(b'\n', offset); header = output[offset:end].split(); size = int(header[2])
            body = output[end + 1:end + 1 + size]; offset = end + 2 + size
            if header[1] == b'blob':
                history += 1; failures.extend(findings(body, 'git-object:' + oid.decode()[:12]))
    if args.binary:
        failures.extend(findings(args.binary.read_bytes(), 'release-executable'))
    report = {'result': 'failed' if failures else 'passed', 'trackedFiles': count, 'historicalBlobs': history, 'binaryChecked': bool(args.binary), 'findings': failures, 'scope': 'Common credential formats and absolute local paths only; does not prove absence of all personal data or legal provenance.'}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return bool(failures)

if __name__ == '__main__':
    raise SystemExit(main())
