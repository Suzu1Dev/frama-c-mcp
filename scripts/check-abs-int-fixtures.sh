#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
frama_c="${FRAMA_C_BIN:-frama-c}"
version="$("$frama_c" -version | awk '{print $1}')"

case "$version" in
31.0 | 33.0) ;;
*)
    echo "Unsupported Frama-C version: $version" >&2
    echo "Supported versions are 31.0 and 33.0." >&2
    exit 1
    ;;
esac

status=0

check_wp() {
    local name="$1"
    local file="$2"
    local expected_proved="$3"
    local expected_total="$4"
    local require_goal="$5"

    local out
    if ! out="$("$frama_c" -wp -wp-rte -wp-prover alt-ergo -wp-timeout 5 "$file" 2>&1)"; then
        echo "FAIL $name: Frama-C command failed" >&2
        echo "$out" >&2
        status=1
        return
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

    if [[ "$require_goal" == yes ]] &&
        ! printf '%s\n' "$out" | grep -q 'typed_abs_int_assert_rte_signed_overflow'; then
        echo "FAIL $name: missing signed-overflow goal" >&2
        echo "$out" >&2
        status=1
        return
    fi

    if [[ "$require_goal" == no ]] &&
        printf '%s\n' "$out" | grep -q 'typed_abs_int_assert_rte_signed_overflow'; then
        echo "FAIL $name: fixed fixture still reports signed-overflow goal" >&2
        echo "$out" >&2
        status=1
        return
    fi

    echo "ok $name: $proved / $total"
}

check_wp "abs-int-buggy.c" "$root/tests/fixtures/abs-int-buggy.c" 9 10 yes
check_wp "abs-int-fixed.c" "$root/tests/fixtures/abs-int-fixed.c" 14 14 no

# The WP half above proves the fixtures still differ. This half proves `check`
# says so, which is a separate claim: the buggy fixture returned `incomplete`
# for a whole release while its overflow alarm was missing from `incomplete[]`
# and the verdict came entirely from dead-code demotion. Assert the reason, not
# the verdict.
check_mcp() {
    local name="$1"
    local file="$2"
    local expectation="$3"
    local binary="$root/target/release/frama-c-mcp"

    if [[ ! -x "$binary" ]]; then
        echo "SKIP $name (MCP): $binary not built" >&2
        return
    fi

    # stdout only. `check` prints JSON there, and folding stderr in would turn
    # any future log line into a parse failure reported as a fixture regression.
    local out
    if ! out="$("$binary" check "$file")"; then
        echo "FAIL $name (MCP): check failed" >&2
        echo "$out" >&2
        status=1
        return
    fi

    if ! printf '%s' "$out" | EXPECT="$expectation" python3 -c '
import json, os, sys

payload = json.load(sys.stdin)
verdict = payload.get("verdict")
incomplete = payload.get("incomplete") or []
codes = [item.get("code") for item in incomplete]

if os.environ["EXPECT"] == "buggy":
    if verdict != "incomplete":
        sys.exit(f"verdict is {verdict}, expected incomplete")
    if not any(
        item.get("code") == "ALARM_NOT_VALID"
        and "signed_overflow" in (item.get("descr") or "")
        for item in incomplete
    ):
        sys.exit(f"no ALARM_NOT_VALID naming signed_overflow; got {codes}")
else:
    if verdict != "proved":
        sys.exit(f"verdict is {verdict}, expected proved; incomplete {codes}")
    if incomplete:
        sys.exit(f"expected an empty incomplete[], got {codes}")
'; then
        echo "FAIL $name (MCP)" >&2
        status=1
        return
    fi

    echo "ok $name (MCP)"
}

check_mcp "abs-int-buggy.c" "$root/tests/fixtures/abs-int-buggy.c" buggy
check_mcp "abs-int-fixed.c" "$root/tests/fixtures/abs-int-fixed.c" fixed

exit "$status"
