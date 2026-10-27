# Firefox Gecko iOS

Private integration project for Soumen's Firefox-style iOS browser with the Gecko engine, Reynard add-ons, and FetchDock downloads.

## Status

**Phase 1: source overlay and preflight. Not yet an installable Firefox replacement.**

- Gecko and Firefox add-on runtime: based on [`soum91/reynard-browser`](https://github.com/soum91/reynard-browser), pinned in [`config/build.json`](config/build.json).
- Parallel background HTTP/HTTPS downloads: uses Reynard's existing `FetchDockTransferEngine` instead of reimplementing transfers.
- New: iOS 16.1+ Lock Screen / Dynamic Island download Live Activity, driven by `DownloadStore` notifications. Progress is best effort while the app is suspended.
- New: Firefox-style numeric versioning, beginning at `159.0.1 (78950)` after the reference Firefox `159.0 (78949)`. Every release increments both public and internal numbers for sideloader feed compatibility.
- Planned: incorporate Firefox 159 native chrome/interface from Mozilla's maintained iOS source, preserve Gecko as primary engine, evaluate optional WebKit fallback, and test managed default-browser entitlement behavior. These are **not yet implemented**.

The supplied decrypted Firefox 159.0 IPA is a local **reference only** and is deliberately **not stored here**. Mozilla's official code signature and managed entitlements cannot be inherited by repackaging or re-signing it. The initial development app uses `com.soum91.FirefoxGecko`; the official `org.mozilla.ios.Firefox` ID is reserved for a separately verified signing experiment, not assumed to be installable as an update over App Store Firefox.

## Source preparation

Check out the pinned Reynard commit without building Gecko, then apply this repository's overlay:

```sh
git clone https://github.com/soum91/reynard-browser.git reynard-source
git -C reynard-source checkout 55eecc5b63114b0072bf14bd4c55acec01e3a40a
python3 scripts/bootstrap.py reynard-source --revision 1 --output dist/version.json
python3 -m unittest discover -s tests -v
```

The source preparation adds the download WidgetKit extension target, ActivityKit coordinator, background event observation, `NSSupportsLiveActivities`, and version stamp. It does **not** build an IPA and does not modify the public Reynard repository. GitHub Actions runs a fast preflight on each push; a full Gecko build will be added once the new browser interface is ready for testing.

## Background download behavior

- iOS's background `URLSession` can continue supported transfers when the browser is suspended or terminated by the system, then relaunch the app for completion events.
- A Live Activity is **display only**, not a background execution or JIT entitlement. It can show stale progress while the app is suspended; it will update when the app receives progress/lifecycle events.
- **Force-quitting the browser from the app switcher cancels background URLSession transfers.** We cannot bypass that with a Live Activity.
- Reynard presently forwards eligible resumable HTTPS GET downloads to the FetchDock transfer engine. Other Gecko-captured downloads may not continue while suspended. Widening safe background handoff is a separate task, and must protect cookies, POST requests, one-time URLs, and DRM content.
- The WidgetKit extension must be kept when re-signing/installing the final IPA.

## Release version policy

`config/build.json` records the upstream Firefox base and reference build. Release revision `N` produces public version `159.0.N` and internal build `78949+N` until we update the Firefox base. A release feed must use the **same values** as the IPA's `Info.plist`; never publish the same version string for a different build.

## Copyright and signing

This repository contains only integration code and source references. Mozilla Firefox iOS and Gecko are subject to their respective open-source licenses; Reynard's code has its own licensing obligations. Official Firefox branding, default-browser registration, app groups, and privileged entitlements are **not** conferred by retaining a bundle identifier or icon.
