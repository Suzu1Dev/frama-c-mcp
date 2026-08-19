#!/usr/bin/env bash

set -euo pipefail

FC="${FRAMA_C:-$(command -v frama-c || echo ~/.opam/frama/bin/frama-c)}"
if [[ ! -x "$FC" ]]; then
    echo "frama-c not found; set FRAMA_C env var" >&2
    exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$HERE/payload-shapes.c" "$WORK/"
cat >"$WORK/batch.json" <<'JSON'
[
  {"kind":"GET","id":"cil","request":"plugins.ast-utils.getCilContext","data":"sum"},
  {"kind":"GET","id":"loop","request":"plugins.ast-utils.getLoopEffects","data":"sum"},
  {"kind":"GET","id":"contract","request":"plugins.ast-utils.getContractContext","data":"inc"},
  {"kind":"GET","id":"logic","request":"plugins.ast-utils.getLogicDeps","data":"inc"},
  {"kind":"GET","id":"rte","request":"plugins.ast-utils.getRteObligations","data":"divide"}
]
JSON

(cd "$WORK" && "$FC" -load-module ast_utils_plugin \
    -server-batch batch.json \
    -server-batch-output-dir . \
    payload-shapes.c >/dev/null 2>&1)

python3 - "$WORK/batch.out.json" <<'PY'
import json
import sys

fails = []
raw = json.load(open(sys.argv[1]))
data = {}
for entry in raw:
    case_id = entry.get("id")
    if not case_id:
        fails.append(f"entry without id: {entry!r}")
        continue
    if "data" not in entry:
        fails.append(f"{case_id}: missing data payload: {entry!r}")
        continue
    data[case_id] = entry.get("data")

for case_id in ["cil", "loop", "contract", "logic", "rte"]:
    if case_id not in data:
        fails.append(f"missing response id: {case_id}")

def want(cond, msg):
    if not cond:
        fails.append(msg)

def is_obj(value):
    return isinstance(value, dict)

def is_list(value):
    return isinstance(value, list)

cil = data.get("cil")
want(is_obj(cil), "cil: object payload")
if is_obj(cil):
    for key in ["name", "formals", "locals", "statements", "loops",
                "logic_labels", "function_acsl_attachment_points",
                "memory_accesses", "calls", "body"]:
        want(key in cil, f"cil: missing {key}")
    want(cil.get("name") == "sum", "cil: wrong function")
    want(is_list(cil.get("statements")), "cil: statements is not array")
    want(any(s.get("kind") == "loop" for s in cil.get("statements", [])
             if is_obj(s)), "cil: missing loop statement")

loops = data.get("loop")
want(is_list(loops) and loops, "loop: non-empty array payload")
if is_list(loops) and loops and is_obj(loops[0]):
    loop = loops[0]
    for key in ["stmt_id", "loc", "writes", "modified_vars", "callee_assigns"]:
        want(key in loop, f"loop: missing {key}")
    want(is_list(loop.get("writes")), "loop: writes is not array")
    want({"i", "s"}.issubset(set(loop.get("modified_vars", []))),
         "loop: modified vars missing i/s")

contract = data.get("contract")
want(is_obj(contract), "contract: object payload")
if is_obj(contract):
    for key in ["function", "callers", "callees", "unresolved_callees",
                "callee_resolution_complete"]:
        want(key in contract, f"contract: missing {key}")
    fn = contract.get("function")
    want(is_obj(fn), "contract: function is not object")
    if is_obj(fn):
        want(fn.get("function") == "inc", "contract: wrong function")
        spec = fn.get("contract")
        want(is_obj(spec), "contract: nested contract is not object")
        if is_obj(spec):
            want(is_list(spec.get("requires")), "contract: requires is not array")
            want(is_obj(spec.get("assigns")), "contract: assigns is not object")

logic = data.get("logic")
want(is_obj(logic), "logic: object payload")
if is_obj(logic):
    for key in ["function", "contract", "annotations"]:
        want(key in logic, f"logic: missing {key}")
    deps = logic.get("contract", {}).get("deps", {})
    preds = deps.get("logic_predicates", [])
    want(is_list(preds), "logic: predicates is not array")
    want(any(p.get("name") == "nonneg" for p in preds if is_obj(p)),
         "logic: missing nonneg predicate dependency")

rte = data.get("rte")
want(is_obj(rte), "rte: object payload")
if is_obj(rte):
    for key in ["function", "count", "obligations"]:
        want(key in rte, f"rte: missing {key}")
    obligations = rte.get("obligations", [])
    want(is_list(obligations) and obligations, "rte: obligations is empty")
    zero_kinds = {"division_by_zero", "div_by_zero"}
    want(any(o.get("kind") in zero_kinds for o in obligations
             if is_obj(o)), "rte: missing division_by_zero obligation")
    for i, obligation in enumerate(obligations):
        if not is_obj(obligation):
            fails.append(f"rte: obligation {i} is not object")
            continue
        for key in ["predicate", "sid", "loc", "rank", "annot_id", "kind",
                    "short_kind", "description", "text"]:
            want(key in obligation, f"rte: obligation {i} missing {key}")

if fails:
    print("FAIL - ast-utils payload shape regression")
    for fail in fails:
        print(f"  {fail}")
    sys.exit(1)

print("PASS - ast-utils payload shape regression")
PY
