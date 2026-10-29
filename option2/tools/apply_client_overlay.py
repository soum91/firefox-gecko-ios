#!/usr/bin/env python3
"""Make Firefox iOS 159's app run on the Reynard Gecko engine.

Run after apply_overlay.py (which adds GeckoView to BrowserKit). Edits Mozilla's
firefox-v159.0 Client sources in place:

1. main.swift starts Firefox through GeckoRuntime.main instead of
   UIApplicationMain, with Gecko's app delegate forwarding to Firefox's
   AppDelegate (option2/Client/GeckoFirefoxBootstrap.swift).
2. The five places that look up AppDelegate through UIApplication.shared.delegate
   use AppDelegate.current, because Gecko's delegate is the UIApplication one.
3. TabWebView renders tabs with Gecko sessions while keeping its WKWebView
   contract (option2/Client/GeckoTabEngine.swift plus property overrides).
4. Downloads go through Firefox's queue with Reynard's FetchDock engine.
5. Add-ons: Reynard's WebExtension runtime with a Settings screen and a menu
   entry (option2/Client/GeckoAddons.swift).

Every edit must match the expected Firefox 159 source exactly once, so source
drift fails loudly here instead of producing a silently broken app. New code is
appended to existing Firefox files so the Xcode project needs no edits.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

OVERLAY = Path(__file__).resolve().parents[1] / "Client"
CLIENT = Path("firefox-ios/Client")
MARKER = "// firefox-gecko-ios overlay"
GECKO_IMPORTS = ["@preconcurrency import GeckoView", "import ObjectiveC"]


def replace_once(text: str, old: str, new: str, where: str) -> str:
    count = text.count(old)
    if count != 1:
        raise ValueError(f"{where}: expected exactly one match, found {count}:\n{old}")
    return text.replace(old, new, 1)


def add_imports(text: str, imports: list[str], where: str) -> str:
    lines = text.split("\n")
    last_import = max((i for i, line in enumerate(lines) if re.match(r"^(@\w+ )*import ", line)), default=None)
    if last_import is None:
        raise ValueError(f"{where}: no import block found")
    missing = [imp for imp in imports if imp not in lines]
    lines[last_import + 1:last_import + 1] = missing
    return "\n".join(lines)


LINT_OFF = "// swiftlint:disable all"
LINT_ON = "// swiftlint:enable all"


def unlinted(code: str) -> str:
    """Firefox's SwiftLint build phase fails the build on style rules; they
    are not meant for imported Reynard code or this overlay."""
    return f"{LINT_OFF}\n{code.strip(chr(10))}\n{LINT_ON}"


def overlay_body(name: str) -> str:
    """Overlay source without its import lines (those go to the file top)."""
    lines = (OVERLAY / name).read_text(encoding="utf-8").split("\n")
    # Drop the file's own header comment; it describes the standalone file.
    while lines and lines[0].startswith("//"):
        lines.pop(0)
    body = [line for line in lines if not re.match(r"^(@\w+ )*import ", line)]
    return "\n".join(body).strip("\n")


def patch_main(root: Path) -> None:
    path = root / CLIENT / "Application/main.swift"
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        raise ValueError(f"{path} already has the overlay")
    text = add_imports(text, ["import Foundation", "import UIKit", *GECKO_IMPORTS], str(path))
    original = ("_ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, "
                "NSStringFromClass(UIApplication.self), appDelegate)")
    replacement = f"""{MARKER}: sideloaded builds have no App Group; see SideloadAppGroupFallback.
SideloadAppGroupFallback.install()

{MARKER}: start through Gecko unless running tests or WebKit was requested.
if appDelegate == NSStringFromClass(AppDelegate.self) && GeckoFirefoxBootstrap.isGeckoRequested {{
    GeckoFirefoxBootstrap.run(firefoxDelegate: AppDelegate(), argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
}} else {{
    {original}
}}"""
    text = replace_once(text, original, replacement, str(path))
    text = text.rstrip("\n") + f"\n\n{MARKER}\n" + unlinted(overlay_body("GeckoFirefoxBootstrap.swift")) + "\n"
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")


def patch_app_delegate_lookups(root: Path) -> None:
    replaced = 0
    for path in sorted((root / CLIENT).rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        new = text.replace("(UIApplication.shared.delegate as? AppDelegate)", "AppDelegate.current")
        new = new.replace("UIApplication.shared.delegate as? AppDelegate", "AppDelegate.current")
        if new != text:
            replaced += 1
            path.write_text(new, encoding="utf-8")
            print(f"patched AppDelegate lookup in {path.relative_to(root)}")
    if replaced != 5:
        raise ValueError(f"expected AppDelegate lookups in 5 files, patched {replaced}")


TAB_WEBVIEW_OVERRIDES = """
    // MARK: - Gecko engine (firefox-gecko-ios overlay)
    // In Gecko mode these report the Gecko session's state; KVO notifications
    // for them are sent by GeckoTabEngine. In WebKit mode they defer to WKWebView.

    override var url: URL? {
        if let gecko { return gecko.currentURL }
        return super.url
    }

    override var title: String? {
        if let gecko { return gecko.currentTitle }
        return super.title
    }

    override var estimatedProgress: Double {
        if let gecko { return gecko.progress }
        return super.estimatedProgress
    }

    override var isLoading: Bool {
        if let gecko { return gecko.loading }
        return super.isLoading
    }

    override var canGoBack: Bool {
        if let gecko { return gecko.canGoBack }
        return super.canGoBack
    }

    override var canGoForward: Bool {
        if let gecko { return gecko.canGoForward }
        return super.canGoForward
    }

    @discardableResult
    override func load(_ request: URLRequest) -> WKNavigation? {
        if let gecko {
            gecko.load(request.url)
            return nil
        }
        return super.load(request)
    }

    @discardableResult
    override func loadFileURL(_ url: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
        if let gecko {
            gecko.load(url)
            return nil
        }
        return super.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }

    @discardableResult
    override func goBack() -> WKNavigation? {
        if let gecko {
            gecko.goBack()
            return nil
        }
        return super.goBack()
    }

    @discardableResult
    override func goForward() -> WKNavigation? {
        if let gecko {
            gecko.goForward()
            return nil
        }
        return super.goForward()
    }

    @discardableResult
    override func reload() -> WKNavigation? {
        if let gecko {
            gecko.reload(bypassCache: false)
            return nil
        }
        return super.reload()
    }

    @discardableResult
    override func reloadFromOrigin() -> WKNavigation? {
        if let gecko {
            gecko.reload(bypassCache: true)
            return nil
        }
        return super.reloadFromOrigin()
    }

    override func stopLoading() {
        if let gecko {
            gecko.stopLoading()
            return
        }
        super.stopLoading()
    }

    override var interactionState: Any? {
        get {
            if let gecko { return gecko.interactionState }
            return super.interactionState
        }
        set {
            if let gecko {
                if let data = newValue as? Data { gecko.restore(interactionState: data) }
                return
            }
            super.interactionState = newValue
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        gecko?.setVisible(window != nil)
    }

"""


def patch_tab_webview(root: Path) -> None:
    path = root / CLIENT / "TabManagement/TabWebView.swift"
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        raise ValueError(f"{path} already has the overlay")
    text = add_imports(text, GECKO_IMPORTS, str(path))
    text = replace_once(
        text,
        "    var notificationCenter: any NotificationProtocol\n",
        "    var notificationCenter: any NotificationProtocol\n"
        f"    {MARKER}: Gecko engine rendering this tab; nil in WebKit mode.\n"
        "    private(set) var gecko: GeckoTabEngine?\n",
        str(path),
    )
    text = replace_once(
        text,
        "            uiTestLeakView?.removeFromSuperview()\n",
        "            uiTestLeakView?.removeFromSuperview()\n"
        "            gecko?.close()\n",
        str(path),
    )
    text = replace_once(
        text,
        "        super.init(frame: frame, configuration: configuration)\n"
        "        observeHardwareKeyboardChanges()\n",
        "        super.init(frame: frame, configuration: configuration)\n"
        "        observeHardwareKeyboardChanges()\n"
        "        if GeckoTabEngine.isEnabled {\n"
        "            gecko = GeckoTabEngine(host: self, isPrivate: !configuration.websiteDataStore.isPersistent)\n"
        "        }\n",
        str(path),
    )
    text = replace_once(
        text,
        "    override var hasOnlySecureContent: Bool {\n",
        "    override var hasOnlySecureContent: Bool {\n"
        "        if let gecko { return gecko.isSecure }\n",
        str(path),
    )
    text = replace_once(
        text,
        "    required init?(coder: NSCoder) {\n",
        f"    {LINT_OFF}\n" + TAB_WEBVIEW_OVERRIDES + f"    {LINT_ON}\n" + "    required init?(coder: NSCoder) {\n",
        str(path),
    )
    text = text.rstrip("\n") + f"\n\n{MARKER}\n" + unlinted(overlay_body("GeckoTabEngine.swift")) + "\n"
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")


def patch_empty_onboarding(root: Path) -> None:
    """Skip onboarding when Firefox gets no cards.

    The cards depend on Nimbus' messaging helper. When it cannot be created,
    Firefox returns no cards but still presents the flow, and its Skip button
    ignores taps on an empty flow, leaving the app stuck on the background.
    """
    path = root / CLIENT / "Coordinators/Launch/LaunchCoordinator.swift"
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "            for: .freshInstall\n"
        "        )\n"
        "        let activityEventHelper = ActivityEventHelper()\n",
        "            for: .freshInstall\n"
        "        )\n"
        f"        {MARKER}: no cards means a stuck, unskippable onboarding.\n"
        "        if onboardingModel.cards.isEmpty {\n"
        "            manager.didSeeIntroScreen()\n"
        "            parentCoordinator?.didFinishLaunch(from: self)\n"
        "            return\n"
        "        }\n"
        "        let activityEventHelper = ActivityEventHelper()\n",
        str(path),
    )
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")


def patch_downloads(root: Path, reynard: Path) -> None:
    """Gecko downloads in Firefox's queue, with Reynard's FetchDock engine."""
    path = root / CLIENT / "Frontend/Browser/DownloadHelper/Download.swift"
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        raise ValueError(f"{path} already has the overlay")
    engine_path = reynard / "browser/Reynard/Client/Stores/FetchDockTransferEngine.swift"
    engine = engine_path.read_text(encoding="utf-8")
    # Swift 5 code: all mutable state is confined to its serial queue.
    engine = replace_once(
        engine,
        "final class FetchDockTransferEngine: NSObject, URLSessionDownloadDelegate {",
        "final class FetchDockTransferEngine: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {",
        str(engine_path),
    )
    engine_body = "\n".join(line for line in engine.split("\n") if not re.match(r"^(@\w+ )*import ", line))
    text = add_imports(text, ["import Foundation", "import UIKit", "@preconcurrency import GeckoView"], str(path))
    text = (text.rstrip("\n") + f"\n\n{MARKER}: Reynard's FetchDockTransferEngine (soum91/reynard-browser)\n"
            + unlinted(engine_body) + f"\n\n{MARKER}\n" + unlinted(overlay_body("GeckoDownloads.swift")) + "\n")
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")


def patch_addons(root: Path) -> None:
    """Add-ons: Settings > General > Add-ons, a menu entry, and the runtime glue."""
    path = root / CLIENT / "Frontend/Settings/Main/AppSettingsTableViewController.swift"
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        raise ValueError(f"{path} already has the overlay")
    text = add_imports(text, ["import Foundation", "@preconcurrency import GeckoView"], str(path))
    text = replace_once(
        text,
        "        // Toolbar position cannot be changed on iPad\n",
        f"        {MARKER}: Gecko add-ons\n"
        "        if GeckoTabEngine.isEnabled {\n"
        "            generalSettings.insert(GeckoAddonsSetting(theme: currentTheme()), at: 0)\n"
        "        }\n\n"
        "        // Toolbar position cannot be changed on iPad\n",
        str(path),
    )
    text = text.rstrip("\n") + f"\n\n{MARKER}\n" + unlinted(overlay_body("GeckoAddons.swift")) + "\n"
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")

    path = root / CLIENT / "Frontend/Browser/MainMenu/MainMenuConfigurationUtility.swift"
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "        options.append(configureUserAgentItem(with: uuid, tabInfo: tabInfo))\n",
        "        options.append(configureUserAgentItem(with: uuid, tabInfo: tabInfo))\n"
        f"        {MARKER}: Gecko add-ons\n"
        "        if GeckoTabEngine.isEnabled {\n"
        "            options.append(MenuElement(\n"
        "                title: \"Add-ons\",\n"
        "                iconName: Icons.lightning,\n"
        "                isEnabled: true,\n"
        "                isActive: false,\n"
        "                a11yLabel: \"Add-ons\",\n"
        "                a11yHint: \"\",\n"
        "                a11yId: \"firefoxGeckoAddons\",\n"
        "                action: {\n"
        "                    store.dispatch(MainMenuAction(windowUUID: uuid, actionType: MainMenuActionType.tapCloseMenu))\n"
        "                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {\n"
        "                        GeckoAddonManager.shared.presentMenu()\n"
        "                    }\n"
        "                }\n"
        "            ))\n"
        "        }\n",
        str(path),
    )
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")


def apply(root: Path, reynard: Path) -> None:
    root = root.resolve()
    if not (root / CLIENT / "TabManagement/TabWebView.swift").is_file():
        raise ValueError(f"{root} is not a firefox-ios v159.0 checkout")
    if not (root / "BrowserKit/Binaries/GeckoView.xcframework").is_dir():
        raise ValueError("Run apply_overlay.py first: BrowserKit has no GeckoView binary target")
    patch_app_delegate_lookups(root)
    patch_main(root)
    patch_tab_webview(root)
    patch_empty_onboarding(root)
    patch_downloads(root, reynard.resolve())
    patch_addons(root)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("firefox_source", type=Path)
    parser.add_argument("reynard_source", type=Path,
                        help="Reynard checkout providing FetchDockTransferEngine.swift")
    arguments = parser.parse_args()
    apply(arguments.firefox_source, arguments.reynard_source)
