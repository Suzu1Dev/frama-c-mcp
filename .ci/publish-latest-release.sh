#!/usr/bin/env bash

# Delete and recreate rather than upload --clobber: the "latest" tag has to move
# to the commit that produced these binaries, and no gh invocation repoints an
# existing tag. That leaves a window where the release is gone and its
# replacement does not exist yet, which drives the care below.
#
# Reads the HTTP status rather than branching on gh's exit code. gh exits
# nonzero for every HTTP failure alike, so "if gh ... ; then" reads a 500, a
# revoked token or a DNS blip as "no release here" and walks straight into the
# deletions below. Only 200 and 404 are answers; anything else is an unknown
# state, and deleting from an unknown state is how the tag of a live release
# gets removed.
#
# Expects GH_TOKEN, GH_REPO, GITHUB_SHA in the environment and assets.txt on
# disk, as written by stage-release-assets.sh.

set -eu

status_of() {
    gh api "$1" --silent -i 2>/dev/null | head -1 | awk '{print $2}'
}
require_answer() {
    case "$1" in
    200 | 404) return 0 ;;
    esac
    echo "unexpected status '${1:-none}' querying $2, aborting before any deletion" >&2
    exit 1
}

release_status=$(status_of "repos/$GH_REPO/releases/tags/latest")
require_answer "$release_status" "the latest release"
if [ "$release_status" = 200 ]; then
    # No --cleanup-tag. It deletes the release first and then errors if the
    # tag is already gone, which is the state left by a previous run that died
    # between the two steps, or by someone deleting the tag in the web UI. Under
    # set -e that ends the run with the release destroyed and no replacement
    # published, which is the one outcome this script is arranged to avoid. The
    # explicit tag check below removes the tag, and tolerates it being absent.
    gh release delete latest --yes
fi

# The tag can outlive the release: deleting a release in the web UI leaves its
# tag behind, and so does a run that got as far as the delete and then failed.
# "gh release create" ignores --target when the tag already exists (the API
# documents target_commitish as unused in that case), so a stale "latest" tag
# would publish these binaries under a release pointing at an older commit.
#
# Queried after the delete above rather than before it, so the answer describes
# the state the create below will meet.
tag_status=$(status_of "repos/$GH_REPO/git/ref/tags/latest")
require_answer "$tag_status" "the latest tag"
if [ "$tag_status" = 200 ]; then
    gh api -X DELETE "repos/$GH_REPO/git/refs/tags/latest" >/dev/null
fi

# A read loop rather than mapfile, which is bash 4 and absent from the bash 3.2
# macOS still ships. This script is documented as runnable by hand, and failing
# here would leave the release deleted and unpublished.
assets=()
while IFS= read -r asset; do
    [ -n "$asset" ] && assets+=("$asset")
done <assets.txt
gh release create latest "${assets[@]}" \
    --target "$GITHUB_SHA" \
    --title "latest" \
    --notes "Automated build of ${GITHUB_SHA:0:7} on $(date -u +%Y-%m-%d). The ast-utils Frama-C plugin is not included; build it from source in your opam switch."
