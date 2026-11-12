import ActivityKit
import AppIntents
import SwiftUI

// Compiled into the app and the widget: the widget draws the Live Activity, the app starts it
// and completes items from its button.

extension Persona {
    /// Each persona's own gradient, light to deep, so its orb can be told apart at a glance.
    var colors: [Color] {
        switch self {
        case .health: return [.mint, .green]
        case .work: return [.cyan, .blue]
        case .family: return [.yellow, .orange]
        case .friends: return [.pink, .red]
        case .personal: return [.purple, .indigo]
        }
    }
    /// The persona's deeper colour, for text and tints.
    var color: Color { colors[1] }
}

/// One timed item followed on the lock screen and in the Dynamic Island, from shortly before its
/// start to its end (or, for a single moment, until it's ticked off).
struct GuideAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        var title: String
        var start: Date
        /// Nil for a single moment.
        var end: Date?
        var personas: [Persona]
    }
    var itemID: String
    /// How long before its start an item's activity appears.
    static let lead: TimeInterval = 15 * 60
    /// Where tapping the activity goes: iOS always opens the app, so at least it opens this item.
    var itemURL: URL? { URL(string: "timo://item/\(itemID)") }
    /// Part of the activity's identity, so moving an item starts a new one at the new time.
    var start: Date
}

extension GuideAttributes.ContentState {
    init(_ stop: GuideStop) {
        self.init(title: stop.item.title, start: stop.start, end: stop.end, personas: stop.item.personas)
    }
}

extension GuideAttributes.ContentState {
    /// Where the item's time stands. A Live Activity is only redrawn when the app updates it or
    /// it turns stale, so the stale date is always the next of these changes (`staleDate(now:)`)
    /// and the views read the phase when they're drawn.
    enum Phase { case upcoming, running, over }
    func phase(isStale: Bool, now: Date = Date()) -> Phase {
        // Stale means at least the start has come, even if the clock reads a moment earlier.
        if !isStale && now < start { return .upcoming }
        if let end, now < end { return .running }
        return .over
    }
    /// The start while it's still ahead, otherwise the end of a range; a moment has nothing after
    /// its start. Started ahead of time by itself, an activity only turns stale at the start, so
    /// its countdown stops at zero rather than running past the end (`TimeLeft`).
    static func staleDate(for stop: GuideStop, now: Date) -> Date {
        now < stop.start ? stop.start : stop.finish
    }
    var range: String {
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end else { return from }
        return "\(from)–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

/// Ticks the item off from its Live Activity. It runs in the app, which then ends the activity.
struct CompleteGuideItemIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Complete Item"
    static let isDiscoverable = false
    @Parameter(title: "Item") var itemID: String
    init() {}
    init(itemID: String) { self.itemID = itemID }
    func perform() async throws -> some IntentResult {
        #if !TIMO_WIDGET
        await MainActor.run { PlanStore.shared.complete(itemID: itemID) }
        #endif
        return .result()
    }
}
