import ObjectiveC
import UIKit
import UniformTypeIdentifiers

/// Share sheet > Firefox Gecko: open the shared link or text in a normal or
/// private tab, or download the link with FetchDock.
final class ShareViewController: UIViewController {
    private static let scheme = "firefoxgecko"

    private let card = UIView()
    private let stack = UIStackView()
    private var sharedURL: URL?
    private var sharedText: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        let backdrop = UIButton(type: .custom)
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        view.addSubview(backdrop)

        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        loadSharedItem { [weak self] in self?.buildButtons() }
    }

    private func buildButtons() {
        let title = UILabel()
        title.text = "Firefox Gecko"
        title.font = .preferredFont(forTextStyle: .headline)
        let subtitle = UILabel()
        subtitle.text = sharedURL?.absoluteString ?? sharedText ?? "Nothing to open"
        subtitle.font = .preferredFont(forTextStyle: .footnote)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 2
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(16, after: subtitle)

        guard sharedURL != nil || sharedText != nil else {
            stack.addArrangedSubview(button("Close", symbol: "xmark", primary: false) { [weak self] in self?.cancel() })
            return
        }
        stack.addArrangedSubview(button("Open in Firefox Gecko", symbol: "safari", primary: true) { [weak self] in
            self?.openInApp(isPrivate: false)
        })
        stack.addArrangedSubview(button("Open in Private Tab", symbol: "eyeglasses", primary: false) { [weak self] in
            self?.openInApp(isPrivate: true)
        })
        if let url = sharedURL, url.scheme?.lowercased() == "https" {
            stack.addArrangedSubview(button("Download with FetchDock", symbol: "arrow.down.circle", primary: false) { [weak self] in
                self?.open(Self.link("fetchdock", ["url": url.absoluteString]))
            })
        }
        stack.addArrangedSubview(button("Cancel", symbol: nil, primary: false) { [weak self] in self?.cancel() })
    }

    private func button(_ title: String, symbol: String?, primary: Bool, action: @escaping () -> Void) -> UIButton {
        var config = primary ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = title
        config.image = symbol.flatMap { UIImage(systemName: $0) }
        config.imagePadding = 8
        config.cornerStyle = .large
        config.buttonSize = .large
        config.baseBackgroundColor = primary ? UIColor(red: 1, green: 0.44, blue: 0.22, alpha: 1) : nil
        config.baseForegroundColor = primary ? .white : nil
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.contentHorizontalAlignment = .fill
        return button
    }

    // MARK: Shared item

    private func loadSharedItem(_ completion: @escaping () -> Void) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            provider.loadItem(forTypeIdentifier: urlType) { item, _ in
                DispatchQueue.main.async {
                    self.sharedURL = item as? URL ?? (item as? String).flatMap(URL.init(string:))
                    completion()
                }
            }
        } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            provider.loadItem(forTypeIdentifier: textType) { item, _ in
                DispatchQueue.main.async {
                    let text = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let text, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        self.sharedURL = url
                    } else {
                        self.sharedText = text
                    }
                    completion()
                }
            }
        } else {
            completion()
        }
    }

    // MARK: Opening the app

    private func openInApp(isPrivate: Bool) {
        if let url = sharedURL {
            open(Self.link("open-url", ["private": String(isPrivate), "url": url.absoluteString]))
        } else if let text = sharedText {
            open(Self.link("open-text", ["private": String(isPrivate), "text": text]))
        }
    }

    /// Firefox reads `url` as the last query item.
    private static func link(_ host: String, _ query: KeyValuePairs<String, String>) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    /// Extensions cannot call UIApplication.open directly; find the
    /// application in the responder chain and send it the open message.
    private func open(_ url: URL?) {
        guard let url else { return cancel() }
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let current = responder {
            if current.isKind(of: UIApplication.self),
               let method = class_getInstanceMethod(type(of: current), selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(method_getImplementation(method), to: Open.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                break
            }
            responder = current.next
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
