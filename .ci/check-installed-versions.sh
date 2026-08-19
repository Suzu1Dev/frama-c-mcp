#!/usr/bin/env bash

# The switch holds the Frama-C and Alt-Ergo this lane's numbers were measured
# under. Usage: check-installed-versions.sh <expected-frama-c-version>

set -eu

expected=${1:?expected a Frama-C version}

version="$(opam exec -- frama-c -version)"
case "$version" in
"$expected"*) ;;
*)
    echo "Expected Frama-C $expected, got: $version" >&2
    exit 1
    ;;
esac

# Checked here as well as inside the corpus gate, because the gate reads the
# version out of WP's own output and so can only report it after a fixture has
# run. This says which binary is installed, before anything is proved.
prover="$(opam exec -- alt-ergo --version)"
case "$prover" in
v2.6.3 | 2.6.3) ;;
*)
    echo "Expected Alt-Ergo 2.6.3, got: ${prover:-nothing}" >&2
    echo "scripts/check-tutorial-corpus.sh baselines are keyed to that version." >&2
    exit 1
    ;;
esac
