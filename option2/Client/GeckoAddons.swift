// Appended to firefox-ios/Client/Frontend/Settings/Main/AppSettingsTableViewController.swift
// by option2/tools/apply_client_overlay.py. Imports below are moved to the top
// of that file by the overlay; they are here so this file parses on its own.
import Common
import Foundation
import UIKit
import UniformTypeIdentifiers
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
              let host = url.host?.lowercased(),
              (host == "addons.mozilla.org" || host.hasSuffix(".addons.mozilla.org") ||
               host == "mozilla.org" || host.hasSuffix(".mozilla.org")) else { return false }
        // AMO's desktop Firefox button and its explicit "Download file" link
        // can use different download routes, but both deliver signed .xpi files.
        // Key off the package extension rather than one AMO route shape.
        let filename = response.filename?.lowercased() ?? ""
        return url.path.lowercased().hasSuffix(".xpi") || filename.hasSuffix(".xpi")
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
    static let timbreID = "timbre@soum91"
    private static let signatureKey = "FirefoxGeckoRequireAddonSignatures"

    static var requireAddonSignatures: Bool {
        UserDefaults.standard.object(forKey: signatureKey) as? Bool ?? true
    }

    static func setRequireAddonSignatures(_ required: Bool) {
        UserDefaults.standard.set(required, forKey: signatureKey)
        GeckoRuntime.setDefaultPrefs(["xpinstall.signatures.required": required])
        GeckoRuntime.dispatchEvent(type: "GeckoView:ResetUserPrefs",
                                   message: ["names": ["xpinstall.signatures.required"]])
    }
    static let galleryURL = URL(string: "https://addons.mozilla.org/android/")!

    private var started = false
    private var installingBundled = false
    private(set) var builtInErrors: [String: String] = [:]
    private var browserActions: [ObjectIdentifier: [String: AddonAction]] = [:]
    private var pageActions: [ObjectIdentifier: [String: AddonAction]] = [:]

    var addons: [Addon] {
        AddonRuntime.shared.installedAddons.filter { !$0.isBuiltIn || $0.id == Self.companionID || $0.id == Self.timbreID }
    }

    func start() {
        guard !started else { return }
        started = true
        AddonRuntime.shared.delegate = self
        GeckoRuntime.setDefaultPrefs(["xpinstall.signatures.required": Self.requireAddonSignatures])
        Task { @MainActor in await self.registerBundledAddons() }
    }

    func refresh() async {
        await registerBundledAddons()
    }

    /// Gecko's extension listener may start after the first tab is created.
    /// Keep the failures visible and retry when Add-ons is opened.
    private func registerBundledAddons() async {
        guard !installingBundled else { return }
        installingBundled = true
        defer {
            installingBundled = false
            changed()
        }
        let packages = [
            (Self.companionID, "resource://app/extensions/fetchdock/"),
            (Self.timbreID, "resource://app/extensions/timbre/"),
        ]
        for attempt in 0..<4 {
            for (id, location) in packages {
                guard !AddonRuntime.shared.installedAddons.contains(where: { $0.id == id }) else {
                    builtInErrors[id] = nil
                    continue
                }
                do {
                    _ = try await AddonRuntime.shared.ensureBuiltIn(location: location, id: id)
                    builtInErrors[id] = nil
                } catch {
                    builtInErrors[id] = String(describing: error)
                }
            }
            do {
                _ = try await AddonRuntime.shared.list()
            } catch {
                for (id, _) in packages where !AddonRuntime.shared.installedAddons.contains(where: { $0.id == id }) {
                    builtInErrors[id] = "Extension list failed: \(error)"
                }
            }
            for (id, _) in packages {
                if AddonRuntime.shared.installedAddons.contains(where: { $0.id == id }) {
                    builtInErrors[id] = nil
                } else if builtInErrors[id] == nil {
                    builtInErrors[id] = "Gecko did not return the bundled add-on"
                }
            }
            changed()
            guard !packages.allSatisfy({ package in
                AddonRuntime.shared.installedAddons.contains(where: { $0.id == package.0 })
            }), attempt < 3 else { break }
            try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .geckoAddonsChanged, object: nil)
        GeckoTimbreButton.shared.update()
    }

    var timbre: Addon? {
        AddonRuntime.shared.installedAddons.first { $0.id == Self.timbreID }
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
        var message = "\(name) could not be installed (\(failure.code ?? "unknown error"))."
        if GeckoAddonManager.requireAddonSignatures {
            message += "\n\nIf this add-on is unsigned, turn off Require signed add-ons in Settings > Add-ons, restart the app and install it again."
        }
        Self.alert(title: "Add-on not installed", message: message)
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
    private var failedBuiltIns: [(id: String, name: String, error: String)] = []

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
        let errors = GeckoAddonManager.shared.builtInErrors
        failedBuiltIns = [
            (GeckoAddonManager.timbreID, "Timbre EQ"),
            (GeckoAddonManager.companionID, "FetchDock Companion"),
        ].compactMap { package in
            errors[package.0].map { (id: package.0, name: package.1, error: $0) }
        }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? max(addons.count + failedBuiltIns.count, 1) : section == 1 ? 2 : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Installed"
        case 2: return "Extension verification"
        case 3: return "Timbre EQ"
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 1 { return "Search Mozilla Add-ons, or install an .xpi file from Files (unsigned ones need Require signed add-ons turned off)." }
        if section == 3 { return "A button over web pages that opens the Timbre EQ panel. Drag it to move it." }
        if section == 2 { return "Restart after changing this setting. With checks off, install only add-ons you trust. Turning checks on may disable unsigned add-ons." }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "addon", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        cell.accessoryType = .none
        if indexPath.section == 3 {
            content = UIListContentConfiguration.cell()
            content.text = "Floating Timbre button"
            let toggle = UISwitch()
            toggle.isOn = GeckoTimbreButton.isEnabled
            toggle.addTarget(self, action: #selector(timbreButtonChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        } else if indexPath.section == 1, indexPath.row == 1 {
            cell.accessoryView = nil
            content = UIListContentConfiguration.cell()
            content.text = "Install add-on from file"
            content.image = UIImage(systemName: "doc.badge.plus")
            content.textProperties.color = tableView.tintColor
        } else if indexPath.section == 2 {
            content = UIListContentConfiguration.cell()
            content.text = "Require signed add-ons"
            let signatureSwitch = UISwitch()
            signatureSwitch.isOn = GeckoAddonManager.requireAddonSignatures
            signatureSwitch.addTarget(self, action: #selector(signatureRequirementChanged(_:)), for: .valueChanged)
            cell.accessoryView = signatureSwitch
            cell.selectionStyle = .none
        } else if indexPath.section == 1 {
            cell.accessoryView = nil
            content = UIListContentConfiguration.cell()
            content.text = "Browse compatible add-ons"
            content.image = UIImage(systemName: "magnifyingglass")
            content.textProperties.color = tableView.tintColor
        } else if indexPath.row >= addons.count, !failedBuiltIns.isEmpty {
            cell.accessoryView = nil
            let failure = failedBuiltIns[indexPath.row - addons.count]
            content.text = failure.name + " failed to load"
            content.secondaryText = failure.error
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.textProperties.color = .systemOrange
            cell.accessoryType = .disclosureIndicator
        } else if addons.isEmpty {
            cell.accessoryView = nil
            content.text = "No add-ons installed"
            content.textProperties.color = .secondaryLabel
        } else {
            cell.accessoryView = nil
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
        if indexPath.section == 2 || indexPath.section == 3 { return }
        if indexPath.section == 1, indexPath.row == 1 {
            pickPackage()
            return
        }
        if indexPath.section == 1 {
            navigationController?.pushViewController(GeckoAddonCatalogViewController(), animated: true)
            return
        }
        if indexPath.row >= addons.count, failedBuiltIns.indices.contains(indexPath.row - addons.count) {
            let failure = failedBuiltIns[indexPath.row - addons.count]
            let alert = UIAlertController(title: failure.name + " failed to load",
                                          message: failure.error, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Retry", style: .default) { _ in
                Task { await GeckoAddonManager.shared.refresh() }
            })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(alert, animated: true)
            return
        }
        guard addons.indices.contains(indexPath.row) else { return }
        showActions(for: addons[indexPath.row], from: tableView.cellForRow(at: indexPath))
    }

    @objc private func timbreButtonChanged(_ sender: UISwitch) {
        GeckoTimbreButton.isEnabled = sender.isOn
    }

    private func pickPackage() {
        // .xpi has no registered type on iOS, so accept any file and check
        // the extension after picking. asCopy hands us a readable copy.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    @objc private func signatureRequirementChanged(_ sender: UISwitch) {
        GeckoAddonManager.setRequireAddonSignatures(sender.isOn)
        let alert = UIAlertController(title: "Restart Firefox",
            message: "Close and reopen the app before installing an add-on. Turning checks back on may disable unsigned add-ons.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
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

extension GeckoAddonsViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let picked = urls.first else { return }
        let ext = picked.pathExtension.lowercased()
        guard ext == "xpi" || ext == "zip" else {
            GeckoAddonManager.alert(title: "Not an add-on", message: "Choose a Firefox add-on package (.xpi).")
            return
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-\(UUID().uuidString).xpi")
        do {
            let access = picked.startAccessingSecurityScopedResource()
            defer { if access { picked.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: picked, to: file)
        } catch {
            GeckoAddonManager.alert(title: "Add-on not installed", message: "Could not read the file: \(error.localizedDescription)")
            return
        }
        GeckoAddonManager.shared.installPackage(at: file.path, succeeded: true)
    }
}

/// Floating button over web pages that opens Timbre EQ's panel. Draggable,
/// snaps to the nearest side, and remembers where it was left.
@MainActor
final class GeckoTimbreButton: NSObject {
    static let shared = GeckoTimbreButton()
    private static let enabledKey = "FirefoxGeckoTimbreFloatingButton"
    private static let sideKey = "FirefoxGeckoTimbreButtonRight"
    private static let heightKey = "FirefoxGeckoTimbreButtonY"
    private static let size: CGFloat = 52

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            shared.update()
        }
    }

    private var button: UIButton?
    private var waiting = false

    func update() {
        let wanted = Self.isEnabled && GeckoAddonManager.shared.timbre?.metaData.enabled == true
        guard wanted else {
            button?.removeFromSuperview()
            button = nil
            return
        }
        guard let host = GeckoAddonManager.browserViewController()?.view else {
            // Firefox's browser window may not exist yet on a cold launch.
            guard !waiting else { return }
            waiting = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.waiting = false
                self.update()
            }
            return
        }
        let button = self.button ?? makeButton()
        self.button = button
        if button.superview !== host {
            button.removeFromSuperview()
            host.addSubview(button)
            restorePosition(of: button, in: host)
        }
        host.bringSubviewToFront(button)
    }

    private func makeButton() -> UIButton {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "slider.vertical.3",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
        config.baseBackgroundColor = UIColor.systemIndigo.withAlphaComponent(0.92)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        let button = UIButton(configuration: config)
        button.frame = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        button.accessibilityLabel = "Timbre EQ"
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowRadius = 6
        button.layer.shadowOffset = CGSize(width: 0, height: 3)
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        return button
    }

    @objc private func tapped() {
        let manager = GeckoAddonManager.shared
        guard let timbre = manager.timbre else { return }
        if manager.action(for: timbre) != nil {
            manager.click(timbre)
        } else {
            GeckoAddonManager.alert(title: "Timbre EQ", message: "Timbre is still starting. Try again in a moment.")
        }
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let button = pan.view, let host = button.superview else { return }
        let move = pan.translation(in: host)
        button.center = CGPoint(x: button.center.x + move.x, y: button.center.y + move.y)
        pan.setTranslation(.zero, in: host)
        guard pan.state == .ended || pan.state == .cancelled else { return }
        let right = button.center.x > host.bounds.midX
        let area = host.bounds.inset(by: host.safeAreaInsets)
        let fraction = area.height > 0 ? (button.center.y - area.minY) / area.height : 0.7
        UserDefaults.standard.set(right, forKey: Self.sideKey)
        UserDefaults.standard.set(Double(min(max(fraction, 0), 1)), forKey: Self.heightKey)
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            self.restorePosition(of: button, in: host)
        }
    }

    private func restorePosition(of button: UIView, in host: UIView) {
        let defaults = UserDefaults.standard
        let right = defaults.object(forKey: Self.sideKey) as? Bool ?? true
        let fraction = CGFloat(defaults.object(forKey: Self.heightKey) as? Double ?? 0.7)
        let area = host.bounds.inset(by: host.safeAreaInsets)
        let half = Self.size / 2 + 12
        let x = right ? area.maxX - half : area.minX + half
        let y = min(max(area.minY + area.height * fraction, area.minY + half), area.maxY - half - 60)
        button.center = CGPoint(x: x, y: y)
        button.autoresizingMask = right ? [.flexibleLeftMargin, .flexibleTopMargin, .flexibleBottomMargin]
                                        : [.flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
    }
}

/// Search and install Mozilla-listed Firefox desktop add-ons without relying
/// on addons.mozilla.org's browser detection, which treats this Gecko iOS shell
/// as Firefox for iOS and disables its install button.
@MainActor
final class GeckoAddonCatalogViewController: UITableViewController, UISearchResultsUpdating {
    private struct SearchResponse: Decodable {
        let results: [CatalogAddon]
    }

    private struct CatalogAddon: Decodable {
        struct Version: Decodable {
            struct File: Decodable {
                let url: String?
            }
            let file: File?
        }

        let id: Int
        let name: [String: String]?
        let summary: [String: String]?
        let currentVersion: Version?
        let iconURL: String?

        enum CodingKeys: String, CodingKey {
            case id, name, summary
            case currentVersion = "current_version"
            case iconURL = "icon_url"
        }

        var displayName: String {
            localized(name) ?? "Unnamed add-on"
        }

        var displaySummary: String {
            localized(summary) ?? "Mozilla-listed Firefox for Android extension"
        }

        var downloadURL: URL? {
            guard let value = currentVersion?.file?.url,
                  let url = URL(string: value),
                  url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "addons.mozilla.org" else {
                return nil
            }
            return url
        }

        private func localized(_ values: [String: String]?) -> String? {
            guard let values else { return nil }
            return values["en-US"] ?? values["en-us"] ?? values.values.first
        }
    }

    private let searchController = UISearchController(searchResultsController: nil)
    private var results: [CatalogAddon] = []
    private var searchTask: Task<Void, Never>?
    private var isLoading = false
    private var requestGeneration = 0

    init() {
        super.init(style: .insetGrouped)
        title = "Browse Add-ons"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "catalog-addon")
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search Mozilla Add-ons"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        load(query: "")
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            load(query: query)
        }
    }

    private func load(query: String) {
        searchTask?.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        tableView.reloadData()

        searchTask = Task { @MainActor in
            defer {
                if generation == requestGeneration {
                    isLoading = false
                    tableView.reloadData()
                }
            }

            do {
                var components = URLComponents(string: "https://addons.mozilla.org/api/v5/addons/search/")!
                components.queryItems = [
                    URLQueryItem(name: "app", value: "firefox"),
                    URLQueryItem(name: "appversion", value: "159.0"),
                    URLQueryItem(name: "type", value: "extension"),
                    URLQueryItem(name: "page_size", value: "40"),
                    URLQueryItem(name: "sort", value: query.isEmpty ? "users" : "relevance"),
                    URLQueryItem(name: "q", value: query)
                ]
                guard let url = components.url else { throw URLError(.badURL) }
                var request = URLRequest(url: url)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard generation == requestGeneration else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                results = try JSONDecoder().decode(SearchResponse.self, from: data).results
            } catch is CancellationError {
                return
            } catch {
                guard generation == requestGeneration else { return }
                results = []
                GeckoAddonManager.alert(title: "Add-on catalog unavailable", message: error.localizedDescription)
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        isLoading ? "Searching Mozilla Add-ons…" : "Firefox desktop extensions"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "catalog-addon", for: indexPath)
        let addon = results[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = addon.displayName
        content.secondaryText = addon.displaySummary
        content.image = UIImage(systemName: "puzzlepiece.extension")
        content.imageProperties.maximumSize = CGSize(width: 30, height: 30)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard results.indices.contains(indexPath.row) else { return }
        let addon = results[indexPath.row]
        guard addon.downloadURL != nil else {
            GeckoAddonManager.alert(title: "Add-on unavailable", message: "Mozilla did not provide a signed package for this extension.")
            return
        }

        let alert = UIAlertController(
            title: "Install \(addon.displayName)?",
            message: addon.displaySummary,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Install", style: .default) { [weak self] _ in
            self?.install(addon)
        })
        alert.addAction(UIAlertAction(title: .CancelString, style: .cancel))
        present(alert, animated: true)
    }

    private func install(_ addon: CatalogAddon) {
        guard let url = addon.downloadURL else { return }
        let progress = UIAlertController(title: "Installing \(addon.displayName)", message: "Downloading signed add-on…", preferredStyle: .alert)
        present(progress, animated: true)

        Task { @MainActor in
            let package = FileManager.default.temporaryDirectory
                .appendingPathComponent("amo-\(addon.id)-\(UUID().uuidString).xpi")
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let finalURL = response.url,
                      finalURL.scheme?.lowercased() == "https",
                      ["addons.mozilla.org", "addons.cdn.mozilla.net"].contains(finalURL.host?.lowercased() ?? "") else {
                    throw URLError(.badServerResponse)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: package)
                _ = try await AddonRuntime.shared.install(url: package.absoluteString, installMethod: .manager)
                try? FileManager.default.removeItem(at: package)
                progress.dismiss(animated: true) {
                    GeckoAddonManager.alert(title: "Add-on installed", message: addon.displayName)
                }
                await GeckoAddonManager.shared.refresh()
            } catch {
                try? FileManager.default.removeItem(at: package)
                progress.dismiss(animated: true) {
                    GeckoAddonManager.alert(title: "Add-on not installed", message: error.localizedDescription)
                }
            }
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
