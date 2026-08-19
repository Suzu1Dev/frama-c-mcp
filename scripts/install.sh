#!/usr/bin/env bash

# Build frama-c-mcp and ast-utils, then install the plugin into the active opam
# switch and the binary into BINDIR (default ~/.local/bin). Run this from the
# switch that contains Frama-C.
#
# Overwriting the destination in place is what breaks this on macOS: once a
# binary has been executed the kernel holds a validated code-signature blob on
# that vnode, so a new image written over the same path is checked against a
# blob describing bytes that are no longer there. Page validation then fails at
# fault-in and every exec dies with SIGKILL (Code Signature Invalid). Install to
# a temp name in the same directory, ad-hoc sign it there, then rename over the
# target so the destination gets a fresh inode with no blob attached.
set -euo pipefail

BINDIR=${BINDIR:-$HOME/.local/bin}
BINDIR=${BINDIR%/}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Both halves are built before either is installed, so a Rust compile error does
# not leave a freshly installed plugin paired with the previous binary.
cargo build --release --manifest-path "$ROOT/Cargo.toml"

# Through "opam exec", not a bare dune: dune resolves Frama-C through the opam
# switch rather than through PATH, so an unwrapped invocation compiles and
# installs the plugin against whichever switch happens to be active.
(
    cd "$ROOT/ast-utils"
    # Clean first because an incremental build may not relink the .cmxs, which
    # installs the old plugin under a new timestamp and looks like a no-op change.
    opam exec -- dune clean
    opam exec -- dune build
    opam exec -- dune install
)

# The plugin's own option only parses once the .cmxs has loaded, so this fails
# when the install landed in a switch this frama-c does not read. Without it the
# mismatch first shows up as MCP tools failing at run time for no stated reason.
if ! opam exec -- frama-c -ast-utils-h >/dev/null 2>&1; then
    echo "error: ast-utils is not loadable by frama-c in this switch" >&2
    exit 1
fi

mkdir -p "$BINDIR"
tmp=$(mktemp "$BINDIR/frama-c-mcp.XXXXXX")

# INT TERM HUP as well as EXIT: bash does not run an EXIT trap on a signal in a
# non-interactive shell, so a Ctrl-C during the sign or smoke step below would
# otherwise leave an executable temp file sitting in the user's bin directory.
trap 'rm -f "$tmp"' EXIT INT TERM HUP

cp "$ROOT/target/release/frama-c-mcp" "$tmp"
chmod 755 "$tmp"
if command -v codesign >/dev/null 2>&1; then
    codesign -f -s - "$tmp"
fi

# Prove the image runs before it becomes the installed one. This is what turns a
# signature failure into an install-time error rather than an MCP client
# reporting an unexplained connection failure later.
if ! "$tmp" --help >/dev/null; then
    echo "error: built binary failed to run, not installing" >&2
    exit 1
fi

# Cleared before the rename, not after: past this point "$tmp" names the
# installed file, so any later failure would fire the trap and delete the thing
# just installed.
trap - EXIT INT TERM HUP
mv -f "$tmp" "$BINDIR/frama-c-mcp"
echo "installed $BINDIR/frama-c-mcp"
