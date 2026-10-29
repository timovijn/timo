import Foundation
import Combine
import UserNotifications

@MainActor final class PlanStore: ObservableObject {
    @Published private(set) var items: [PlanItem] = []
    @Published var errorMessage: String?
    private let url: URL
    private var canWrite = true
    private var reminderRevision = 0
    private var reminderWorker: Task<Void, Never>?
    private let notificationCenter = UNUserNotificationCenter.current()
    private struct Document: Codable { var version = 4; var items: [PlanItem] }
    init() {
        url = URL.applicationSupportDirectory.appending(path: "Timo", directoryHint: .isDirectory).appending(path: "plan.json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
                guard (1...4).contains(document.version) else { throw CocoaError(.fileReadCorruptFile) }
                items = document.items
            }
        } catch {
            canWrite = false
            errorMessage = "Your saved plan could not be opened. It has been left untouched. \(error.localizedDescription)"
        }
        notificationCenter.delegate = ReminderNotificationDelegate.shared
        reconcile()
        refreshReminders()
    }
    private func commit(_ updated: [PlanItem]) {
        guard canWrite else { errorMessage = "Saving is disabled to protect the existing plan. Please close the app and resolve the saved-file error."; return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Document(items: updated)).write(to: url, options: .atomic)
            items = updated
            refreshReminders()
        } catch { errorMessage = "This change could not be saved. \(error.localizedDescription)" }
    }
    func reconcile(now: Date = Date()) {
        var updated = items
        if Planner.reconcile(&updated, now: now) { commit(updated) }
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
                let activeIDs = Set(snapshot.filter { !$0.isComplete }.map { "timo.reminder." + $0.id.uuidString })
                let delivered = await notificationCenter.deliveredNotifications()
                notificationCenter.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier)
                    .filter { $0.hasPrefix("timo.reminder.") && !activeIDs.contains($0) })
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { continue }
                for item in Planner.upcomingReminders(in: snapshot, now: Date()) {
                    guard let date = item.reminderAt, date > Date() else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = item.title
                    content.body = "A moment for what you planned."
                    content.sound = .default
                    content.userInfo = ["itemID": item.id.uuidString]
                    let components = Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
                    let request = UNNotificationRequest(identifier: "timo.reminder." + item.id.uuidString,
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
        if let i = updated.firstIndex(where: { $0.id == item.id }) { updated[i] = item }
        else { var fresh = item; fresh.originalDay = fresh.day; updated.append(fresh) }
        // New items use their own carry-over preference, including when saved on a past day.
        Planner.reconcile(&updated, now: Date())
        commit(updated)
    }
    func toggle(_ item: PlanItem) {
        var updated = items
        guard let i = updated.firstIndex(where: { $0.id == item.id }) else { return }
        updated[i].completedAt = updated[i].isComplete ? nil : Date()
        updated[i].suggestionDismissed = false
        Planner.reconcile(&updated, now: Date())
        commit(updated)
    }
    func dismissSuggestion(_ item: PlanItem) {
        var updated = items
        guard let i = updated.firstIndex(where: { $0.id == item.id }) else { return }
        updated[i].suggestionDismissed = true; commit(updated)
    }
    func delete(_ item: PlanItem, children: Bool) {
        var updated = items; Planner.delete(item.id, includingChildren: children, from: &updated); commit(updated)
    }
    func item(_ id: UUID?) -> PlanItem? { items.first { $0.id == id } }
    func children(of item: PlanItem) -> [PlanItem] { items.filter { $0.parentID == item.id }.sorted { $0.createdAt < $1.createdAt } }
    func addSampleDay() {
        guard items.isEmpty else { return }
        let calendar = Calendar.current; let today = Day(Date())
        func date(_ hour: Int, _ minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today.date())! }
        let cooking = PlanItem(title: "Cook dinner", day: today, minute: 19 * 60, end: date(19, 45), movesToNextDay: false)
        let samples = [
            PlanItem(title: "Shave", day: today, minute: 8 * 60),
            PlanItem(title: "Work", day: today, minute: 9 * 60, end: date(17), movesToNextDay: false),
            PlanItem(title: "Sport", day: today, minute: 17 * 60 + 30, end: date(18, 30), movesToNextDay: false),
            cooking,
            PlanItem(title: "Go to the supermarket", day: today, parentID: cooking.id),
            PlanItem(title: "Call Mum", day: today),
            PlanItem(title: "Read", day: today, minute: 21 * 60)
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
