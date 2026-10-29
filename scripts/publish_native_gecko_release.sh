#!/bin/bash
# Publish a Firefox Gecko native IPA as a GitHub prerelease with a changelog.
#
# Usage: publish_native_gecko_release.sh <ipa> <build-number> <commit-sha> [missing-files.txt]
#
# The tag is native-gecko-159.0-build-<N>, the asset keeps the build number in
# its file name, and the notes are option2/RELEASE_NOTES.md, any Gecko files
# the build lacks, and the commits since the previous native-gecko release.
# Safe to re-run: an existing release just gets the asset re-uploaded.
#
# The tag goes on the default branch, not on the build commit: GitHub refuses
# (403) to let the Actions token create a tag on a commit whose workflow files
# differ from the default branch. The build commit is recorded in the notes
# and used for the changelog.
# Needs GH_TOKEN and GITHUB_REPOSITORY.

set -uo pipefail

ipa="$1"
build="$2"
sha="$3"
missing="${4:-}"
repo="$GITHUB_REPOSITORY"
tag="native-gecko-159.0-build-${build}"
notes=$(mktemp)

fail() {
  echo "error: publishing $tag failed: $*" >&2
  exit 1
}

[ -s "$ipa" ] || fail "IPA not found at $ipa"
case "$(basename "$ipa")" in
  *"-build-${build}.ipa") ;;
  *) fail "IPA name $(basename "$ipa") does not carry build ${build}" ;;
esac

# The previous native release's build commit, from its notes marker.
previous=$(gh api "repos/$repo/releases?per_page=100" \
  --jq '[.[] | select(.tag_name | startswith("native-gecko-")) | select(.tag_name != "'"$tag"'")][0].body // ""' \
  | sed -n 's/.*<!-- source-sha:\([0-9a-f]\{7,40\}\) -->.*/\1/p' | head -n 1) \
  || fail "could not list releases"
default_branch=$(gh api "repos/$repo" --jq .default_branch) || fail "could not read the default branch"

{
  cat option2/RELEASE_NOTES.md
  echo
  if [ -n "$missing" ] && [ -s "$missing" ]; then
    echo "## Gecko files missing from this build"
    echo "These generated Gecko files were not in the cached engine, so this build lacks them:"
    sed 's/^/- /' "$missing"
    echo
  fi
  echo "Built from commit ${sha:0:7} on the firefox-native-gecko branch."
  echo
  echo "## Changes in build ${build}"
  if [ -n "$previous" ]; then
    gh api "repos/$repo/compare/${previous}...${sha}" \
      --jq '.commits[] | "- " + (.commit.message | split("\n")[0]) + " (" + .sha[0:7] + ")"'
  else
    gh api "repos/$repo/commits?sha=${sha}&per_page=12" \
      --jq '.[] | "- " + (.commit.message | split("\n")[0]) + " (" + .sha[0:7] + ")"'
  fi
  echo
  echo "<!-- source-sha:${sha} -->"
} > "$notes" || fail "could not build the changelog"
echo "----- release notes -----"
cat "$notes"
echo "-------------------------"

if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  echo "Release $tag exists; re-uploading the IPA"
else
  if ! output=$(gh release create "$tag" --repo "$repo" --target "$default_branch" \
      --title "Firefox Gecko native 159.0 (build ${build})" \
      --notes-file "$notes" --prerelease --latest=false 2>&1); then
    fail "gh release create: $(echo "$output" | tr '\n' ' ')"
  fi
  echo "$output"
fi
if ! output=$(gh release upload "$tag" "$ipa" --repo "$repo" --clobber 2>&1); then
  fail "uploading $(basename "$ipa"): $(echo "$output" | tr '\n' ' ')"
fi
echo "Published https://github.com/$repo/releases/tag/$tag"
