import Foundation
import Combine
import UserNotifications

@MainActor final class PlanStore: ObservableObject {
    @Published private(set) var items: [PlanItem] = []
    private var series: [RepeatingPlan] = []
    private var displayedDay = Day(Date())
    @Published var errorMessage: String?
    private let url: URL
    private var canWrite = true
    private var reminderRevision = 0
    private var reminderWorker: Task<Void, Never>?
    private let notificationCenter = UNUserNotificationCenter.current()
    private struct Document: Codable {
        var version = 6
        var items: [PlanItem]
        var series: [RepeatingPlan]
        private enum CodingKeys: String, CodingKey { case version, items, series }
        init(items: [PlanItem], series: [RepeatingPlan]) { self.items = items; self.series = series }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            items = try values.decode([PlanItem].self, forKey: .items)
            series = try values.decodeIfPresent([RepeatingPlan].self, forKey: .series) ?? []
        }
    }
    init() {
        url = URL.applicationSupportDirectory.appending(path: "Timo", directoryHint: .isDirectory).appending(path: "plan.json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
                guard (1...6).contains(document.version) else { throw CocoaError(.fileReadCorruptFile) }
                items = document.items
                series = document.series
            }
        } catch {
            canWrite = false
            errorMessage = "Your saved plan could not be opened. It has been left untouched. \(error.localizedDescription)"
        }
        notificationCenter.delegate = ReminderNotificationDelegate.shared
        reconcile()
        refreshReminders()
    }
    private func commit(_ updated: [PlanItem], series updatedSeries: [RepeatingPlan]? = nil) {
        guard canWrite else { errorMessage = "Saving is disabled to protect the existing plan. Please close the app and resolve the saved-file error."; return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Document(items: updated, series: updatedSeries ?? series)).write(to: url, options: .atomic)
            items = updated
            if let updatedSeries { series = updatedSeries }
            refreshReminders()
        } catch { errorMessage = "This change could not be saved. \(error.localizedDescription)" }
    }
    @discardableResult private func materialize(_ updated: inout [PlanItem], series plans: [RepeatingPlan], now: Date) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: 60, to: today)!
        let changed = Planner.materialize(plans, in: &updated, from: Day(today), through: Day(horizon))
        // Include earlier starts for overnight/multi-day ranges overlapping the viewed day.
        var selectedChanged = false
        for plan in plans {
            let span = plan.template.end.flatMap { end in plan.template.start().map { max(0, end.timeIntervalSince($0)) } } ?? 0
            let previous = calendar.date(byAdding: .day, value: -(Int(ceil(span / 86400))), to: displayedDay.date())!
            if Planner.materialize([plan], in: &updated, from: Day(previous), through: displayedDay) { selectedChanged = true }
        }
        return changed || selectedChanged
    }
    func showDay(_ day: Day) {
        displayedDay = day
        reconcile()
    }
    func reconcile(now: Date = Date()) {
        var updated = items
        let generated = materialize(&updated, series: series, now: now)
        // Plans saved when carrying moved an item's day get their scheduled days back once.
        let restored = Planner.restoreScheduledDays(&updated)
        if generated || restored { commit(updated) }
    }
    func requestReminderPermission() async throws -> Bool {
        try await notificationCenter.requestAuthorization(options: [.alert, .sound])
    }
    func refreshReminders() {
        guard canWrite else { return }
        reminderRevision += 1
        guard reminderWorker == nil else { return }
        // A single worker always finishes with the newest saved state, even when
        // editing, completing or deleting while notification requests are in flight.
        reminderWorker = Task {
            var processed = -1
            while processed != reminderRevision {
                processed = reminderRevision
                let snapshot = items
                let settings = await notificationCenter.notificationSettings()
                let pending = await notificationCenter.pendingNotificationRequests()
                notificationCenter.removePendingNotificationRequests(withIdentifiers:
                    pending.filter { $0.identifier.hasPrefix("timo.reminder.") }.map(\.identifier))
                // Identifiers are "timo.reminder.<item>.<time>", one per reminder.
                let activeIDs = Set(snapshot.filter { !$0.isComplete }.map(\.id.uuidString))
                let delivered = await notificationCenter.deliveredNotifications()
                notificationCenter.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier)
                    .filter { $0.hasPrefix("timo.reminder.") && !activeIDs.contains(String($0.dropFirst("timo.reminder.".count).prefix(36))) })
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { continue }
                for reminder in Planner.upcomingReminders(in: snapshot, now: Date()) {
                    let item = reminder.item, date = reminder.date
                    guard date > Date() else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = item.title
                    content.body = "A moment for what you planned."
                    content.sound = .default
                    content.userInfo = ["itemID": item.id.uuidString]
                    let components = Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
                    let request = UNNotificationRequest(identifier: "timo.reminder.\(item.id.uuidString).\(Int(date.timeIntervalSince1970))",
                        content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
                    do { try await notificationCenter.add(request) }
                    catch { errorMessage = "Your plan was saved, but a reminder could not be scheduled. \(error.localizedDescription)" }
                }
            }
            reminderWorker = nil
        }
    }
    func save(_ item: PlanItem) throws {
        try Planner.validate(item, in: items)
        var updated = items
        var plans = series
        let previous = items.first { $0.id == item.id }
        var previousDefinition = previous
        previousDefinition?.completedAt = item.completedAt
        previousDefinition?.suggestionDismissed = item.suggestionDismissed
        if (item.repeatRule != .never || previous?.seriesID != nil) && previousDefinition != item {
            Planner.saveRepeating(item, items: &updated, series: &plans)
        } else if let i = updated.firstIndex(where: { $0.id == item.id }) {
            updated[i] = item
        } else {
            var fresh = item; fresh.originalDay = fresh.day; updated.append(fresh)
        }
        materialize(&updated, series: plans, now: Date())
        commit(updated, series: plans)
    }
    /// Ticks an item off, or undoes it. Ticked off while viewing a past day, it counts as done on
    /// that day, so a carried item stops there instead of showing on the days after.
    func toggle(_ item: PlanItem, on day: Day) {
        var updated = items
        guard let i = updated.firstIndex(where: { $0.id == item.id }) else { return }
        updated[i].completedAt = updated[i].isComplete ? nil : Planner.completionDate(on: day, now: Date())
        updated[i].suggestionDismissed = false
        commit(updated)
    }
    func dismissSuggestion(_ item: PlanItem) {
        var updated = items
        guard let i = updated.firstIndex(where: { $0.id == item.id }) else { return }
        updated[i].suggestionDismissed = true; commit(updated)
    }
    func delete(_ item: PlanItem, children: Bool) {
        var updated = items
        var plans = series
        if item.seriesID != nil {
            Planner.deleteSeries(item, items: &updated, series: &plans)
        } else {
            Planner.delete(item.id, includingChildren: children, from: &updated)
        }
        commit(updated, series: plans)
    }
    func item(_ id: UUID?) -> PlanItem? { items.first { $0.id == id } }
    func children(of item: PlanItem) -> [PlanItem] { items.filter { $0.parentID == item.id }.sorted { $0.createdAt < $1.createdAt } }
    func addSampleDay() {
        guard items.isEmpty else { return }
        let calendar = Calendar.current; let today = Day(Date())
        func date(_ hour: Int, _ minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today.date())! }
        func persona(_ persona: Persona, _ item: PlanItem) -> PlanItem { var item = item; item.persona = persona; return item }
        let cooking = persona(.family, PlanItem(title: "Cook dinner", day: today, minute: 19 * 60, end: date(19, 45), movesToNextDay: false))
        let samples = [
            PlanItem(title: "Shave", day: today, minute: 8 * 60),
            persona(.work, PlanItem(title: "Work", day: today, minute: 9 * 60, end: date(17), movesToNextDay: false)),
            persona(.health, PlanItem(title: "Sport", day: today, minute: 17 * 60 + 30, end: date(18, 30), movesToNextDay: false)),
            cooking,
            PlanItem(title: "Go to the supermarket", day: today, parentID: cooking.id),
            persona(.family, PlanItem(title: "Call Mum", day: today)),
            persona(.personal, PlanItem(title: "Read", day: today, minute: 21 * 60))
        ]
        commit(samples)
    }
}

private final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
