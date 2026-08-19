#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
frama_c="${FRAMA_C_BIN:-frama-c}"
version="$("$frama_c" -version | awk '{print $1}')"

case "$version" in
31.0 | 33.0) ;;
*)
    echo "Unsupported tutorial corpus Frama-C version: $version" >&2
    echo "Supported versions are 31.0 and 33.0." >&2
    exit 1
    ;;
esac

status=0

# The Frama-C version guard above does not pin the prover, and the prover is
# what moves these numbers: CI picks it with `why3 config detect`, and locally
# ~/.why3.conf sits outside ~/.opam and is shared by every switch. So assert the
# version the rows were measured under. An Alt-Ergo change then fails here
# saying so, instead of silently shifting every baseline.
expected_prover="Alt-Ergo 2.6.3"
prover_seen=0

# Measured 2026-08-10 on both switches with -wp-cache none, and identical on
# both, which is why there is one table rather than one per Frama-C version. The
# prover moves these numbers and `expected_prover` above pins it; the Frama-C
# version does not. If a future version ever does move a row, add a `case
# "$version:$name"` arm above the shared table rather than duplicating all
# eleven again.
expected_baseline() {
    local name="$1"
    case "$name" in
    swap-frame.c) echo "57 57 5" ;;
    abs-behaviors.c) echo "15 16 5" ;;
    triangle-behaviors.c) echo "43 43 10" ;;
    loops.c) echo "46 46 5" ;;
    bsearch.c) echo "27 27 5" ;;
    ghost-code.c) echo "20 20 5" ;;
    count-logic.c) echo "13 15 5" ;;
    sort-permutation.c) echo "33 33 5" ;;
    verker-string.c) echo "31 42 5" ;;
    linked-n.c) echo "14 20 5" ;;
    modular-group) echo "28 28 5" ;;
    *)
        echo "Missing tutorial corpus baseline for fixture $name" >&2
        exit 1
        ;;
    esac
}

check_wp() {
    local name="$1"
    shift
    local expected_proved expected_total timeout
    read -r expected_proved expected_total timeout < <(expected_baseline "$name")

    local out

    # WP caches prover verdicts across runs, so without -wp-cache none a rerun
    # replays the previous run's numbers and the gate checks nothing.
    if ! out="$("$frama_c" -wp -wp-rte -wp-prover alt-ergo -wp-cache none -wp-timeout "$timeout" "$@" 2>&1)"; then
        echo "FAIL $name: Frama-C command failed" >&2
        echo "$out" >&2
        status=1
        return
    fi

    # WP lists a prover only for the goals it actually ran, so a fixture Qed
    # discharged on its own prints no such row and cannot be required to name
    # one; the run-wide check below catches a run where no fixture named any.
    local prover
    prover="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*(Alt-Ergo [0-9.]+):.*/\1/p' | tail -1 || true)"
    if [[ -n "$prover" ]]; then
        prover_seen=1
        if [[ "$prover" != "$expected_prover" ]]; then
            echo "FAIL $name: baselines were measured under $expected_prover, got $prover" >&2
            echo "Re-measure every row before changing expected_prover." >&2
            status=1
            return
        fi
    fi

    local line proved total
    line="$(printf '%s\n' "$out" | grep -E 'Proved goals:[[:space:]]+[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | tail -1 || true)"
    if [[ -z "$line" ]]; then
        echo "FAIL $name: missing WP proved-goals summary" >&2
        echo "$out" >&2
        status=1
        return
    fi

    proved="$(printf '%s\n' "$line" | sed -E 's/.*Proved goals:[[:space:]]*([0-9]+)[[:space:]]*\/[[:space:]]*([0-9]+).*/\1/')"
    total="$(printf '%s\n' "$line" | sed -E 's/.*Proved goals:[[:space:]]*([0-9]+)[[:space:]]*\/[[:space:]]*([0-9]+).*/\2/')"

    if [[ "$proved" != "$expected_proved" || "$total" != "$expected_total" ]]; then
        echo "FAIL $name: expected $expected_proved / $expected_total, got $proved / $total" >&2
        echo "$out" >&2
        status=1
        return
    fi

    if [[ "$expected_proved" -eq "$expected_total" && "$total" -eq 0 ]]; then
        echo "FAIL $name: zero-goal fully-proved result is not a valid shape gate" >&2
        status=1
        return
    fi

    echo "ok $name: $proved / $total"
}

fixture="$root/tests/fixtures/tutorial"

check_wp "swap-frame.c" "$fixture/swap-frame.c"
check_wp "abs-behaviors.c" "$fixture/abs-behaviors.c"
check_wp "triangle-behaviors.c" "$fixture/triangle-behaviors.c"
check_wp "loops.c" "$fixture/loops.c"
check_wp "bsearch.c" "$fixture/bsearch.c"
check_wp "ghost-code.c" "$fixture/ghost-code.c"
check_wp "count-logic.c" "$fixture/count-logic.c"
check_wp "sort-permutation.c" "$fixture/sort-permutation.c"
check_wp "verker-string.c" "$fixture/verker-string.c"
check_wp "linked-n.c" "$fixture/linked-n.c"
check_wp "modular-group" \
    "$fixture/mod-max-abs.c" \
    "$fixture/mod-abs.c" \
    "$fixture/mod-max.c"

echo "skip eva-rotate.c: EVA fixture, not a WP baseline"

if [[ "$prover_seen" -eq 0 ]]; then
    echo "FAIL: no fixture reported a prover version, so nothing checked which one ran" >&2
    status=1
fi

exit "$status"
