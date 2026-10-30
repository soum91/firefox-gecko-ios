#!/usr/bin/env bash
# Build the Safari redirect and share sheet extensions as .appex bundles
# without an Xcode project: one Swift file each, linked as app extensions.
#
# Usage: build_link_extensions.sh <output-dir>
set -euo pipefail

out="$1"
src="$(cd "$(dirname "$0")/.." && pwd)/option2/LinkExtensions"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p "$out"

build() {
  local name="$1"; shift
  local appex="$out/$name.appex"
  rm -rf "$appex"
  mkdir -p "$appex"
  xcrun -sdk iphoneos swiftc -swift-version 5 -O \
    -target arm64-apple-ios15.0 -sdk "$sdk" \
    -application-extension -parse-as-library -module-name "$name" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -rpath -Xlinker @executable_path/../../Frameworks \
    "$@" -o "$appex/$name"
  cp "$src/$name/Info.plist" "$appex/Info.plist"
  echo "built $appex"
}

build SafariRedirect "$src/SafariRedirect/SafariWebExtensionHandler.swift" -framework Foundation
# Safari loads the web extension (manifest.json, scripts, icons) from the bundle root.
cp "$src/SafariRedirect/Resources/"* "$out/SafariRedirect.appex/"

build ShareTo "$src/ShareTo/ShareViewController.swift" \
  -framework UIKit -framework UniformTypeIdentifiers

test -f "$out/SafariRedirect.appex/manifest.json"
test -x "$out/ShareTo.appex/ShareTo"
