import ActivityKit
import Foundation
import UIKit

/// Mirrors DownloadStore snapshots. It does not keep the app running in the background.
@available(iOS 16.1, *)
@MainActor
final class FirefoxDownloadActivityCoordinator {
    static let shared = FirefoxDownloadActivityCoordinator()

    private var observers: [NSObjectProtocol] = []
    private var activity: Activity<FirefoxDownloadActivityAttributes>?
    private var refreshTask: Task<Void, Never>?
    private var lastContent: FirefoxDownloadActivityAttributes.ContentState?
    private var lastUpdated = Date.distantPast

    private init() {}

    func startObserving() {
        guard observers.isEmpty else { return }
        activity = Activity<FirefoxDownloadActivityAttributes>.activities.first
        for name: Notification.Name in [.downloadStoreDidChange, .downloadStoreDidStartDownload] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
        scheduleRefresh(immediate: true)
    }

    private func scheduleRefresh(immediate: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let downloads = DownloadStore.shared.currentSnapshot().items.filter {
            $0.state == .downloading || $0.state == .paused
        }
        guard let selected = downloads.first else {
            if let activity {
                await activity.end(using: lastContent, dismissalPolicy: .after(Date().addingTimeInterval(30)))
                self.activity = nil
                lastContent = nil
            }
            return
        }

        let state = FirefoxDownloadActivityAttributes.ContentState(
            filename: selected.fileName,
            received: max(0, selected.downloadedBytes),
            expected: selected.totalBytes,
            bytesPerSecond: max(0, selected.bytesPerSecond),
            activeCount: downloads.count,
            paused: downloads.allSatisfy { $0.state == .paused }
        )

        if activity == nil {
            // Starting an Activity in the background is not supported on iOS 16.1.
            guard UIApplication.shared.applicationState == .active else { return }
            do {
                activity = try Activity.request(
                    attributes: FirefoxDownloadActivityAttributes(downloadSession: "browser-downloads"),
                    contentState: state,
                    pushType: nil
                )
                lastContent = state
                lastUpdated = Date()
            } catch {
                NSLog("Firefox download Live Activity request failed: %@", String(describing: error))
            }
            return
        }

        // Avoid flooding ActivityKit with progress callbacks from parallel transfers.
        guard state != lastContent, Date().timeIntervalSince(lastUpdated) >= 4 else { return }
        await activity?.update(using: state)
        lastContent = state
        lastUpdated = Date()
    }
}
