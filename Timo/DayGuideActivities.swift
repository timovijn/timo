import ActivityKit
import Foundation

/// Keeps the "Guide my day" Live Activities in step with the plan: one per timed item of today,
/// scheduled to start at the item's start so it appears while the app isn't running, updated when
/// the item changes and ended once it's ticked off, cancelled, moved or deleted.
@MainActor final class DayGuideActivities {
    static let settingKey = "guideMyDay"
    /// How many items to come are scheduled ahead; the system limits how many can wait.
    static let lookahead = 4
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }
    private var latest: [PlanItem] = []
    private var revision = 0
    private var worker: Task<Void, Never>?

    /// The items followed now: those running or ended unticked today, and the next few to come.
    static func followed(_ items: [PlanItem], now: Date) -> [GuideStop] {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return [] }
        let stops = DayGuide.stops(in: items, now: now)
        return stops.filter { $0.start <= now } + stops.filter { $0.start > now }.prefix(lookahead)
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
            if activity.content.state != state || activity.content.staleDate != stop.end {
                await activity.update(ActivityContent(state: state, staleDate: stop.end))
            }
        }
        // An item whose time already ended keeps the activity it had, but doesn't get a new one.
        for (attributes, stop) in wanted where stop.end > now {
            let content = ActivityContent(state: GuideAttributes.ContentState(stop), staleDate: stop.end)
            do {
                if stop.start <= now {
                    _ = try Activity.request(attributes: attributes, content: content)
                } else {
                    // A scheduled activity announces itself when it starts; reminders at that
                    // moment are left out (`announcedStarts`), so the item isn't announced twice.
                    let range = "\(stop.start.formatted(date: .omitted, time: .shortened))–\(stop.end.formatted(date: .omitted, time: .shortened))"
                    _ = try Activity.request(attributes: attributes, content: content, style: .standard,
                                             alertConfiguration: AlertConfiguration(title: "\(stop.item.title)", body: "\(range)", sound: .default),
                                             start: stop.start)
                }
            } catch { /* Over the system's limit; the rest are scheduled on a later refresh. */ }
        }
    }

    /// Items whose start the guide announces, so a reminder at that same moment can be skipped.
    static func announcedStarts(_ items: [PlanItem], now: Date) -> Set<UUID> {
        Set(followed(items, now: now).filter { $0.start > now }.map(\.item.id))
    }
}
