import WidgetKit
import SwiftUI

@main struct TimoWidgets: WidgetBundle {
    var body: some Widget {
        ProgressWidget()
        GuideLiveActivity()
    }
}

/// Today's "x/y complete" on the lock screen: a ring, or a line above the clock.
struct ProgressWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Progress", provider: ProgressProvider()) { entry in
            TodayView(entry: entry).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Today")
        .description("How many of today's items are done.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

struct ProgressEntry: TimelineEntry {
    let date: Date
    /// Nil when the plan can't be read, as on a device without the App Group.
    let progress: DayProgress?
}

struct ProgressProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProgressEntry {
        ProgressEntry(date: Date(), progress: DayProgress(items: Self.sample(), day: Day(Date()), now: Date()))
    }
    func getSnapshot(in context: Context, completion: @escaping (ProgressEntry) -> Void) {
        let now = Date()
        // The widget gallery shows a sample day rather than an empty or unreadable one.
        let items = Self.plan()
        let shown = context.isPreview && (items ?? []).isEmpty ? Self.sample() : items
        completion(ProgressEntry(date: now, progress: shown.map { DayProgress(items: $0, day: Day(now), now: now) }))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProgressEntry>) -> Void) {
        let now = Date()
        let items = Self.plan()
        // The app reloads the timeline after every save. Otherwise the count only changes when a
        // running range ends (a carried item moves on) or at midnight, when a new day starts.
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let ends = (items ?? []).compactMap(\.end).filter { $0 > now && $0 < midnight }
        let dates = Set([now, midnight] + ends).sorted()
        completion(Timeline(entries: dates.map { date in
            ProgressEntry(date: date, progress: items.map { DayProgress(items: $0, day: Day(date), now: date) })
        }, policy: .atEnd))
    }

    private struct Document: Decodable { let items: [PlanItem] }
    static func plan() -> [PlanItem]? {
        guard let url = PlanLocation.shared else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Document.self, from: $0).items }
    }
    static func sample() -> [PlanItem] {
        let today = Day(Date())
        return ["Run", "Deep work", "Lunch with Sam", "Gym", "Call the bank"].enumerated().map { index, title in
            var item = PlanItem(title: title, day: today, movesToNextDay: false)
            if index < 3 { item.completedAt = Date() }
            return item
        }
    }
}

struct TodayView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ProgressEntry

    var body: some View {
        Group {
            if let progress = entry.progress {
                switch family {
                case .accessoryInline: inline(progress)
                default: ring(progress)
                }
            } else {
                Text("Open timo")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.progress.map { $0.total == 0 ? "Nothing planned today" : "\($0.done) of \($0.total) done today" }
                            ?? "Open timo to show your day")
    }

    private func ring(_ progress: DayProgress) -> some View {
        Gauge(value: Double(progress.done), in: 0...Double(max(progress.total, 1))) {
            Text("Today")
        } currentValueLabel: {
            if progress.total == 0 {
                Image(systemName: "checkmark")
            } else {
                Text("\(progress.done)/\(progress.total)")
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private func inline(_ progress: DayProgress) -> some View {
        Label {
            Text(progress.total == 0 ? "Nothing planned" : "\(progress.done) of \(progress.total) done")
        } icon: {
            Image(systemName: "checklist")
        }
    }
}
