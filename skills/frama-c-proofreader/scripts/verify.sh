#!/usr/bin/env bash
set -euo pipefail

skillDir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
framaC="${FRAMA_C_BIN:-$(command -v frama-c || true)}"
eacsl="${EACSL_BIN:-$(command -v e-acsl-gcc.sh || command -v e-acsl-gcc || true)}"
failed=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failed=1
}
skip() { printf 'SKIP: %s\n' "$1"; }

if command -v npx >/dev/null 2>&1; then
    npx --yes skills-ref validate "$skillDir"
else
    skip "npx not found; skill shape validation skipped"
fi

if [ -z "$framaC" ]; then
    fail "frama-c not found; set FRAMA_C_BIN"
else
    "$framaC" -version
    buggyOut="$("$framaC" -wp -wp-rte "$skillDir/examples/abs-int/abs-buggy.c" 2>&1 || true)"
    if printf '%s\n' "$buggyOut" | grep -q 'typed_abs_int_assert_rte_signed_overflow' &&
        printf '%s\n' "$buggyOut" | grep -qE 'Proved goals:[[:space:]]*9[[:space:]]*/[[:space:]]*10'; then
        pass "WP reports abs-buggy signed-overflow proof gap"
    else
        printf '%s\n' "$buggyOut" >&2
        fail "WP output for abs-buggy changed"
    fi

    fixedOut="$("$framaC" -wp -wp-rte "$skillDir/examples/abs-int/abs-fixed.c" 2>&1 || true)"
    if printf '%s\n' "$fixedOut" | grep -qE 'Proved goals:[[:space:]]*14[[:space:]]*/[[:space:]]*14'; then
        pass "WP proves abs-fixed"
    else
        printf '%s\n' "$fixedOut" >&2
        fail "WP output for abs-fixed changed"
    fi
fi

if [ -z "$eacsl" ]; then
    skip "E-ACSL compiler not found"
else
    workDir="$(mktemp -d)"
    trap 'rm -rf "$workDir"' EXIT
    cp "$skillDir/examples/abs-int/abs-buggy.c" "$workDir/abs-buggy.c"
    set +e
    compileOut="$(cd "$workDir" && "$eacsl" abs-buggy.c 2>&1)"
    compileStatus=$?
    set -e
    if [ "$compileStatus" -ne 0 ]; then
        printf '%s\n' "$compileOut"
        skip "E-ACSL instrumentation failed in this environment"
    elif [ -x "$workDir/a.out.e-acsl" ]; then
        set +e
        runOut="$(cd "$workDir" && ./a.out.e-acsl 2>&1)"
        runStatus=$?
        set -e
        if printf '%s\n' "$runOut" | grep -q 'Postcondition failed' && [ "$runStatus" -ne 0 ]; then
            pass "E-ACSL finds abs-buggy runtime violation"
        else
            printf '%s\n' "$runOut" >&2
            fail "E-ACSL run did not report the expected violation"
        fi
    else
        skip "E-ACSL did not produce a.out.e-acsl"
    fi
fi

exit "$failed"
