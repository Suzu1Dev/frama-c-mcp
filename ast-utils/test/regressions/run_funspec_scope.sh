#!/usr/bin/env bash

# Regression: funspec scope must reject local-var references (ACSL §2.3).
#
# History: before the find_var Kglobal fix, validate_acsl silently accepted
# broken funspecs like "assigns i, j, tmp;" where i/j/tmp are function locals —
# causing downstream WP to verify against a contract the function doesn't
# actually satisfy.
#
# Expected verdict matrix per case id:
#   valid_*           → valid:true
#   broken_local_*    → valid:false, error includes "Unbound variable"
#   broken_undef      → valid:false, error includes "Unbound variable"
#   broken_syntax     → valid:false, error includes "syntax error"

set -euo pipefail

FC="${FRAMA_C:-$(command -v frama-c || echo ~/.opam/frama/bin/frama-c)}"
if [[ ! -x "$FC" ]]; then
    echo "frama-c not found; set FRAMA_C env var" >&2
    exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$HERE/funspec_scope.c" "$HERE/batch_funspec_scope.json" "$WORK/"
(cd "$WORK" && "$FC" -load-module ast_utils_plugin \
    -server-batch batch_funspec_scope.json funspec_scope.c \
    >/dev/null 2>&1)

# Parse output and verify each id's verdict.
python3 - "$WORK/batch_funspec_scope.out.json" <<'PY'
import json, re, sys

EXPECTED = {
    "valid_formal":          ("valid",   None),
    "valid_global":          ("valid",   None),
    "valid_result":          ("valid",   None),
    "valid_old":             ("valid",   None),
    # Locals in funspec → actionable ACSL §2.3 message
    "broken_local_assigns":  ("invalid", "function local"),
    "broken_local_requires": ("invalid", "function local"),
    "broken_local_ensures":  ("invalid", "function local"),
    "broken_local_ptr":      ("invalid", "function local"),
    # Truly unbound (not a local, not a formal, not a global) → generic message
    "broken_undef":          ("invalid", "Unbound variable"),
    "broken_syntax":         ("invalid", "syntax error"),
}

with open(sys.argv[1]) as f:
    data = json.load(f)

fails = []
seen = set()
for entry in data:
    case_id = entry["id"]
    seen.add(case_id)
    if case_id not in EXPECTED:
        fails.append(f"unexpected case id: {case_id}")
        continue
    want_verdict, want_substr = EXPECTED[case_id]
    result = entry["data"]["result"]
    actual_valid = result.get("valid")
    actual_error = result.get("error") or ""
    if want_verdict == "valid":
        if actual_valid is not True:
            fails.append(f"{case_id}: expected valid, got valid={actual_valid} error={actual_error!r}")
    else:
        if actual_valid is not False:
            fails.append(f"{case_id}: expected invalid, got valid={actual_valid}")
        elif want_substr and want_substr not in actual_error:
            fails.append(f"{case_id}: error missing {want_substr!r}, got {actual_error!r}")

missing = set(EXPECTED) - seen
for m in sorted(missing):
    fails.append(f"missing case in output: {m}")

if fails:
    print("FAIL — funspec_scope regression")
    for f in fails:
        print(f"  {f}")
    sys.exit(1)

print(f"PASS — funspec_scope regression ({len(EXPECTED)} cases)")
PY
