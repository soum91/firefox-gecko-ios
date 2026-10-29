Mozilla's Firefox 159 app (its own UI, tab tray, menus and settings) with web pages rendered by the Reynard Gecko engine instead of WebKit.

**Test build. Not verified on a device yet.** Not published to FlareStore. The IPA is unsigned: re-sign it with your certificate so that `Frameworks/XUL.dylib`, `Frameworks/GeckoView.framework` and `PlugIns/Reynard Helper.appex` are signed too, or Gecko cannot start its content process.

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

## Not working yet in Gecko tabs
- Anything built on WebKit user scripts: reader mode, find in page, password autofill, page metadata
- Long-press back/forward history list, tab thumbnails in the tab tray
- Hiding the toolbars on scroll, pull to refresh
- Firefox's link context menu (long-press on links)
- Downloads, and links that open a new window (they load in the current tab)
- Firefox's own error and session-restore pages (Gecko shows its own error pages)
- Firefox's widgets, share sheet and other app extensions are removed from this IPA
- JIT: JavaScript runs on the interpreter only
