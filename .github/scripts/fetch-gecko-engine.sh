#!/bin/bash
# Find a Gecko engine archive that an earlier run of this workflow already
# compiled, so a push never pays for a second multi-hour Gecko build.
#
# Usage: fetch-gecko-engine.sh <engine-key> <reynard-ref> <output-dir>
#
# Writes <output-dir>/gecko-engine-dist.tar.gz and prints found=true to
# $GITHUB_OUTPUT on success. Never fails the job: on any problem it prints
# found=false and the workflow falls back to compiling.

set -uo pipefail

KEY="$1"
REYNARD_REF="$2"
OUT="$3"
ARTIFACT="Gecko-iOS-arm64-compiled-engine-dist"
WORKFLOW_PATH=".github/workflows/build-gecko-dev-framework.yml"
REPO="$GITHUB_REPOSITORY"
MAX_WAIT_MINUTES="${MAX_WAIT_MINUTES:-150}"
POLL_SECONDS=180

mkdir -p "$OUT"

finish() {
  echo "found=$1" >> "$GITHUB_OUTPUT"
  exit 0
}

# An archive is usable if its embedded key matches. Archives made before keys
# existed are accepted only if the run that made them pinned the same Reynard
# commit, which fixes the Gecko release tag and patches.
legacy_run_matches() {
  local run_id="$1" sha path content
  path=$(gh api "repos/$REPO/actions/runs/$run_id" --jq .path 2>/dev/null) || return 1
  [ "$path" = "$WORKFLOW_PATH" ] || return 1
  sha=$(gh api "repos/$REPO/actions/runs/$run_id" --jq .head_sha 2>/dev/null) || return 1
  content=$(gh api "repos/$REPO/contents/$WORKFLOW_PATH?ref=$sha" --jq .content 2>/dev/null | base64 --decode 2>/dev/null) || return 1
  grep -q "$REYNARD_REF" <<<"$content"
}

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
    if [ -n "$embedded" ]; then
      if [ "$embedded" != "$KEY" ]; then
        echo "Run $run_id was built for $embedded, need $KEY"
        rm -rf "$tmp"; continue
      fi
    elif ! legacy_run_matches "$run_id"; then
      echo "Run $run_id predates engine keys and used a different Reynard pin"
      rm -rf "$tmp"; continue
    fi
    mv "$archive" "$OUT/gecko-engine-dist.tar.gz"
    rm -rf "$tmp"
    echo "Reusing Gecko engine compiled by run $run_id"
    return 0
  done
  return 1
}

older_build_running() {
  local count
  count=$(gh api "repos/$REPO/actions/workflows/build-gecko-dev-framework.yml/runs?status=in_progress&per_page=20" \
    --jq "[.workflow_runs[] | select(.id < $GITHUB_RUN_ID)] | length" 2>/dev/null) || return 1
  [ "${count:-0}" -gt 0 ]
}

waited=0
while true; do
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
