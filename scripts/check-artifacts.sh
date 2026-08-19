#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

python3 - <<'PY'
from pathlib import Path
import re
import sys

roots = [
    Path("README.md"),
    Path("CLAUDE.md"),
    Path("TODO.md"),
    Path("Cargo.toml"),
    Path("docs"),
    Path("src"),
    Path("tests"),
    Path("ast-utils"),
    Path("scripts"),
    Path(".github"),
]
skip_dirs = {".git", ".frama-c-mcp", "_build", "_opam", "target"}
skip_files = {Path("DONE.md"), Path("framac.md"), Path("scripts/check-artifacts.sh")}

cjk = re.compile(r"[\u2e80-\u9fff\u3040-\u30ff\u3100-\u312f\uac00-\ud7af\uff00-\uffef]")
translator = re.compile(
    r"Google Translate|Translated by Google|This page could not be translated|"
    r"enable JavaScript and cookies|Attention Required!|Just a moment\.\.\.|"
    r"Checking if the site connection is secure|Sorry, you have been blocked|Access denied",
    re.IGNORECASE,
)
bad_frama = re.compile(r"\b(Frama C|Frama\.C|Frama[–—‑]C|frame-c)\b", re.IGNORECASE)
doc_path = re.compile(r"docs/[A-Za-z0-9._/#?=-]+\.(?:md|png|svg|json|txt|c|h)")


def active_files():
    for root in roots:
        if not root.exists() or root in skip_files:
            continue
        paths = [root] if root.is_file() else (p for p in root.rglob("*") if p.is_file())
        for path in paths:
            if path in skip_files or any(part in skip_dirs for part in path.parts):
                continue
            yield path


def read_text(path):
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def report(path, line_no, message, line):
    print(f"{path}:{line_no}: {message}: {line}", file=sys.stderr)


failed = False
for path in active_files():
    for line_no, line in enumerate(read_text(path), 1):
        for name, pattern in (
            ("CJK text", cjk),
            ("translator artifact", translator),
            ("misspelled Frama-C reference", bad_frama),
        ):
            if pattern.search(line):
                report(path, line_no, name, line)
                failed = True

seen = set()
for path in active_files():
    for line_no, line in enumerate(read_text(path), 1):
        for match in doc_path.finditer(line):
            target = match.group(0).rstrip(").,;:'\"]`>")
            target = target.split("#", 1)[0].split("?", 1)[0]
            if not target:
                continue
            key = (path, line_no, target)
            if key in seen:
                continue
            seen.add(key)
            if not Path(target).exists():
                report(path, line_no, f"dead docs path {target}", line)
                failed = True

if failed:
    sys.exit(1)
PY
