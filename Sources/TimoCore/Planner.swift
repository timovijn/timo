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

public struct PlanItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var movesToNextDay: Bool
    public var title: String
    public var notes: String
    public var locations: [String]
    public var people: [String]
    public var day: Day
    public var minute: Int?
    public var end: Date?
    public var reminderAt: Date?
    public var completedAt: Date?
    public var parentID: UUID?
    public var originalDay: Day
    public var carriedFrom: Day?
    public var suggestionDismissed: Bool
    public var createdAt: Date
    public var isComplete: Bool { completedAt != nil }
    public init(id: UUID = UUID(), title: String, notes: String = "", day: Day,
                minute: Int? = nil, end: Date? = nil, parentID: UUID? = nil, movesToNextDay: Bool = true, reminderAt: Date? = nil, locations: [String] = [], people: [String] = []) {
        self.id = id; self.movesToNextDay = movesToNextDay; self.title = title; self.notes = notes; self.day = day
        self.minute = minute; self.end = end; self.parentID = parentID; originalDay = day
        self.locations = locations; self.people = people
        self.reminderAt = reminderAt
        suggestionDismissed = false; createdAt = Date()
    }
    // Read the original task/event format without changing IDs or scheduling choices.
    private enum CodingKeys: String, CodingKey {
        case id, title, notes, locations, people, day, minute, end, reminderAt, completedAt, parentID, originalDay, carriedFrom, suggestionDismissed, createdAt, movesToNextDay
    }
    private enum LegacyKeys: String, CodingKey { case kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decode(String.self, forKey: .notes)
        locations = try c.decodeIfPresent([String].self, forKey: .locations) ?? []
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        day = try c.decode(Day.self, forKey: .day)
        minute = try c.decodeIfPresent(Int.self, forKey: .minute)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        reminderAt = try c.decodeIfPresent(Date.self, forKey: .reminderAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        originalDay = try c.decode(Day.self, forKey: .originalDay)
        carriedFrom = try c.decodeIfPresent(Day.self, forKey: .carriedFrom)
        suggestionDismissed = try c.decode(Bool.self, forKey: .suggestionDismissed)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        if let preference = try c.decodeIfPresent(Bool.self, forKey: .movesToNextDay) {
            movesToNextDay = preference
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let kind = try legacy.decode(String.self, forKey: .kind)
            guard kind == "task" || kind == "event" else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: legacy, debugDescription: "Unknown legacy item kind")
            }
            movesToNextDay = kind == "task"
        }
    }
    public func start(calendar: Calendar = .current) -> Date? {
        guard let minute else { return nil }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day.date(calendar: calendar))
    }
    public func isElapsed(now: Date, calendar: Calendar = .current) -> Bool {
        guard !isComplete else { return false }
        guard let boundary = end ?? start(calendar: calendar) else { return false }
        return boundary < now
    }
    public func appears(on selected: Day, calendar: Calendar = .current) -> Bool {
        guard let start = start(calendar: calendar), let end else { return day == selected }
        let beginning = calendar.startOfDay(for: selected.date(calendar: calendar))
        let next = calendar.date(byAdding: .day, value: 1, to: beginning)!
        return start < next && end > beginning
    }
}

public enum PlannerError: LocalizedError {
    case title, schedule, parent, nested, children
    public var errorDescription: String? {
        switch self {
        case .title: return "Give this item a title."
        case .schedule: return "Choose a valid time, with any end time after the start."
        case .parent: return "Choose an existing parent."
        case .nested: return "Linked items can only be one level deep."
        case .children: return "An item with linked children cannot itself have a parent."
        }
    }
}

public enum Planner {
    @discardableResult public static func reconcile(_ items: inout [PlanItem], now: Date, calendar: Calendar = .current) -> Bool {
        let today = Day(now, calendar: calendar)
        var changed = false
        for index in items.indices where items[index].movesToNextDay && !items[index].isComplete && items[index].day < today {
            // An overnight item still in progress stays on its original schedule.
            if let end = items[index].end, end > now { continue }
            if let reminder = items[index].reminderAt, reminder < now { items[index].reminderAt = nil }
            let start = items[index].start(calendar: calendar)
            let duration = items[index].end.flatMap { end in start.map { end.timeIntervalSince($0) } }
            if items[index].carriedFrom == nil { items[index].carriedFrom = items[index].day }
            items[index].day = today
            if let duration, let newStart = items[index].start(calendar: calendar) {
                items[index].end = newStart.addingTimeInterval(duration)
            } else {
                items[index].minute = nil
                items[index].end = nil
            }
            items[index].suggestionDismissed = false
            changed = true
        }
        return changed
    }
    public static func validate(_ item: PlanItem, in items: [PlanItem], calendar: Calendar = .current) throws {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlannerError.title }
        if let minute = item.minute, !(0..<1440).contains(minute) { throw PlannerError.schedule }
        if let end = item.end {
            guard let start = item.start(calendar: calendar), end > start else { throw PlannerError.schedule }
        }
        if let parentID = item.parentID {
            guard parentID != item.id, let parent = items.first(where: { $0.id == parentID }) else { throw PlannerError.parent }
            guard parent.parentID == nil else { throw PlannerError.nested }
            guard !items.contains(where: { $0.parentID == item.id }) else { throw PlannerError.children }
        }
    }
    public static func delete(_ id: UUID, includingChildren: Bool, from items: inout [PlanItem]) {
        if includingChildren { items.removeAll { $0.parentID == id } }
        else { for i in items.indices where items[i].parentID == id { items[i].parentID = nil } }
        items.removeAll { $0.id == id }
    }
    public static func upcomingReminders(in items: [PlanItem], now: Date, limit: Int = 64) -> [PlanItem] {
        Array(items.filter { !$0.isComplete && ($0.reminderAt ?? .distantPast) > now }
            .sorted {
                if $0.reminderAt != $1.reminderAt { return $0.reminderAt! < $1.reminderAt! }
                return $0.id.uuidString < $1.id.uuidString
            }.prefix(max(0, limit)))
    }
    public static func updateStart(_ item: inout PlanItem, day: Day, minute: Int?, calendar: Calendar = .current) {
        let oldStart = item.start(calendar: calendar)
        let duration = item.end.flatMap { end in oldStart.map { end.timeIntervalSince($0) } }
        let oldDay = item.day
        item.day = day; item.minute = minute
        if let reminder = item.reminderAt {
            if let oldStart, let newStart = item.start(calendar: calendar) {
                item.reminderAt = reminder.addingTimeInterval(newStart.timeIntervalSince(oldStart))
            } else if oldDay != day {
                let days = calendar.dateComponents([.day], from: oldDay.date(calendar: calendar), to: day.date(calendar: calendar)).day ?? 0
                item.reminderAt = calendar.date(byAdding: .day, value: days, to: reminder)
            }
        }
        if let duration, let start = item.start(calendar: calendar) { item.end = start.addingTimeInterval(duration) }
        else { item.end = nil }
        item.carriedFrom = nil; item.suggestionDismissed = false
    }
    public static func reschedule(_ item: inout PlanItem, to day: Day, minute: Int?, end: Date? = nil) {
        updateStart(&item, day: day, minute: minute)
        item.end = end
    }
    public static func suggestsParentCompletion(_ parent: PlanItem, in items: [PlanItem]) -> Bool {
        let children = items.filter { $0.parentID == parent.id }
        return !parent.isComplete && !parent.suggestionDismissed && !children.isEmpty && children.allSatisfy(\.isComplete)
    }
}
