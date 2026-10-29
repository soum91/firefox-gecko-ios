// Appended to firefox-ios/Client/Frontend/Browser/DownloadHelper/Download.swift by
// option2/tools/apply_client_overlay.py, after Reynard's FetchDockTransferEngine.
// Imports below are moved to the top of Download.swift by the overlay.
import Foundation
import UIKit
import Common
@preconcurrency import GeckoView

// MARK: - Gecko downloads (firefox-gecko-ios overlay)

/// Gecko tabs hand downloads to Firefox through `ContentDelegate.onExternalResponse`.
/// They become ordinary Firefox `Download`s in the browser's `DownloadQueue`, so
/// Firefox's prompt, toast, Downloads panel and download Live Activity all work.
///
/// Same rule as Reynard's DownloadStore: resumable HTTPS GETs of 1 MB or more
/// with a strong ETag and byte ranges are replayed by FetchDock as parallel
/// segmented background downloads. Everything else (POSTs, private tabs,
/// one-shot or unsupported resources) keeps Gecko's own response stream.
enum GeckoDownloadPolicy {
    static func usesFetchDock(_ response: ExternalResponseInfo, isPrivate: Bool) -> Bool {
        guard !isPrivate,
              response.requestMethod == "GET",
              response.statusCode == 200,
              URL(string: response.url)?.scheme == "https",
              (response.contentLength ?? 0) >= 1024 * 1024 else {
            return false
        }
        let header: (String) -> String? = { name in
            response.headers.first { $0.name.lowercased() == name }?.value
        }
        let etag = header("etag") ?? ""
        return header("accept-ranges")?.lowercased() == "bytes" && etag.hasPrefix("\"") && etag.hasSuffix("\"")
    }

    static func filename(for response: ExternalResponseInfo) -> String {
        let suggested = response.filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = URL(string: response.url)?.lastPathComponent ?? ""
        let name = suggested.isEmpty ? fallback : suggested
        let safe = Download.stripUnicode(fromFilename: name)
        return safe.isEmpty ? "Download" : safe
    }
}

/// The app's single FetchDock engine (one background URLSession).
final class FetchDockService: @unchecked Sendable {
    static let shared = FetchDockService()

    static var sessionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "org.mozilla.ios.Firefox") + ".fetchdock.parallel.v1"
    }

    let engine: FetchDockTransferEngine
    /// Main-thread only: engine change callbacks arrive on the main queue.
    private var observers: [UUID: (FetchDockTransferEngine.Transfer) -> Void] = [:]

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FetchDock", isDirectory: true)
        engine = FetchDockTransferEngine(
            identifier: Self.sessionIdentifier,
            root: support.appendingPathComponent("Transfers", isDirectory: true),
            output: support.appendingPathComponent("Completed", isDirectory: true)
        )
        engine.onChange = { [weak self] transfer in
            self?.observers[transfer.id]?(transfer)
        }
    }

    func observe(_ id: UUID, _ handler: @escaping (FetchDockTransferEngine.Transfer) -> Void) {
        observers[id] = handler
    }

    func stopObserving(_ id: UUID) {
        observers[id] = nil
    }

    /// iOS relaunches the app to finish background segments.
    func handleBackgroundEvents(_ completion: @escaping () -> Void) {
        engine.backgroundCompletion = completion
        engine.connect()
    }
}

/// A FetchDock parallel download shown in Firefox's download UI.
final class FetchDockDownload: Download, @unchecked Sendable {
    private let sourceURL: URL
    private let requestHeaders: [String: String]
    private var transferID: UUID?
    private var reportedBytes: Int64 = 0

    init(originWindow: WindowUUID, response: ExternalResponseInfo, url: URL) {
        sourceURL = url
        requestHeaders = response.requestHeaders
        super.init(originWindow: originWindow)
        filename = GeckoDownloadPolicy.filename(for: response)
        mimeType = response.mimeType ?? MIMEType.OctetStream
        totalBytesExpected = response.contentLength
    }

    @MainActor
    override func resume() {
        let service = FetchDockService.shared
        if let transferID {
            service.engine.resume(transferID)
            return
        }
        let id = UUID()
        transferID = id
        service.observe(id) { [weak self] transfer in
            MainActor.assumeIsolated { self?.update(transfer) }
        }
        service.engine.start(id: id, url: sourceURL, filename: filename, headers: requestHeaders, connections: 4)
    }

    override func pause() {
        guard let transferID else { return }
        FetchDockService.shared.engine.pause(transferID)
    }

    override func cancel() {
        guard let transferID else { return }
        FetchDockService.shared.engine.cancel(transferID)
    }

    @MainActor
    private func update(_ transfer: FetchDockTransferEngine.Transfer) {
        if transfer.expected > 0 { totalBytesExpected = transfer.expected }
        if transfer.received > reportedBytes {
            let delta = transfer.received - reportedBytes
            reportedBytes = transfer.received
            bytesDownloaded = transfer.received
            delegate?.download(self, didDownloadBytes: delta)
        }
        switch transfer.state {
        case .completed:
            finish(transfer)
        case .failed:
            FetchDockService.shared.stopObserving(transfer.id)
            let message = transfer.error ?? "FetchDock download failed"
            delegate?.download(self, didCompleteWithError: NSError(
                domain: "FetchDock", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        case .cancelled:
            FetchDockService.shared.stopObserving(transfer.id)
            delegate?.download(self, didCompleteWithError: URLError(.cancelled))
        case .running, .paused:
            break
        }
    }

    @MainActor
    private func finish(_ transfer: FetchDockTransferEngine.Transfer) {
        let service = FetchDockService.shared
        service.stopObserving(transfer.id)
        do {
            let destination = try uniqueDownloadPathForFilename(filename)
            try FileManager.default.moveItem(at: service.engine.fileURL(transfer), to: destination)
            service.engine.remove(transfer.id)
            isComplete = true
            delegate?.download(self, didFinishDownloadingTo: destination)
        } catch {
            delegate?.download(self, didCompleteWithError: error)
        }
    }
}

/// A download Gecko keeps streaming itself, shown in Firefox's download UI.
final class GeckoStreamDownload: Download, @unchecked Sendable {
    private let response: ExternalResponseInfo
    private var started = false
    private var paused = false
    private var cancelled = false

    init(originWindow: WindowUUID, response: ExternalResponseInfo) {
        self.response = response
        super.init(originWindow: originWindow)
        filename = GeckoDownloadPolicy.filename(for: response)
        mimeType = response.mimeType ?? MIMEType.OctetStream
        totalBytesExpected = response.contentLength
    }

    var localFilePath: String { response.localFilePath }

    @MainActor
    override func resume() {
        if paused {
            paused = false
            response.resume()
        }
        started = true
    }

    override func pause() {
        guard started, !paused else { return }
        paused = true
        response.pause()
    }

    override func cancel() {
        guard !cancelled else { return }
        cancelled = true
        response.cancel()
        GeckoStreamRegistry.shared.remove(response.localFilePath)
        ensureMainThread {
            self.delegate?.download(self, didCompleteWithError: URLError(.cancelled))
        }
    }

    /// Returns whether Gecko should keep streaming.
    func received(totalBytes: Int64) -> Bool {
        guard !cancelled else { return false }
        let delta = totalBytes - bytesDownloaded
        guard delta > 0 else { return true }
        bytesDownloaded = totalBytes
        ensureMainThread {
            self.delegate?.download(self, didDownloadBytes: delta)
        }
        return true
    }

    @MainActor
    func complete(succeeded: Bool) {
        guard !cancelled else { return }
        guard succeeded else {
            delegate?.download(self, didCompleteWithError: NSError(
                domain: "GeckoView", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download failed"]))
            return
        }
        do {
            let destination = try uniqueDownloadPathForFilename(filename)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: response.localFilePath), to: destination)
            isComplete = true
            delegate?.download(self, didFinishDownloadingTo: destination)
        } catch {
            delegate?.download(self, didCompleteWithError: error)
        }
    }
}

/// Gecko reports stream progress by local file path.
final class GeckoStreamRegistry: @unchecked Sendable {
    static let shared = GeckoStreamRegistry()
    private let lock = NSLock()
    private var downloads: [String: GeckoStreamDownload] = [:]

    func add(_ download: GeckoStreamDownload) {
        lock.lock(); defer { lock.unlock() }
        downloads[download.localFilePath] = download
    }

    func download(at path: String) -> GeckoStreamDownload? {
        lock.lock(); defer { lock.unlock() }
        return downloads[path]
    }

    @discardableResult
    func remove(_ path: String) -> GeckoStreamDownload? {
        lock.lock(); defer { lock.unlock() }
        return downloads.removeValue(forKey: path)
    }
}

extension BrowserViewController {
    /// Firefox's download prompt for a Gecko download. Calls `decide` with
    /// whether Gecko should keep streaming the response itself.
    func presentGeckoDownload(
        _ response: ExternalResponseInfo,
        isPrivate: Bool,
        from sourceView: UIView,
        decide: @escaping (Bool) -> Void
    ) {
        let filename = GeckoDownloadPolicy.filename(for: response)
        let host = URL(string: response.url)?.host ?? ""
        let size = response.contentLength.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let alert = UIAlertController(
            title: filename,
            message: [size, host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: .OpenInDownloadHelperAlertDownloadNow, style: .default) { [weak self] _ in
            guard let self else { decide(false); return }
            if GeckoDownloadPolicy.usesFetchDock(response, isPrivate: isPrivate),
               let url = URL(string: response.url) {
                response.cancel()
                decide(false)
                downloadQueue.enqueue(FetchDockDownload(originWindow: windowUUID, response: response, url: url))
            } else {
                let download = GeckoStreamDownload(originWindow: windowUUID, response: response)
                GeckoStreamRegistry.shared.add(download)
                decide(true)
                downloadQueue.enqueue(download)
            }
        })
        alert.addAction(UIAlertAction(title: .CancelString, style: .cancel) { _ in decide(false) })
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = CGRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }
}
