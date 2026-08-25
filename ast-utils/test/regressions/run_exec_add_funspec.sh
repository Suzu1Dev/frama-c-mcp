#!/usr/bin/env bash

# Regression: per-entry contract of execAddAnnotation under funspec scope fix.
#
# This is the unit-level contract that inject_all_annotations_sandbox depends
# on:
#   - execAddAnnotation rejects broken funspec → success=false → no AST mutation
#   - execAddAnnotation accepts valid funspec → success=true → AST mutated
#
# Verified end-to-end via:
#   1. Per-entry success/error matches expectation matrix
#   2. printSource output contains the ACSL markers of accepted entries only
#      (rejected entries' markers MUST NOT appear in the source)
#   3. Each error message is correctly classifiable by the Rust-side
#      classify_failure() (simulated here in Python)

set -euo pipefail

FC="${FRAMA_C:-$(command -v frama-c || echo ~/.opam/frama/bin/frama-c)}"
if [[ ! -x "$FC" ]]; then
    echo "frama-c not found; set FRAMA_C env var" >&2
    exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$HERE/funspec_scope.c" "$HERE/batch_exec_add_funspec.json" "$WORK/"
(cd "$WORK" && "$FC" -load-module ast_utils_plugin \
    -server-batch batch_exec_add_funspec.json funspec_scope.c \
    > /dev/null 2>&1)

python3 - "$WORK/batch_exec_add_funspec.out.json" << 'PY'
import json, sys

# Per-entry contract: (expected_success,
#                      expected_error_substr_or_None,
#                      expected_classify_or_None,
#                      ast_marker_or_None)
#
# ast_marker: a snippet from rendered ACSL that proves presence (for
#   success=True) or proves absence (for success=False) of the spec
#   in the printSource output. Rejected entries' markers MUST be
#   absent (AST not polluted).
#
# classify must match the Rust classify_failure() rules (mirrored below).
EXPECTED = {
    # Locals in funspec → actionable ACSL §2.3 message + new category
    "E1_local_assigns":     (False, "function local",       "ProposedLocalVarInFunspec", "assigns i,"),
    "E2_valid_formal":      (True,  None,                    None,                        "L2_valid_formal: n > 0"),
    "E3_local_ptr":         (False, "function local",       "ProposedLocalVarInFunspec", "assigns *p"),
    "E4_valid_global":      (True,  None,                    None,                        "g_arr[0 .. 9]"),
    # Syntax/lexer level
    "E5_broken_syntax":     (False, "syntax error",          "SyntaxError",               "L5_broken_syntax"),
    # Undefined logic names → ProposedSelfReferential (after our classify extension)
    "E6_undef_predicate":   (False, "unbound logic predicate","ProposedSelfReferential",  "unknown_pred"),
    "E7_undef_function":    (False, "unbound logic function", "ProposedSelfReferential",  "unknown_func"),
    "E8_undef_var":         (False, "Unbound variable",      "ProposedSelfReferential",   "nonexistent_var"),
    # Type / semantic errors → ProposedError catchall
    "E9_compare_ptr_int":   (False, "incompatible types",    "ProposedError",             "L9_compare_ptr_int"),
    "E10_nonlval_assigns":  (False, "not an assignable",     "ProposedError",             "L10_nonlval"),
    # Label not found → SelfReferential ("not found" match)
    "E11_unknown_label":    (False, "not found",             "ProposedSelfReferential",   "L11_unknown_label"),
    # Duplicate behavior → ProposedError catchall
    "E12_dup_behavior":     (False, "already defined",       "ProposedError",             "L12_dup_behavior"),
}

# Mirror of Rust classify_failure (server.rs ~3537)
def classify_failure(error):
    lower = error.lower()
    if "function local" in lower:
        return "ProposedLocalVarInFunspec"
    if any(s in lower for s in (
            "unbound", "no such", "not found",
            "unknown identifier", "undeclared type",
            "reference to unknown", "cannot find")):
        return "ProposedSelfReferential"
    if any(s in lower for s in ("syntax error", "parse error",
                                 "unexpected", "lexeme")):
        return "SyntaxError"
    return "ProposedError"

with open(sys.argv[1]) as f:
    data = json.load(f)
per_id = {r["id"]: r["data"] for r in data}

fails = []

# Phase 1: per-entry success/error/classify
for case_id, (want_succ, want_err, want_cat, _) in EXPECTED.items():
    if case_id not in per_id:
        fails.append(f"{case_id}: missing from output")
        continue
    res = per_id[case_id]["result"]
    actual_succ = res.get("success")
    actual_err = res.get("error") or ""
    if actual_succ != want_succ:
        fails.append(f"{case_id}: expected success={want_succ}, got {actual_succ} (error={actual_err!r})")
        continue
    if want_err and want_err not in actual_err:
        fails.append(f"{case_id}: error missing {want_err!r}, got {actual_err!r}")
    if want_cat:
        actual_cat = classify_failure(actual_err)
        if actual_cat != want_cat:
            fails.append(f"{case_id}: classify expected {want_cat}, got {actual_cat} for error {actual_err!r}")

# Phase 2: AST consistency via printSource
if "final_source" not in per_id:
    fails.append("missing final_source GET")
else:
    src = per_id["final_source"]
    if not isinstance(src, str):
        src = src.get("source", "") if isinstance(src, dict) else str(src)
    for case_id, (want_succ, _, _, marker) in EXPECTED.items():
        if marker is None:
            continue
        present = marker in src
        if want_succ and not present:
            fails.append(f"{case_id}: marker {marker!r} expected in source but missing (insert failed?)")
        elif not want_succ and present:
            fails.append(f"{case_id}: marker {marker!r} should be absent (rejected) but present — AST polluted!")

if fails:
    print(f"FAIL — exec_add_funspec regression ({len(fails)} issues)")
    for f in fails:
        print(f"  {f}")
    sys.exit(1)

print(f"PASS — exec_add_funspec regression ({len(EXPECTED)} entries × (success + error + classify + AST))")
PY
