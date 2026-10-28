# Option 2: Original Firefox iOS 159 front end, Reynard Gecko engine

Goal: retain **Mozilla's actual native Firefox UI**, home, tab tray, browser menus, settings and icons, while replacing the rendering engine and adding Reynard's Gecko/JIT/add-on/FetchDock functionality. Firefox Sync will be excluded.

## Verified work

- Uses the exact public Mozilla source tag `firefox-v159.0` instead of copying Reynard's UI.
- Identified Firefox's `BrowserKit/Sources/WebEngine/Engine.swift`, `EngineSession.swift` and `EngineView.swift` abstraction.
- Implemented a first `ReynardGeckoEngine` adapter that maps URL loading, reload, navigation, progress, title, page zoom, and Gecko history to BrowserKit interfaces.
- Added an overlay script to include `GeckoView.xcframework` in BrowserKit as a SwiftPM binary target.
- Recovered a device `GeckoView.xcframework` from the existing successful `v159.0.2` Reynard IPA. This does **not** recompile Gecko.
- Syntax/preflight checks pass. A full link/startup has **not** passed yet.

Device framework artifact run:

https://github.com/soum91/firefox-gecko-ios/actions/runs/40616713433

## Apply to upstream Firefox source

```sh
git clone --depth 1 --branch firefox-v159.0 https://github.com/mozilla-mobile/firefox-ios.git firefox-source
# Download the previously built device GeckoView xcframework artifact
# and unpack it so /path/to/GeckoView.xcframework/Info.plist exists.
python3 option2/tools/apply_overlay.py firefox-source /path/to/GeckoView.xcframework
```

This copies the adapter into Firefox's BrowserKit `WebEngine` source and adds a binary `GeckoView` dependency. It deliberately **does not** redirect the production engine factory yet, because Gecko's runtime and child process resources must first be initialized. Doing so prematurely would crash Firefox.

## Required before a working IPA

1. Integrate `GeckoRuntime.main` with Firefox startup, the Gecko helper/XPC process entry points and runtime assets; embed and re-sign those alongside `GeckoView.framework`.
2. Inject `ReynardGeckoEngine` into Firefox's actual `Engine` factory in place of `WKEngine`, with correct private mode sessions and restore semantics.
3. Implement all remaining Firefox engine surface, including security/permissions, reader mode, media capture, contextual menus, native selection, per-tab protection, WebKit-only components and downloads.
4. Hook Reynard add-ons, JIT pairing, background FetchDock downloads and Live Activities to the unchanged Firefox controls.
5. Disable Firefox Sync without removing native Firefox settings; test all app extensions and signing.
6. Produce a signed-on-device test and validate real navigation before publishing a FlareStore release.

No official Mozilla signatures, team identifier or privileged browser entitlements transfer from the original IPA. `org.mozilla.ios.Firefox` remains a *desired experiment*, not a claim of App Store recognition. An independent signing identity will ordinarily be necessary.

The current `main` release is the **older Reynard UI diagnostic** and is not an output of this branch.
