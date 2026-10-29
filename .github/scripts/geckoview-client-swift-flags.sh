#!/bin/bash
# Print the Swift flags a module needs to import the GeckoView framework.
#
# GeckoView is compiled with Reynard's app bridging header, and its binary
# .swiftmodule records that header. Anything importing GeckoView (Firefox
# BrowserKit) must re-read the header and every header it imports, which
# Reynard finds through its own Xcode header search paths. Without them the
# client fails with: Reynard-Bridging-Header.h: 'ExtensionBridge.h' not found.
#
# The folders are derived from the bridging header itself, so new imports in
# Reynard are picked up without editing this script.
#
# Usage: geckoview-client-swift-flags.sh <reynard-source>

set -euo pipefail

src=$(cd "$1" && pwd)
browser="$src/browser"
bridging="$browser/Reynard/Bridging/Reynard-Bridging-Header.h"
dist="$src/engine/firefox/obj-aarch64-apple-ios/dist"

test -f "$bridging"
test -d "$dist/include"

dirs=("$(dirname "$bridging")")
missing=0
while IFS= read -r header; do
  [ -n "$header" ] || continue
  match=$(find "$browser" -type f -name "$header" -not -path '*/build/*' | head -n 1)
  if [ -z "$match" ]; then
    echo "warning: $header from the bridging header was not found under browser/" >&2
    missing=1
    continue
  fi
  dirs+=("$(dirname "$match")")
done < <(grep -oE '^[[:space:]]*#[[:space:]]*(import|include)[[:space:]]+"[^"]+"' "$bridging" | sed -E 's/.*"([^"]+)"/\1/')

# <GeckoView/...> imports resolve against the compiled engine's exports,
# exactly as Reynard's own GECKO_DIST header search path does.
dirs+=("$dist/include")

flags=""
for d in $(printf '%s\n' "${dirs[@]}" | awk '!seen[$0]++'); do
  flags="$flags -Xcc -I$d"
done
echo "${flags# }"
# A missing header is reported above; the compile then names it exactly.
[ "$missing" -eq 0 ] || echo "warning: some bridging header imports were not found" >&2
exit 0
