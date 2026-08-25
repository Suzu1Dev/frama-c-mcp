#!/usr/bin/env bash

# Two fixtures whose point is that WP answers FAILED or TIMEOUT for a reason
# that is not a wrong specification, and that the server has to keep telling
# those apart from one. Both are computed rather than replayed: -wp-cache none
# on every run, because a verdict off the cache proves nothing about the
# toolchain this checkout has.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
frama_c="${FRAMA_C_BIN:-frama-c}"
version="$("$frama_c" -version | awk '{print $1}')"

case "$version" in
    33.0) ;;
    *)
        echo "Unsupported Frama-C version: $version" >&2
        echo "The verdicts below are pinned to 33.0." >&2
        exit 1
        ;;
esac

status=0

# The version guard above pins Frama-C and not the prover, and the prover is
# what moves the counts below: 3 / 6 and three [Timeout] rows are facts about
# what Alt-Ergo could not discharge, not about Frama-C. CI picks the prover with
# `why3 config detect`, and locally ~/.why3.conf sits outside ~/.opam and is
# shared by every switch. Without this, an Alt-Ergo upgrade that closes one of
# those three goals reports "expected 3 / 6" with nothing pointing at the cause.
# check-tutorial-corpus.sh pins its prover for exactly this reason; this script
# took the style of assertion and, until now, left the guard behind.
expected_prover="Alt-Ergo 2.6.3"
prover_seen=0

check_prover()
{
    local out="$1"
    local name="$2"
    local seen
    seen="$(printf '%s\n' "$out" | grep -oE 'Alt-Ergo [0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    [[ -z "$seen" ]] && return 0
    prover_seen=1
    if [[ "$seen" != "$expected_prover" ]]; then
        echo "FAIL $name: prover is $seen, the counts here were measured under $expected_prover" >&2
        status=1
    fi
}

wp()
{
    "$frama_c" -wp -wp-model "$1" -wp-prover alt-ergo -wp-timeout 10 \
        -wp-cache none "$2" 2>&1
}

# The cast reaches the goal, so Typed+nocast does not fail safely: Why3 aborts
# and WP stamps the goal FAILED with no prover having answered. The same
# contract proves under Typed+cast. If a Frama-C or Why3 upgrade fixes the
# abort, this fails, which is the point: the server's whole wp_backend_diagnosis
# path exists for a defect that is meant to go away one day.
anomaly_fixture="$root/tests/fixtures/pointer-cast-anomaly.c"

nocast_out="$(wp 'Typed+nocast' "$anomaly_fixture" || true)"
if ! printf '%s\n' "$nocast_out" | grep -q 'Why3 Error\] anomaly'; then
    echo "FAIL pointer-cast-anomaly.c: no Why3 anomaly under Typed+nocast" >&2
    printf '%s\n' "$nocast_out" >&2
    status=1
elif ! printf '%s\n' "$nocast_out" | grep -q '\[Failure\] typed_nocast_nextblk_ensures'; then
    echo "FAIL pointer-cast-anomaly.c: anomaly left no FAILED goal" >&2
    printf '%s\n' "$nocast_out" >&2
    status=1
else

    # The attribution the server relies on. WP names a goal kind here, never a
    # goal, so the FAILED status above is the only link from the abort to the
    # obligation it cost. wp_backend_anomaly_left_goal_unjudged reads that
    # status for exactly this reason; a matcher over the message text would have
    # nothing to match.
    if ! printf '%s\n' "$nocast_out" | grep -q 'Goal Property:'; then
        echo "FAIL pointer-cast-anomaly.c: abort no longer worded 'Goal <kind>:'" >&2
        printf '%s\n' "$nocast_out" >&2
        status=1
    else
        echo "ok pointer-cast-anomaly.c: Typed+nocast aborts Why3 and fails one goal"
    fi
fi

cast_out="$(wp 'Typed+cast' "$anomaly_fixture" || true)"
check_prover "$cast_out" "pointer-cast-anomaly.c"
proved_goals()
{
    printf '%s\n' "$1" \
        | sed -nE 's/.*Proved goals:[[:space:]]*([0-9]+)[[:space:]]*\/[[:space:]]*([0-9]+).*/\1 \/ \2/p' \
        | tail -1
}
cast_counts="$(proved_goals "$cast_out")"
if [[ "$cast_counts" != "4 / 4" ]]; then
    echo "FAIL pointer-cast-anomaly.c: Typed+cast expected 4 / 4, got ${cast_counts:-no summary line}" >&2
    printf '%s\n' "$cast_out" >&2
    status=1
else
    echo "ok pointer-cast-anomaly.c: Typed+cast proves 4 / 4"
fi

# Every postcondition is true and none is provable: WP encodes bitwise-or on
# machine integers as an uninterpreted function, so nothing connects ((x - 1) |
# (align - 1)) + 1 to a multiple of align. A timeout here is the encoding, not
# the budget, which is why the server must not answer it with "raise the
# timeout".
operator_out="$(wp 'Typed' "$root/tests/fixtures/uninterpreted-operator.c" || true)"
check_prover "$operator_out" "uninterpreted-operator.c"
operator_counts="$(proved_goals "$operator_out")"
if [[ "$operator_counts" != "3 / 6" ]]; then
    echo "FAIL uninterpreted-operator.c: expected 3 / 6, got ${operator_counts:-no summary line}" >&2
    printf '%s\n' "$operator_out" >&2
    status=1
elif [[ "$(printf '%s\n' "$operator_out" | grep -c '\[Timeout\] typed_align_up_ensures')" != 3 ]]; then
    echo "FAIL uninterpreted-operator.c: expected three timed-out ensures goals" >&2
    printf '%s\n' "$operator_out" >&2
    status=1
else
    echo "ok uninterpreted-operator.c: 3 / 6, three ensures time out"
fi

# The Frama-C half above proves the abort still happens. This half proves the
# server turns it into the right payload, which is a separate claim and the one
# that regressed: an earlier gate matched goal identifiers against the anomaly
# text, and since WP names a goal kind there and never a goal, the code below
# was unreachable on every real run while three documents said otherwise.
check_mcp_anomaly()
{
    local binary="$root/target/release/frama-c-mcp"

    if [[ ! -x "$binary" ]]; then
        echo "SKIP pointer-cast-anomaly.c (MCP): $binary not built" >&2
        return
    fi

    # stdout only, as in check-abs-int-fixtures.sh: check prints JSON there and
    # folding stderr in turns a future log line into a parse failure reported as
    # a fixture regression.
    local out
    if ! out="$("$binary" check "$anomaly_fixture")"; then
        echo "FAIL pointer-cast-anomaly.c (MCP): check failed" >&2
        echo "$out" >&2
        status=1
        return
    fi

    if ! printf '%s' "$out" | python3 -c '
import json, sys

payload = json.load(sys.stdin)

diagnosis = payload.get("wp_backend_diagnosis")
if not diagnosis:
    sys.exit("wp_backend_diagnosis is null; the abort was not read off the stream")
if diagnosis.get("kind") != "why3_anomaly_with_pointer_cast":
    sys.exit("diagnosis kind is " + str(diagnosis.get("kind")))
if not diagnosis.get("cast_warning_lines"):
    sys.exit("no cast warning lines, so the pointer-cast case was not recognised")

codes = [item.get("code") for item in (payload.get("incomplete") or [])]
if "WP_BACKEND_ANOMALY" not in codes:
    sys.exit(f"no WP_BACKEND_ANOMALY in incomplete[]; got {codes}")

# The abort must displace the recommendation. Reading a VC no prover received
# sends the caller to rewrite an annotation that was never judged.
call = payload.get("recommended_next_call") or {}
if call.get("tool") != "run_wp" or call.get("args", {}).get("model") != "Typed+cast":
    sys.exit(f"recommendation does not route to Typed+cast: {call}")
'; then
        echo "FAIL pointer-cast-anomaly.c (MCP)" >&2
        status=1
        return
    fi

    echo "ok pointer-cast-anomaly.c (MCP): anomaly reported and routed to Typed+cast"
}

check_mcp_anomaly

# A silent pin is not a pin. If no run reported a version, the guard above never
# compared anything and the counts are unattributed.
if [[ "$prover_seen" -eq 0 ]]; then
    echo "FAIL: no run reported a prover version, so $expected_prover went unverified" >&2
    status=1
fi

exit "$status"
