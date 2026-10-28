// Firefox 159 BrowserKit engine adapter: Firefox native UI with Reynard Gecko.
// Experimental: integration is not complete until GeckoView.framework is linked,
// child-process extensions are embedded, and GeckoRuntime startup is wired.
// This source belongs in Firefox's BrowserKit/Sources/WebEngine module.
import Foundation
import UIKit
import GeckoView

@MainActor
public final class ReynardGeckoEngine: Engine {
    // Protect against GeckoSession.open() before GeckoRuntime.main is ready.
    public private(set) static var runtimeReady = false
    public static func markRuntimeReady() { runtimeReady = true }

    public init() {}
    public func createView() -> EngineView { ReynardGeckoEngineView(frame: .zero) }

    public func createSession(dependencies: EngineSessionDependencies) throws -> EngineSession {
        guard Self.runtimeReady else { throw EngineError.sessionNotCreated }
        let session = ReynardGeckoEngineSession()
        // TODO: Pass Firefox's private browsing context from dependencies into
        // GeckoSession(isPrivateMode:), rather than silently making every tab normal.
        session.open()
        return session
    }

    public func warmEngine() {}
    public func idleEngine() {}
    public func clearCaches() {
        Task { try? await GeckoStorageController.clearData(flags: GeckoStorageClearFlags.allCaches) }
    }
    public func clearCookies() {
        Task { try? await GeckoStorageController.clearData(flags: GeckoStorageClearFlags.cookies | GeckoStorageClearFlags.domStorages) }
    }
    public func clearOfflineWebsiteData() {
        Task { try? await GeckoStorageController.clearData(flags: GeckoStorageClearFlags.domStorages) }
    }
    public func clearTrackingProtection() {
        // TODO: Mirror Firefox's tracking exceptions to Gecko.
    }
}

@MainActor
final class ReynardGeckoEngineView: UIView, EngineView {
    private var rendered: UIView?
    func render(session: EngineSession) {
        rendered?.removeFromSuperview()
        rendered = nil
        guard let session = session as? ReynardGeckoEngineSession else { return }
        let view = session.contentView
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        rendered = view
    }
}

@MainActor
final class ReynardGeckoEngineSession: NSObject, EngineSession,
    NavigationDelegate, ProgressDelegate, ContentDelegate {

    weak var delegate: EngineSessionDelegate?
    nonisolated(unsafe) weak var telemetryProxy: EngineTelemetryProxy?
    private let gecko = GeckoSession()
    let contentView = GeckoView(frame: .zero)
    private var zoomLevel = 100
    private var canBack = false
    private var canForward = false
    var isActive = false { didSet { gecko.setActive(isActive) } }

    func open() {
        gecko.open()
        gecko.navigationDelegate = self
        gecko.progressDelegate = self
        gecko.contentDelegate = self
        contentView.session = gecko
    }
    func load(browserURL: BrowserURL) { gecko.load(browserURL.url.absoluteString) }
    func stopLoading() { gecko.stop() }
    func reload(bypassCache: Bool) {
        gecko.reload(flags: bypassCache ? GeckoSessionLoadFlags.bypassCache : GeckoSessionLoadFlags.none)
    }
    func goBack() { gecko.goBack() }
    func goForward() { gecko.goForward() }
    func scrollToTop() { gecko.scrollTo(.zero) }
    @available(iOS 16.0, *)
    func showFindInPage(withSearchText searchText: String?) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.gecko.findInPage(searchText)
        }
    }
    func goToHistory(item: EngineSessionBackForwardListItem) {
        let items = gecko.currentSessionState?.history ?? []
        guard let index = items.firstIndex(where: { $0.url == item.url.absoluteString }) else { return }
        gecko.goToHistoryIndex(index)
    }
    func currentHistoryItem() -> EngineSessionBackForwardListItem? {
        guard let state = gecko.currentSessionState,
              let index = state.currentHistoryIndex,
              state.history.indices.contains(index) else { return nil }
        return historyItem(state.history[index])
    }
    func getBackListItems() -> [EngineSessionBackForwardListItem] {
        guard let state = gecko.currentSessionState, let index = state.currentHistoryIndex else { return [] }
        return state.history.prefix(index).compactMap(historyItem)
    }
    func getForwardListItems() -> [EngineSessionBackForwardListItem] {
        guard let state = gecko.currentSessionState, let index = state.currentHistoryIndex else { return [] }
        return state.history.dropFirst(index + 1).compactMap(historyItem)
    }
    private func historyItem(_ item: GeckoSessionHistoryItem) -> EngineSessionBackForwardListItem? {
        guard let url = URL(string: item.url) else { return nil }
        return ReynardHistoryItem(url: url, title: item.title)
    }
    func restore(state: Data) {
        guard let text = String(data: state, encoding: .utf8),
              let saved = GeckoSessionState(serializedString: text) else { return }
        gecko.restoreState(saved)
    }
    func close() {
        contentView.session = nil
        gecko.close()
        delegate = nil
    }
    func switchToStandardTrackingProtection() {
        // TODO: Hook session-scoped Gecko protection settings.
    }
    func switchToStrictTrackingProtection() {
        // TODO: Hook session-scoped Gecko protection settings.
    }
    func disableTrackingProtection() {
        // TODO: Hook session-scoped Gecko protection settings.
    }
    func toggleNoImageMode() {
        // TODO: Hook Gecko image loading settings for this tab.
    }
    func updatePageZoom(_ change: ZoomChangeValue) {
        switch change {
        case .increase: zoomLevel = min(300, zoomLevel + 10)
        case .decrease: zoomLevel = max(50, zoomLevel - 10)
        case .reset: zoomLevel = 100
        @unknown default: return
        }
        let old = gecko.settings
        gecko.updateSettings(GeckoSessionSettings(
            websiteMode: old.websiteMode,
            pageZoom: PageZoomSetting(level: zoomLevel),
            language: old.language
        ))
    }

    // Events: Gecko -> Firefox BrowserKit UI.
    func onLocationChange(session: GeckoSession, url: String?, permissions: [ContentPermission]) {
        guard let url else { return }
        delegate?.onLocationChange(url: url)
    }
    func onCanGoBack(session: GeckoSession, canGoBack: Bool) {
        canBack = canGoBack
        delegate?.onNavigationStateChange(canGoBack: canBack, canGoForward: canForward)
    }
    func onCanGoForward(session: GeckoSession, canGoForward: Bool) {
        canForward = canGoForward
        delegate?.onNavigationStateChange(canGoBack: canBack, canGoForward: canForward)
    }
    func onPageStart(session: GeckoSession, url: String) {
        delegate?.onLoadingStateChange(loading: true)
    }
    func onPageStop(session: GeckoSession, success: Bool) {
        delegate?.onLoadingStateChange(loading: false)
        delegate?.onHideProgressBar()
    }
    func onProgressChange(session: GeckoSession, progress: Int) {
        delegate?.onProgress(progress: Double(max(0, min(progress, 100))) / 100.0)
    }
    func onSessionStateChange(session: GeckoSession, sessionState: GeckoSessionState) {}
    func onTitleChange(session: GeckoSession, title: String) {
        delegate?.onTitleChange(title: title)
    }
}
@MainActor
private struct ReynardHistoryItem: EngineSessionBackForwardListItem {
    let url: URL
    let title: String?
}
