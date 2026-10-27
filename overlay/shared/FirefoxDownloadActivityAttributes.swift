import ActivityKit
import Foundation

/// Duplicated into the host and WidgetKit extension so both use the same wire format.
@available(iOS 16.1, *)
struct FirefoxDownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let filename: String
        let received: Int64
        let expected: Int64?
        let bytesPerSecond: Int64
        let activeCount: Int
        let paused: Bool

        var progress: Double? {
            guard let expected, expected > 0 else { return nil }
            return min(1, max(0, Double(received) / Double(expected)))
        }
    }

    let downloadSession: String
}
