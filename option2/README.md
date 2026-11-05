# Firefox Gecko iOS

Mozilla Firefox for iOS 159's native interface with pages rendered by the Gecko engine. This is the **Firefox Gecko (Native UI)** app, separate from the Reynard browser shell.

## Current Native UI behavior

- Firefox's own home screen, tab tray, menus, settings and browser controls.
- Gecko sessions render browser tabs. Cookies, site storage and installed WebExtensions use a persistent app-private Gecko profile.
- Firefox Accounts/Sync stays enabled. Sideloaded builds use the app's own Keychain group for account tokens because they cannot access Mozilla's shared group.
- Settings > Add-ons manages installed extensions. The next native build adds a searchable AMO catalog for Firefox for Android extensions and installs the signed XPI through Gecko's permission prompt.
- AMO's website still identifies this app as Firefox for iOS and disables its web install button. Use the in-app catalog instead.

The profile and Keychain changes are in the source branch; persistence across launches still needs confirmation on a device after installing the build.

## Build and FlareStore

The native app work is on the `firefox-native-gecko` branch. The FlareStore source feed is `main/source.json` and contains only the Native UI app entry. The build workflow produces an unsigned IPA; re-sign the Gecko framework, XUL binary, and helper extension with the same team before installing.

## Known limitations

- WebKit-only Firefox features are not bridged in Gecko tabs, including reader mode, find in page, password autofill and some page metadata.
- Firefox's back/forward history menu, tab thumbnails, pull to refresh and link context menu are not available in Gecko tabs.
- Some WebExtensions may not work because they require APIs GeckoView does not implement or are restricted to desktop Firefox.
- JavaScript JIT is unavailable in this sideloaded build.
