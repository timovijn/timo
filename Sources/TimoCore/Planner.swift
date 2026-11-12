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
    case never, daily, weekdays, weekly, monthEnd, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .never: return "Never"
        case .daily: return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly: return "Every week"
        case .monthEnd: return "Last day of the month"
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
        case .monthEnd: return day.isLastOfMonth(calendar: calendar)
        case .custom: return weekdays.contains(weekday)
        }
    }
}

extension Day {
    /// The 28th to the 31st, whichever ends its month: the next day is in another month.
    public func isLastOfMonth(calendar: Calendar = .current) -> Bool {
        let next = calendar.date(byAdding: .day, value: 1, to: date(calendar: calendar))!
        return calendar.component(.month, from: next) != calendar.component(.month, from: date(calendar: calendar))
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
    /// Legacy full-day group, consolidated into a single event when all its records arrive.
    public var isDateRange: Bool?
    public var excludedDays: [Day] = []
    public init(template: PlanItem) {
        id = UUID()
        familyID = id
        self.template = template.unprojected
        self.template.dailyStatuses = nil
        self.template.completedAt = nil
        self.template.cancelledAt = nil
        self.template.carriedFrom = nil
        self.template.suggestionDismissed = false
        self.template.seriesID = nil
        self.template.occurrenceDay = nil
        self.template.detachedFrom = nil
    }
    public func includes(_ day: Day, calendar: Calendar = .current) -> Bool {
        guard endBefore.map({ day < $0 }) ?? true, !excludedDays.contains(day) else { return false }
        return template.repeatRule.matches(day, starting: template.day, weekdays: template.repeatWeekdays, calendar: calendar)
    }
}

/// Retains where an individually edited occurrence came from, even if its date changes.
public struct LinkedItemOrigin: Codable, Equatable, Hashable {
    public var seriesID: UUID
    public var day: Day
    public init(seriesID: UUID, day: Day) { self.seriesID = seriesID; self.day = day }
}
public enum LinkedItemStatus: String, Equatable { case linked, changed, deleted }
public struct LinkedItemEntry: Identifiable, Equatable {
    public var origin: LinkedItemOrigin
    public var status: LinkedItemStatus
    public var item: PlanItem?
    public var id: UUID { PlanItem.occurrenceID(series: origin.seriesID, day: origin.day) }
}

/// Something kept with an item: a link, a piece of text or a file such as a photo or PDF. Links
/// and text are stored in the plan itself; a file's bytes sit beside the plan, in a folder named
/// after the attachment's ID, so copies of an item (a repeat's days, a duplicate) share one file.
public struct Attachment: Identifiable, Codable, Equatable, Hashable {
    public enum Kind: String, Codable { case link, text, file }
    public var id: UUID
    public var kind: Kind
    /// What it's called on the item: a link's host, a file's name, the text's first line.
    public var title: String
    public var url: URL?
    public var text: String?
    /// A file's name inside its folder, its uniform type identifier and its size.
    public var fileName: String?
    public var contentType: String?
    public var byteCount: Int?
    public var addedAt: Date

    public init(id: UUID = UUID(), kind: Kind, title: String, url: URL? = nil, text: String? = nil,
                fileName: String? = nil, contentType: String? = nil, byteCount: Int? = nil, addedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.title = title; self.url = url; self.text = text
        self.fileName = fileName; self.contentType = contentType; self.byteCount = byteCount; self.addedAt = addedAt
    }
    /// A web address, titled by its host without "www.".
    public static func link(_ url: URL, now: Date = Date()) -> Attachment {
        let host = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        return Attachment(kind: .link, title: host ?? url.absoluteString, url: url, addedAt: now)
    }
    /// Words to keep, titled by their first line (shortened when long).
    public static func text(_ text: String, now: Date = Date()) -> Attachment {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        let title = trimmed.count > 60 ? String(trimmed.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : trimmed
        return Attachment(kind: .text, title: title, text: text, addedAt: now)
    }
    /// What a typed or pasted line is: a link when it's a web address, otherwise text. Nil when blank.
    public static func reading(_ typed: String, now: Date = Date()) -> Attachment? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(where: \.isWhitespace) {
            // "example.com/page" without a scheme still reads as a link.
            let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
            if let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
               let host = url.host, !host.hasPrefix("."), let ending = host.split(separator: ".").last, ending != Substring(host),
               // Ends in a real domain ending, so "v1.2" or "3.5" stay text.
               ending.count >= 2, ending.allSatisfy(\.isLetter) {
                return .link(url, now: now)
            }
        }
        return .text(trimmed, now: now)
    }
    /// The words search looks in: the title, a link's address, the text.
    public var searchableText: [String] {
        [title, url?.absoluteString, text].compactMap { $0 }
    }
}

/// One line of an item's checklist, such as one thing to buy on a shopping trip. It's ticked off
/// on its own; ticking every entry doesn't complete the item, nor does completing the item tick them.
public struct ChecklistEntry: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    /// When it was ticked off; nil while open.
    public var doneAt: Date?
    public var isDone: Bool { doneAt != nil }
    public init(id: UUID = UUID(), title: String, doneAt: Date? = nil) {
        self.id = id; self.title = title; self.doneAt = doneAt
    }
    /// `entries` as defined (titles and order) with each one's tick taken from `source`, matched
    /// by ID; an entry `source` doesn't have is open. A repeating item's days share the entries
    /// but each keeps its own ticks.
    public static func ticks(from source: [ChecklistEntry], onto entries: [ChecklistEntry]) -> [ChecklistEntry] {
        let done = Dictionary(source.map { ($0.id, $0.doneAt) }, uniquingKeysWith: { first, _ in first })
        return entries.map { var entry = $0; entry.doneAt = done[$0.id] ?? nil; return entry }
    }
    /// The entries with nothing ticked: what a new day of a repeating item, or a copy, starts with.
    public static func untouched(_ entries: [ChecklistEntry]) -> [ChecklistEntry] {
        entries.map { var entry = $0; entry.doneAt = nil; return entry }
    }
    /// Combines two edits of one checklist made apart from each other, entry by entry, from the
    /// version both started from: a tick or a new title on either side is kept, entries added on
    /// either side are both kept, and an entry deleted on either side goes. The order comes from
    /// whichever side reordered, else from `theirs`; entries only `mine` added follow at the end.
    public static func merged(base: [ChecklistEntry], mine: [ChecklistEntry], theirs: [ChecklistEntry]) -> [ChecklistEntry] {
        func byID(_ entries: [ChecklistEntry]) -> [UUID: ChecklistEntry] {
            Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let original = byID(base), mineByID = byID(mine), theirsByID = byID(theirs)
        func order(_ entries: [ChecklistEntry], among others: [ChecklistEntry]) -> [UUID] {
            let shared = Set(others.map(\.id))
            return entries.map(\.id).filter(shared.contains)
        }
        let mineReordered = order(mine, among: base) != order(base, among: mine)
        let (first, second) = mineReordered ? (mine, theirs) : (theirs, mine)
        var ids = first.map(\.id)
        ids += second.map(\.id).filter { !ids.contains($0) && original[$0] == nil }
        return ids.compactMap { id in
            // Deleted on either side.
            if original[id] != nil && (mineByID[id] == nil || theirsByID[id] == nil) { return nil }
            guard let mineEntry = mineByID[id] else { return theirsByID[id] }
            guard let theirEntry = theirsByID[id], let baseEntry = original[id] else { return mineEntry }
            var entry = theirEntry
            if mineEntry.title != baseEntry.title { entry.title = mineEntry.title }
            if mineEntry.doneAt != baseEntry.doneAt { entry.doneAt = mineEntry.doneAt }
            return entry
        }
    }
}

/// One day's check-off on a single full-day event. Open entries are retained for sync merges.
public struct DateRangeDayStatus: Codable, Equatable, Identifiable {
    public var id: Day { day }
    public var day: Day
    public var completedAt: Date?
    public var cancelledAt: Date?
}

public struct PlanItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var movesToNextDay: Bool
    public var repeatRule: RepeatRule = .never
    public var repeatWeekdays: [Int] = []
    public var seriesID: UUID?
    public var occurrenceDay: Day?
    public var detachedFrom: LinkedItemOrigin?
    /// Retired full-day groups, retained so late sync records cannot recreate daily copies.
    public var mergedRangeSeriesIDs: [UUID]?
    public var dailyStatuses: [DateRangeDayStatus]?
    /// Exceptions retained only when importing a legacy group with individually removed days.
    public var excludedRangeDays: [Day]?
    /// The personas this item belongs to; it can be in several, or none.
    public var personas: [Persona] = []
    /// Links, text and files kept with the item, in the order they were added.
    public var attachments: [Attachment] = []
    /// Things to tick off within the item, in order: the groceries on a shopping trip.
    public var checklist: [ChecklistEntry] = []
    /// How many entries are ticked off, of how many; nil without a checklist.
    public var checklistProgress: (done: Int, total: Int)? {
        checklist.isEmpty ? nil : (checklist.filter(\.isDone).count, checklist.count)
    }
    public var title: String
    public var notes: String
    public var locations: [String]
    public var people: [String]
    public var day: Day
    public var minute: Int?
    public var end: Date?
    /// Inclusive final day of an untimed range, independent of time zone.
    public var endDay: Day?
    /// Moments to be reminded; an item can have several.
    public var reminders: [Date]
    /// When the item has to be done by. Only marked, not notified.
    public var deadline: Date?
    private var wholeCompletedAt: Date?
    private var wholeCancelledAt: Date?
    /// A display-only selection; never encoded. Every displayed day retains the same item ID.
    private var statusDay: Day?
    public var completedAt: Date? {
        get {
            if let selectedStatus { return selectedStatus.completedAt }
            return wholeCompletedAt
        }
        set {
            if let statusKey { setDailyStatus(on: statusKey, completedAt: newValue, cancelledAt: cancelledAt) }
            else { wholeCompletedAt = newValue }
        }
    }
    /// When the item was called off. A cancelled item is never complete, doesn't carry on,
    /// isn't reviewed or reminded about, and stays visible in a quiet style until restored.
    public var cancelledAt: Date? {
        get {
            if let selectedStatus { return selectedStatus.cancelledAt }
            return wholeCancelledAt
        }
        set {
            if let statusKey { setDailyStatus(on: statusKey, completedAt: completedAt, cancelledAt: newValue) }
            else { wholeCancelledAt = newValue }
        }
    }
    private var statusKey: Day? {
        guard minute == nil, let endDay else { return nil }
        return statusDay.map { min(max($0, day), endDay) }
    }
    private var selectedStatus: DateRangeDayStatus? {
        statusKey.flatMap { day in dailyStatuses?.first { $0.day == day } }
    }
    private mutating func setDailyStatus(on day: Day, completedAt: Date?, cancelledAt: Date?) {
        var statuses = dailyStatuses ?? []
        statuses.removeAll { $0.day == day }
        statuses.append(DateRangeDayStatus(day: day, completedAt: completedAt, cancelledAt: cancelledAt))
        dailyStatuses = statuses.sorted { $0.day < $1.day }
    }
    /// The check-off state for the viewed date; carry-over after the range uses its final day.
    public func on(_ selected: Day) -> PlanItem {
        var result = self
        result.statusDay = endDay != nil && minute == nil ? selected : nil
        return result
    }
    /// A new, unsaved copy to start from: the same plan (title, schedule, repeat, personas,
    /// people, places, reminders, deadline) but open, unshared and linked to nothing, so saving a
    /// repeating one starts a series of its own.
    public func duplicate(now: Date = Date()) -> PlanItem {
        var copy = unprojected
        copy.id = UUID()
        copy.wholeCompletedAt = nil
        copy.wholeCancelledAt = nil
        copy.dailyStatuses = nil
        copy.seriesID = nil
        copy.occurrenceDay = nil
        copy.detachedFrom = nil
        copy.mergedRangeSeriesIDs = nil
        copy.excludedRangeDays = nil
        copy.carriedFrom = nil
        copy.suggestionDismissed = false
        copy.checklist = ChecklistEntry.untouched(copy.checklist)
        copy.originalDay = copy.day
        copy.createdAt = now
        return copy
    }
    public var unprojected: PlanItem {
        var result = self
        result.statusDay = nil
        return result
    }
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
                minute: Int? = nil, end: Date? = nil, endDay: Day? = nil, parentID: UUID? = nil, movesToNextDay: Bool = true, reminders: [Date] = [], locations: [String] = [], people: [String] = []) {
        self.id = id; self.movesToNextDay = movesToNextDay; self.title = title; self.notes = notes; self.day = day
        self.minute = minute; self.end = end; self.endDay = endDay; self.parentID = parentID; originalDay = day
        self.locations = locations; self.people = people
        self.reminders = reminders
        suggestionDismissed = false; createdAt = Date()
    }
    // Read the original task/event format without changing IDs or scheduling choices.
    private enum CodingKeys: String, CodingKey {
        case id, title, notes, locations, people, day, minute, end, endDay, reminders, deadline, completedAt, cancelledAt, parentID, originalDay, carriedFrom, suggestionDismissed, createdAt, movesToNextDay, repeatRule, repeatWeekdays, seriesID, occurrenceDay, detachedFrom, personas, mergedRangeSeriesIDs, dailyStatuses, excludedRangeDays, attachments, checklist
    }
    private enum LegacyKeys: String, CodingKey { case kind, reminderAt, persona }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        repeatRule = try c.decodeIfPresent(RepeatRule.self, forKey: .repeatRule) ?? .never
        repeatWeekdays = try c.decodeIfPresent([Int].self, forKey: .repeatWeekdays) ?? []
        seriesID = try c.decodeIfPresent(UUID.self, forKey: .seriesID)
        occurrenceDay = try c.decodeIfPresent(Day.self, forKey: .occurrenceDay)
        detachedFrom = try c.decodeIfPresent(LinkedItemOrigin.self, forKey: .detachedFrom)
        mergedRangeSeriesIDs = try c.decodeIfPresent([UUID].self, forKey: .mergedRangeSeriesIDs)
        dailyStatuses = try c.decodeIfPresent([DateRangeDayStatus].self, forKey: .dailyStatuses)
        excludedRangeDays = try c.decodeIfPresent([Day].self, forKey: .excludedRangeDays)
        // Personas this version doesn't know are left out. Version 6 kept a single persona.
        if let saved = try c.decodeIfPresent([String].self, forKey: .personas) {
            personas = Persona.ordered(saved.compactMap(Persona.init(rawValue:)))
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            personas = try legacy.decodeIfPresent(String.self, forKey: .persona).flatMap(Persona.init(rawValue:)).map { [$0] } ?? []
        }
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decode(String.self, forKey: .notes)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        checklist = try c.decodeIfPresent([ChecklistEntry].self, forKey: .checklist) ?? []
        locations = try c.decodeIfPresent([String].self, forKey: .locations) ?? []
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        day = try c.decode(Day.self, forKey: .day)
        minute = try c.decodeIfPresent(Int.self, forKey: .minute)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        endDay = try c.decodeIfPresent(Day.self, forKey: .endDay)
        if let saved = try c.decodeIfPresent([Date].self, forKey: .reminders) {
            reminders = saved
        } else {
            // Items saved before multiple reminders kept a single optional reminder.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            reminders = try legacy.decodeIfPresent(Date.self, forKey: .reminderAt).map { [$0] } ?? []
        }
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        wholeCompletedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        wholeCancelledAt = try c.decodeIfPresent(Date.self, forKey: .cancelledAt)
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
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(notes, forKey: .notes)
        try c.encode(locations, forKey: .locations)
        try c.encode(people, forKey: .people)
        try c.encode(day, forKey: .day)
        try c.encode(reminders, forKey: .reminders)
        try c.encode(originalDay, forKey: .originalDay)
        try c.encode(suggestionDismissed, forKey: .suggestionDismissed)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(movesToNextDay, forKey: .movesToNextDay)
        try c.encode(repeatRule, forKey: .repeatRule)
        try c.encode(repeatWeekdays, forKey: .repeatWeekdays)
        try c.encode(personas, forKey: .personas)
        try c.encodeIfPresent(minute, forKey: .minute)
        try c.encodeIfPresent(end, forKey: .end)
        try c.encodeIfPresent(endDay, forKey: .endDay)
        try c.encodeIfPresent(deadline, forKey: .deadline)
        try c.encodeIfPresent(parentID, forKey: .parentID)
        try c.encodeIfPresent(carriedFrom, forKey: .carriedFrom)
        try c.encodeIfPresent(seriesID, forKey: .seriesID)
        try c.encodeIfPresent(occurrenceDay, forKey: .occurrenceDay)
        try c.encodeIfPresent(detachedFrom, forKey: .detachedFrom)
        try c.encodeIfPresent(mergedRangeSeriesIDs, forKey: .mergedRangeSeriesIDs)
        try c.encodeIfPresent(dailyStatuses, forKey: .dailyStatuses)
        try c.encodeIfPresent(excludedRangeDays, forKey: .excludedRangeDays)
        try c.encodeIfPresent(wholeCompletedAt, forKey: .completedAt)
        try c.encodeIfPresent(wholeCancelledAt, forKey: .cancelledAt)
        // Left out when empty, so items without attachments are saved and synced as before.
        if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
        if !checklist.isEmpty { try c.encode(checklist, forKey: .checklist) }
    }
    /// The ID of a repeating item's occurrence on `day`: the same on every device, from the
    /// series and the day alone. Two 64-bit FNV-1a hashes keep it Foundation-only; the version
    /// and variant bits mark it as a custom (version 8) UUID.
    public static func occurrenceID(series: UUID, day: Day) -> UUID {
        let s = series.uuid
        var bytes: [UInt8] = [s.0, s.1, s.2, s.3, s.4, s.5, s.6, s.7, s.8, s.9, s.10, s.11, s.12, s.13, s.14, s.15]
        for part in [day.era, day.year, day.month, day.day] {
            withUnsafeBytes(of: Int32(truncatingIfNeeded: part).littleEndian) { bytes.append(contentsOf: $0) }
        }
        func fnv(_ basis: UInt64) -> UInt64 {
            bytes.reduce(basis) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        }
        let high = fnv(0xcbf29ce484222325), low = fnv(0x84222325cbf29ce4)
        var out = (0..<8).map { UInt8(truncatingIfNeeded: high >> (56 - 8 * $0)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: low >> (56 - 8 * $0)) }
        out[6] = out[6] & 0x0f | 0x80
        out[8] = out[8] & 0x3f | 0x80
        return UUID(uuid: (out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7],
                           out[8], out[9], out[10], out[11], out[12], out[13], out[14], out[15]))
    }
    /// Unfinished with a deadline set, passed or not; marked with a red dot.
    public var hasOpenDeadline: Bool { !isSettled && deadline != nil }
    /// The reminder to show for this item: the next one still to come, otherwise the latest.
    public func displayedReminder(now: Date) -> Date? {
        let active = reminders.filter { !on(Day($0)).isSettled }
        return active.filter { $0 > now }.min() ?? active.max()
    }
    public func start(calendar: Calendar = .current) -> Date? {
        guard let minute else { return nil }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day.date(calendar: calendar))
    }
    // About the time, not the item: a range ticked off early still runs until its end,
    // so it stays in the Ongoing group. Only cancelling takes it out.
    public func isInProgress(now: Date, calendar: Calendar = .current) -> Bool {
        guard !isCancelled, let start = start(calendar: calendar), let end else { return false }
        return start <= now && now < end
    }
    /// Exclusive boundary: untimed ranges end at midnight after their inclusive final day.
    public func scheduleEnd(calendar: Calendar = .current) -> Date? {
        if let endDay { return calendar.date(byAdding: .day, value: 1, to: endDay.date(calendar: calendar)) }
        return end
    }
    public func isElapsed(now: Date, calendar: Calendar = .current) -> Bool {
        guard !isSettled else { return false }
        if let statusDay, appears(on: statusDay, calendar: calendar),
           let boundary = calendar.date(byAdding: .day, value: 1, to: statusDay.date(calendar: calendar)) { return boundary < now }
        guard let boundary = scheduleEnd(calendar: calendar) ?? start(calendar: calendar) else { return false }
        return boundary < now
    }
    public func appears(on selected: Day, calendar: Calendar = .current) -> Bool {
        if let endDay { return day <= selected && selected <= endDay && excludedRangeDays?.contains(selected) != true }
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
        if let endDay, minute == nil {
            if on(endDay).isSettled { return day }
            return Day(now, calendar: calendar) > endDay ? Day(now, calendar: calendar) : day
        }
        if let settled = completedAt ?? cancelledAt {
            let settledDay = Day(settled, calendar: calendar)
            if let endDay, settledDay <= endDay { return day }
            return max(day, settledDay)
        }
        if let boundary = scheduleEnd(calendar: calendar), boundary > now { return day }
        return max(day, Day(now, calendar: calendar))
    }
    /// Whether this item is shown on a later day than it was scheduled for.
    public func isCarried(now: Date, calendar: Calendar = .current) -> Bool {
        if let statusDay, appears(on: statusDay, calendar: calendar) { return false }
        return liveDay(now: now, calendar: calendar) > day
    }
    /// Whether `selected` shows this item as itself. A carried item is shown once, on its live
    /// day, as an untimed item; otherwise it is shown on every day its schedule covers.
    public func shows(on selected: Day, now: Date, calendar: Calendar = .current) -> Bool {
        let live = liveDay(now: now, calendar: calendar)
        if endDay != nil, minute == nil, appears(on: selected, calendar: calendar) { return true }
        return live == day ? appears(on: selected, calendar: calendar) : selected == live
    }
    /// Whether this item was carried on from `selected`: every day from its scheduled day up
    /// to its live day keeps a quiet entry pointing to where it went.
    public func movedAway(from selected: Day, now: Date, calendar: Calendar = .current) -> Bool {
        let live = liveDay(now: now, calendar: calendar)
        if let endDay, minute == nil, selected <= endDay { return false }
        return live > day && day <= selected && selected < live
    }
    /// Whether a reminder still to come falls on `selected`, while the item is unfinished.
    public func reminds(on selected: Day, now: Date, calendar: Calendar = .current) -> Bool {
        !on(selected).isSettled && reminders.contains { $0 > now && Day($0, calendar: calendar) == selected }
    }
    /// Whether the item's open deadline falls on `selected`, passed or not.
    public func isDue(on selected: Day, calendar: Calendar = .current) -> Bool {
        hasOpenDeadline && deadline.map { Day($0, calendar: calendar) == selected } == true
    }
    /// Whether `selected` doesn't show this item, as itself or as a "Carried to" entry, but has
    /// one of its upcoming reminders or its open deadline: the reminder and deadline filters
    /// show it there too, as a visitor from its own day.
    public func visits(_ selected: Day, now: Date, calendar: Calendar = .current) -> Bool {
        !shows(on: selected, now: now, calendar: calendar) && !movedAway(from: selected, now: now, calendar: calendar)
            && (reminds(on: selected, now: now, calendar: calendar) || isDue(on: selected, calendar: calendar))
    }
    /// When a visitor's first upcoming reminder or deadline falls on `selected`, where it's placed.
    public func visitTime(on selected: Day, now: Date, calendar: Calendar = .current) -> Date? {
        let reminder = isSettled ? nil : reminders.filter { $0 > now && Day($0, calendar: calendar) == selected }.min()
        let due = isDue(on: selected, calendar: calendar) ? deadline : nil
        return [reminder, due].compactMap { $0 }.min()
    }
}

/// What each person keeps for themselves on a shared item: my reminders don't notify you and
/// my personas aren't yours. Everything else is the same for everyone, completion included,
/// so one person ticking an item off completes it for all.
public struct PersonalDetails: Codable, Equatable {
    public var reminders: [Date]
    public var personas: [Persona]
    public var suggestionDismissed: Bool
    public init(reminders: [Date] = [], personas: [Persona] = [], suggestionDismissed: Bool = false) {
        self.reminders = reminders; self.personas = personas; self.suggestionDismissed = suggestionDismissed
    }
}

extension PlanItem {
    public var personal: PersonalDetails {
        get { PersonalDetails(reminders: reminders, personas: personas, suggestionDismissed: suggestionDismissed) }
        set { reminders = newValue.reminders; personas = Persona.ordered(newValue.personas); suggestionDismissed = newValue.suggestionDismissed }
    }
    /// The item as other people get it: without what each person keeps for themselves.
    public var forSharing: PlanItem {
        var shared = self
        shared.personal = PersonalDetails()
        return shared
    }
    /// Combines two edits of one item made apart from each other, from the version both started
    /// from: whatever `mine` changed wins, everything else comes from `theirs`. Fields that only
    /// make sense together (the schedule, completion and cancelling, the repeat pattern) are
    /// taken as one, so a merge never pairs one edit's start with another's end.
    public static func merged(base: PlanItem, mine: PlanItem, theirs: PlanItem) -> PlanItem {
        if let oldSeries = theirs.seriesID, mine.mergedRangeSeriesIDs?.contains(oldSeries) == true { return mine }
        if let oldSeries = mine.seriesID, theirs.mergedRangeSeriesIDs?.contains(oldSeries) == true { return theirs }
        var result = theirs
        func changed(_ fields: (PlanItem) -> [AnyHashable]) -> Bool { fields(mine) != fields(base) }
        func take<T: Equatable>(_ path: WritableKeyPath<PlanItem, T>) {
            if mine[keyPath: path] != base[keyPath: path] { result[keyPath: path] = mine[keyPath: path] }
        }
        take(\.title); take(\.notes); take(\.locations); take(\.people); take(\.deadline)
        take(\.parentID); take(\.movesToNextDay); take(\.carriedFrom); take(\.excludedRangeDays)
        take(\.reminders); take(\.personas); take(\.suggestionDismissed); take(\.attachments)
        if mine.checklist != base.checklist { result.checklist = ChecklistEntry.merged(base: base.checklist, mine: mine.checklist, theirs: theirs.checklist) }
        if changed({ [$0.day, $0.minute, $0.end, $0.endDay, $0.originalDay] }) {
            result.day = mine.day; result.minute = mine.minute; result.end = mine.end; result.endDay = mine.endDay; result.originalDay = mine.originalDay
        }
        if changed({ [$0.completedAt, $0.cancelledAt] }) {
            result.completedAt = mine.completedAt; result.cancelledAt = mine.cancelledAt
        }
        if changed({ [$0.repeatRule, $0.repeatWeekdays, $0.seriesID, $0.occurrenceDay, $0.detachedFrom] }) {
            result.repeatRule = mine.repeatRule; result.repeatWeekdays = mine.repeatWeekdays
            result.seriesID = mine.seriesID; result.occurrenceDay = mine.occurrenceDay; result.detachedFrom = mine.detachedFrom
        }
        let retired = Set((mine.mergedRangeSeriesIDs ?? []) + (theirs.mergedRangeSeriesIDs ?? []))
        if !retired.isEmpty { result.mergedRangeSeriesIDs = retired.sorted { $0.uuidString < $1.uuidString } }
        let baseStatuses = Dictionary((base.dailyStatuses ?? []).map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        let mineStatuses = Dictionary((mine.dailyStatuses ?? []).map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        var statuses = Dictionary((theirs.dailyStatuses ?? []).map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        for (day, status) in mineStatuses where baseStatuses[day] != status { statuses[day] = status }
        if !statuses.isEmpty { result.dailyStatuses = statuses.values.sorted { $0.day < $1.day } }
        return result
    }
}

extension RepeatingPlan {
    /// The plan as other people get it, so a shared series generates no one else's reminders.
    public var forSharing: RepeatingPlan {
        var shared = self
        shared.template.personal = PersonalDetails()
        return shared
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
        case .schedule: return "Choose an end date on or after the start date, or an end time after the start time."
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
        var usedIDs = Set(items.map(\.id))
        for plan in series {
            var existing = Set(items.filter { $0.seriesID == plan.id }.compactMap(\.occurrenceDay))
            var cursor = max(first, plan.template.day)
            while cursor <= last {
                if !existing.contains(cursor), plan.includes(cursor, calendar: calendar) {
                    var occurrence = plan.template
                    // Every device derives the same ID for a series' day, so syncing doesn't
                    // double it. A shifted or detached occurrence can already hold that ID.
                    let derived = PlanItem.occurrenceID(series: plan.id, day: cursor)
                    occurrence.id = usedIDs.contains(derived) ? UUID() : derived
                    usedIDs.insert(occurrence.id)
                    occurrence.seriesID = plan.id
                    occurrence.occurrenceDay = cursor
                    updateStart(&occurrence, day: cursor, minute: occurrence.minute, calendar: calendar)
                    occurrence.originalDay = cursor
                    occurrence.deadline = deadline(of: plan.template, on: cursor, calendar: calendar)
                    occurrence = occurrence.unprojected
                    occurrence.dailyStatuses = nil
                    occurrence.completedAt = nil
                    occurrence.cancelledAt = nil
                    occurrence.parentID = nil
                    occurrence.checklist = ChecklistEntry.untouched(occurrence.checklist)
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
    /// Folds occurrences of the same series day into one. Before occurrence IDs came from the
    /// series and day, each device generated its own, so syncing two can bring a day twice. The
    /// one kept is chosen from the IDs alone, so every device keeps the same one: the derived ID,
    /// otherwise the lowest. A dropped copy that was completed or cancelled passes that on, and
    /// its children move to the one kept.
    @discardableResult public static func mergeDuplicateOccurrences(_ items: inout [PlanItem]) -> Bool {
        struct Key: Hashable { let series: UUID; let day: Day }
        let occurrences = items.indices.filter { items[$0].seriesID != nil && items[$0].occurrenceDay != nil }
        let groups = Dictionary(grouping: occurrences) { Key(series: items[$0].seriesID!, day: items[$0].occurrenceDay!) }
        var dropped: [UUID: UUID] = [:]
        for (key, indices) in groups where indices.count > 1 {
            let derived = PlanItem.occurrenceID(series: key.series, day: key.day)
            let keep = indices.first { items[$0].id == derived }
                ?? indices.min { items[$0].id.uuidString < items[$1].id.uuidString }!
            for index in indices where index != keep {
                if !items[keep].isSettled, items[index].isSettled {
                    items[keep].completedAt = items[index].completedAt
                    items[keep].cancelledAt = items[index].cancelledAt
                }
                dropped[items[index].id] = items[keep].id
            }
        }
        guard !dropped.isEmpty else { return false }
        items.removeAll { dropped[$0.id] != nil }
        for index in items.indices {
            if let parent = items[index].parentID, let kept = dropped[parent] { items[index].parentID = kept }
        }
        return true
    }
    /// Combine legacy daily full-day groups once. Wait for every linked day to arrive before
    /// migrating, so a partial sync batch cannot decide the event's completion prematurely.
    @discardableResult public static func consolidateDateRanges(items: inout [PlanItem], series: inout [RepeatingPlan], calendar: Calendar = .current) -> Bool {
        let previousItems = items, previousSeries = series
        for plan in series where plan.isDateRange == true {
            guard !items.contains(where: { $0.mergedRangeSeriesIDs?.contains(plan.id) == true }),
                  plan.template.minute == nil, let end = plan.endBefore,
                  let finalDate = calendar.date(byAdding: .day, value: -1, to: end.date(calendar: calendar)),
                  Day(finalDate, calendar: calendar) >= plan.template.day else { continue }
            let linked = items.filter { $0.seriesID == plan.id }
            var cursor = plan.template.day
            var complete = true
            while cursor < end {
                if plan.includes(cursor, calendar: calendar), !linked.contains(where: { ($0.occurrenceDay ?? $0.day) == cursor }) {
                    complete = false; break
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor.date(calendar: calendar)) else { complete = false; break }
                cursor = Day(next, calendar: calendar)
            }
            guard complete, !linked.isEmpty else { continue }
            var event = linked.first { $0.id == plan.template.id } ?? plan.template
            // Keep a separately edited original if it already owns the template ID.
            if items.contains(where: { $0.id == event.id && $0.seriesID != plan.id }) {
                event.id = PlanItem.occurrenceID(series: plan.id, day: end)
            }
            event.day = plan.template.day
            event.originalDay = event.day
            event.endDay = Day(finalDate, calendar: calendar)
            event.minute = nil; event.end = nil; event.carriedFrom = nil
            event.seriesID = nil; event.occurrenceDay = nil; event.detachedFrom = nil
            event.repeatRule = .never; event.repeatWeekdays = []
            event.mergedRangeSeriesIDs = [plan.id]
            event.excludedRangeDays = plan.excludedDays.isEmpty ? nil : plan.excludedDays.sorted()
            event.dailyStatuses = linked.map {
                DateRangeDayStatus(day: $0.occurrenceDay ?? $0.day, completedAt: $0.completedAt, cancelledAt: $0.cancelledAt)
            }.sorted { $0.day < $1.day }
            event.completedAt = nil; event.cancelledAt = nil
            event.reminders = Array(Set(linked.flatMap(\.reminders))).sorted()
            event.personas = Persona.ordered(linked.flatMap(\.personas))
            event.people = Array(Set(linked.flatMap(\.people))).sorted()
            event.locations = Array(Set(linked.flatMap(\.locations))).sorted()
            event.deadline = linked.compactMap(\.deadline).max() ?? plan.template.deadline
            let notes = Array(Set(linked.map(\.notes).filter { !$0.isEmpty })).sorted()
            if notes.count > 1 { event.notes = notes.joined(separator: "\n\n") }
            let oldIDs = Set(linked.map(\.id))
            items.removeAll { oldIDs.contains($0.id) }
            for index in items.indices where items[index].parentID.map(oldIDs.contains) == true {
                items[index].parentID = event.id
            }
            items.append(event)
        }
        // The event's marker also handles old group/daily records arriving in a later batch.
        let retired = Set(items.flatMap { $0.mergedRangeSeriesIDs ?? [] })
        items.removeAll { $0.seriesID.map(retired.contains) == true }
        series.removeAll { retired.contains($0.id) }
        for index in items.indices where items[index].detachedFrom.map({ retired.contains($0.seriesID) }) == true {
            items[index].detachedFrom = nil
        }
        for index in items.indices where items[index].minute == nil && items[index].endDay != nil && items[index].dailyStatuses == nil && items[index].seriesID == nil {
            items[index].dailyStatuses = []
        }
        return items != previousItems || series != previousSeries
    }
    // A repeating item has one shared definition. Edits update its whole family, including
    // plans split by older versions. The editor detaches later days instead.
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
            case .monthEnd: return day.isLastOfMonth(calendar: calendar)
            case .custom: return edited.repeatWeekdays.contains(weekday)
            }
        }
        // A week finds any weekday; a month finds its last day.
        var start = earliest
        for offset in 0..<31 {
            let candidate = Day(calendar.date(byAdding: .day, value: offset, to: earliest.date(calendar: calendar))!, calendar: calendar)
            if matches(candidate) { start = candidate; break }
        }
        var definition = edited
        updateStart(&definition, day: start, minute: edited.minute, calendar: calendar)
        definition.deadline = deadline(of: edited, on: start, calendar: calendar)
        var plan = RepeatingPlan(template: definition)
        // The template holds the entries; every day keeps its own ticks.
        plan.template.checklist = ChecklistEntry.untouched(definition.checklist)
        if let first = plans.min(by: { $0.template.day < $1.template.day }) {
            plan.id = first.id
            plan.familyID = first.familyID
            if first.isDateRange == true, definition.repeatRule == .daily,
               definition.minute == nil, definition.endDay == definition.day {
                plan.isDateRange = true
            }
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
            updated.deadline = deadline(of: definition, on: day, calendar: calendar)
            updated.id = old.id
            updated.seriesID = plan.id
            updated.occurrenceDay = day
            updated.originalDay = day
            updated.createdAt = old.createdAt
            updated.detachedFrom = old.id == edited.id ? edited.detachedFrom : old.detachedFrom
            updated.completedAt = old.id == edited.id ? edited.completedAt : old.completedAt
            updated.cancelledAt = old.id == edited.id ? edited.cancelledAt : old.cancelledAt
            updated.parentID = old.parentID
            if old.id != edited.id { updated.checklist = ChecklistEntry.ticks(from: old.checklist, onto: definition.checklist) }
            let scheduleChanged = old.day != updated.day || old.minute != updated.minute || old.end != updated.end || old.endDay != updated.endDay
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
            let removed = items.filter { occurrence in
                occurrence.seriesID.map(related.contains) ?? false && (occurrence.occurrenceDay ?? occurrence.day) >= day
            }
            for index in series.indices where related.contains(series[index].id) {
                let dates = removed.filter { $0.seriesID == series[index].id }.map { $0.occurrenceDay ?? $0.day }
                series[index].excludedDays = Array(Set(series[index].excludedDays + dates)).sorted()
            }
            let ids = removed.map(\.id)
            for id in ids { delete(id, includingChildren: false, from: &items) }
            series.removeAll { related.contains($0.id) && $0.template.day >= day }
            for index in series.indices where related.contains(series[index].id) {
                series[index].endBefore = min(series[index].endBefore ?? day, day)
            }
        }
    }
    /// Each occurrence is due the same number of days after its own day as the original is after
    /// its day, so a deadline on the day itself stays on each occurrence's own day.
    static func deadline(of template: PlanItem, on day: Day, calendar: Calendar) -> Date? {
        guard let deadline = template.deadline else { return nil }
        let shift = calendar.dateComponents([.day], from: template.day.date(calendar: calendar), to: day.date(calendar: calendar)).day ?? 0
        return calendar.date(byAdding: .day, value: shift, to: deadline)
    }
    private static func defaultLinkedItem(_ plan: RepeatingPlan, on day: Day, calendar: Calendar) -> PlanItem {
        var value = plan.template
        updateStart(&value, day: day, minute: value.minute, calendar: calendar)
        value.deadline = deadline(of: plan.template, on: day, calendar: calendar)
        value.id = PlanItem.occurrenceID(series: plan.id, day: day)
        value.seriesID = plan.id; value.occurrenceDay = day; value.originalDay = day
        value.detachedFrom = nil; value.carriedFrom = nil; value.parentID = nil
        value.completedAt = nil; value.cancelledAt = nil; value.suggestionDismissed = false
        value.checklist = ChecklistEntry.untouched(value.checklist)
        return value
    }
    private static func linkedItem(_ origin: LinkedItemOrigin, plan: RepeatingPlan, items: [PlanItem]) -> PlanItem? {
        if let linked = items.first(where: { $0.seriesID == origin.seriesID && ($0.occurrenceDay ?? $0.day) == origin.day }) { return linked }
        if let detached = items.first(where: { $0.detachedFrom == origin }) { return detached }
        // Older detached records have no provenance. Their stable occurrence ID still identifies them.
        let derived = PlanItem.occurrenceID(series: origin.seriesID, day: origin.day)
        return items.first {
            $0.seriesID != plan.id && $0.detachedFrom == nil
                && ($0.id == derived || (origin.day == plan.template.day && $0.id == plan.template.id))
        }
    }
    private static func matchesLinkedDefault(_ item: PlanItem, _ expected: PlanItem) -> Bool {
        item.title == expected.title && item.notes == expected.notes && item.locations == expected.locations && item.people == expected.people
            && item.day == expected.day && item.minute == expected.minute && item.end == expected.end && item.endDay == expected.endDay
            && item.movesToNextDay == expected.movesToNextDay && item.repeatRule == expected.repeatRule && item.repeatWeekdays == expected.repeatWeekdays
            && item.personas == expected.personas && Set(item.reminders) == Set(expected.reminders) && item.deadline == expected.deadline
            && item.attachments == expected.attachments
            && ChecklistEntry.untouched(item.checklist) == ChecklistEntry.untouched(expected.checklist)
    }
    /// Finite groups show their full range. Open-ended repeats show generated and excluded
    /// dates plus the requested horizon; merely opening the overview never creates records.
    public static func linkedItems(for original: PlanItem, in items: [PlanItem], series: [RepeatingPlan], through horizon: Day,
                                   calendar: Calendar = .current) -> [LinkedItemEntry] {
        guard let family = series.first(where: { $0.id == original.seriesID })?.familyID else { return [] }
        var entries: [LinkedItemEntry] = []
        for plan in series where plan.familyID == family {
            let materialized = items.filter { $0.seriesID == plan.id }.compactMap(\.occurrenceDay).max() ?? plan.template.day
            let last = max(plan.endBefore.map { Day(calendar.date(byAdding: .day, value: -1, to: $0.date(calendar: calendar))!, calendar: calendar) } ?? max(horizon, materialized), plan.excludedDays.max() ?? plan.template.day)
            var day = plan.template.day
            while day <= last {
                let excluded = plan.excludedDays.contains(day)
                if plan.template.repeatRule.matches(day, starting: plan.template.day, weekdays: plan.template.repeatWeekdays, calendar: calendar),
                   excluded || plan.endBefore.map({ day < $0 }) ?? true {
                    let origin = LinkedItemOrigin(seriesID: plan.id, day: day)
                    let actual = linkedItem(origin, plan: plan, items: items)
                    let status: LinkedItemStatus
                    if excluded { status = actual == nil ? .deleted : .changed }
                    else if let actual { status = matchesLinkedDefault(actual, defaultLinkedItem(plan, on: day, calendar: calendar)) ? .linked : .changed }
                    else { status = .linked }
                    entries.append(LinkedItemEntry(origin: origin, status: status, item: actual))
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day.date(calendar: calendar)) else { break }
                day = Day(next, calendar: calendar)
            }
        }
        return entries.sorted { $0.origin.day < $1.origin.day }
    }
    /// Restore one date to the saved template. Existing settlement and identity survive;
    /// a deleted date returns open. An individually changed date rejoins its original series.
    @discardableResult public static func restoreLinkedItem(_ entry: LinkedItemEntry, items: inout [PlanItem], series: inout [RepeatingPlan], calendar: Calendar = .current) -> Bool {
        guard entry.status != .linked, let index = series.firstIndex(where: { $0.id == entry.origin.seriesID }) else { return false }
        let plan = series[index], day = entry.origin.day
        guard plan.template.repeatRule.matches(day, starting: plan.template.day, weekdays: plan.template.repeatWeekdays, calendar: calendar) else { return false }
        let actual = linkedItem(entry.origin, plan: plan, items: items)
        var restored = defaultLinkedItem(plan, on: day, calendar: calendar)
        if let actual {
            restored.id = actual.id; restored.createdAt = actual.createdAt
            restored.completedAt = actual.completedAt; restored.cancelledAt = actual.cancelledAt
            restored.parentID = actual.parentID
            if let other = actual.seriesID, other != plan.id, let otherIndex = series.firstIndex(where: { $0.id == other }) {
                let otherDay = actual.occurrenceDay ?? actual.day
                if !series[otherIndex].excludedDays.contains(otherDay) { series[otherIndex].excludedDays.append(otherDay) }
            }
            items.removeAll { $0.id == actual.id }
        }
        if let end = series[index].endBefore, day >= end {
            // Restoring one day after a "delete following" keeps the intervening deleted days out.
            var cursor = end
            while cursor < day {
                if !series[index].excludedDays.contains(cursor) { series[index].excludedDays.append(cursor) }
                cursor = Day(calendar.date(byAdding: .day, value: 1, to: cursor.date(calendar: calendar))!, calendar: calendar)
            }
            series[index].endBefore = Day(calendar.date(byAdding: .day, value: 1, to: day.date(calendar: calendar))!, calendar: calendar)
        }
        series[index].excludedDays.removeAll { $0 == day }
        items.append(restored)
        return true
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
        if let source = previous?.seriesID ?? edited.seriesID {
            single.detachedFrom = previous?.detachedFrom ?? LinkedItemOrigin(seriesID: source, day: previous?.occurrenceDay ?? edited.occurrenceDay ?? edited.day)
        }
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
    /// Ticks one checklist entry off, or opens it again, on this item alone: on a repeating item
    /// it's this day's tick, never the series'. Unknown entries are left alone.
    public static func setEntry(_ entryID: UUID, done: Bool, in item: inout PlanItem, now: Date) {
        guard let index = item.checklist.firstIndex(where: { $0.id == entryID }) else { return }
        item.checklist[index].doneAt = done ? now : nil
    }
    /// Cancels an item while viewing `day`, or restores it. Like completion, cancelling counts on
    /// a past day when done from it, so a carried item stops there. The two never stand together:
    /// cancelling clears completion, and restoring leaves the item open.
    public static func setComplete(_ completed: Bool, _ item: inout PlanItem, on day: Day, now: Date, calendar: Calendar = .current) {
        var projected = item.on(day)
        projected.completedAt = completed ? completionDate(on: day, now: now, calendar: calendar) : nil
        projected.cancelledAt = nil
        projected.suggestionDismissed = false
        item = projected.unprojected
    }
    public static func setCancelled(_ cancelled: Bool, _ item: inout PlanItem, on day: Day, now: Date, calendar: Calendar = .current) {
        var projected = item.on(day)
        projected.cancelledAt = cancelled ? completionDate(on: day, now: now, calendar: calendar) : nil
        projected.completedAt = nil
        projected.suggestionDismissed = false
        item = projected.unprojected
    }
    public static func validate(_ item: PlanItem, in items: [PlanItem], calendar: Calendar = .current) throws {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlannerError.title }
        if item.repeatRule == .custom && (item.repeatWeekdays.isEmpty || item.repeatWeekdays.contains(where: { !(1...7).contains($0) })) { throw PlannerError.repeatDays }
        if let minute = item.minute, !(0..<1440).contains(minute) { throw PlannerError.schedule }
        if let end = item.end {
            guard let start = item.start(calendar: calendar), end > start else { throw PlannerError.schedule }
        }
        if let endDay = item.endDay {
            guard item.minute == nil, item.end == nil, endDay >= item.day else { throw PlannerError.schedule }
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
        items.filter { $0.movedAway(from: day, now: now, calendar: calendar) }.map { $0.on(day) }.sorted { $0.createdAt < $1.createdAt }
    }
    /// Items from other days with an upcoming reminder or open deadline on `day`, by when it falls.
    public static func visitingItems(on day: Day, in items: [PlanItem], now: Date, calendar: Calendar = .current) -> [PlanItem] {
        items.map { $0.on(day) }.filter { $0.visits(day, now: now, calendar: calendar) }.sorted {
            ($0.visitTime(on: day, now: now, calendar: calendar) ?? .distantFuture) < ($1.visitTime(on: day, now: now, calendar: calendar) ?? .distantFuture)
        }
    }
    /// Every item in `persona` (among any others it has), grouped by day, newest day first. Each
    /// day lists what that day's list shows of the persona, in the same order: an item on its own
    /// (live) day, a "Carried to" entry on every day it was carried on from, and today for anything
    /// today's list shows, such as a range that is still running. Every generated linked item of a
    /// repeating item is listed, including those ahead of today up to `repeatsThrough`.
    public static func history(of persona: Persona, in items: [PlanItem], now: Date, repeatsThrough: Day? = nil,
                               calendar: Calendar = .current) -> [PersonaDay] {
        let today = Day(now, calendar: calendar)
        let matching = items.filter {
            guard $0.personas.contains(persona) else { return false }
            return within(repeatsThrough, $0, now: now, calendar: calendar)
        }
        var days = Set<Day>()
        for item in matching {
            let live = item.liveDay(now: now, calendar: calendar)
            days.insert(live)
            if let endDay = item.endDay {
                var covered = item.day
                while covered <= endDay {
                    days.insert(covered)
                    guard let next = calendar.date(byAdding: .day, value: 1, to: covered.date(calendar: calendar)) else { break }
                    covered = Day(next, calendar: calendar)
                }
            }
            var carriedFrom = item.day
            while carriedFrom < live, let next = calendar.date(byAdding: .day, value: 1, to: carriedFrom.date(calendar: calendar)) {
                days.insert(carriedFrom)
                carriedFrom = Day(next, calendar: calendar)
            }
        }
        if matching.contains(where: { $0.shows(on: today, now: now, calendar: calendar) }) { days.insert(today) }
        return days.sorted(by: >).map { day in
            let listed = matching.filter {
                $0.shows(on: day, now: now, calendar: calendar) || $0.movedAway(from: day, now: now, calendar: calendar)
            }
            // Like the day list: Anytime items first, then Scheduled ones. A carried item keeps
            // its time only on its scheduled day.
            let timed = { (item: PlanItem) in
                item.minute != nil && (!item.isCarried(now: now, calendar: calendar) || item.day == day)
            }
            return PersonaDay(day: day, items: listed.map { $0.on(day) }.sorted {
                if timed($0) != timed($1) { return !timed($0) }
                if $0.minute != $1.minute { return ($0.minute ?? -1) < ($1.minute ?? -1) }
                return $0.createdAt < $1.createdAt
            })
        }
    }
    /// Items matching `query`, grouped by the day each is shown as itself, newest day first (like
    /// a persona's history, but each item once). Every plain word has to appear in the title, notes,
    /// a location, a person, an attachment or a checklist entry, ignoring case and accents, and every date the query names (see
    /// `SearchQuery`) has to fall on a day the item is listed on (its own, or one it was carried on
    /// from, as a "Carried to" entry), or its words appear in that text. Such an item is listed
    /// under the day the date matched, preferring its own. A repeating item lists its days up to
    /// `repeatsThrough`, unless the query names a date, when every generated day of it in that date
    /// is listed. With a persona, only items in it are found.
    public static func search(_ query: String, in items: [PlanItem], now: Date, persona: Persona? = nil,
                              repeatsThrough: Day? = nil, calendar: Calendar = .current, locale: Locale = .current) -> [PersonaDay] {
        let parsed = SearchQuery(query, now: now, calendar: calendar, locale: locale)
        guard !parsed.isEmpty else { return [] }
        /// The days an item is listed on, its own first: then every day it was carried on from.
        func listedDays(_ item: PlanItem) -> [Day] {
            let live = item.liveDay(now: now, calendar: calendar)
            var days = [live], day = item.day
            while day < live, let next = calendar.date(byAdding: .day, value: 1, to: day.date(calendar: calendar)) {
                days.append(day)
                day = Day(next, calendar: calendar)
            }
            if let endDay = item.endDay {
                var covered = item.day
                while covered <= endDay {
                    if !days.contains(covered) { days.append(covered) }
                    guard let next = calendar.date(byAdding: .day, value: 1, to: covered.date(calendar: calendar)) else { break }
                    covered = Day(next, calendar: calendar)
                }
            }
            return days
        }
        /// Where each found item is listed: the first of its days every date matches.
        var listing: [UUID: Day] = [:]
        let found = items.filter { item in
            if let persona, !item.personas.contains(persona) { return false }
            let fields = [item.title, item.notes] + item.locations + item.people + item.attachments.flatMap(\.searchableText)
                + item.checklist.map(\.title)
            let mentions = { (word: String) in
                fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            guard parsed.words.allSatisfy(mentions) else { return false }
            let days = listedDays(item)
            // The dates not met by the item's text have to share one of its days.
            let byDay = parsed.dates.filter { !$0.words.allSatisfy(mentions) }
            guard !byDay.isEmpty else { listing[item.id] = days[0]; return true }
            guard let day = days.first(where: { day in byDay.allSatisfy { $0.contains(day, calendar: calendar) } }) else { return false }
            listing[item.id] = day
            return true
        }
        let listed = parsed.dates.isEmpty ? found.filter { within(repeatsThrough, $0, now: now, calendar: calendar) } : found
        return Dictionary(grouping: listed) { listing[$0.id] ?? $0.liveDay(now: now, calendar: calendar) }
            .sorted { $0.key > $1.key }
            .map { day, items in
                PersonaDay(day: day, items: items.map { $0.on(day) }.sorted {
                    if $0.minute != $1.minute { return ($0.minute ?? -1) < ($1.minute ?? -1) }
                    return $0.createdAt < $1.createdAt
                })
            }
    }
    /// Whether a list that shows repeating items up to `last` shows `item`: anything that doesn't
    /// repeat, and a repeating item's days up to then.
    static func within(_ last: Day?, _ item: PlanItem, now: Date, calendar: Calendar) -> Bool {
        guard let last, item.seriesID != nil else { return true }
        return item.liveDay(now: now, calendar: calendar) <= last
    }
    /// Whether any of `seriesIDs` goes on past `day`, so a list cut off there can offer more.
    public static func repeats(_ seriesIDs: Set<UUID>, in series: [RepeatingPlan], after day: Day, calendar: Calendar = .current) -> Bool {
        series.contains { plan in
            guard seriesIDs.contains(plan.id) else { return false }
            guard let end = plan.endBefore else { return true }
            return calendar.dateComponents([.day], from: day.date(calendar: calendar), to: end.date(calendar: calendar)).day ?? 0 > 1
        }
    }
    /// The nearest future reminders of unfinished, uncancelled items, one entry per reminder.
    public static func upcomingReminders(in items: [PlanItem], now: Date, limit: Int = 64) -> [ScheduledReminder] {
        Array(items.flatMap { item in Set(item.reminders).filter { $0 > now && !item.on(Day($0)).isSettled }.map { ScheduledReminder(item: item.on(Day($0)), date: $0) } }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.item.id.uuidString < $1.item.id.uuidString
            }.prefix(max(0, limit)))
    }
    public static func updateStart(_ item: inout PlanItem, day: Day, minute: Int?, calendar: Calendar = .current) {
        let oldStart = item.start(calendar: calendar)
        let duration = item.end.flatMap { end in oldStart.map { end.timeIntervalSince($0) } }
        let oldDay = item.day
        let oldEndDay = item.endDay
        if oldDay != day, let excluded = item.excludedRangeDays {
            let shift = calendar.dateComponents([.day], from: oldDay.date(calendar: calendar), to: day.date(calendar: calendar)).day ?? 0
            item.excludedRangeDays = excluded.map { Day(calendar.date(byAdding: .day, value: shift, to: $0.date(calendar: calendar))!, calendar: calendar) }
        }
        if oldDay != day, let statuses = item.dailyStatuses {
            let shift = calendar.dateComponents([.day], from: oldDay.date(calendar: calendar), to: day.date(calendar: calendar)).day ?? 0
            item.dailyStatuses = statuses.map { status in
                var moved = status
                moved.day = Day(calendar.date(byAdding: .day, value: shift, to: status.day.date(calendar: calendar))!, calendar: calendar)
                return moved
            }
        }
        item.day = day; item.minute = minute
        if let oldStart, let newStart = item.start(calendar: calendar) {
            item.reminders = item.reminders.map { $0.addingTimeInterval(newStart.timeIntervalSince(oldStart)) }
        } else if oldDay != day {
            let days = calendar.dateComponents([.day], from: oldDay.date(calendar: calendar), to: day.date(calendar: calendar)).day ?? 0
            item.reminders = item.reminders.compactMap { calendar.date(byAdding: .day, value: days, to: $0) }
        }
        if let duration, let start = item.start(calendar: calendar) { item.end = start.addingTimeInterval(duration) }
        else { item.end = nil }
        if let oldEndDay {
            let span = calendar.dateComponents([.day], from: oldDay.date(calendar: calendar), to: oldEndDay.date(calendar: calendar)).day ?? 0
            let finalDay = calendar.date(byAdding: .day, value: span, to: day.date(calendar: calendar))!
            if let start = item.start(calendar: calendar) {
                // Adding a time keeps the final date, with a one-hour end by default.
                item.end = calendar.date(byAdding: .day, value: span, to: start.addingTimeInterval(3600))
                item.endDay = nil
            } else { item.endDay = Day(finalDay, calendar: calendar) }
        } else if minute == nil, let oldEnd = item.end ?? (duration.flatMap { oldStart?.addingTimeInterval($0) }) {
            // Dropping time keeps the calendar days the timed range actually occupied.
            let finalDay = Day(oldEnd.addingTimeInterval(-1), calendar: calendar)
            let span = calendar.dateComponents([.day], from: oldDay.date(calendar: calendar), to: finalDay.date(calendar: calendar)).day ?? 0
            if span > 0 {
                item.endDay = Day(calendar.date(byAdding: .day, value: span, to: day.date(calendar: calendar))!, calendar: calendar)
            }
        }
        item.suggestionDismissed = false
    }
    /// Use the live clock at tap time. The time picker supplies its selected day; the quick
    /// action omits it so a scheduled item moves to today, keeping its duration and offsets.
    public static func updateStartToNow(_ item: inout PlanItem, now: Date, on selected: Day? = nil, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        updateStart(&item, day: selected ?? Day(now, calendar: calendar),
                    minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0), calendar: calendar)
    }
    /// Start only this scheduled item. A linked occurrence detaches instead of moving its series.
    @discardableResult public static func startNow(_ id: UUID, items: inout [PlanItem], series: inout [RepeatingPlan], now: Date, calendar: Calendar = .current) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isSettled,
              items[index].minute != nil || items[index].endDay != nil else { return false }
        var updated = items[index]
        updateStartToNow(&updated, now: now, calendar: calendar)
        if updated.seriesID != nil { detach(updated, items: &items, series: &series, calendar: calendar) }
        else { items[index] = updated }
        return true
    }
    public static func reschedule(_ item: inout PlanItem, to day: Day, minute: Int?, end: Date? = nil) {
        updateStart(&item, day: day, minute: minute)
        item.end = end
        if minute != nil { item.endDay = nil }
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

    /// Minutes a point task's dot occupies on its track, about the dot's height.
    public static let pointMinutes: Double = 4

    /// Tracks for timeline entries, where a point task (no end, or an end at its start)
    /// takes a short span so it moves aside from a range or point it would sit on.
    public static func assign(starts: [Double], ends: [Double?]) -> [Int] {
        assign(zip(starts, ends).map { start, end in
            if let end, end > start { return start..<end }
            return start..<(start + pointMinutes)
        })
    }
}

/// How far a day is: what its list shows, done and in all, the same as its "x/y complete".
/// Cancelled items aren't counted.
public struct DayProgress: Equatable {
    public let done: Int
    public let total: Int
    init(done: Int, total: Int) { self.done = done; self.total = total }
    public init(items: [PlanItem], day: Day, now: Date, calendar: Calendar = .current) {
        let shown = items.filter { $0.shows(on: day, now: now, calendar: calendar) }.map { $0.on(day) }
        done = shown.filter(\.isComplete).count
        total = shown.filter { !$0.isCancelled }.count
    }
}

/// A timed item the day guide follows on the lock screen: a time range from its start to its end,
/// or a single moment, which has no end.
public struct GuideStop: Equatable {
    public let item: PlanItem
    public let start: Date
    public let end: Date?
    /// When the item's time is over: its end, or the moment itself.
    public var finish: Date { end ?? start }
}

public enum DayGuide {
    /// Today's unfinished timed items in order of their start: those running or still to come, and
    /// those whose time passed today without being ticked off, so they can still be completed.
    /// Anytime items and carried items aren't followed; their reminders cover them. Neither are
    /// ranges that began before yesterday, like a trip of several days: they're the backdrop of
    /// the day rather than something under way in it.
    public static func stops(in items: [PlanItem], now: Date, calendar: Calendar = .current) -> [GuideStop] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let midnight = calendar.date(byAdding: .day, value: 1, to: today)!
        let open = items.filter { !$0.isSettled && !$0.isCarried(now: now, calendar: calendar) }
        return open.compactMap { item -> GuideStop? in
            guard let start = item.start(calendar: calendar), start < midnight, start >= yesterday else { return nil }
            guard let end = item.end else {
                // A moment of yesterday is over; only a range can still be running from there.
                return start >= today ? GuideStop(item: item, start: start, end: nil) : nil
            }
            guard end > start, end > today else { return nil }
            return GuideStop(item: item, start: start, end: end)
        }
        .sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.item.createdAt < $1.item.createdAt
        }
    }
}

/// A search split into plain words and the dates it names. Dates are read in English and in the
/// locale's language: month names ("november", "nov"), a month with a day or year in either order
/// ("november 14", "14th of nov", "nov 14, 2027", "2027 november"), numeric dates in the locale's
/// order ("14/11", "2027-11-14"; an impossible month is read the other way round), a year
/// ("2027"), an ordinal day ("14th"), and relative words ("today", "tomorrow", "yesterday",
/// "friday", "next week", "last month", "this year", "next friday").
public struct SearchQuery: Equatable {
    public struct DateTerm: Equatable {
        public enum Kind: Equatable {
            /// Every day with the fields given; a field left out matches any.
            case pattern(year: Int?, month: Int?, day: Int?)
            /// The days from one to another, both included.
            case span(Day, Day)
        }
        public var kind: Kind
        /// The words that named it, so an item whose text says them is found too: "may" is also
        /// a word, and "friday drinks" a title.
        public var words: [String]
        public func contains(_ day: Day, calendar: Calendar = .current) -> Bool {
            switch kind {
            case let .pattern(year, month, dayOfMonth):
                return (year.map { $0 == day.year } ?? true) && (month.map { $0 == day.month } ?? true)
                    && (dayOfMonth.map { $0 == day.day } ?? true)
            case let .span(start, end):
                return start <= day && day <= end
            }
        }
    }
    public var words: [String] = []
    public var dates: [DateTerm] = []
    public var isEmpty: Bool { words.isEmpty && dates.isEmpty }

    public init(_ text: String, now: Date, calendar: Calendar = .current, locale: Locale = .current) {
        let names = Names(calendar: calendar, locale: locale)
        let today = Day(now, calendar: calendar)
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = tokens.map(Self.key)
        // Words not (yet) part of a date, with their place, so a month can take the day or year before it.
        var plain: [(index: Int, word: String)] = []
        func shifted(_ day: Day, by value: Int, _ unit: Calendar.Component) -> Day {
            Day(calendar.date(byAdding: unit, value: value, to: day.date(calendar: calendar)) ?? day.date(calendar: calendar), calendar: calendar)
        }
        func span(of unit: Calendar.Component, around day: Day) -> DateTerm.Kind {
            guard let interval = calendar.dateInterval(of: unit, for: day.date(calendar: calendar)) else { return .span(day, day) }
            return .span(Day(interval.start, calendar: calendar), Day(interval.end.addingTimeInterval(-1), calendar: calendar))
        }
        /// The coming day with that weekday, today included unless `excludingToday`; or the last one before today.
        func weekday(_ value: Int, past: Bool = false, excludingToday: Bool = false) -> Day {
            var day = past ? shifted(today, by: -1, .day) : (excludingToday ? shifted(today, by: 1, .day) : today)
            while calendar.component(.weekday, from: day.date(calendar: calendar)) != value {
                day = shifted(day, by: past ? -1 : 1, .day)
            }
            return day
        }
        var i = 0
        while i < tokens.count {
            let key = keys[i]
            let next = i + 1 < keys.count ? keys[i + 1] : nil
            if let offset = ["yesterday": -1, "today": 0, "tomorrow": 1][key] {
                let day = shifted(today, by: offset, .day)
                dates.append(DateTerm(kind: .span(day, day), words: [tokens[i]]))
                i += 1
            } else if let step = ["last": -1, "this": 0, "next": 1][key], let next,
                      let unit = ["week": Calendar.Component.weekOfYear, "month": .month, "year": .year][next] {
                dates.append(DateTerm(kind: span(of: unit, around: shifted(today, by: step, unit)), words: [tokens[i], tokens[i + 1]]))
                i += 2
            } else if let step = ["last": -1, "this": 0, "next": 1][key], let next, let value = names.weekdays[next] {
                let day = weekday(value, past: step < 0, excludingToday: step > 0)
                dates.append(DateTerm(kind: .span(day, day), words: [tokens[i], tokens[i + 1]]))
                i += 2
            } else if let value = names.weekdays[key] {
                let day = weekday(value)
                dates.append(DateTerm(kind: .span(day, day), words: [tokens[i]]))
                i += 1
            } else if let month = names.months[key] {
                var used = [tokens[i]], dayOfMonth: Int?, year: Int?
                // Before it: "14 november", "14th of november", "2027 november".
                if let last = plain.last, last.index == i - 1, Self.year(keys[last.index]) != nil {
                    year = Self.year(keys[last.index]); used.insert(last.word, at: 0); plain.removeLast()
                } else if let last = plain.last, last.index == i - 1, keys[last.index] == "of",
                          plain.count >= 2, plain[plain.count - 2].index == i - 2, let value = Self.dayOfMonth(keys[i - 2]) {
                    dayOfMonth = value; used.insert(contentsOf: [plain[plain.count - 2].word, last.word], at: 0); plain.removeLast(2)
                } else if let last = plain.last, last.index == i - 1, let value = Self.dayOfMonth(keys[last.index]) {
                    dayOfMonth = value; used.insert(last.word, at: 0); plain.removeLast()
                }
                i += 1
                // After it: "november 14", "november 14, 2027", "november 2027".
                if dayOfMonth == nil, i < keys.count, Self.year(keys[i]) == nil, let value = Self.dayOfMonth(keys[i]) {
                    dayOfMonth = value; used.append(tokens[i]); i += 1
                }
                if year == nil, i < keys.count, let value = Self.year(keys[i]) {
                    year = value; used.append(tokens[i]); i += 1
                }
                dates.append(DateTerm(kind: .pattern(year: year, month: month, day: dayOfMonth), words: used))
            } else if let kind = Self.numericDate(key, dayFirst: names.dayFirst) {
                dates.append(DateTerm(kind: kind, words: [tokens[i]]))
                i += 1
            } else {
                plain.append((i, tokens[i]))
                i += 1
            }
        }
        // What no month took: a year on its own, or an ordinal day such as "14th".
        for (index, word) in plain {
            if let year = Self.year(keys[index]) {
                dates.append(DateTerm(kind: .pattern(year: year, month: nil, day: nil), words: [word]))
            } else if keys[index].last?.isLetter == true, let value = Self.dayOfMonth(keys[index]) {
                dates.append(DateTerm(kind: .pattern(year: nil, month: nil, day: value), words: [word]))
            } else {
                words.append(word)
            }
        }
    }

    /// Lowercased, without accents and the punctuation around a word, so "Nov," and "nov" agree.
    static func key(_ token: String) -> String {
        token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?()'\""))
    }
    static func year(_ key: String) -> Int? {
        guard key.count == 4, let value = Int(key), (1900...2200).contains(value) else { return nil }
        return value
    }
    /// "14", "14th", "1st", "22nd", "3rd": a day of the month.
    static func dayOfMonth(_ key: String) -> Int? {
        var digits = key
        for suffix in ["st", "nd", "rd", "th", "e"] where digits.hasSuffix(suffix) && digits.count > suffix.count {
            digits.removeLast(suffix.count)
            break
        }
        guard digits.count <= 2, let value = Int(digits), (1...31).contains(value) else { return nil }
        return value
    }
    /// "14/11", "14-11-2027", "14.11.27", "2027-11-14", "2027-11".
    static func numericDate(_ key: String, dayFirst: Bool) -> DateTerm.Kind? {
        let parts = key.split(whereSeparator: { "/-.".contains($0) }).map(String.init)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              key.allSatisfy({ $0.isNumber || "/-.".contains($0) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        if parts[0].count == 4 {
            // Year first, as in ISO dates.
            guard (1...12).contains(numbers[1]) else { return nil }
            let dayOfMonth = numbers.count == 3 ? numbers[2] : nil
            if let dayOfMonth, !(1...31).contains(dayOfMonth) { return nil }
            return .pattern(year: numbers[0], month: numbers[1], day: dayOfMonth)
        }
        guard parts[0].count <= 2, parts[1].count <= 2 else { return nil }
        var (dayOfMonth, month) = dayFirst ? (numbers[0], numbers[1]) : (numbers[1], numbers[0])
        // An impossible month is the other way round: 11/14 is the 14th of November anywhere.
        if !(1...12).contains(month), (1...12).contains(dayOfMonth) { swap(&dayOfMonth, &month) }
        guard (1...12).contains(month), (1...31).contains(dayOfMonth) else { return nil }
        var year: Int?
        if numbers.count == 3 {
            guard parts[2].count == 2 || parts[2].count == 4 else { return nil }
            year = parts[2].count == 2 ? 2000 + numbers[2] : numbers[2]
        }
        return .pattern(year: year, month: month, day: dayOfMonth)
    }

    /// Month and weekday names in English and the locale's language, by key, and the locale's
    /// order for numeric dates.
    struct Names {
        var months: [String: Int] = [:]
        var weekdays: [String: Int] = [:]
        var dayFirst = true
        /// Short forms that are also everyday words; full names still count.
        private static let ambiguous: Set<String> = ["sun", "sat", "wed", "mar"]

        init(calendar: Calendar, locale: Locale) {
            for identifier in [locale.identifier, "en_US_POSIX"] {
                var named = calendar
                named.locale = Locale(identifier: identifier)
                for list in [named.monthSymbols, named.standaloneMonthSymbols] { add(list, to: &months) }
                for list in [named.shortMonthSymbols, named.shortStandaloneMonthSymbols] { add(list, short: true, to: &months) }
                for list in [named.weekdaySymbols, named.standaloneWeekdaySymbols] { add(list, to: &weekdays) }
                for list in [named.shortWeekdaySymbols, named.shortStandaloneWeekdaySymbols] { add(list, short: true, to: &weekdays) }
            }
            months["sept"] = 9
            for (name, value) in ["tues": 3, "thur": 5, "thurs": 5] { weekdays[name] = value }
            let format = DateFormatter.dateFormat(fromTemplate: "dM", options: 0, locale: locale) ?? "d/M"
            if let d = format.firstIndex(of: "d"), let m = format.firstIndex(of: "M") { dayFirst = d < m }
        }
        /// Names in order, so a name's place is its number: January is 1, and Sunday is 1 as in `Calendar`.
        private func add(_ list: [String], short: Bool = false, to names: inout [String: Int]) {
            for (index, name) in list.enumerated() {
                let key = SearchQuery.key(name)
                guard key.count >= 3, !(short && Self.ambiguous.contains(key)) else { continue }
                names[key] = index + 1
            }
        }
    }
}

