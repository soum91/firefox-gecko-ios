#!/bin/bash
# Print a content key for the compiled Gecko engine.
#
# The key covers everything that decides what build-gecko.sh produces: the
# pinned Firefox submodule and release tag (engine/), the Gecko patches
# (patches/), the scripts that fetch, patch and build Gecko, and the build
# flags. Any checkout with the same inputs gets the same key, so other
# projects (firefox-gecko-ios) can reuse an engine this repo already built.
#
# Usage: gecko-engine-key.sh <repo-root> <build-args>
# Copy of soum91/reynard-browser tools/ci/gecko-engine-key.sh; keep identical.

set -euo pipefail

root="$1"
args="$2"

inputs=$(
  printf 'schema v1\n'
  git -C "$root" rev-parse \
    HEAD:engine \
    HEAD:patches \
    HEAD:tools/development/build-gecko.sh \
    HEAD:tools/development/apply-patches.sh \
    HEAD:tools/development/update-gecko.sh
  printf 'args %s\n' "$args"
)

printf 'gecko-%s\n' "$(printf '%s\n' "$inputs" | shasum -a 256 | cut -c1-24)"
