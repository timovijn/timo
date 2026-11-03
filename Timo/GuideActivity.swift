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

/// One timed item followed on the lock screen and in the Dynamic Island, from its start to its end.
struct GuideAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        var title: String
        var start: Date
        var end: Date
        var personas: [Persona]
        var nextTitle: String?
        var nextStart: Date?
    }
    var itemID: String
    /// Part of the activity's identity, so moving an item starts a new one at the new time.
    var start: Date
}

extension GuideAttributes.ContentState {
    init(_ stop: GuideStop) {
        self.init(title: stop.item.title, start: stop.start, end: stop.end, personas: stop.item.personas,
                  nextTitle: stop.next?.title, nextStart: stop.nextStart)
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
