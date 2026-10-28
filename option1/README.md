# Option 1: Original decrypted Firefox iOS 159 wrapper

Goal: keep the **real Firefox Client.app**, Firefox UI, icon, tabs and menus, then integrate the user's Reynard backend (Gecko/JIT/extensions/FetchDock); Firefox Sync should not be used.

## Implemented and verified

- Requires the original decrypted Firefox 159.0 (78949) IPA, with executable `Client` and bundle ID `org.mozilla.ios.Firefox`.
- The packaging script checks those exact values, retains original Firefox UI/resources/icons, injects a named arm64 dylib load command, and removes stale signing files.
- A first-stage arm64 iOS bridge dylib builds successfully in GitHub Actions. It **only proves a bridge can be loaded**. It does not substitute Gecko or integrate FetchDock yet.
- Structural injection tests passed on GitHub Actions. The source IPA itself is never uploaded to GitHub.

## Build probe and package locally

The arm64 bridge artifact is published in the workflow run (not a public Firefox binary):

https://github.com/soum91/firefox-gecko-ios/actions/runs/40616754640

Download the `FirefoxReynardBridge-arm64-probe` workflow artifact, extract `FirefoxReynardBridge.dylib`, then execute locally:

```sh
python3 option1/tools/prepare_firefox_ipa.py \
  /path/to/org.mozilla.ios.Firefox_159.0_decrypted.ipa \
  /path/to/FirefoxReynardBridge.dylib \
  /path/to/Firefox-original-wrapper-probe.ipa
```

This produces an **unsigned experimental IPA**, not a tested working Gecko browser. Sideload it only after re-signing the app and all embedded libraries/extensions using a suitable provisioning profile.

## Still required for a real Firefox + Reynard implementation

1. Add a bridge with actual GeckoView runtime bootstrap, child-process handling and Firefox WKWebView engine interception. The current probe has no browser changes.
2. Route Firefox's rendering navigation/tabs/events to Gecko while preserving Firefox native UI. Simply injecting the Gecko framework cannot replace WebKit.
3. Bridge Gecko extension runtime, Reynard JIT/pairing and FetchDock background transfers to Firefox's download UI.
4. Disable Firefox Sync in a controlled, testable way without affecting browser settings.
5. Sign and validate every extension, dylib and entitlement, and test on-device before labeling a release installable.

## iOS signing and default-browser limitations

`org.mozilla.ios.Firefox` is preserved in the experiment, but **bundle ID does not confer Mozilla's trusted Team ID, App Store identity, default-browser registration or restricted entitlements**. Re-signing changes the app's cryptographic identity. Installation over App Store Firefox and iOS approval as Firefox are not guaranteed. This is not an official Firefox distribution.

Never commit the decrypted IPA, certificate, private key or provisioning profiles to this public repository.
