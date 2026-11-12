import ActivityKit
import Foundation

/// Keeps the "Guide my day" Live Activities in step with the plan: one per timed item of today,
/// scheduled to start a little before the item so it appears while the app isn't running, updated
/// when the item changes and ended once it's ticked off, cancelled, moved or deleted.
@MainActor final class DayGuideActivities {
    static let settingKey = "guideMyDay"
    /// How many items to come are scheduled ahead; the system limits how many can wait.
    static let lookahead = 4
    static let lead = GuideAttributes.lead
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }
    private var latest: [PlanItem] = []
    private var revision = 0
    private var worker: Task<Void, Never>?

    /// When an item's activity appears.
    static func shown(_ stop: GuideStop) -> Date { stop.start - lead }

    /// The items followed now: those shown already (starting soon, running, or over unticked
    /// today), and the next few to come.
    static func followed(_ items: [PlanItem], now: Date) -> [GuideStop] {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return [] }
        let stops = DayGuide.stops(in: items, now: now)
        return stops.filter { shown($0) <= now } + stops.filter { shown($0) > now }.prefix(lookahead)
    }

    func refresh(_ items: [PlanItem]) {
        latest = items
        revision += 1
        guard worker == nil else { return }
        // Like reminders, a single worker always finishes with the newest plan.
        worker = Task {
            var processed = -1
            while processed != revision {
                processed = revision
                await apply(latest, now: Date())
            }
            worker = nil
        }
    }

    private func apply(_ items: [PlanItem], now: Date) async {
        var wanted = Dictionary(Self.followed(items, now: now).map {
            (GuideAttributes(itemID: $0.item.id.uuidString, start: $0.start), $0)
        }, uniquingKeysWith: { first, _ in first })
        for activity in Activity<GuideAttributes>.activities {
            if activity.activityState == .ended || activity.activityState == .dismissed { continue }
            guard let stop = wanted.removeValue(forKey: activity.attributes) else {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            let state = GuideAttributes.ContentState(stop)
            let staleDate = GuideAttributes.ContentState.staleDate(for: stop, now: now)
            if activity.content.state != state || activity.content.staleDate != staleDate {
                await activity.update(ActivityContent(state: state, staleDate: staleDate))
            }
        }
        // An item whose time is already over keeps the activity it had, but doesn't get a new one.
        for (attributes, stop) in wanted where stop.finish > now {
            let state = GuideAttributes.ContentState(stop)
            let content = ActivityContent(state: state, staleDate: GuideAttributes.ContentState.staleDate(for: stop, now: now))
            do {
                if Self.shown(stop) <= now {
                    _ = try Activity.request(attributes: attributes, content: content)
                } else {
                    // A scheduled activity announces its item when it appears; a reminder at that
                    // moment is left out (`announcements`), so the item isn't announced twice.
                    _ = try Activity.request(attributes: attributes, content: content, style: .standard,
                                             alertConfiguration: AlertConfiguration(title: "\(stop.item.title)", body: "\(state.range)", sound: .default),
                                             start: Self.shown(stop))
                }
            } catch { /* Over the system's limit; the rest are scheduled on a later refresh. */ }
        }
    }

    /// When the guide announces each item it has scheduled, so a reminder at that same moment can
    /// be skipped.
    static func announcements(_ items: [PlanItem], now: Date) -> [UUID: Date] {
        Dictionary(followed(items, now: now).filter { shown($0) > now }.map { ($0.item.id, shown($0)) },
                   uniquingKeysWith: { first, _ in first })
    }
}
