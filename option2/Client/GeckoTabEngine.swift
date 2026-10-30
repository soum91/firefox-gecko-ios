// Appended to firefox-ios/Client/TabManagement/TabWebView.swift by
// option2/tools/apply_client_overlay.py. Imports below are moved to the top of
// TabWebView.swift by the overlay; they are here so this file parses on its own.
import Foundation
import UIKit
import WebKit
@preconcurrency import GeckoView

// MARK: - Gecko-rendered Firefox tabs

/// Renders one Firefox tab with a Reynard Gecko session.
///
/// Firefox 159's browser is written against `WKWebView`: the browser view
/// controller observes `URL`, `title`, `estimatedProgress`, `loading`,
/// `canGoBack`, `canGoForward` and `hasOnlySecureContent` through KVO and
/// receives `WKNavigationDelegate` callbacks. `TabWebView` keeps that contract:
/// in Gecko mode it hosts a `GeckoView` over its (unused) WebKit content,
/// overrides those properties with Gecko's state, sends the same KVO change
/// notifications, and drives Firefox's real navigation delegate methods from
/// Gecko events. Firefox's toolbar, tab tray, history and session code keep
/// working unchanged.
///
/// Not yet bridged (WebKit-only Firefox features stay inert in Gecko tabs):
/// JavaScript user scripts (reader mode, page metadata, password autofill,
/// find in page), the back/forward history menu, tab thumbnails, toolbar
/// hide-on-scroll and pull to refresh, and Firefox's link context menu.
/// Pages themselves render, navigate, go back/forward, reload and
/// restore with Gecko.
@MainActor
final class GeckoTabEngine {
    static var isEnabled: Bool { GeckoFirefoxBootstrap.isGeckoRunning }

    /// Session ID an add-on asked for with tabs.create; used by the next tab.
    static var pendingWindowID: String?

    /// Prefix that marks session data written by Gecko, so WebKit session data
    /// saved before switching engines is ignored instead of misread.
    private static let interactionStatePrefix = "GECKO1:"

    private weak var host: TabWebView?
    private let isPrivate: Bool
    private let bridge = GeckoTabDelegateBridge()
    private let geckoView = GeckoView(frame: .zero)
    private(set) var session: GeckoSession

    private(set) var currentURL: URL?
    private(set) var currentTitle: String?
    private(set) var progress: Double = 0
    private(set) var loading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isSecure = false
    private var sessionState: GeckoSessionState?

    init(host: TabWebView, isPrivate: Bool) {
        self.host = host
        self.isPrivate = isPrivate
        session = GeckoSession(settings: Self.sessionSettings(for: nil, isPrivate: isPrivate), isPrivateMode: isPrivate)
        bridge.engine = self
        attachDelegates()
        GeckoAddonManager.shared.start()
        session.open(windowId: Self.pendingWindowID)
        Self.pendingWindowID = nil
        geckoView.session = session
        geckoView.frame = host.bounds
        geckoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        geckoView.backgroundColor = .systemBackground
        host.addSubview(geckoView)
        // The WebKit content underneath never loads a page in Gecko mode.
        host.scrollView.isHidden = true
    }

    private func attachDelegates() {
        session.progressDelegate = bridge
        session.navigationDelegate = bridge
        session.contentDelegate = bridge
    }

    func close() {
        session.close()
        geckoView.removeFromSuperview()
    }

    // MARK: Commands from Firefox

    func load(_ url: URL?) {
        guard let url else { return }
        if url.scheme?.lowercased() == "internal" {
            showFirefoxInternalPage(url)
            return
        }
        applySettings(for: url)
        session.load(url.absoluteString)
    }

    func goBack() { session.goBack() }
    func goForward() { session.goForward() }
    func reload(bypassCache: Bool) {
        // Firefox's Request Desktop Site toggles its domain list, then reloads.
        if let currentURL { applySettings(for: currentURL) }
        // GeckoSession.LOAD_FLAGS_BYPASS_CACHE
        session.reload(flags: bypassCache ? 1 : 0)
    }
    func stopLoading() { session.stop() }

    func setVisible(_ visible: Bool) {
        guard session.isOpen() else { return }
        session.setActive(visible)
        session.setAddonTabActive(visible)
        if visible { session.setFocused(true) }
    }

    var interactionState: Data? {
        guard let serialized = sessionState?.serializedString() else { return nil }
        return Data((Self.interactionStatePrefix + serialized).utf8)
    }

    func restore(interactionState data: Data) {
        guard let text = String(data: data, encoding: .utf8),
              text.hasPrefix(Self.interactionStatePrefix),
              let state = GeckoSessionState(serializedString: String(text.dropFirst(Self.interactionStatePrefix.count))),
              !state.isEmpty else {
            return
        }
        sessionState = state
        session.restoreState(state)
    }

    /// Firefox renders its own pages (home, error, session restore) from
    /// `internal://` URLs through a WebKit scheme handler that Gecko does not
    /// have. Its home screen is native UI shown when the tab URL is the
    /// internal home URL, so record the URL and complete a navigation for
    /// Firefox without handing it to Gecko.
    private func showFirefoxInternalPage(_ url: URL) {
        guard let host else { return }
        host.navigationDelegate?.webView?(host, didStartProvisionalNavigation: nil)
        change("URL") { currentURL = url }
        change("title") { currentTitle = nil }
        change("hasOnlySecureContent") { isSecure = true }
        host.navigationDelegate?.webView?(host, didCommit: nil)
        change("estimatedProgress") { progress = 1 }
        change("loading") { loading = false }
        host.navigationDelegate?.webView?(host, didFinish: nil)
    }

    // MARK: Events from Gecko

    fileprivate func pageStarted(_ urlString: String) {
        guard let host else { return }
        // A link to a site that needs another user agent (AMO, desktop mode)
        // is reloaded with it, as Reynard does.
        if let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           applySettings(for: url) {
            session.load(urlString)
            return
        }
        change("loading") { loading = true }
        change("estimatedProgress") { progress = 0.1 }
        host.navigationDelegate?.webView?(host, didStartProvisionalNavigation: nil)
    }

    fileprivate func locationChanged(_ urlString: String?) {
        guard let host else { return }
        let url = urlString.flatMap { URL(string: $0) }
        change("URL") { currentURL = url }
        change("hasOnlySecureContent") { isSecure = url?.scheme?.lowercased() == "https" }
        host.navigationDelegate?.webView?(host, didCommit: nil)
    }

    fileprivate func progressChanged(_ percent: Int) {
        change("estimatedProgress") { progress = max(0.1, min(1, Double(percent) / 100)) }
    }

    /// Gecko shows its own error pages, so a failed load is still reported to
    /// Firefox as finished; Firefox's error pages need WebKit.
    fileprivate func pageStopped() {
        guard let host else { return }
        change("estimatedProgress") { progress = 1 }
        change("loading") { loading = false }
        host.navigationDelegate?.webView?(host, didFinish: nil)
    }

    fileprivate func titleChanged(_ title: String) {
        change("title") { currentTitle = title.isEmpty ? nil : title }
    }

    fileprivate func canGoBackChanged(_ value: Bool) {
        change("canGoBack") { canGoBack = value }
    }

    fileprivate func canGoForwardChanged(_ value: Bool) {
        change("canGoForward") { canGoForward = value }
    }

    fileprivate func sessionStateChanged(_ state: GeckoSessionState) {
        sessionState = GeckoSessionState(copying: state)
    }

    /// Opened-in-new-window links load in this tab for now.
    fileprivate func openInThisTab(_ uri: String) {
        session.load(uri)
    }

    /// Firefox's download prompt; `decide` tells Gecko whether to keep streaming.
    fileprivate func offerDownload(_ response: ExternalResponseInfo, decide: @escaping (Bool) -> Void) {
        if GeckoAddonPackageDownloads.isAddonPackage(response) {
            GeckoAddonPackageDownloads.shared.add(response.localFilePath)
            decide(true)
            return
        }
        guard let host, let browser = host.navigationDelegate as? BrowserViewController else {
            decide(false)
            return
        }
        browser.presentGeckoDownload(response, isPrivate: isPrivate, from: host, decide: decide)
    }

    /// A crashed or killed content process leaves the session unusable:
    /// reopen it and reload the page the tab was showing.
    fileprivate func recoverFromContentProcessLoss() {
        session.close()
        session = GeckoSession(settings: Self.sessionSettings(for: currentURL, isPrivate: isPrivate), isPrivateMode: isPrivate)
        attachDelegates()
        session.open()
        geckoView.session = session
        setVisible(host?.window != nil)
        if let url = currentURL, url.scheme?.lowercased() != "internal" {
            session.load(url.absoluteString)
        }
    }

    // MARK: User agent

    /// Reynard's defaults: Gecko on iOS presents itself as Firefox for Android
    /// (sites, and addons.mozilla.org in particular, do not expect Gecko on
    /// iOS); Google gets a Chrome-style Android UA; Firefox's Request Desktop
    /// Site list switches a site to the desktop Firefox UA.
    static func sessionSettings(for url: URL?, isPrivate: Bool) -> GeckoSessionSettings {
        let host = url?.host?.lowercased() ?? ""
        let forcesMobile = host == "addons.mozilla.org" || url?.scheme?.lowercased() == "moz-extension"
        let desktop = !forcesMobile && (url.map { Tab.ChangeUserAgent.contains(url: $0, isPrivate: isPrivate) } ?? false)
        let gecko = GeckoRuntime.version.split(whereSeparator: { !$0.isNumber }).first.map(String.init) ?? "0"
        let userAgent: String
        if desktop {
            userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:\(gecko).0) Gecko/20100101 Firefox/\(gecko).0"
        } else if host.split(separator: ".").contains("google") {
            let chrome = (Int(gecko) ?? 0) + 4
            userAgent = "Mozilla/5.0 (Linux; Android 15; Nexus 5 Build/MRA58N) FxQuantum/\(gecko).0 AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chrome).0.0.0 Mobile Safari/537.36"
        } else {
            userAgent = "Mozilla/5.0 (Android 15; Mobile; rv:\(gecko).0) Gecko/\(gecko).0 Firefox/\(gecko).0"
        }
        let platform = desktop ? "Intel Mac OS X 10.15" : "Linux armv81"
        let mode = desktop ? 1 : 0
        let languages = Locale.preferredLanguages.isEmpty ? ["en"] : Locale.preferredLanguages
        return GeckoSessionSettings(
            websiteMode: WebsiteModeSetting(
                userAgentOverride: userAgent,
                platformOverride: platform,
                appVersionOverride: desktop ? "5.0 (Macintosh)" : "5.0 (Android 15)",
                oscpuOverride: platform,
                buildIDOverride: nil,
                userAgentMode: mode,
                viewportMode: mode),
            pageZoom: .default,
            language: LanguageSetting(codes: languages))
    }

    /// Returns whether the session's settings changed.
    @discardableResult
    private func applySettings(for url: URL) -> Bool {
        let settings = Self.sessionSettings(for: url, isPrivate: isPrivate)
        guard settings != session.settings else { return false }
        session.updateSettings(settings)
        return true
    }

    // MARK: KVO

    /// Sends the same change notifications WebKit sends for these keys, so
    /// Firefox's observers read the new value through TabWebView's overrides.
    private func change(_ key: String, _ update: () -> Void) {
        host?.willChangeValue(forKey: key)
        update()
        host?.didChangeValue(forKey: key)
    }
}

/// Receives Gecko's callbacks, which are not main-actor isolated, and applies
/// them to the tab's engine on the main actor.
final class GeckoTabDelegateBridge: ProgressDelegate, NavigationDelegate, ContentDelegate, @unchecked Sendable {
    weak var engine: GeckoTabEngine?

    private func onMain(_ work: @escaping @MainActor (GeckoTabEngine) -> Void) {
        let apply: @MainActor () -> Void = { [weak self] in
            guard let engine = self?.engine else { return }
            work(engine)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { apply() }
        } else {
            Task { @MainActor in apply() }
        }
    }

    // ProgressDelegate
    func onPageStart(session: GeckoSession, url: String) {
        onMain { $0.pageStarted(url) }
    }

    func onPageStop(session: GeckoSession, success: Bool) {
        onMain { $0.pageStopped() }
    }

    func onProgressChange(session: GeckoSession, progress: Int) {
        onMain { $0.progressChanged(progress) }
    }

    func onSessionStateChange(session: GeckoSession, sessionState: GeckoSessionState) {
        let snapshot = GeckoSessionState(copying: sessionState)
        onMain { $0.sessionStateChanged(snapshot) }
    }

    // NavigationDelegate
    func onLocationChange(session: GeckoSession, url: String?, permissions: [ContentPermission]) {
        onMain { $0.locationChanged(url) }
    }

    func onCanGoBack(session: GeckoSession, canGoBack: Bool) {
        onMain { $0.canGoBackChanged(canGoBack) }
    }

    func onCanGoForward(session: GeckoSession, canGoForward: Bool) {
        onMain { $0.canGoForwardChanged(canGoForward) }
    }

    /// Web schemes stay in Gecko; anything else (tel:, mailto:, App Store and
    /// app links) is handed to iOS, as Firefox does for WebKit tabs.
    func onLoadRequest(session: GeckoSession, request: LoadRequest) async -> AllowOrDeny {
        let webSchemes: Set<String> = [
            "http", "https", "about", "data", "blob", "file", "javascript",
            "moz-extension", "resource", "chrome", "view-source",
        ]
        guard let url = URL(string: request.uri),
              let scheme = url.scheme?.lowercased(),
              !webSchemes.contains(scheme) else {
            return .allow
        }
        if scheme == "fetchdock" {
            if request.hasUserGesture || request.isUserInitiatedNavigation {
                let uri = request.uri
                await MainActor.run { GeckoAddonManager.startFetchDockDownload(uri) }
            }
            return .deny
        }
        await MainActor.run {
            UIApplication.shared.open(url)
        }
        return .deny
    }

    func onNewSession(session: GeckoSession, uri: String, windowId: String, target: LoadRequestTarget) async -> GeckoSession? {
        onMain { $0.openInThisTab(uri) }
        return nil
    }

    // ContentDelegate
    func onTitleChange(session: GeckoSession, title: String) {
        onMain { $0.titleChanged(title) }
    }

    func onCrash(session: GeckoSession) {
        onMain { $0.recoverFromContentProcessLoss() }
    }

    func onKill(session: GeckoSession) {
        onMain { $0.recoverFromContentProcessLoss() }
    }

    func onExternalResponse(session: GeckoSession, response: ExternalResponseInfo) async -> Bool {
        await withCheckedContinuation { continuation in
            onMain { engine in
                engine.offerDownload(response) { continuation.resume(returning: $0) }
            }
        }
    }

    func onExternalResponseProgress(session: GeckoSession, localFilePath: String, bytesReceived: Int64) -> Bool {
        if GeckoAddonPackageDownloads.shared.contains(localFilePath) { return true }
        return GeckoStreamRegistry.shared.download(at: localFilePath)?.received(totalBytes: bytesReceived) ?? false
    }

    func onExternalResponseComplete(session: GeckoSession, localFilePath: String, succeeded: Bool) {
        if GeckoAddonPackageDownloads.shared.remove(localFilePath) {
            Task { @MainActor in GeckoAddonManager.shared.installPackage(at: localFilePath, succeeded: succeeded) }
            return
        }
        guard let download = GeckoStreamRegistry.shared.remove(localFilePath) else { return }
        Task { @MainActor in download.complete(succeeded: succeeded) }
    }
}
