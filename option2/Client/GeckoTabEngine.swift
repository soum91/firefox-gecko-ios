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
/// hide-on-scroll and pull to refresh, Firefox's link context menu, and
/// downloads. Pages themselves render, navigate, go back/forward, reload and
/// restore with Gecko.
@MainActor
final class GeckoTabEngine {
    static var isEnabled: Bool { GeckoFirefoxBootstrap.isGeckoRunning }

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
        session = GeckoSession(isPrivateMode: isPrivate)
        bridge.engine = self
        attachDelegates()
        session.open()
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
        session.load(url.absoluteString)
    }

    func goBack() { session.goBack() }
    func goForward() { session.goForward() }
    func reload(bypassCache: Bool) {
        // GeckoSession.LOAD_FLAGS_BYPASS_CACHE
        session.reload(flags: bypassCache ? 1 : 0)
    }
    func stopLoading() { session.stop() }

    func setVisible(_ visible: Bool) {
        guard session.isOpen() else { return }
        session.setActive(visible)
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

    fileprivate func pageStarted() {
        guard let host else { return }
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

    /// A crashed or killed content process leaves the session unusable:
    /// reopen it and reload the page the tab was showing.
    fileprivate func recoverFromContentProcessLoss() {
        session.close()
        session = GeckoSession(isPrivateMode: isPrivate)
        attachDelegates()
        session.open()
        geckoView.session = session
        setVisible(host?.window != nil)
        if let url = currentURL, url.scheme?.lowercased() != "internal" {
            session.load(url.absoluteString)
        }
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
        onMain { $0.pageStarted() }
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
}
