import Foundation
import Combine

@MainActor final class PlanStore: ObservableObject {
    @Published private(set) var items: [PlanItem] = []
    @Published var errorMessage: String?
    private let url: URL
    private var canWrite = true
    private struct Document: Codable { var version = 1; var items: [PlanItem] }
    init() {
        url = URL.applicationSupportDirectory.appending(path: "Timo", directoryHint: .isDirectory).appending(path: "plan.json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
                guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                items = document.items
            }
        } catch {
            canWrite = false
            errorMessage = "Your saved plan could not be opened. It has been left untouched. \(error.localizedDescription)"
        }
        reconcile()
    }
    private func commit(_ updated: [PlanItem]) {
        guard canWrite else { errorMessage = "Saving is disabled to protect the existing plan. Please close the app and resolve the saved-file error."; return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Document(items: updated)).write(to: url, options: .atomic)
            items = updated
        } catch { errorMessage = "This change could not be saved. \(error.localizedDescription)" }
    }
    func reconcile(now: Date = Date()) {
        var updated = items
        if Planner.reconcile(&updated, now: now) { commit(updated) }
    }
    func save(_ item: PlanItem) throws {
        try Planner.validate(item, in: items)
        var updated = items
        if let i = updated.firstIndex(where: { $0.id == item.id }) { updated[i] = item }
        else { var fresh = item; fresh.originalDay = fresh.day; updated.append(fresh) }
        // A newly entered past task is subject to the same carry-over rule.
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
        let cooking = PlanItem(kind: .event, title: "Cook dinner", day: today, minute: 19 * 60, end: date(19, 45))
        let samples = [
            PlanItem(title: "Shave", day: today, minute: 8 * 60),
            PlanItem(kind: .event, title: "Work", day: today, minute: 9 * 60, end: date(17)),
            PlanItem(kind: .event, title: "Sport", day: today, minute: 17 * 60 + 30, end: date(18, 30)),
            cooking,
            PlanItem(title: "Go to the supermarket", day: today, parentID: cooking.id),
            PlanItem(title: "Call Mum", day: today),
            PlanItem(title: "Read", day: today, minute: 21 * 60)
        ]
        commit(samples)
    }
}
