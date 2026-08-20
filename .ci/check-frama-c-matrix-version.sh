#!/usr/bin/env bash

# The matrix value is a supported one, checked before ten minutes of opam
# install rather than after. Usage: check-frama-c-matrix-version.sh <version>

set -eu

version=${1:?expected a Frama-C version}

case "$version" in
33.0) ;;
*)
    echo "Unsupported Frama-C CI version: $version" >&2
    echo "Supported smoke-test version is 33.0." >&2
    exit 1
    ;;
esac
