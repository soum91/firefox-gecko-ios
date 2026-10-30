// Appended to firefox-ios/Client/Frontend/Settings/Main/AppSettingsTableViewController.swift
// by option2/tools/apply_client_overlay.py. Imports below are moved to the top
// of that file by the overlay; they are here so this file parses on its own.
import Common
import Foundation
import UIKit
@preconcurrency import GeckoView

// MARK: - Gecko add-ons (Reynard's WebExtension runtime in Firefox's UI)

extension Notification.Name {
    static let geckoAddonsChanged = Notification.Name("GeckoAddonsChanged")
}

/// Add-on packages Gecko is downloading from addons.mozilla.org, by the
/// local file path Gecko reports progress for.
final class GeckoAddonPackageDownloads: @unchecked Sendable {
    static let shared = GeckoAddonPackageDownloads()
    private let lock = NSLock()
    private var paths = Set<String>()

    static func isAddonPackage(_ response: ExternalResponseInfo) -> Bool {
        guard let url = URL(string: response.url),
              url.host?.lowercased() == "addons.mozilla.org" else { return false }
        let path = url.path.lowercased()
        return path.contains("/downloads/file/") && path.hasSuffix(".xpi")
    }

    func add(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        paths.insert(path)
    }

    func contains(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths.contains(path)
    }

    func remove(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths.remove(path) != nil
    }
}

/// Connects Gecko's WebExtension runtime to Firefox: install prompts, toolbar
/// (browser action) popups, options pages, tabs opened by add-ons, and the
/// bundled FetchDock Companion.
@MainActor
final class GeckoAddonManager: NSObject {
    static let shared = GeckoAddonManager()
    static let companionID = "fetchdock@soum91"
    static let galleryURL = URL(string: "https://addons.mozilla.org/android/")!

    private var started = false
    private var browserActions: [ObjectIdentifier: [String: AddonAction]] = [:]
    private var pageActions: [ObjectIdentifier: [String: AddonAction]] = [:]

    var addons: [Addon] {
        AddonRuntime.shared.installedAddons.filter { !$0.isBuiltIn || $0.id == Self.companionID }
    }

    func start() {
        guard !started else { return }
        started = true
        AddonRuntime.shared.delegate = self
        Task { @MainActor in
            _ = try? await AddonRuntime.shared.ensureBuiltIn(
                location: "resource://app/extensions/fetchdock/", id: Self.companionID)
            _ = try? await AddonRuntime.shared.list()
            self.changed()
        }
    }

    func refresh() async {
        _ = try? await AddonRuntime.shared.list()
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: .geckoAddonsChanged, object: nil)
    }

    // MARK: Actions

    /// The toolbar action of an add-on for the selected tab, if it has one.
    func action(for addon: Addon) -> AddonAction? {
        guard addon.metaData.enabled else { return nil }
        let key = Self.selectedSession().map(ObjectIdentifier.init)
        if let action = Self.merge(key.flatMap { browserActions[$0]?[addon.id] }, addon.browserAction),
           action.enabled != false {
            return action
        }
        if let action = Self.merge(key.flatMap { pageActions[$0]?[addon.id] }, addon.pageAction),
           action.enabled == true {
            return action
        }
        return nil
    }

    private static func merge(_ tabAction: AddonAction?, _ defaultAction: AddonAction?) -> AddonAction? {
        guard let tabAction else { return defaultAction }
        guard let defaultAction else { return tabAction }
        return tabAction.merged(with: defaultAction)
    }

    func click(_ addon: Addon) {
        guard let action = action(for: addon) else { return }
        Task { @MainActor in
            do {
                if let url = try await AddonRuntime.shared.clickAction(kind: action.kind, addon: addon), !url.isEmpty {
                    self.presentPopup(url: url)
                }
            } catch {
                Self.alert(title: addon.metaData.name, message: "\(error)")
            }
        }
    }

    func openOptions(_ addon: Addon) {
        guard let value = addon.metaData.optionsPageURL, let url = URL(string: value) else { return }
        Self.openInNewTab(url)
    }

    func setEnabled(_ addon: Addon, _ enabled: Bool) async throws {
        if enabled {
            _ = try await AddonRuntime.shared.enable(addon)
        } else {
            _ = try await AddonRuntime.shared.disable(addon)
        }
    }

    func setAllowedInPrivate(_ addon: Addon, _ allowed: Bool) async throws {
        _ = try await AddonRuntime.shared.setAllowedInPrivateBrowsing(addon, allowed: allowed)
    }

    func remove(_ addon: Addon) async throws {
        try await AddonRuntime.shared.uninstall(addon)
    }

    func installPackage(at path: String, succeeded: Bool) {
        let file = URL(fileURLWithPath: path)
        guard succeeded else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                _ = try await AddonRuntime.shared.install(url: file.absoluteString, installMethod: .manager)
            } catch {
                Self.alert(title: "Add-on not installed", message: "\(error)")
            }
        }
    }

    // MARK: Presentation

    /// Firefox menu > Add-ons: each add-on's toolbar button, then Manage.
    func presentMenu() {
        start()
        let sheet = UIAlertController(title: "Add-ons", message: nil, preferredStyle: .actionSheet)
        for addon in addons where action(for: addon) != nil {
            let title = action(for: addon)?.title ?? addon.metaData.name ?? addon.id
            let item = UIAlertAction(title: title, style: .default) { [weak self] _ in self?.click(addon) }
            item.setValue(GeckoAddonIcon.image(for: addon), forKey: "image")
            sheet.addAction(item)
        }
        sheet.addAction(UIAlertAction(title: "Manage add-ons", style: .default) { _ in
            let navigation = UINavigationController(rootViewController: GeckoAddonsViewController())
            navigation.topViewController?.navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .done, primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
            Self.present(navigation)
        })
        sheet.addAction(UIAlertAction(title: .CancelString, style: .cancel))
        if let popover = sheet.popoverPresentationController, let view = Self.keyWindow() {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.maxX - 40, y: view.bounds.maxY - 80, width: 1, height: 1)
        }
        Self.present(sheet)
    }

    private func presentPopup(url: String) {
        let popup = GeckoAddonPopupViewController(url: url)
        let navigation = UINavigationController(rootViewController: popup)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        Self.present(navigation)
    }

    static func present(_ viewController: UIViewController) {
        guard var top = keyWindow()?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(viewController, animated: true)
    }

    static func alert(title: String?, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: .OKString, style: .default))
        present(alert)
    }

    private static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    static func browserViewController() -> BrowserViewController? {
        func search(_ controller: UIViewController?) -> BrowserViewController? {
            guard let controller else { return nil }
            if let browser = controller as? BrowserViewController { return browser }
            for child in controller.children {
                if let found = search(child) { return found }
            }
            return search(controller.presentedViewController)
        }
        return search(keyWindow()?.rootViewController)
    }

    static func selectedSession() -> GeckoSession? {
        browserViewController()?.tabManager.selectedTab?.webView?.gecko?.session
    }

    /// Dismisses Firefox's sheets (menu, settings) and opens `url` in a new tab.
    static func openInNewTab(_ url: URL, windowID: String? = nil) {
        guard let browser = browserViewController() else { return }
        let open: () -> Void = {
            GeckoTabEngine.pendingWindowID = windowID
            _ = browser.openURLInNewTab(url, isPrivate: false)
        }
        if browser.presentedViewController != nil {
            browser.dismiss(animated: true, completion: open)
        } else {
            open()
        }
    }

    /// FetchDock Companion and `fetchdock://download?url=` links.
    static func startFetchDockDownload(_ uri: String) {
        guard let components = URLComponents(string: uri),
              components.host == "download",
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = URL(string: value) else { return }
        startFetchDockDownload(url: url)
    }

    /// Also used by the share sheet (`firefoxgecko://fetchdock?url=`), which
    /// can arrive before Firefox's browser window exists on a cold launch.
    static func startFetchDockDownload(url: URL, attempts: Int = 20) {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return }
        guard let browser = browserViewController() else {
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { startFetchDockDownload(url: url, attempts: attempts - 1) }
            }
            return
        }
        browser.downloadQueue.enqueue(FetchDockDownload(originWindow: browser.windowUUID, url: url))
    }
}

extension GeckoAddonManager: @preconcurrency AddonEmbedderDelegate {
    func addonController(_ controller: AddonRuntime, didUpdate addon: Addon) {
        if !addon.metaData.enabled || !controller.installedAddons.contains(where: { $0.id == addon.id }) {
            for key in browserActions.keys { browserActions[key]?[addon.id] = nil }
            for key in pageActions.keys { pageActions[key]?[addon.id] = nil }
        }
        changed()
    }

    func addonController(_ controller: AddonRuntime, didFailInstall failure: AddonInstallFailure) {
        let name = failure.extensionName ?? failure.extensionID ?? "The add-on"
        Self.alert(title: "Add-on not installed", message: "\(name) could not be installed (\(failure.code ?? "unknown error")).")
    }

    func addonController(_ controller: AddonRuntime, promptFor prompt: AddonPermissionPrompt) async -> AddonPermissionPromptResponse {
        await withCheckedContinuation { continuation in MainActor.assumeIsolated {
            let name = prompt.addon.metaData.name ?? prompt.addon.id
            let title: String
            switch prompt.kind {
            case .install: title = "Add \(name)?"
            case .update: title = "\(name) needs new permissions"
            case .optional: title = "\(name) requests more permissions"
            }
            let lines = GeckoAddonPermissionText.describe(
                permissions: prompt.permissions, origins: prompt.origins,
                dataCollection: prompt.dataCollectionPermissions)
            let alert = UIAlertController(
                title: title,
                message: lines.isEmpty ? nil : "It can:\n" + lines.map { "• " + $0 }.joined(separator: "\n"),
                preferredStyle: .alert)
            if prompt.kind == .install {
                alert.addAction(UIAlertAction(title: "Add", style: .default) { _ in
                    continuation.resume(returning: AddonPermissionPromptResponse(allow: true))
                })
                alert.addAction(UIAlertAction(title: "Add and allow in private tabs", style: .default) { _ in
                    continuation.resume(returning: AddonPermissionPromptResponse(allow: true, privateBrowsingAllowed: true))
                })
            } else {
                alert.addAction(UIAlertAction(title: "Allow", style: .default) { _ in
                    continuation.resume(returning: AddonPermissionPromptResponse(allow: true))
                })
            }
            alert.addAction(UIAlertAction(title: .CancelString, style: .cancel) { _ in
                continuation.resume(returning: .deny)
            })
            Self.present(alert)
        } }
    }

    func addonController(_ controller: AddonRuntime, didUpdate action: AddonAction, for addon: Addon, session: GeckoSession?) {
        guard let session else {
            changed()
            return
        }
        let key = ObjectIdentifier(session)
        switch action.kind {
        case .browser: browserActions[key, default: [:]][addon.id] = action
        case .page: pageActions[key, default: [:]][addon.id] = action
        }
        changed()
    }

    func addonController(_ controller: AddonRuntime, didRequestOpenPopup popupURL: String, for addon: Addon, action: AddonAction, session: GeckoSession?) {
        presentPopup(url: popupURL)
    }

    func addonController(_ controller: AddonRuntime, didRequestOpenOptionsPageFor addon: Addon) {
        openOptions(addon)
    }

    func addonController(_ controller: AddonRuntime, createNewTabFor addon: Addon, details: AddonCreateTabDetails, newSessionID: String) -> Bool {
        guard let value = details.url, let url = URL(string: value) else { return false }
        Self.openInNewTab(url, windowID: newSessionID)
        return true
    }
}

/// Plain-language WebExtension permissions, as Firefox words them.
enum GeckoAddonPermissionText {
    private static let names: [String: String] = [
        "<all_urls>": "Access your data for all websites",
        "bookmarks": "Read and modify bookmarks",
        "browsingData": "Clear recent browsing history, cookies, and related data",
        "clipboardRead": "Get data from the clipboard",
        "clipboardWrite": "Input data to the clipboard",
        "cookies": "Read and modify cookies",
        "declarativeNetRequest": "Block content on any page",
        "declarativeNetRequestFeedback": "Read your browsing history",
        "downloads": "Download files and read and modify the browser's download history",
        "downloads.open": "Open files downloaded to your device",
        "geolocation": "Access your location",
        "history": "Access browsing history",
        "management": "Monitor extension usage and manage themes",
        "nativeMessaging": "Exchange messages with programs other than Firefox",
        "notifications": "Display notifications to you",
        "privacy": "Read and modify privacy settings",
        "proxy": "Control browser proxy settings",
        "sessions": "Access recently closed tabs",
        "tabs": "Access browser tabs",
        "topSites": "Access browsing history",
        "webNavigation": "Access browser activity during navigation",
    ]

    static func describe(permissions: [String], origins: [String], dataCollection: [String]) -> [String] {
        var lines: [String] = []
        let allSites = origins.contains { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.hasPrefix("http://*/") || $0.hasPrefix("https://*/") }
        if allSites {
            lines.append(names["<all_urls>"]!)
        } else {
            let hosts = Set(origins.compactMap { URLComponents(string: $0.replacingOccurrences(of: "*.", with: ""))?.host })
            lines += hosts.sorted().map { "Access your data for \($0)" }
        }
        lines += permissions.compactMap { names[$0] }
        if !dataCollection.isEmpty, dataCollection != ["none"] {
            lines.append("Share data with the developer: " + dataCollection.joined(separator: ", "))
        }
        return lines
    }
}

/// An add-on's toolbar popup, rendered by Gecko.
final class GeckoAddonPopupViewController: UIViewController, ContentDelegate, NavigationDelegate {
    private let url: String
    private let session: GeckoSession
    private let geckoView = GeckoView(frame: .zero)

    init(url: String) {
        self.url = url
        session = GeckoSession(
            settings: GeckoTabEngine.sessionSettings(for: URL(string: url), isPrivate: false),
            isPrivateMode: false, isAddonPopup: true)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))
        geckoView.frame = view.bounds
        geckoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(geckoView)
        session.contentDelegate = self
        session.navigationDelegate = self
        session.open()
        geckoView.session = session
        session.setActive(true)
        session.setFocused(true)
        session.load(url)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true, session.isOpen() {
            session.close()
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    nonisolated func onTitleChange(session: GeckoSession, title: String) {
        Task { @MainActor in self.title = title }
    }

    nonisolated func onCloseRequest(session: GeckoSession) {
        Task { @MainActor in self.dismiss(animated: true) }
    }

    nonisolated func onNewSession(session: GeckoSession, uri: String, windowId: String, target: LoadRequestTarget) async -> GeckoSession? {
        await MainActor.run {
            if let url = URL(string: uri) { GeckoAddonManager.openInNewTab(url) }
        }
        return nil
    }
}

/// Settings > Add-ons.
final class GeckoAddonsSetting: Setting {
    override var accessoryView: UIImageView? {
        guard let theme else { return nil }
        return SettingDisclosureUtility.buildDisclosureIndicator(theme: theme)
    }

    init(theme: Theme) {
        super.init(title: NSAttributedString(
            string: "Add-ons",
            attributes: [.foregroundColor: theme.colors.textPrimary]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        navigationController?.pushViewController(GeckoAddonsViewController(), animated: true)
    }
}

/// Installed add-ons: open their popup or options, enable, private tabs, remove,
/// and a link to addons.mozilla.org to find more.
final class GeckoAddonsViewController: UITableViewController {
    private var addons: [Addon] = []

    init() {
        super.init(style: .insetGrouped)
        title = "Add-ons"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "addon")
        NotificationCenter.default.addObserver(self, selector: #selector(addonsChanged), name: .geckoAddonsChanged, object: nil)
        GeckoAddonManager.shared.start()
        reload()
        Task { await GeckoAddonManager.shared.refresh() }
    }

    @objc private func addonsChanged() {
        reload()
    }

    private func reload() {
        addons = GeckoAddonManager.shared.addons
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? max(addons.count, 1) : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Installed" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "Tap Add to Firefox on an add-on's page to install it. Signed add-ons only." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "addon", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        cell.accessoryType = .none
        if indexPath.section == 1 {
            content = UIListContentConfiguration.cell()
            content.text = "Find more add-ons"
            content.image = UIImage(systemName: "magnifyingglass")
            content.textProperties.color = tableView.tintColor
        } else if addons.isEmpty {
            content.text = "No add-ons installed"
            content.textProperties.color = .secondaryLabel
        } else {
            let addon = addons[indexPath.row]
            content.text = addon.metaData.name ?? addon.id
            var detail = [addon.metaData.version]
            if !addon.metaData.enabled { detail.append("Disabled") }
            if addon.metaData.allowedInPrivateBrowsing { detail.append("Private tabs") }
            content.secondaryText = detail.filter { !$0.isEmpty }.joined(separator: " · ")
            content.image = GeckoAddonIcon.image(for: addon)
            content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
            content.textProperties.color = addon.metaData.enabled ? .label : .secondaryLabel
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            GeckoAddonManager.openInNewTab(GeckoAddonManager.galleryURL)
            return
        }
        guard addons.indices.contains(indexPath.row) else { return }
        showActions(for: addons[indexPath.row], from: tableView.cellForRow(at: indexPath))
    }

    private func showActions(for addon: Addon, from cell: UIView?) {
        let manager = GeckoAddonManager.shared
        let sheet = UIAlertController(title: addon.metaData.name ?? addon.id,
                                      message: addon.metaData.description, preferredStyle: .actionSheet)
        if let action = manager.action(for: addon) {
            sheet.addAction(UIAlertAction(title: action.title ?? "Open", style: .default) { _ in
                manager.click(addon)
            })
        }
        if addon.metaData.optionsPageURL != nil, addon.metaData.enabled {
            sheet.addAction(UIAlertAction(title: "Settings", style: .default) { _ in manager.openOptions(addon) })
        }
        let enabled = addon.metaData.enabled
        sheet.addAction(UIAlertAction(title: enabled ? "Disable" : "Enable", style: .default) { [weak self] _ in
            self?.run { try await manager.setEnabled(addon, !enabled) }
        })
        if addon.metaData.incognito != .notAllowed {
            let allowed = addon.metaData.allowedInPrivateBrowsing
            sheet.addAction(UIAlertAction(title: allowed ? "Don't run in private tabs" : "Run in private tabs", style: .default) { [weak self] _ in
                self?.run { try await manager.setAllowedInPrivate(addon, !allowed) }
            })
        }
        if !addon.isBuiltIn {
            sheet.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
                self?.run { try await manager.remove(addon) }
            })
        }
        sheet.addAction(UIAlertAction(title: .CancelString, style: .cancel))
        if let popover = sheet.popoverPresentationController, let cell {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await work()
            } catch {
                GeckoAddonManager.alert(title: nil, message: "\(error)")
            }
            self.reload()
        }
    }
}

/// Add-on icons from unpacked (file:) add-ons; packed ones use a symbol.
enum GeckoAddonIcon {
    @MainActor private static var cache: [String: UIImage] = [:]

    @MainActor
    static func image(for addon: Addon) -> UIImage? {
        if let cached = cache[addon.id] { return cached }
        let fallback = UIImage(systemName: "puzzlepiece.extension")
        guard let value = addon.metaData.iconURL, let url = URL(string: value), url.isFileURL,
              let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return fallback
        }
        let size = CGSize(width: 28, height: 28)
        let scaled = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        cache[addon.id] = scaled
        return scaled
    }
}
