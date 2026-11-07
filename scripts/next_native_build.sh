#!/bin/bash
# Print the next free Firefox Gecko (Native UI) build number.
#
# Engine builds used to take github.run_number while quick repackages picked
# numbers by hand, so the two could publish over each other's release tag.
# Both now take one more than the highest number already used by a
# native-gecko release or by any engine workflow run (including runs still
# queued, which may publish under their run number).
# Needs GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail
repo="$GITHUB_REPOSITORY"
releases=$(gh api "repos/$repo/releases?per_page=100" \
  --jq '.[] | select(.tag_name | startswith("native-gecko-159.0-build-")) | .tag_name | sub("native-gecko-159.0-build-"; "")')
runs=$(gh api "repos/$repo/actions/workflows/build-gecko-dev-framework.yml/runs?per_page=20" \
  --jq '.workflow_runs[].run_number')
max=0
for n in $releases $runs; do
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > max )) && max=$n
done
echo $((max + 1))
