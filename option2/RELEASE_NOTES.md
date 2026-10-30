Mozilla's Firefox 159 app (its own UI, tab tray, menus and settings) with web pages rendered by the Reynard Gecko engine instead of WebKit.

**Test build.** Also listed in the FlareStore feed as "Firefox Gecko (Native UI)". The IPA is unsigned: re-sign it with your certificate so that `Frameworks/XUL.dylib`, `Frameworks/GeckoView.framework` and `PlugIns/Reynard Helper.appex` are signed too, or Gecko cannot start its content process.

## How it is put together
- Firefox starts through `GeckoRuntime.main`; Gecko's app delegate forwards to Firefox's `AppDelegate`, so Firefox's own startup still runs.
- Each tab's `TabWebView` hosts a Gecko session and reports Gecko's URL, title, progress, loading and back/forward state to Firefox the same way WebKit did.
- Launch argument / user default `FirefoxGeckoUseWebKit = YES` starts the unchanged WebKit Firefox instead.
- Sideloaded installs have no App Group, so Firefox's profile (history, Nimbus, onboarding) lives in a private folder inside the app instead of the shared group container.

## Expected to work
- Loading pages, typing a URL or search, back, forward, reload, stop
- Address bar URL, page title, progress bar, lock icon, tab titles
- New tabs and private tabs (Gecko private sessions)
- Firefox's native home screen, tab tray, menus and settings
- Tabs restored across launches from Gecko session state
- Recovering a tab whose Gecko content process crashed
- Non-web links (tel:, mailto:, App Store) open in iOS
- Downloads in Firefox's own prompt, toast and Downloads panel: large resumable HTTPS files use FetchDock parallel segmented background downloads (4 connections), everything else keeps Gecko's stream
- Firefox's download Live Activity (Lock Screen / Dynamic Island), via the kept widget extension
- Gecko tabs identify as Firefox for Android, like Reynard (desktop Firefox with Request Desktop Site), so addons.mozilla.org offers Add to Firefox
- Add-ons: Settings > Add-ons lists them (enable, disable, run in private tabs, settings, remove) and links to addons.mozilla.org; tapping Add to Firefox there installs signed add-ons with a permission prompt
- Menu > Add-ons opens each add-on's toolbar popup (for example uBlock Origin's panel)
- FetchDock Companion is built in: it lists direct file links on a page and sends them to FetchDock
- Safari redirect: with Safari as the default browser, links that open in Safari jump to Firefox Gecko. Turn on "Open in Firefox Gecko" in Settings > Apps > Safari > Extensions and allow it on all websites. Its toolbar popup turns it off, excludes a site, or keeps you in Safari for 10 minutes
- Share sheet: Firefox Gecko opens a shared link or text in a normal or private tab, or downloads the link with FetchDock
- This app uses the URL scheme firefoxgecko:// instead of firefox://, so it no longer catches links meant for a real Firefox

## Not working yet in Gecko tabs
- Anything built on WebKit user scripts: reader mode, find in page, password autofill, page metadata
- Long-press back/forward history list, tab thumbnails in the tab tray
- Hiding the toolbars on scroll, pull to refresh
- Firefox's link context menu (long-press on links)
- Links that open a new window (they load in the current tab)
- Firefox's own error and session-restore pages (Gecko shows its own error pages)
- Firefox's own share, notification and other app extensions are removed from this IPA; it ships the widget (download Live Activity), Safari redirect and share sheet extensions instead
- JIT: JavaScript runs on the interpreter only
