#!/usr/bin/env python3
"""Validate the self-contained public documentation set."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
required = ["LICENSE", "NOTICE", "LICENSE.zh-CN.md", "README.md", "AGENTS.md", "CONTRIBUTING.md", "SECURITY.md", "THIRD_PARTY_NOTICES.md", "docs/README.md", "docs/product/requirements.md", "docs/design/ui-spec.md", "docs/engineering/technical-design.md", "docs/testing/test-plan.md", "docs/distribution.md"]
for name in required:
    p = root / name
    assert p.is_file() and p.stat().st_size > 0, name
for p in root.rglob("*.md"):
    if any(part in {".git", ".build", "dist", "artifacts"} for part in p.relative_to(root).parts): continue
    for target in re.findall(r"\]\(([^)]+)\)", p.read_text()):
        if target.startswith(("https://", "http://", "#", "mailto:")): continue
        assert (p.parent / target.split("#")[0]).resolve().exists(), (str(p.relative_to(root)), target)
print("Public documentation and relative links verified")
