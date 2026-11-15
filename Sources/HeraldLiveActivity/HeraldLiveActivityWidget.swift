#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import SwiftUI
import WidgetKit

/// Add `HeraldLiveActivityWidget()` to your widget extension's `WidgetBundle` and set
/// `NSSupportsLiveActivities` to YES in the app's Info.plist.
@available(iOS 16.1, *)
public struct HeraldLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: HeraldActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text(context.state.title).font(.headline)
                Text(context.state.body).font(.subheadline).lineLimit(2)
                HeraldActivityMeter(state: context.state)
            }
            .padding()
            .widgetURL(context.attributes.deeplinkURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.state.body).font(.subheadline).lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HeraldActivityMeter(state: context.state)
                }
            } compactLeading: {
                HeraldActivityIcon(state: context.state)
            } compactTrailing: {
                HeraldActivityShortValue(state: context.state)
            } minimal: {
                HeraldActivityIcon(state: context.state)
            }
            .widgetURL(context.attributes.deeplinkURL)
        }
    }
}

extension HeraldActivityAttributes {
    var deeplinkURL: URL? { deeplink.flatMap(URL.init(string:)) }
}

extension HeraldActivityAttributes.ContentState {
    var endDate: Date? { endsAt.map { Date(timeIntervalSince1970: $0) } }
    var clampedProgress: Double? { progress.map { min(max($0, 0), 1) } }
}

/// `now...end`, safe once the end has passed (a reversed range would trap).
private func countdownRange(to end: Date) -> ClosedRange<Date> {
    min(Date(), end)...end
}

/// A progress bar in progress mode, countdown text in countdown mode.
@available(iOS 16.1, *)
struct HeraldActivityMeter: View {
    let state: HeraldActivityAttributes.ContentState

    var body: some View {
        if let progress = state.clampedProgress {
            ProgressView(value: progress)
        } else if let end = state.endDate {
            Text(timerInterval: countdownRange(to: end), countsDown: true).monospacedDigit()
        }
    }
}

/// A small progress ring, or a timer icon in countdown mode.
@available(iOS 16.1, *)
struct HeraldActivityIcon: View {
    let state: HeraldActivityAttributes.ContentState

    var body: some View {
        if let progress = state.clampedProgress {
            ProgressView(value: progress).progressViewStyle(.circular)
        } else {
            Image(systemName: "timer")
        }
    }
}

/// A percentage, or a short countdown.
@available(iOS 16.1, *)
struct HeraldActivityShortValue: View {
    let state: HeraldActivityAttributes.ContentState

    var body: some View {
        if let progress = state.clampedProgress {
            Text("\(Int((progress * 100).rounded()))%").monospacedDigit()
        } else if let end = state.endDate {
            Text(timerInterval: countdownRange(to: end), countsDown: true)
                .monospacedDigit()
                .frame(maxWidth: 48)
        }
    }
}
#endif
