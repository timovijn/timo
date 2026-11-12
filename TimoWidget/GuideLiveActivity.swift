import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// "Guide my day": a timed item from 15 minutes before it starts, how soon it starts, then how much
/// of its time is left. The countdowns and bar run by themselves; the activity turns stale at the
/// start and again at the end (`ContentState.staleDate`), which redraws it for the next phase.    
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

/// The time bar, the scheduled range and the Complete button, shared by the lock screen and the
/// expanded Dynamic Island.
private struct GuideDetails: View {
    let context: ActivityViewContext<GuideAttributes>
    /// For the island, whose title row has no room for it. A live count takes all the width
    /// it's offered and `fixedSize` stops it drawing at all, so it fills the rest of a line.
    var showsTimeLeft = false
    var body: some View {
        let state = context.state
        let range = Text(state.range)
        let phase = state.phase(isStale: context.isStale)
        VStack(alignment: .leading, spacing: 8) {
            // Says whether the item has started, since "in 12 minutes" and "12 minutes left" look
            // alike at a glance, and "Past" beside "12 minutes ago". Only on the lock screen: the
            // expanded island has no line to spare.
            if !showsTimeLeft {
                Text(phase == .upcoming ? "Upcoming" : phase == .running ? "Ongoing" : "Past")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(phase == .running ? state.personas.first?.color ?? .primary : Color.secondary)
                    .padding(.bottom, -4)
            }
            TimeProgress(state: state)
                .tint(state.personas.first?.color ?? .primary)
                // The system's own track is barely darker than the activity, so an item yet to
                // start looked as if it had no bar; a light grey one shows it's there. The bar is 4
                // points tall in a taller frame.
                .background(Capsule().fill(Color.secondary.opacity(0.45)).frame(height: 4))
                .accessibilityHidden(true)
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
                if !showsTimeLeft {
                    range
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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

/// The bar or ring of an item's time: empty until it starts, then for a range filling by itself
/// over its time (so the start needs no redraw), and full once the time is over. A moment has no
/// time of its own, so its bar is empty until it comes and full after.
private struct TimeProgress: View {
    let state: GuideAttributes.ContentState
    var body: some View {
        if let end = state.end {
            ProgressView(timerInterval: state.start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
        } else {
            // A one-second timer rather than a fixed value: a value of 0 drew no track at all.
            ProgressView(timerInterval: state.start...state.start.addingTimeInterval(1), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
        }
    }
}

/// A ring filling as the item's time passes, and a checkmark to tick it off once it's up.
private struct TimeRing: View {
    let state: GuideAttributes.ContentState
    let isStale: Bool
    var body: some View {
        let tint = state.personas.first?.color ?? .primary
        if state.phase(isStale: isStale) == .over {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(tint)
                .accessibilityLabel(Text("Ended at \((state.end ?? state.start).formatted(date: .omitted, time: .shortened))"))
        } else {
            TimeProgress(state: state)
                .progressViewStyle(.circular)
                .tint(tint)
                .accessibilityLabel(Text(state.end.map { "Ends at \($0.formatted(date: .omitted, time: .shortened))" }
                    ?? "At \(state.start.formatted(date: .omitted, time: .shortened))"))
        }
    }
}

/// "In 12 minutes" before the start, then "35 minutes left" while a range runs, counting by
/// itself; "12 minutes ago" once a range has ended or a moment has come, counting from then.
private struct TimeLeft: View {
    let state: GuideAttributes.ContentState
    let isStale: Bool
    var body: some View {
        switch state.phase(isStale: isStale) {
        case .upcoming:
            // Whole minutes, which the dimmed Lock Screen keeps showing, where it hides seconds.
            Text(.currentDate, format: .reference(to: state.start, allowedFields: [.hour, .minute]))
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text("Starts at \(state.start.formatted(date: .omitted, time: .shortened))"))
        case .running:
            if let end = state.end {
                // A timer stops at zero: an activity started ahead of time turns stale at the start,
                // not the end, so without the app this count is still showing at the end.
                HStack(spacing: 3) {
                    Text(.currentDate, format: .timer(countingDownIn: state.start..<end, maxFieldCount: 2, maxPrecision: .seconds(60)))
                        .multilineTextAlignment(.trailing)
                    Text("left")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Ends at \(end.formatted(date: .omitted, time: .shortened))"))
            }
        case .over:
            // Counts by itself, so it says how long the item has waited without the app updating it.
            // Whole minutes counted from a minute earlier, so the first minute reads "1 minute ago"
            // rather than "0". The relative-date format read "This minute" there, and later ran
            // a minute or two ahead.
            HStack(spacing: 3) {
                Text(.currentDate, format: .offset(to: (state.end ?? state.start) - 60, allowedFields: [.hour, .minute], maxFieldCount: 1, sign: .never))
                    .multilineTextAlignment(.trailing)
                Text("ago")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Ended at \((state.end ?? state.start).formatted(date: .omitted, time: .shortened))"))
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
