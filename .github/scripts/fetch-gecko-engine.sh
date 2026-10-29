#!/bin/bash
# Find a Gecko engine archive that an earlier run of this workflow already
# compiled, so a push never pays for a second multi-hour Gecko build.
#
# Usage: fetch-gecko-engine.sh <engine-key> <reynard-ref> <output-dir> [<content-key>]
#
# Looks, in order, at: the Reynard fork's "gecko-engine" release (engines its
# nightly builds already compiled, matched by content key), then engine
# artifacts from earlier runs of this workflow, then waits for an older run
# that is still compiling.
#
# Writes <output-dir>/gecko-engine-dist.tar.gz and prints found=true to
# $GITHUB_OUTPUT on success. Never fails the job: on any problem it prints
# found=false and the workflow falls back to compiling.

set -uo pipefail

KEY="$1"
REYNARD_REF="$2"
OUT="$3"
CONTENT_KEY="${4:-}"
ENGINE_REPO="${ENGINE_REPO:-soum91/reynard-browser}"
ENGINE_TAG="gecko-engine"
ARTIFACT="Gecko-iOS-arm64-compiled-engine-dist"
REPO="$GITHUB_REPOSITORY"
MAX_WAIT_MINUTES="${MAX_WAIT_MINUTES:-150}"
POLL_SECONDS=180

mkdir -p "$OUT"
echo "Looking for Gecko engine $KEY (Reynard $REYNARD_REF)"

finish() {
  echo "found=$1" >> "$GITHUB_OUTPUT"
  exit 0
}

# An archive is usable only if its embedded key matches this run's key.
try_artifacts() {
  local runs run_id tmp archive embedded
  runs=$(gh api "repos/$REPO/actions/artifacts?name=$ARTIFACT&per_page=30" \
    --jq '.artifacts[] | select(.expired == false) | .workflow_run.id' 2>/dev/null) || return 1
  for run_id in $runs; do
    [ "$run_id" = "$GITHUB_RUN_ID" ] && continue
    tmp=$(mktemp -d)
    echo "Trying engine artifact from run $run_id"
    if ! gh run download "$run_id" -R "$REPO" -n "$ARTIFACT" -D "$tmp"; then
      rm -rf "$tmp"; continue
    fi
    archive="$tmp/gecko-engine-dist.tar.gz"
    if [ ! -s "$archive" ]; then rm -rf "$tmp"; continue; fi
    embedded=$(tar -xzOf "$archive" reynard-engine-key.txt 2>/dev/null || true)
    # Only keyed archives: unkeyed ones predate v2 and keep dangling links.
    if [ "$embedded" != "$KEY" ]; then
      echo "Run $run_id was built for ${embedded:-an unkeyed v1 engine}, need $KEY"
      rm -rf "$tmp"; continue
    fi
    mv "$archive" "$OUT/gecko-engine-dist.tar.gz"
    rm -rf "$tmp"
    echo "Reusing Gecko engine compiled by run $run_id"
    return 0
  done
  return 1
}

try_release() {
  [ -n "$CONTENT_KEY" ] || return 1
  local tmp archive embedded expected actual
  tmp=$(mktemp -d)
  echo "Looking for engine $CONTENT_KEY on $ENGINE_REPO release $ENGINE_TAG"
  if ! gh release download "$ENGINE_TAG" -R "$ENGINE_REPO" -D "$tmp" \
      -p "$CONTENT_KEY.tar.gz.part*" -p "$CONTENT_KEY.sha256" 2>/dev/null; then
    # Public release assets also download without a token.
    local urls
    urls=$(curl -fsSL "https://api.github.com/repos/$ENGINE_REPO/releases/tags/$ENGINE_TAG" 2>/dev/null \
      | jq -r --arg k "$CONTENT_KEY" '.assets[] | select(.name | startswith($k + ".")) | .browser_download_url' 2>/dev/null) || urls=""
    [ -n "$urls" ] || { echo "No published engine for $CONTENT_KEY"; rm -rf "$tmp"; return 1; }
    for url in $urls; do
      curl -fsSL -o "$tmp/$(basename "$url")" "$url" || { rm -rf "$tmp"; return 1; }
    done
  fi
  ls "$tmp/$CONTENT_KEY".tar.gz.part* >/dev/null 2>&1 || { echo "No published engine for $CONTENT_KEY"; rm -rf "$tmp"; return 1; }
  archive="$tmp/gecko-engine-dist.tar.gz"
  # Globs expand in sorted order, so the parts concatenate correctly.
  cat "$tmp/$CONTENT_KEY".tar.gz.part* > "$archive"
  if [ -s "$tmp/$CONTENT_KEY.sha256" ]; then
    expected=$(cut -d ' ' -f 1 "$tmp/$CONTENT_KEY.sha256")
    actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
    if [ "$expected" != "$actual" ]; then
      echo "Published engine checksum mismatch"; rm -rf "$tmp"; return 1
    fi
  fi
  embedded=$(tar -xzOf "$archive" reynard-engine-key.txt 2>/dev/null | tr -d '[:space:]')
  if [ "$embedded" != "$CONTENT_KEY" ]; then
    echo "Published engine is keyed $embedded, need $CONTENT_KEY"; rm -rf "$tmp"; return 1
  fi
  mv "$archive" "$OUT/gecko-engine-dist.tar.gz"
  rm -rf "$tmp"
  echo "Reusing Gecko engine $CONTENT_KEY compiled by $ENGINE_REPO"
  return 0
}

older_build_running() {
  local count
  count=$(gh api "repos/$REPO/actions/workflows/build-gecko-dev-framework.yml/runs?status=in_progress&per_page=20" \
    --jq "[.workflow_runs[] | select(.id < $GITHUB_RUN_ID)] | length" 2>/dev/null) || return 1
  [ "${count:-0}" -gt 0 ]
}

waited=0
while true; do
  if try_release; then finish true; fi
  if try_artifacts; then finish true; fi
  if ! older_build_running; then
    echo "No reusable engine and no older build in progress; compiling."
    finish false
  fi
  if [ "$waited" -ge "$MAX_WAIT_MINUTES" ]; then
    echo "Older build still running after ${MAX_WAIT_MINUTES}m; compiling instead."
    finish false
  fi
  echo "An older run is still compiling Gecko. Waiting for its engine artifact (${waited}m so far)."
  sleep "$POLL_SECONDS"
  waited=$((waited + POLL_SECONDS / 60))
done
