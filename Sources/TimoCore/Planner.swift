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

/// A focus in someone's life that an item can belong to. The set is fixed for now.
/// Items store the raw value, so a persona this version doesn't know reads as none.
public enum Persona: String, Codable, CaseIterable, Identifiable {
    case health, work, family, friends, personal
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .health: return "Health"
        case .work: return "Work"
        case .family: return "Family"
        case .friends: return "Friends"
        case .personal: return "Personal"
        }
    }
    /// Personas without repeats, in their standard order, so saved plans and comparisons
    /// don't depend on the order they were chosen in.
    public static func ordered<S: Sequence>(_ personas: S) -> [Persona] where S.Element == Persona {
        let chosen = Set(personas)
        return allCases.filter(chosen.contains)
    }
}

/// One day of a persona's history: its items on that day, in day-view order.
public struct PersonaDay: Equatable, Identifiable {
    public let day: Day
    public let items: [PlanItem]
    public var id: Day { day }
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
        self.template.cancelledAt = nil
        self.template.carriedFrom = nil
        self.template.suggestionDismissed = false
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
    /// The personas this item belongs to; it can be in several, or none.
    public var personas: [Persona] = []
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
    /// When the item was called off. A cancelled item is never complete, doesn't carry on,
    /// isn't reviewed or reminded about, and stays visible in a quiet style until restored.
    public var cancelledAt: Date?
    public var parentID: UUID?
    public var originalDay: Day
    /// Only in plans saved before the scheduled day stayed fixed: the day an item was moved on
    /// from. Opening such a plan restores it as the scheduled day (see `restoreScheduledDays`).
    public var carriedFrom: Day?
    public var suggestionDismissed: Bool
    public var createdAt: Date
    public var isComplete: Bool { completedAt != nil }
    public var isCancelled: Bool { cancelledAt != nil }
    /// Done with either way: completed or cancelled. Nothing more is asked of it.
    public var isSettled: Bool { isComplete || isCancelled }
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
        case id, title, notes, locations, people, day, minute, end, reminders, completedAt, cancelledAt, parentID, originalDay, carriedFrom, suggestionDismissed, createdAt, movesToNextDay, repeatRule, repeatWeekdays, seriesID, occurrenceDay, personas
    }
    private enum LegacyKeys: String, CodingKey { case kind, reminderAt, persona }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        repeatRule = try c.decodeIfPresent(RepeatRule.self, forKey: .repeatRule) ?? .never
        repeatWeekdays = try c.decodeIfPresent([Int].self, forKey: .repeatWeekdays) ?? []
        seriesID = try c.decodeIfPresent(UUID.self, forKey: .seriesID)
        occurrenceDay = try c.decodeIfPresent(Day.self, forKey: .occurrenceDay)
        // Personas this version doesn't know are left out. Version 6 kept a single persona.
        if let saved = try c.decodeIfPresent([String].self, forKey: .personas) {
            personas = Persona.ordered(saved.compactMap(Persona.init(rawValue:)))
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            personas = try legacy.decodeIfPresent(String.self, forKey: .persona).flatMap(Persona.init(rawValue:)).map { [$0] } ?? []
        }
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
        cancelledAt = try c.decodeIfPresent(Date.self, forKey: .cancelledAt)
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
        guard !isSettled, let start = start(calendar: calendar), let end else { return false }
        return start <= now && now < end
    }
    public func isElapsed(now: Date, calendar: Calendar = .current) -> Bool {
        guard !isSettled else { return false }
        guard let boundary = end ?? start(calendar: calendar) else { return false }
        return boundary < now
    }
    public func appears(on selected: Day, calendar: Calendar = .current) -> Bool {
        guard let start = start(calendar: calendar), let end else { return day == selected }
        let beginning = calendar.startOfDay(for: selected.date(calendar: calendar))
        let next = calendar.date(byAdding: .day, value: 1, to: beginning)!
        return start < next && end > beginning
    }
    /// Whether this item carries forward until completed or cancelled.
    public var carries: Bool { movesToNextDay }
    /// The day this item is shown as itself. Its scheduled `day` never changes: an item that
    /// carries is shown on the day it was completed or cancelled, or while unfinished on today.
    /// A time range still running stays on its own day until it ends.
    public func liveDay(now: Date, calendar: Calendar = .current) -> Day {
        guard carries else { return day }
        if let settled = completedAt ?? cancelledAt { return max(day, Day(settled, calendar: calendar)) }
        if let end, end > now { return day }
        return max(day, Day(now, calendar: calendar))
    }
    /// Whether this item is shown on a later day than it was scheduled for.
    public func isCarried(now: Date, calendar: Calendar = .current) -> Bool {
        liveDay(now: now, calendar: calendar) > day
    }
    /// Whether `selected` shows this item as itself. A carried item is shown once, on its live
    /// day, as an untimed item; otherwise it is shown on every day its schedule covers.
    public func shows(on selected: Day, now: Date, calendar: Calendar = .current) -> Bool {
        let live = liveDay(now: now, calendar: calendar)
        return live == day ? appears(on: selected, calendar: calendar) : selected == live
    }
    /// Whether this item was carried on from `selected`: every day from its scheduled day up
    /// to its live day keeps a quiet entry pointing to where it went.
    public func movedAway(from selected: Day, now: Date, calendar: Calendar = .current) -> Bool {
        let live = liveDay(now: now, calendar: calendar)
        return live > day && day <= selected && selected < live
    }
}

/// How much of a repeating item to delete: the occurrence that was chosen, it and every later
/// one, or the whole series. Single items are simply deleted.
public enum RepeatDeletion: CaseIterable {
    case occurrence, following, all
}

/// What a deletion took away, so it can be put back: the items removed, every repeating plan
/// as it was before the deletion changed or removed it, and the links it cut from children.
public struct PlanDeletion: Identifiable {
    public let id = UUID()
    /// The deleted item's title, for "Undo" to name what comes back.
    public let title: String
    public let removed: [PlanItem]
    public let previousPlans: [RepeatingPlan]
    public let unlinked: [UUID: UUID]
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
                    occurrence.cancelledAt = nil
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
    // The editor only sends this the master (original entry); a later day is detached instead.
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
            updated.cancelledAt = old.id == edited.id ? edited.cancelledAt : old.cancelledAt
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
            items.append(first)
        }
        let retained = Set(items.map(\.id))
        let removed = Set(occurrences.map(\.id)).subtracting(retained)
        for index in items.indices where items[index].parentID.map({ removed.contains($0) }) ?? false {
            items[index].parentID = nil
        }
    }
    /// Deletes a repeating occurrence, it and the later ones, or the whole series. One occurrence
    /// is kept out of the series by its day, so it isn't generated again; deleting from an
    /// occurrence on ends every plan in the family before that day and drops those starting on
    /// or after it, leaving earlier occurrences (and their completion) as they were.
    public static func delete(_ item: PlanItem, _ scope: RepeatDeletion, items: inout [PlanItem], series: inout [RepeatingPlan]) {
        guard item.seriesID != nil, let family = series.first(where: { $0.id == item.seriesID })?.familyID else {
            delete(item.id, includingChildren: false, from: &items)
            return
        }
        let day = item.occurrenceDay ?? item.day
        switch scope {
        case .all:
            deleteSeries(item, items: &items, series: &series)
        case .occurrence:
            if let index = series.firstIndex(where: { $0.id == item.seriesID }), !series[index].excludedDays.contains(day) {
                series[index].excludedDays.append(day)
            }
            delete(item.id, includingChildren: false, from: &items)
        case .following:
            let related = Set(series.filter { $0.familyID == family }.map(\.id))
            let ids = items.filter { occurrence in
                occurrence.seriesID.map(related.contains) ?? false && (occurrence.occurrenceDay ?? occurrence.day) >= day
            }.map(\.id)
            for id in ids { delete(id, includingChildren: false, from: &items) }
            series.removeAll { related.contains($0.id) && $0.template.day >= day }
            for index in series.indices where related.contains(series[index].id) {
                series[index].endBefore = min(series[index].endBefore ?? day, day)
            }
        }
    }
    /// Records what changed between a plan before and after a deletion.
    public static func deletion(of title: String, before: (items: [PlanItem], series: [RepeatingPlan]),
                                after: (items: [PlanItem], series: [RepeatingPlan])) -> PlanDeletion {
        let remaining = Dictionary(after.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let plans = Dictionary(after.series.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var unlinked: [UUID: UUID] = [:]
        for item in before.items {
            if let parent = item.parentID, let now = remaining[item.id], now.parentID == nil { unlinked[item.id] = parent }
        }
        return PlanDeletion(title: title,
                            removed: before.items.filter { remaining[$0.id] == nil },
                            previousPlans: before.series.filter { plans[$0.id] != $0 },
                            unlinked: unlinked)
    }
    /// Puts back what a deletion took away, leaving anything changed since then as it is.
    public static func undo(_ deletion: PlanDeletion, items: inout [PlanItem], series: inout [RepeatingPlan]) {
        let restoredPlans = Set(deletion.previousPlans.map(\.id))
        series.removeAll { restoredPlans.contains($0.id) }
        series.append(contentsOf: deletion.previousPlans)
        let present = Set(items.map(\.id))
        items.append(contentsOf: deletion.removed.filter { !present.contains($0.id) })
        let ids = Set(items.map(\.id))
        for index in items.indices {
            if let parent = deletion.unlinked[items[index].id], items[index].parentID == nil, ids.contains(parent) {
                items[index].parentID = parent
            }
        }
    }
    /// The day of a repeating item's original entry: its first occurrence still in the series.
    /// Later occurrences are linked to it, and its editor is where the series is changed.
    public static func originalDay(of item: PlanItem, in series: [RepeatingPlan], calendar: Calendar = .current) -> Day? {
        guard let family = series.first(where: { $0.id == item.seriesID })?.familyID else { return nil }
        let plans = series.filter { $0.familyID == family }
        guard var cursor = plans.map(\.template.day).min() else { return nil }
        let last = item.occurrenceDay ?? item.day
        while cursor <= last {
            if plans.contains(where: { $0.includes(cursor, calendar: calendar) }) { return cursor }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor.date(calendar: calendar)) else { break }
            cursor = Day(next, calendar: calendar)
        }
        return last
    }
    /// How many linked items follow an original: all of them when its repeating item ends,
    /// otherwise those up to and including `today` (nil for a single item). Counted from the
    /// rule, since days are only generated as they are opened.
    public static func linkedCount(of item: PlanItem, in series: [RepeatingPlan], today: Day,
                                   calendar: Calendar = .current) -> (count: Int, isTotal: Bool)? {
        guard let family = series.first(where: { $0.id == item.seriesID })?.familyID,
              let start = originalDay(of: item, in: series, calendar: calendar) else { return nil }
        let plans = series.filter { $0.familyID == family }
        let ends = plans.allSatisfy { $0.endBefore != nil }
        let last = ends ? plans.compactMap(\.endBefore).max()! : calendar.date(byAdding: .day, value: 1, to: today.date(calendar: calendar)).map { Day($0, calendar: calendar) }!
        var count = 0
        var cursor = start
        while true {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor.date(calendar: calendar)) else { break }
            cursor = Day(next, calendar: calendar)
            guard cursor < last else { break }
            if plans.contains(where: { $0.includes(cursor, calendar: calendar) }) { count += 1 }
        }
        return (count, ends)
    }
    /// Whether `item` is its repeating item's original entry (true for single items too).
    public static func isOriginal(_ item: PlanItem, in series: [RepeatingPlan], calendar: Calendar = .current) -> Bool {
        guard item.seriesID != nil else { return true }
        return originalDay(of: item, in: series, calendar: calendar).map { (item.occurrenceDay ?? item.day) <= $0 } ?? true
    }
    /// Saves an edited later day on its own: it leaves its repeating item, whose day is kept out
    /// of the series so the series doesn't fill it again, and every other day stays linked to its
    /// master. Given a different repeat pattern, the detached day becomes the master of a new
    /// repeating item from its day; the old one carries on beside it, so the two can share later
    /// dates. Other changes make it a single item.
    public static func detach(_ edited: PlanItem, items: inout [PlanItem], series: inout [RepeatingPlan], calendar: Calendar = .current) {
        let previous = items.first { $0.id == edited.id }
        if let seriesID = previous?.seriesID ?? edited.seriesID,
           let index = series.firstIndex(where: { $0.id == seriesID }) {
            let day = previous?.occurrenceDay ?? edited.occurrenceDay ?? edited.day
            if !series[index].excludedDays.contains(day) { series[index].excludedDays.append(day) }
        }
        var single = edited
        single.seriesID = nil
        single.occurrenceDay = nil
        single.originalDay = single.day
        items.removeAll { $0.id == edited.id }
        if single.repeatRule == .never || !(previous.map { changesPattern($0, to: edited) } ?? false) {
            single.repeatRule = .never
            single.repeatWeekdays = []
            items.append(single)
        } else {
            saveRepeating(single, items: &items, series: &series, calendar: calendar)
        }
    }
    /// Whether an edit changes how an item repeats, rather than what it is or when on its day.
    public static func changesPattern(_ previous: PlanItem, to edited: PlanItem) -> Bool {
        previous.repeatRule != edited.repeatRule
            || (edited.repeatRule == .custom && Set(previous.repeatWeekdays) != Set(edited.repeatWeekdays))
    }
    /// The first day of the repeating item an occurrence belongs to, or nil for a single item.
    public static func seriesStart(of item: PlanItem, in series: [RepeatingPlan]) -> Day? {
        guard let family = series.first(where: { $0.id == item.seriesID })?.familyID else { return nil }
        return series.filter { $0.familyID == family }.map(\.template.day).min()
    }
    /// Whether `item` is the first occurrence of its series, so deleting it and the following
    /// ones would delete the whole series.
    public static func startsSeries(_ item: PlanItem, in series: [RepeatingPlan]) -> Bool {
        isOriginal(item, in: series)
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
    /// Plans saved before the scheduled day stayed fixed moved an unfinished item's `day` to
    /// today. This puts it back on the day it was carried from, with its time range shifted
    /// along. A single time was dropped when it moved and cannot be recovered.
    @discardableResult public static func restoreScheduledDays(_ items: inout [PlanItem], calendar: Calendar = .current) -> Bool {
        var changed = false
        for index in items.indices {
            guard let from = items[index].carriedFrom else { continue }
            let shift = calendar.dateComponents([.day], from: from.date(calendar: calendar),
                                                to: items[index].day.date(calendar: calendar)).day ?? 0
            items[index].day = from
            items[index].end = items[index].end.flatMap { calendar.date(byAdding: .day, value: -shift, to: $0) }
            items[index].carriedFrom = nil
            changed = true
        }
        return changed
    }
    /// When an item ticked off while viewing `day` counts as done: on that day if it is in the
    /// past (at the current time of day), otherwise now.
    public static func completionDate(on day: Day, now: Date, calendar: Calendar = .current) -> Date {
        guard day < Day(now, calendar: calendar) else { return now }
        let time = calendar.dateComponents([.hour, .minute, .second], from: now)
        return calendar.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0, second: time.second ?? 0,
                             of: day.date(calendar: calendar)) ?? now
    }
    /// Cancels an item while viewing `day`, or restores it. Like completion, cancelling counts on
    /// a past day when done from it, so a carried item stops there. The two never stand together:
    /// cancelling clears completion, and restoring leaves the item open.
    public static func setCancelled(_ cancelled: Bool, _ item: inout PlanItem, on day: Day, now: Date, calendar: Calendar = .current) {
        item.cancelledAt = cancelled ? completionDate(on: day, now: now, calendar: calendar) : nil
        item.completedAt = nil
        item.suggestionDismissed = false
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
    /// Items carried on from `day`, oldest first. They are the same items as on their live
    /// day, so they are not counted, reviewed or reminded about again.
    public static func movedItems(from day: Day, in items: [PlanItem], now: Date, calendar: Calendar = .current) -> [PlanItem] {
        items.filter { $0.movedAway(from: day, now: now, calendar: calendar) }.sorted { $0.createdAt < $1.createdAt }
    }
    /// Every item in `persona` (among any others it has), grouped by its live day, newest day first. A carried item is
    /// listed once, where it is shown as itself. Repeating items only list occurrences up to
    /// today, since future ones are generated ahead and would bury the history.
    public static func history(of persona: Persona, in items: [PlanItem], now: Date, calendar: Calendar = .current) -> [PersonaDay] {
        let today = Day(now, calendar: calendar)
        let matching = items.filter { $0.personas.contains(persona) && ($0.seriesID == nil || $0.day <= today) }
        return Dictionary(grouping: matching, by: { $0.liveDay(now: now, calendar: calendar) })
            .map { day, items in
                PersonaDay(day: day, items: items.sorted {
                    if $0.minute != $1.minute { return ($0.minute ?? -1) < ($1.minute ?? -1) }
                    return $0.createdAt < $1.createdAt
                })
            }
            .sorted { $0.day > $1.day }
    }
    /// The nearest future reminders of unfinished, uncancelled items, one entry per reminder.
    public static func upcomingReminders(in items: [PlanItem], now: Date, limit: Int = 64) -> [ScheduledReminder] {
        Array(items.filter { !$0.isSettled }
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
        item.suggestionDismissed = false
    }
    public static func reschedule(_ item: inout PlanItem, to day: Day, minute: Int?, end: Date? = nil) {
        updateStart(&item, day: day, minute: minute)
        item.end = end
    }
    public static func suggestsParentCompletion(_ parent: PlanItem, in items: [PlanItem]) -> Bool {
        let children = items.filter { $0.parentID == parent.id }
        return !parent.isSettled && !parent.suggestionDismissed && !children.isEmpty && children.allSatisfy(\.isSettled)
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
