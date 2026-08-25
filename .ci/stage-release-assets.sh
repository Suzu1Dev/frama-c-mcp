#!/usr/bin/env bash

# Name every asset rather than counting them. A bare count passes when a target
# is renamed or swapped for another, which publishes the wrong set under a name
# users are told to trust, and these names are what README documents. The list
# duplicates the build matrix on purpose: Actions has no YAML anchors, and
# threading the targets through a setup job's fromJSON output buys one less
# duplicated line at the cost of a whole extra job. A rename fails here rather
# than shipping quietly, and released_tarball_names_match_the_build_matrix
# covers the copy in README, which this script cannot see.
#
# Runs before anything is deleted, so a missing artifact fails while the old
# release is still up.

set -eu

expected=(
    frama-c-mcp-x86_64-unknown-linux-gnu.tar.gz
    frama-c-mcp-aarch64-apple-darwin.tar.gz
)

shopt -s nullglob
found=(dist/*.tar.gz)
missing=()
for name in "${expected[@]}"; do
    [ -f "dist/$name" ] || missing+=("$name")
done
if [ ${#missing[@]} -ne 0 ] || [ ${#found[@]} -ne ${#expected[@]} ]; then
    echo "release assets do not match the expected set" >&2
    echo "  missing: ${missing[*]:-none}" >&2
    echo "  found:   ${found[*]:-none}" >&2
    exit 1
fi
printf 'dist/%s\n' "${expected[@]}" > assets.txt
