#!/bin/bash
# Publish a Firefox Gecko native IPA as a GitHub prerelease with a changelog.
#
# Usage: publish_native_gecko_release.sh <ipa> <build-number> <commit-sha> [missing-files.txt]
#
# The tag is native-gecko-159.0-build-<N>, the asset keeps the build number in
# its file name, and the notes are option2/RELEASE_NOTES.md, any Gecko files
# the build lacks, and the commits since the previous native-gecko release.
# Safe to re-run: an existing release just gets the asset re-uploaded.
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

previous=$(gh api "repos/$repo/releases?per_page=100" \
  --jq '[.[] | select(.tag_name | startswith("native-gecko-")) | select(.tag_name != "'"$tag"'")][0].target_commitish // empty') \
  || fail "could not list releases"

{
  cat option2/RELEASE_NOTES.md
  echo
  if [ -n "$missing" ] && [ -s "$missing" ]; then
    echo "## Gecko files missing from this build"
    echo "These generated Gecko files were not in the cached engine, so this build lacks them:"
    sed 's/^/- /' "$missing"
    echo
  fi
  echo "## Changes in build ${build}"
  if [ -n "$previous" ]; then
    gh api "repos/$repo/compare/${previous}...${sha}" \
      --jq '.commits[] | "- " + (.commit.message | split("\n")[0]) + " (" + .sha[0:7] + ")"'
  else
    gh api "repos/$repo/commits?sha=${sha}&per_page=12" \
      --jq '.[] | "- " + (.commit.message | split("\n")[0]) + " (" + .sha[0:7] + ")"'
  fi
} > "$notes" || fail "could not build the changelog"
echo "----- release notes -----"
cat "$notes"
echo "-------------------------"

if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  echo "Release $tag exists; re-uploading the IPA"
else
  gh release create "$tag" --repo "$repo" --target "$sha" \
    --title "Firefox Gecko native 159.0 (build ${build})" \
    --notes-file "$notes" --prerelease --latest=false \
    || fail "gh release create returned $?"
fi
gh release upload "$tag" "$ipa" --repo "$repo" --clobber || fail "uploading $(basename "$ipa") returned $?"
echo "Published https://github.com/$repo/releases/tag/$tag"
