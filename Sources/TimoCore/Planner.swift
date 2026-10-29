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

public enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case never, daily, weekdays, weekly, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .never: return "Never"
        case .daily: return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly: return "Every week"
        case .custom: return "Custom days"
        }
    }
    public func matches(_ day: Day, starting start: Day, weekdays: [Int], calendar: Calendar = .current) -> Bool {
        guard day >= start else { return false }
        let weekday = calendar.component(.weekday, from: day.date(calendar: calendar))
        switch self {
        case .never: return day == start
        case .daily: return true
        case .weekdays: return (2...6).contains(weekday)
        case .weekly: return weekday == calendar.component(.weekday, from: start.date(calendar: calendar))
        case .custom: return weekdays.contains(weekday)
        }
    }
}

public struct ScheduledReminder: Equatable {
    public let item: PlanItem
    public let date: Date
    public init(item: PlanItem, date: Date) { self.item = item; self.date = date }
}

public struct RepeatingPlan: Codable, Equatable, Identifiable {
    public var id: UUID
    public var familyID: UUID
    public var template: PlanItem
    public var endBefore: Day?
    public var excludedDays: [Day] = []
    public init(template: PlanItem) {
        id = UUID()
        familyID = id
        self.template = template
        self.template.completedAt = nil
        self.template.carriedFrom = nil
        self.template.suggestionDismissed = false
        self.template.movesToNextDay = false
        self.template.seriesID = nil
        self.template.occurrenceDay = nil
    }
    public func includes(_ day: Day, calendar: Calendar = .current) -> Bool {
        guard endBefore.map({ day < $0 }) ?? true, !excludedDays.contains(day) else { return false }
        return template.repeatRule.matches(day, starting: template.day, weekdays: template.repeatWeekdays, calendar: calendar)
    }
}

public struct PlanItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var movesToNextDay: Bool
    public var repeatRule: RepeatRule = .never
    public var repeatWeekdays: [Int] = []
    public var seriesID: UUID?
    public var occurrenceDay: Day?
    public var title: String
    public var notes: String
    public var locations: [String]
    public var people: [String]
    public var day: Day
    public var minute: Int?
    public var end: Date?
    /// Moments to be reminded; an item can have several.
    public var reminders: [Date]
    public var completedAt: Date?
    public var parentID: UUID?
    public var originalDay: Day
    public var carriedFrom: Day?
    public var suggestionDismissed: Bool
    public var createdAt: Date
    public var isComplete: Bool { completedAt != nil }
    public init(id: UUID = UUID(), title: String, notes: String = "", day: Day,
                minute: Int? = nil, end: Date? = nil, parentID: UUID? = nil, movesToNextDay: Bool = true, reminders: [Date] = [], locations: [String] = [], people: [String] = []) {
        self.id = id; self.movesToNextDay = movesToNextDay; self.title = title; self.notes = notes; self.day = day
        self.minute = minute; self.end = end; self.parentID = parentID; originalDay = day
        self.locations = locations; self.people = people
        self.reminders = reminders
        suggestionDismissed = false; createdAt = Date()
    }
    // Read the original task/event format without changing IDs or scheduling choices.
    private enum CodingKeys: String, CodingKey {
        case id, title, notes, locations, people, day, minute, end, reminders, completedAt, parentID, originalDay, carriedFrom, suggestionDismissed, createdAt, movesToNextDay, repeatRule, repeatWeekdays, seriesID, occurrenceDay
    }
    private enum LegacyKeys: String, CodingKey { case kind, reminderAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        repeatRule = try c.decodeIfPresent(RepeatRule.self, forKey: .repeatRule) ?? .never
        repeatWeekdays = try c.decodeIfPresent([Int].self, forKey: .repeatWeekdays) ?? []
        seriesID = try c.decodeIfPresent(UUID.self, forKey: .seriesID)
        occurrenceDay = try c.decodeIfPresent(Day.self, forKey: .occurrenceDay)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decode(String.self, forKey: .notes)
        locations = try c.decodeIfPresent([String].self, forKey: .locations) ?? []
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        day = try c.decode(Day.self, forKey: .day)
        minute = try c.decodeIfPresent(Int.self, forKey: .minute)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        if let saved = try c.decodeIfPresent([Date].self, forKey: .reminders) {
            reminders = saved
        } else {
            // Items saved before multiple reminders kept a single optional reminder.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            reminders = try legacy.decodeIfPresent(Date.self, forKey: .reminderAt).map { [$0] } ?? []
        }
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
    /// The reminder to show for this item: the next one still to come, otherwise the latest.
    public func displayedReminder(now: Date) -> Date? {
        reminders.filter { $0 > now }.min() ?? reminders.max()
    }
    public func start(calendar: Calendar = .current) -> Date? {
        guard let minute else { return nil }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day.date(calendar: calendar))
    }
    public func isInProgress(now: Date, calendar: Calendar = .current) -> Bool {
        guard !isComplete, let start = start(calendar: calendar), let end else { return false }
        return start <= now && now < end
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
    case title, schedule, parent, nested, children, repeatDays
    public var errorDescription: String? {
        switch self {
        case .repeatDays: return "Choose at least one day to repeat on."
        case .title: return "Give this item a title."
        case .schedule: return "Choose a valid time, with any end time after the start."
        case .parent: return "Choose an existing parent."
        case .nested: return "Linked items can only be one level deep."
        case .children: return "An item with linked children cannot itself have a parent."
        }
    }
}

public enum Planner {
    // Generate only the requested window; stored occurrence keys make revisiting idempotent.
    @discardableResult public static func materialize(_ series: [RepeatingPlan], in items: inout [PlanItem],
                                                      from first: Day, through last: Day,
                                                      calendar: Calendar = .current) -> Bool {
        guard first <= last else { return false }
        var changed = false
        for plan in series {
            var existing = Set(items.filter { $0.seriesID == plan.id }.compactMap(\.occurrenceDay))
            var cursor = max(first, plan.template.day)
            while cursor <= last {
                if !existing.contains(cursor), plan.includes(cursor, calendar: calendar) {
                    var occurrence = plan.template
                    occurrence.id = UUID()
                    occurrence.seriesID = plan.id
                    occurrence.occurrenceDay = cursor
                    updateStart(&occurrence, day: cursor, minute: occurrence.minute, calendar: calendar)
                    occurrence.originalDay = cursor
                    occurrence.completedAt = nil
                    occurrence.movesToNextDay = false
                    occurrence.parentID = nil
                    items.append(occurrence)
                    existing.insert(cursor)
                    changed = true
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor.date(calendar: calendar)) else { break }
                cursor = Day(next, calendar: calendar)
            }
        }
        return changed
    }
    // A repeating item has one shared definition. Editing any occurrence updates
    // the whole family, including plans split by older versions of the app.
    public static func saveRepeating(_ edited: PlanItem, items: inout [PlanItem], series: inout [RepeatingPlan], calendar: Calendar = .current) {
        let previous = items.first { $0.id == edited.id }
        let family = series.first { $0.id == previous?.seriesID }?.familyID
        let plans = series.filter { $0.familyID == family }
        let related = Set(plans.map(\.id))
        let occurrences = items.filter { $0.seriesID.map { related.contains($0) } ?? false }
        let shift = previous.map {
            calendar.dateComponents([.day], from: $0.day.date(calendar: calendar), to: edited.day.date(calendar: calendar)).day ?? 0
        } ?? 0
        func shifted(_ day: Day) -> Day {
            Day(calendar.date(byAdding: .day, value: shift, to: day.date(calendar: calendar))!, calendar: calendar)
        }
        series.removeAll { related.contains($0.id) }
        items.removeAll { $0.id == edited.id || ($0.seriesID.map { related.contains($0) } ?? false) }

        guard edited.repeatRule != .never else {
            var single = edited
            single.seriesID = nil
            single.occurrenceDay = nil
            single.originalDay = single.day
            single.carriedFrom = nil
            let removed = Set(occurrences.map(\.id)).subtracting([single.id])
            for index in items.indices where items[index].parentID.map({ removed.contains($0) }) ?? false {
                items[index].parentID = nil
            }
            items.append(single)
            return
        }

        let originalStart = plans.map { $0.template.day }.min()
        let earliest = originalStart.map(shifted) ?? edited.day
        let weeklyDay = calendar.component(.weekday, from: edited.day.date(calendar: calendar))
        func matches(_ day: Day) -> Bool {
            let weekday = calendar.component(.weekday, from: day.date(calendar: calendar))
            switch edited.repeatRule {
            case .never: return false
            case .daily: return true
            case .weekdays: return (2...6).contains(weekday)
            case .weekly: return weekday == weeklyDay
            case .custom: return edited.repeatWeekdays.contains(weekday)
            }
        }
        var start = earliest
        for offset in 0..<7 {
            let candidate = Day(calendar.date(byAdding: .day, value: offset, to: earliest.date(calendar: calendar))!, calendar: calendar)
            if matches(candidate) { start = candidate; break }
        }
        var definition = edited
        updateStart(&definition, day: start, minute: edited.minute, calendar: calendar)
        var plan = RepeatingPlan(template: definition)
        if let first = plans.min(by: { $0.template.day < $1.template.day }) {
            plan.id = first.id
            plan.familyID = first.familyID
        }
        // Preserve previous deletions and an explicitly stopped series.
        plan.excludedDays = Array(Set(plans.flatMap(\.excludedDays).map(shifted))).filter { $0 != edited.day }
        if !plans.isEmpty && plans.allSatisfy({ $0.endBefore != nil }) {
            plan.endBefore = plans.compactMap(\.endBefore).max().map(shifted)
        }
        series.append(plan)

        for old in occurrences {
            let day = shifted(old.occurrenceDay ?? old.day)
            guard plan.includes(day, calendar: calendar) else { continue }
            var updated = definition
            updateStart(&updated, day: day, minute: definition.minute, calendar: calendar)
            updated.id = old.id
            updated.seriesID = plan.id
            updated.occurrenceDay = day
            updated.originalDay = day
            updated.createdAt = old.createdAt
            updated.completedAt = old.id == edited.id ? edited.completedAt : old.completedAt
            updated.movesToNextDay = false
            updated.parentID = old.parentID
            let scheduleChanged = old.day != updated.day || old.minute != updated.minute || old.end != updated.end
            updated.suggestionDismissed = scheduleChanged ? false : old.suggestionDismissed
            items.append(updated)
        }
        if occurrences.isEmpty {
            var first = definition
            first.id = edited.id
            first.seriesID = plan.id
            first.occurrenceDay = first.day
            first.originalDay = first.day
            first.movesToNextDay = false
            items.append(first)
        }
        let retained = Set(items.map(\.id))
        let removed = Set(occurrences.map(\.id)).subtracting(retained)
        for index in items.indices where items[index].parentID.map({ removed.contains($0) }) ?? false {
            items[index].parentID = nil
        }
    }
    public static func deleteSeries(_ item: PlanItem, items: inout [PlanItem], series: inout [RepeatingPlan]) {
        guard let family = series.first(where: { $0.id == item.seriesID })?.familyID else {
            delete(item.id, includingChildren: false, from: &items)
            return
        }
        let related = Set(series.filter { $0.familyID == family }.map(\.id))
        let ids = items.filter { $0.seriesID.map { related.contains($0) } ?? false }.map(\.id)
        for id in ids { delete(id, includingChildren: false, from: &items) }
        series.removeAll { related.contains($0.id) }
    }
    @discardableResult public static func reconcile(_ items: inout [PlanItem], now: Date, calendar: Calendar = .current) -> Bool {
        let today = Day(now, calendar: calendar)
        var changed = false
        for index in items.indices where items[index].movesToNextDay && items[index].seriesID == nil && !items[index].isComplete && items[index].day < today {
            // An overnight item still in progress stays on its original schedule.
            if let end = items[index].end, end > now { continue }
            items[index].reminders.removeAll { $0 < now }
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
        if item.repeatRule == .custom && (item.repeatWeekdays.isEmpty || item.repeatWeekdays.contains(where: { !(1...7).contains($0) })) { throw PlannerError.repeatDays }
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
    /// The nearest future reminders of unfinished items, one entry per reminder.
    public static func upcomingReminders(in items: [PlanItem], now: Date, limit: Int = 64) -> [ScheduledReminder] {
        Array(items.filter { !$0.isComplete }
            .flatMap { item in Set(item.reminders).filter { $0 > now }.map { ScheduledReminder(item: item, date: $0) } }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.item.id.uuidString < $1.item.id.uuidString
            }.prefix(max(0, limit)))
    }
    public static func updateStart(_ item: inout PlanItem, day: Day, minute: Int?, calendar: Calendar = .current) {
        let oldStart = item.start(calendar: calendar)
        let duration = item.end.flatMap { end in oldStart.map { end.timeIntervalSince($0) } }
        let oldDay = item.day
        item.day = day; item.minute = minute
        if let oldStart, let newStart = item.start(calendar: calendar) {
            item.reminders = item.reminders.map { $0.addingTimeInterval(newStart.timeIntervalSince(oldStart)) }
        } else if oldDay != day {
            let days = calendar.dateComponents([.day], from: oldDay.date(calendar: calendar), to: day.date(calendar: calendar)).day ?? 0
            item.reminders = item.reminders.compactMap { calendar.date(byAdding: .day, value: days, to: $0) }
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

// Assign overlapping time ranges to parallel tracks. Touching endpoints may share
// a track; ranges with the same start put the longest event closest to the axis.
public enum TimelineLanes {
    public static func assign(_ intervals: [Range<Double>]) -> [Int] {
        let order = intervals.indices.sorted {
            if intervals[$0].lowerBound != intervals[$1].lowerBound {
                return intervals[$0].lowerBound < intervals[$1].lowerBound
            }
            if intervals[$0].upperBound != intervals[$1].upperBound {
                return intervals[$0].upperBound > intervals[$1].upperBound
            }
            return $0 < $1
        }
        var ends: [Double] = []
        var lanes = Array(repeating: 0, count: intervals.count)
        for index in order where !intervals[index].isEmpty {
            let interval = intervals[index]
            if let lane = ends.firstIndex(where: { $0 <= interval.lowerBound }) {
                ends[lane] = interval.upperBound
                lanes[index] = lane
            } else {
                lanes[index] = ends.count
                ends.append(interval.upperBound)
            }
        }
        return lanes
    }
}
