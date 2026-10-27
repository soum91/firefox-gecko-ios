import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct FirefoxDownloadWidget: Widget {
    let kind = "FirefoxDownloadWidget"

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FirefoxDownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: context.state.paused ? "pause.circle" : "arrow.down.circle.fill")
                    Text(context.state.filename).lineLimit(1)
                    Spacer(minLength: 4)
                    if context.state.activeCount > 1 {
                        Text("\(context.state.activeCount) files").font(.caption2)
                    }
                }
                if let fraction = context.state.progress {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))% • \(size(context.state.bytesPerSecond))/s")
                        .font(.caption2)
                } else {
                    Text("\(size(context.state.received)) received • \(size(context.state.bytesPerSecond))/s")
                        .font(.caption2)
                }
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.filename).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        if let fraction = context.state.progress {
                            ProgressView(value: fraction)
                            Text("\(Int(fraction * 100))% • \(size(context.state.bytesPerSecond))/s")
                        } else {
                            Text("\(size(context.state.received)) • \(size(context.state.bytesPerSecond))/s")
                        }
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill")
            } compactTrailing: {
                if let fraction = context.state.progress {
                    Text("\(Int(fraction * 100))%")
                } else {
                    Image(systemName: "ellipsis")
                }
            } minimal: {
                Image(systemName: "arrow.down")
            }
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@main
@available(iOS 16.1, *)
struct FirefoxDownloadWidgetBundle: WidgetBundle {
    var body: some Widget {
        FirefoxDownloadWidget()
    }
}
