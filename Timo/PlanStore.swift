import Foundation
import Combine
import UserNotifications
import WidgetKit

@MainActor final class PlanStore: ObservableObject {
    /// One store for the app and for intents run from its Live Activities.
    static let shared = PlanStore()
    @Published private(set) var items: [PlanItem] = []
    let cloud = CloudSync()
    private let guide = DayGuideActivities()
    private var series: [RepeatingPlan] = []
    var repeatingPlans: [RepeatingPlan] { series }
    private var displayedDay = Day(Date())
    @Published var errorMessage: String?
    /// Kept until the day view is ready, including when a reminder launches the app.
    @Published var reminderItemToFocus: UUID?
    /// The most recent deletion, offered for undoing until it is undone or dismissed.
    @Published var lastDeletion: PlanDeletion?
    private weak var deletionUndoManager: UndoManager?
    private let url: URL
    private var canWrite = true
    /// What this store last read or wrote, so its own saves aren't taken for another device's.
    private var savedData: Data?
    #if targetEnvironment(simulator)
    private var planWatcher: DispatchSourceFileSystemObject?
    #endif
    private var reminderRevision = 0
    private var reminderWorker: Task<Void, Never>?
    private let notificationCenter = UNUserNotificationCenter.current()
    private struct Document: Codable {
        var version = 8
        var items: [PlanItem]
        var series: [RepeatingPlan]
        private enum CodingKeys: String, CodingKey { case version, items, series }
        init(items: [PlanItem], series: [RepeatingPlan]) { self.items = items; self.series = series }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            items = try values.decode([PlanItem].self, forKey: .items)
            series = try values.decodeIfPresent([RepeatingPlan].self, forKey: .series) ?? []
            // Older versions disabled the stored preference for all repeats. Preserve the
            // previous behaviour for Anytime repeats while making it editable from now on.
            if version < 8 {
                for index in items.indices where items[index].seriesID != nil && items[index].minute == nil {
                    items[index].movesToNextDay = true
                }
                for index in series.indices where series[index].template.minute == nil {
                    series[index].template.movesToNextDay = true
                }
            }
        }
    }
    init() {
        url = PlanLocation.appURL()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                let document = try JSONDecoder().decode(Document.self, from: data)
                guard (1...8).contains(document.version) else { throw CocoaError(.fileReadCorruptFile) }
                items = document.items
                series = document.series
                savedData = data
            }
        } catch {
            canWrite = false
            errorMessage = "Your saved plan could not be opened. It has been left untouched. \(error.localizedDescription)"
        }
        notificationCenter.delegate = ReminderNotificationDelegate.shared
        reconcile()
        refreshReminders()
        // Never sync a plan that couldn't be read, so iCloud can't overwrite or lose it.
        if canWrite { cloud.attach(self) }
        #if targetEnvironment(simulator)
        if canWrite { watchPlanFile() }
        #endif
    }
    #if targetEnvironment(simulator)
    /// The simulators share one plan file (`PlanLocation.simulators`), and several can be open at
    /// once, so a save on one shows on the others straight away. Without this, an open iPad would
    /// write its older plan back over the iPhone's next change. The folder is watched, since a
    /// save replaces the file rather than writing into it.
    private func watchPlanFile() {
        // A new installation may not have saved anything yet. Watch its folder from
        // the start, so the first save on the other simulator is picked up too.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let folder = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard folder >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: .write, queue: .main)
        watcher.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reloadFromOtherDevice() } }
        watcher.setCancelHandler { close(folder) }
        watcher.resume()
        planWatcher = watcher
    }
    private func reloadFromOtherDevice() {
        guard let data = try? Data(contentsOf: url), data != savedData,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              (1...8).contains(document.version) else { return }
        savedData = data
        items = document.items
        series = document.series
        refreshReminders()
        WidgetCenter.shared.reloadAllTimelines()
    }
    #endif
    /// Saves the plan. Changes are also queued for iCloud, except those that came from it.
    private func commit(_ updated: [PlanItem], series updatedSeries: [RepeatingPlan]? = nil, fromCloud: Bool = false) {
        guard canWrite else { errorMessage = "Saving is disabled to protect the existing plan. Please close the app and resolve the saved-file error."; return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Document(items: updated, series: updatedSeries ?? series))
            try data.write(to: url, options: .atomic)
            savedData = data
            if !fromCloud { cloud.queueChanges(items: items, updated, series: series, updatedSeries ?? series) }
            items = updated
            if let updatedSeries { series = updatedSeries }
            refreshReminders()
            WidgetCenter.shared.reloadAllTimelines()
        } catch { errorMessage = "This change could not be saved. \(error.localizedDescription)" }
    }
    @discardableResult private func materialize(_ updated: inout [PlanItem], series plans: [RepeatingPlan], now: Date) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: 60, to: today)!
        var changed = false
        for plan in plans {
            // Carrying repeats can still be unfinished on days the app was never opened.
            // Generate those occurrences as well, retaining their original occurrence keys.
            let first = plan.template.carries ? plan.template.day : Day(today)
            if Planner.materialize([plan], in: &updated, from: first, through: Day(horizon)) { changed = true }
        }
        // Include earlier starts for overnight/multi-day ranges overlapping the viewed day.
        var selectedChanged = false
        for plan in plans {
            let span = plan.template.end.flatMap { end in plan.template.start().map { max(0, end.timeIntervalSince($0)) } } ?? 0
            let previous = calendar.date(byAdding: .day, value: -(Int(ceil(span / 86400))), to: displayedDay.date())!
            if Planner.materialize([plan], in: &updated, from: Day(previous), through: displayedDay) { selectedChanged = true }
        }
        return changed || selectedChanged
    }
    /// Writes what iCloud brought. Occurrences doubled by two devices are then folded into one
    /// and missing ones generated, both as ordinary saves, so iCloud gets the result.
    func applyFromCloud(items updated: [PlanItem], series updatedSeries: [RepeatingPlan]) {
        guard updated != items || updatedSeries != series else { return }
        commit(updated, series: updatedSeries, fromCloud: true)
        var folded = items
        if Planner.mergeDuplicateOccurrences(&folded) { commit(folded) }
        reconcile()
    }
    /// Generates every repeating item's days through `last`, for a persona page or search that
    /// shows repeats that far ahead. Days are otherwise generated about 60 days ahead.
    func generateRepeats(through last: Day) {
        var updated = items
        if Planner.materialize(series, in: &updated, from: Day(Date()), through: last) { commit(updated) }
    }
    /// Whether a repeating item among `listed` goes on past `day`.
    func repeats(_ listed: [PlanItem], after day: Day) -> Bool {
        Planner.repeats(Set(listed.compactMap(\.seriesID)), in: series, after: day)
    }
    func showDay(_ day: Day) {
        displayedDay = day
        reconcile()
    }
    func reconcile(now: Date = Date()) {
        #if targetEnvironment(simulator)
        // Folder events can be missed while suspended; refresh before generating or saving
        // occurrences on return to the foreground and on the regular day refresh.
        if canWrite { reloadFromOtherDevice() }
        #endif
        var updated = items
        let generated = materialize(&updated, series: series, now: now)
        // Plans saved when carrying moved an item's day get their scheduled days back once.
        let restored = Planner.restoreScheduledDays(&updated)
        if generated || restored { commit(updated) }
    }
    func requestReminderPermission() async throws -> Bool {
        try await notificationCenter.requestAuthorization(options: [.alert, .sound])
    }
    /// Brings reminders and the "Guide my day" Live Activities in line with the saved plan.
    func refreshReminders() {
        guard canWrite else { return }
        guide.refresh(items)
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
                let activeIDs = Set(snapshot.filter { !$0.isSettled }.map(\.id.uuidString))
                let delivered = await notificationCenter.deliveredNotifications()
                notificationCenter.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier)
                    .filter { $0.hasPrefix("timo.reminder.") && !activeIDs.contains(String($0.dropFirst("timo.reminder.".count).prefix(36))) })
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { continue }
                let announced = DayGuideActivities.announcedStarts(snapshot, now: Date())
                for reminder in Planner.upcomingReminders(in: snapshot, now: Date()) {
                    let item = reminder.item, date = reminder.date
                    guard date > Date() else { continue }
                    if announced.contains(item.id) && date == item.start() { continue }
                    let content = UNMutableNotificationContent()
                    content.title = item.title
                    content.body = reminderBody(for: item, at: date)
                    content.sound = .default
                    // A reminder is something the user asked for at that moment, so it may
                    // break through a Focus where they allow timo's Time Sensitive notifications.
                    content.interruptionLevel = .timeSensitive
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
    /// Relative dates are based on delivery, since reminders may be scheduled days ahead.
    private func reminderBody(for item: PlanItem, at delivery: Date) -> String {
        let calendar = Calendar.current
        func dayLabel(_ date: Date) -> String {
            if calendar.isDate(date, inSameDayAs: delivery) { return "Today" }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: delivery),
               calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        }
        func when(_ date: Date, sentenceStart: Bool = false) -> String {
            let day = dayLabel(date)
            let label = !sentenceStart && (day == "Today" || day == "Tomorrow") ? day.lowercased() : day
            return "\(label) at \(date.formatted(date: .omitted, time: .shortened))"
        }
        var lines: [String] = []
        if let start = item.start(calendar: calendar) {
            var schedule = when(start, sentenceStart: true)
            if let end = item.end {
                let ending = calendar.isDate(start, inSameDayAs: end)
                    ? end.formatted(date: .omitted, time: .shortened) : when(end)
                schedule += " – \(ending)"
            }
            let minutes = Int(ceil(start.timeIntervalSince(delivery) / 60))
            if minutes > 0 {
                schedule += " · in \(minutes)m"
            } else if start == delivery {
                schedule += " · now"
            }
            lines.append(schedule)
        } else {
            lines.append("Anytime · \(dayLabel(item.liveDay(now: delivery, calendar: calendar).date(calendar: calendar)))")
        }
        if let deadline = item.deadline {
            lines.append("\(deadline < delivery ? "Was due" : "Due") \(when(deadline))")
        }
        let locations = item.locations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let people = item.people.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let context = [people.joined(separator: ", "), locations.joined(separator: ", ")]
            .filter { !$0.isEmpty }.joined(separator: " • ")
        if !context.isEmpty { lines.append(context) }
        return lines.joined(separator: "\n")
    }
    func save(_ item: PlanItem) throws {
        try Planner.validate(item, in: items)
        var updated = items
        var plans = series
        let previous = items.first { $0.id == item.id }
        var previousDefinition = previous
        previousDefinition?.completedAt = item.completedAt
        previousDefinition?.cancelledAt = item.cancelledAt
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
    /// that day, so a carried item stops there instead of showing on the days after. The circle of
    /// a cancelled item restores it instead, so it is never completed by accident.
    func toggle(_ item: PlanItem, on day: Day) {
        var updated = items
        guard let i = updated.firstIndex(where: { $0.id == item.id }) else { return }
        guard !updated[i].isCancelled else { return setCancelled(item, false, on: day) }
        updated[i].completedAt = updated[i].isComplete ? nil : Planner.completionDate(on: day, now: Date())
        updated[i].suggestionDismissed = false
        commit(updated)
    }
    /// Cancels or restores a single item; for a repeating item, only this occurrence.
    func setCancelled(_ item: PlanItem, _ cancelled: Bool, on day: Day) {
        var updated = items
        guard let i = updated.firstIndex(where: { $0.id == item.id }) else { return }
        Planner.setCancelled(cancelled, &updated[i], on: day, now: Date())
        commit(updated)
    }
    /// Ticks an item off from its Live Activity, as done today.
    func complete(itemID: String) {
        guard let item = items.first(where: { $0.id.uuidString == itemID }), !item.isSettled else { return }
        toggle(item, on: Day(Date()))
    }
    func dismissSuggestion(_ item: PlanItem) {
        var updated = items
        guard let i = updated.firstIndex(where: { $0.id == item.id }) else { return }
        updated[i].suggestionDismissed = true; commit(updated)
    }
    /// Deletes an item. For a repeating item, `scope` says how much of the series goes with it.
    /// The deletion can be undone from the Undo button that appears, and through the system's
    /// own undo (shake, or three fingers) when an undo manager is given.
    func delete(_ item: PlanItem, children: Bool, scope: RepeatDeletion = .all, undoManager: UndoManager? = nil) {
        var updated = items
        var plans = series
        if item.seriesID != nil {
            Planner.delete(item, scope, items: &updated, series: &plans)
        } else {
            Planner.delete(item.id, includingChildren: children, from: &updated)
        }
        let deletion = Planner.deletion(of: item.title, before: (items, series), after: (updated, plans))
        commit(updated, series: plans)
        guard items == updated else { return }
        lastDeletion = deletion
        deletionUndoManager = undoManager
        undoManager?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.undo(deletion) }
        }
        undoManager?.setActionName("Delete")
    }
    /// Puts back what a deletion removed.
    func undo(_ deletion: PlanDeletion) {
        var updated = items
        var plans = series
        Planner.undo(deletion, items: &updated, series: &plans)
        commit(updated, series: plans)
        if lastDeletion?.id == deletion.id { lastDeletion = nil }
        // Undone from the button, the system's undo has nothing left to do.
        if let manager = deletionUndoManager, !manager.isUndoing { manager.removeAllActions(withTarget: self) }
    }
    /// Whether a repeating item is its series' first occurrence; then "this and following" is everything.
    func startsSeries(_ item: PlanItem) -> Bool { Planner.startsSeries(item, in: series) }
    /// The first day of the repeating item an occurrence belongs to.
    func seriesStart(of item: PlanItem) -> Day? { Planner.seriesStart(of: item, in: series) }
    /// The day of the original entry of the repeating item an occurrence belongs to.
    func originalDay(of item: PlanItem) -> Day? { Planner.originalDay(of: item, in: series) }
    /// How many linked items follow an original item (see `Planner.linkedCount`).
    func linkedCount(of item: PlanItem) -> (count: Int, isTotal: Bool)? {
        Planner.linkedCount(of: item, in: series, today: Day(Date()))
    }
    /// Whether an item is its repeating item's original entry, where the series is edited.
    func isOriginal(_ item: PlanItem) -> Bool { Planner.isOriginal(item, in: series) }
    /// The original entry of the repeating item an occurrence belongs to. It may be on a day
    /// that was never opened, so it is generated first when needed.
    func original(of item: PlanItem) -> PlanItem? {
        guard let day = Planner.originalDay(of: item, in: series),
              let family = series.first(where: { $0.id == item.seriesID })?.familyID else { return nil }
        let related = Set(series.filter { $0.familyID == family }.map(\.id))
        func find(_ items: [PlanItem]) -> PlanItem? {
            items.first { ($0.seriesID.map(related.contains) ?? false) && $0.occurrenceDay == day }
        }
        if let found = find(items) { return found }
        var updated = items
        Planner.materialize(series.filter { related.contains($0.id) }, in: &updated, from: day, through: day)
        commit(updated)
        return find(items)
    }
    /// Saves an edited occurrence as a single item of its own, leaving the rest of its series.
    func saveDetached(_ item: PlanItem) throws {
        try Planner.validate(item, in: items)
        var updated = items
        var plans = series
        Planner.detach(item, items: &updated, series: &plans)
        commit(updated, series: plans)
    }
    func item(_ id: UUID?) -> PlanItem? { items.first { $0.id == id } }
    func children(of item: PlanItem) -> [PlanItem] { items.filter { $0.parentID == item.id }.sorted { $0.createdAt < $1.createdAt } }
    func addSampleDay() {
        guard items.isEmpty else { return }
        let calendar = Calendar.current; let today = Day(Date())
        func date(_ hour: Int, _ minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today.date())! }
        func persona(_ persona: Persona, _ item: PlanItem) -> PlanItem { var item = item; item.personas = [persona]; return item }
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
                                didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let value = response.notification.request.content.userInfo["itemID"] as? String,
              let id = UUID(uuidString: value) else { return }
        await MainActor.run { PlanStore.shared.reminderItemToFocus = id }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
