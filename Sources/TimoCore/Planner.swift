import Foundation

public struct Day: Codable, Hashable, Comparable {
    public var era: Int
    public var year: Int
    public var month: Int
    public var day: Int
    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.era, .year, .month, .day], from: date)
        era = c.era ?? 1; year = c.year!; month = c.month!; day = c.day!
    }
    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(era: era, year: year, month: month, day: day))!
    }
    public static func < (lhs: Day, rhs: Day) -> Bool {
        [lhs.era, lhs.year, lhs.month, lhs.day].lexicographicallyPrecedes([rhs.era, rhs.year, rhs.month, rhs.day])
    }
}

public enum ItemKind: String, Codable, CaseIterable { case task, event }
public struct PlanItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var kind: ItemKind
    public var title: String
    public var notes: String
    public var day: Day
    public var minute: Int?
    public var end: Date?
    public var completedAt: Date?
    public var parentID: UUID?
    public var originalDay: Day
    public var carriedFrom: Day?
    public var suggestionDismissed: Bool
    public var createdAt: Date
    public var isComplete: Bool { completedAt != nil }
    public init(id: UUID = UUID(), kind: ItemKind = .task, title: String, notes: String = "", day: Day,
                minute: Int? = nil, end: Date? = nil, parentID: UUID? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.notes = notes; self.day = day
        self.minute = minute; self.end = end; self.parentID = parentID; originalDay = day
        suggestionDismissed = false; createdAt = Date()
    }
    public func start(calendar: Calendar = .current) -> Date? {
        guard let minute else { return nil }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day.date(calendar: calendar))
    }
    public func isElapsed(now: Date, calendar: Calendar = .current) -> Bool {
        guard !isComplete else { return false }
        guard let boundary = kind == .event ? end : start(calendar: calendar) else { return false }
        return boundary < now
    }
    public func appears(on selected: Day, calendar: Calendar = .current) -> Bool {
        guard kind == .event, let start = start(calendar: calendar), let end else { return day == selected }
        let beginning = calendar.startOfDay(for: selected.date(calendar: calendar))
        let next = calendar.date(byAdding: .day, value: 1, to: beginning)!
        return start < next && end > beginning
    }
}

public enum PlannerError: LocalizedError {
    case title, eventTime, parent, nested, children
    public var errorDescription: String? {
        switch self {
        case .title: return "Give this item a title."
        case .eventTime: return "An event needs a start time and an end after its start."
        case .parent: return "Choose an existing parent. Events cannot be subtasks."
        case .nested: return "Subtasks can only be one level deep."
        case .children: return "An item with subtasks cannot itself become a subtask."
        }
    }
}

public enum Planner {
    @discardableResult public static func reconcile(_ items: inout [PlanItem], now: Date, calendar: Calendar = .current) -> Bool {
        let today = Day(now, calendar: calendar)
        var changed = false
        for index in items.indices where items[index].kind == .task && !items[index].isComplete && items[index].day < today {
            if items[index].carriedFrom == nil { items[index].carriedFrom = items[index].day }
            items[index].day = today
            items[index].minute = nil
            items[index].suggestionDismissed = false
            changed = true
        }
        return changed
    }
    public static func validate(_ item: PlanItem, in items: [PlanItem], calendar: Calendar = .current) throws {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlannerError.title }
        if item.kind == .event {
            guard let start = item.start(calendar: calendar), let end = item.end, end > start else { throw PlannerError.eventTime }
        }
        if let parentID = item.parentID {
            guard item.kind == .task, parentID != item.id, let parent = items.first(where: { $0.id == parentID }) else { throw PlannerError.parent }
            guard parent.parentID == nil else { throw PlannerError.nested }
            guard !items.contains(where: { $0.parentID == item.id }) else { throw PlannerError.children }
        }
    }
    public static func delete(_ id: UUID, includingChildren: Bool, from items: inout [PlanItem]) {
        if includingChildren { items.removeAll { $0.parentID == id } }
        else { for i in items.indices where items[i].parentID == id { items[i].parentID = nil } }
        items.removeAll { $0.id == id }
    }
    public static func reschedule(_ item: inout PlanItem, to day: Day, minute: Int?, end: Date? = nil) {
        item.day = day; item.minute = minute; item.end = end
        item.carriedFrom = nil; item.suggestionDismissed = false
    }
    public static func suggestsParentCompletion(_ parent: PlanItem, in items: [PlanItem]) -> Bool {
        let children = items.filter { $0.parentID == parent.id }
        return parent.kind == .task && !parent.isComplete && !parent.suggestionDismissed && !children.isEmpty && children.allSatisfy(\.isComplete)
    }
}
