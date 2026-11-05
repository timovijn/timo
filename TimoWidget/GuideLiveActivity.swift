import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// "Guide my day": the timed item under way, how much of its time is left, and what comes next.
/// The countdown and bar run by themselves; once the time is up the activity goes stale and asks
/// to tick the item off instead.
struct GuideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GuideAttributes.self) { context in
            GuideLockScreenView(context: context)
                .activityBackgroundTint(nil)
                .widgetURL(context.attributes.itemURL)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                // The corners hold what the compact island shows. "48 minutes left" wrapped into
                // fragments in a corner, so it sits on the range's line below the bar.
                DynamicIslandExpandedRegion(.leading) {
                    PersonaDot(personas: state.personas).padding(.leading, 6).padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimeRing(state: state, isStale: context.isStale)
                        .frame(width: 22, height: 22)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    GuideDetails(context: context, showsTimeLeft: true).padding(.horizontal, 6)
                }
            } compactLeading: {
                PersonaDot(personas: state.personas)
            } compactTrailing: {
                // Too narrow for "35 minutes"; a ring fills as the time passes.
                TimeRing(state: state, isStale: context.isStale)
            } minimal: {
                TimeRing(state: state, isStale: context.isStale)
            }
            .widgetURL(context.attributes.itemURL)
            .keylineTint(state.personas.first?.color)
        }
    }
}

private struct GuideLockScreenView: View {
    let context: ActivityViewContext<GuideAttributes>
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PersonaDot(personas: context.state.personas)
                Text(context.state.title).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                TimeLeft(state: context.state, isStale: context.isStale)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            GuideDetails(context: context)
        }
        .padding(16)
    }
}

/// The time bar, the scheduled range, "Next" and the Complete button, shared by the lock screen
/// and the expanded Dynamic Island.
private struct GuideDetails: View {
    let context: ActivityViewContext<GuideAttributes>
    /// For the island, whose title row has no room for it. A live count takes all the width
    /// it's offered and `fixedSize` stops it drawing at all, so it fills the rest of a line.
    var showsTimeLeft = false
    var body: some View {
        let state = context.state
        let range = Text("\(state.start.formatted(date: .omitted, time: .shortened))–\(state.end.formatted(date: .omitted, time: .shortened))")
        VStack(alignment: .leading, spacing: 8) {
            if !context.isStale {
                ProgressView(timerInterval: state.start...state.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(state.personas.first?.color ?? .primary)
                    .accessibilityHidden(true)
            }
            if showsTimeLeft {
                HStack(spacing: 8) {
                    range
                    TimeLeft(state: state, isStale: context.isStale)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if !showsTimeLeft { range }
                    if let next = state.nextTitle, let start = state.nextStart {
                        Text("Next: \(next) · \(start.formatted(date: .omitted, time: .shortened))").lineLimit(1)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(intent: CompleteGuideItemIntent(itemID: context.attributes.itemID)) {
                    Label("Complete", systemImage: "checkmark")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(state.personas.first?.color ?? .primary)
                .accessibilityLabel("Complete \(state.title)")
            }
        }
    }
}

/// A ring filling as the item's time passes, and a checkmark to tick it off once it's up.
private struct TimeRing: View {
    let state: GuideAttributes.ContentState
    let isStale: Bool
    var body: some View {
        if isStale || state.end <= Date() {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(state.personas.first?.color ?? .primary)
                .accessibilityLabel("Time’s up")
        } else {
            ProgressView(timerInterval: state.start...state.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.circular)
                .tint(state.personas.first?.color ?? .primary)
                .accessibilityLabel(Text("Ends at \(state.end.formatted(date: .omitted, time: .shortened))"))
        }
    }
}

/// "35 minutes left" while the item runs, counting down by itself; "Time's up" once it has ended.
private struct TimeLeft: View {
    let state: GuideAttributes.ContentState
    let isStale: Bool
    var body: some View {
        if isStale || state.end <= Date() {
            Text("Time’s up")
        } else if state.start > Date() {
            Text(state.start, style: .time)
        } else {
            // Whole minutes, which the dimmed Lock Screen keeps showing, where it hides seconds.
            HStack(spacing: 3) {
                Text(.currentDate, format: .offset(to: state.end, allowedFields: [.hour, .minute], sign: .never))
                    .multilineTextAlignment(.trailing)
                Text("left")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Ends at \(state.end.formatted(date: .omitted, time: .shortened))"))
        }
    }
}

/// The item's persona colour, or a neutral dot when it has none.
private struct PersonaDot: View {
    let personas: [Persona]
    var body: some View {
        Circle()
            .fill(personas.first?.color ?? Color.secondary)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}
