import Foundation

/// A line typed naturally, such as "January 20 Mollie President's Club dinner at 18:00", read
/// into an item. Words that name a day, a time, a length, a repeat, a persona, people or a place
/// become those details, and the words left over are the title. Only the first day, time,
/// length and repeat count; a later one stays in the title, so "Plan Friday drinks on Monday"
/// keeps one of them as words.
public struct QuickEntry: Equatable {
    public enum Kind: String, Equatable { case day, time, length, repeats, persona, people, place }
    /// The words that were read as a detail, so they can be shown and given back to the title.
    public struct Match: Equatable, Identifiable {
        public var kind: Kind
        public var words: [String]
        /// The people, place or persona it names.
        public var values: [String] = []
        /// The same words of the same kind keep their id while the rest of the line changes, so
        /// giving them back to the title survives typing elsewhere.
        public var id: String { kind.rawValue + ":" + words.map(SearchQuery.key).joined(separator: " ") }
        public var phrase: String { words.joined(separator: " ") }
    }

    public var title = ""
    public var day: Day
    /// The last day of an untimed range ("January 20 until January 22").
    public var endDay: Day?
    public var minute: Int?
    /// Minutes after the start of `day`; past 1440 for a time that ends the next day.
    public var endMinute: Int?
    public var repeatRule: RepeatRule = .never
    public var repeatWeekdays: [Int] = []
    public var personas: [Persona] = []
    public var people: [String] = []
    public var locations: [String] = []
    public var matches: [Match] = []

    /// - Parameters:
    ///   - defaultDay: the day when the line names none.
    ///   - ignoring: ids of matches to keep as plain words.
    ///   - knownPeople, knownPlaces: names already used on items, recognised in any case.
    public init(_ text: String, on defaultDay: Day, now: Date, ignoring: Set<String> = [],
                knownPeople: [String] = [], knownPlaces: [String] = [],
                calendar: Calendar = .current, locale: Locale = .current) {
        day = defaultDay
        let reader = Reader(text, now: now, calendar: calendar, locale: locale,
                            knownPeople: knownPeople, knownPlaces: knownPlaces)
        let tokens = reader.tokens
        var plain: [String] = []
        var found: Set<Kind> = []
        var length: (minutes: Int, id: String)?
        var i = 0
        while i < tokens.count {
            guard let (reading, end) = reader.read(at: i, skipping: found) else {
                plain.append(tokens[i]); i += 1; continue
            }
            var match = Match(kind: reading.kind, words: Array(tokens[i..<end]))
            if ignoring.contains(match.id) { plain += match.words; i = end; continue }
            switch reading {
            case let .day(start, last): day = start; endDay = last
            case let .time(start, last): minute = start; endMinute = last
            case let .length(minutes): length = (minutes, match.id)
            case let .repeats(rule, weekdays): repeatRule = rule; repeatWeekdays = weekdays
            case let .persona(persona):
                if !personas.contains(persona) { personas.append(persona) }
                match.values = [persona.title]
            case let .people(names):
                for name in names where !people.contains(where: { SearchQuery.key($0) == SearchQuery.key(name) }) { people.append(name) }
                match.values = names
            case let .place(place):
                locations.append(place)
                match.values = [place]
            }
            if [.day, .time, .length, .repeats].contains(reading.kind) { found.insert(reading.kind) }
            matches.append(match)
            i = end
        }
        // A length needs a start; without one, "for 2 hours" is part of the title.
        if let length {
            guard let minute else {
                self = QuickEntry(text, on: defaultDay, now: now, ignoring: ignoring.union([length.id]),
                                  knownPeople: knownPeople, knownPlaces: knownPlaces, calendar: calendar, locale: locale)
                return
            }
            if endMinute == nil { endMinute = minute + length.minutes }
        }
        // A timed item has no end day, and a repeating one no range.
        if minute != nil || repeatRule != .never { endDay = nil }
        // "every monday" with no day of its own starts on the coming Monday; a day of another
        // weekday keeps its day and repeats on the days named.
        if !repeatWeekdays.isEmpty {
            if !found.contains(.day) { day = reader.coming(weekdays: repeatWeekdays) }
            if repeatRule == .weekly, calendar.component(.weekday, from: day.date(calendar: calendar)) != repeatWeekdays[0] {
                repeatRule = .custom
            }
            if repeatRule == .weekly { repeatWeekdays = [] }
        }
        title = Self.tidy(plain)
    }

    /// The item to save, carrying over only when it's Anytime, as a new item in the editor does.
    public func item(personas extra: [Persona] = [], calendar: Calendar = .current) -> PlanItem {
        var end: Date?
        if let minute, let endMinute,
           let start = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day.date(calendar: calendar)) {
            end = calendar.date(byAdding: .minute, value: endMinute - minute, to: start)
        }
        var item = PlanItem(title: title, day: day, minute: minute, end: end, endDay: endDay,
                            movesToNextDay: minute == nil && endDay == nil, locations: locations, people: people)
        item.personas = Persona.ordered(extra + personas)
        item.repeatRule = repeatRule
        item.repeatWeekdays = repeatWeekdays
        return item
    }

    /// Joins the words left over, without a dangling "at" or comma where a detail was taken out.
    static func tidy(_ words: [String]) -> String {
        var words = words
        let dangling: Set<String> = ["at", "on", "in", "with", "from", "for", "to", "and", "&", "-", "–", "—"]
        while let last = words.last, dangling.contains(SearchQuery.key(last)) || SearchQuery.key(last).isEmpty { words.removeLast() }
        while let first = words.first, ["-", "–", "—", ","].contains(first) { words.removeFirst() }
        var title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
        // "dinner with Sam" reads as "Dinner"; a word with its own capitals, such as "iPhone", is left alone.
        if let first = title.split(separator: " ").first, !first.contains(where: \.isUppercase), let letter = title.first {
            title = letter.uppercased() + title.dropFirst()
        }
        return title
    }
}

extension QuickEntry {
    enum Reading {
        case day(Day, Day?)
        case time(Int, Int?)
        case length(Int)
        case repeats(RepeatRule, [Int])
        case persona(Persona)
        case people([String])
        case place(String)
        var kind: Kind {
            switch self {
            case .day: return .day
            case .time: return .time
            case .length: return .length
            case .repeats: return .repeats
            case .persona: return .persona
            case .people: return .people
            case .place: return .place
            }
        }
    }

    /// Reads one detail at a time from a position in the line. Each reader returns what it read
    /// and the index after its last word.
    struct Reader {
        let tokens: [String]
        let keys: [String]
        let calendar: Calendar
        let today: Day
        let names: SearchQuery.Names
        let knownPeople: [[String]: String]
        let knownPlaces: [[String]: String]

        init(_ text: String, now: Date, calendar: Calendar, locale: Locale, knownPeople: [String], knownPlaces: [String]) {
            tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
            keys = tokens.map(SearchQuery.key)
            self.calendar = calendar
            today = Day(now, calendar: calendar)
            names = SearchQuery.Names(calendar: calendar, locale: locale)
            func index(_ list: [String]) -> [[String]: String] {
                var result: [[String]: String] = [:]
                for name in list {
                    let words = name.split(whereSeparator: \.isWhitespace).map { SearchQuery.key(String($0)) }
                    if !words.isEmpty { result[words] = name }
                }
                return result
            }
            self.knownPeople = index(knownPeople)
            self.knownPlaces = index(knownPlaces)
        }

        func key(_ i: Int) -> String? { tokens.indices.contains(i) ? keys[i] : nil }

        func read(at i: Int, skipping found: Set<Kind>) -> (Reading, Int)? {
            if !found.contains(.repeats), let (rule, days, end) = repeats(at: i) { return (.repeats(rule, days), end) }
            if !found.contains(.day), let (start, last, end) = day(at: i) { return (.day(start, last), end) }
            if !found.contains(.time), let (start, last, end) = time(at: i) { return (.time(start, last), end) }
            if !found.contains(.length), let (minutes, end) = length(at: i) { return (.length(minutes), end) }
            if let persona = persona(at: i) { return (.persona(persona), i + 1) }
            if let (people, end) = people(at: i) { return (.people(people), end) }
            if let (place, end) = place(at: i) { return (.place(place), end) }
            return nil
        }

        // MARK: Days

        func shifted(_ day: Day, by value: Int, _ unit: Calendar.Component) -> Day {
            Day(calendar.date(byAdding: unit, value: value, to: day.date(calendar: calendar)) ?? day.date(calendar: calendar), calendar: calendar)
        }
        func weekday(of day: Day) -> Int { calendar.component(.weekday, from: day.date(calendar: calendar)) }
        /// The first day from today on one of these weekdays.
        func coming(weekdays: [Int], excludingToday: Bool = false) -> Day {
            var day = excludingToday ? shifted(today, by: 1, .day) : today
            for _ in 0..<7 where !weekdays.contains(weekday(of: day)) { day = shifted(day, by: 1, .day) }
            return day
        }
        /// A weekday after "every" or "on": plurals count, and so do the short names that are
        /// also words ("wed", "sat"), since nothing else follows "every".
        func weekdayValue(_ key: String) -> Int? {
            let short = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
            return names.weekdays[key] ?? short[key]
                ?? (key.count > 4 && key.hasSuffix("s") ? names.weekdays[String(key.dropLast())] : nil)
        }
        func makeDay(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Day? {
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) else { return nil }
            let day = Day(date, calendar: calendar)
            return day.year == year && day.month == month && day.day == dayOfMonth ? day : nil
        }
        /// A date without a year is the next one on or after `reference`: in November,
        /// "January 20" is next year's.
        func resolve(year: Int?, month: Int?, day dayOfMonth: Int, after reference: Day) -> Day? {
            if let year, let month { return makeDay(year, month, dayOfMonth) }
            if let month {
                for year in reference.year...(reference.year + 8) {
                    if let day = makeDay(year, month, dayOfMonth), day >= reference { return day }
                }
                return nil
            }
            // Only the day of the month: this month's, or the next month that has it.
            var start = makeDay(reference.year, reference.month, 1) ?? reference
            for _ in 0..<13 {
                if let day = makeDay(start.year, start.month, dayOfMonth), day >= reference { return day }
                start = shifted(start, by: 1, .month)
            }
            return nil
        }

        /// "on Friday", "tomorrow", "January 20 until January 22", "jan 20-22".
        func day(at i: Int) -> (Day, Day?, Int)? {
            var j = i
            if key(j) == "on" { j += 1 }
            guard let (start, rangeEnd, next) = date(at: j, after: today) else { return nil }
            if rangeEnd == nil, let k = key(next), ["until", "till", "til", "through", "thru", "to", "-", "–", "—"].contains(k),
               let (end, _, after) = date(at: next + 1, after: start), end > start {
                return (start, end, after)
            }
            return (start, rangeEnd, next)
        }

        func date(at i: Int, after reference: Day) -> (Day, Day?, Int)? {
            guard let k = key(i) else { return nil }
            if ["today", "tonight"].contains(k) { return (today, nil, i + 1) }
            if ["tomorrow", "tmrw", "tmr"].contains(k) { return (shifted(today, by: 1, .day), nil, i + 1) }
            if k == "day", key(i + 1) == "after", key(i + 2) == "tomorrow" { return (shifted(today, by: 2, .day), nil, i + 3) }
            // "in 3 days", "in a week", "in two weeks".
            if k == "in", let amount = key(i + 1).flatMap(Self.count), let unit = key(i + 2).flatMap(Self.calendarUnit) {
                return (shifted(today, by: amount * unit.1, unit.0), nil, i + 3)
            }
            if ["next", "this"].contains(k), let next = key(i + 1) {
                if let value = names.weekdays[next] { return (coming(weekdays: [value], excludingToday: k == "next"), nil, i + 2) }
                if k == "next", next == "week" { return (shifted(today, by: 7, .day), nil, i + 2) }
                if k == "next", next == "month" { return (shifted(today, by: 1, .month), nil, i + 2) }
            }
            if let value = names.weekdays[k] {
                // "Friday January 20" is the date; the weekday only says it again.
                var after = i + 1
                if key(after) == "the" { after += 1 }
                if let explicit = explicitDate(at: after, after: reference) { return explicit }
                return (coming(weekdays: [value]), nil, i + 1)
            }
            var j = i
            if k == "the" { j += 1 }
            if let explicit = explicitDate(at: j, after: reference) { return explicit }
            // "the 20th", "20th": the next 20th.
            if let ordinal = key(j), ordinal.last?.isLetter == true, let value = SearchQuery.dayOfMonth(ordinal),
               let day = resolve(year: nil, month: nil, day: value, after: reference) {
                return (day, nil, j + 1)
            }
            return nil
        }

        /// A date with a day and month: "20 january", "20th of january 2027", "january 20",
        /// "jan 20, 2027", "jan 20-22", "20/1", "2027-01-20".
        func explicitDate(at i: Int, after reference: Day) -> (Day, Day?, Int)? {
            guard let k = key(i) else { return nil }
            var month: Int?, dayOfMonth: Int?, lastDay: Int?, next = i
            if SearchQuery.year(k) == nil, let value = SearchQuery.dayOfMonth(k) {
                let monthIndex = key(i + 1) == "of" ? i + 2 : i + 1
                guard let named = key(monthIndex).flatMap({ names.months[$0] }) else { return numeric(k, at: i, after: reference) }
                month = named; dayOfMonth = value; next = monthIndex + 1
            } else if let named = names.months[k] {
                guard let after = key(i + 1) else { return nil }
                if SearchQuery.year(after) == nil, let value = SearchQuery.dayOfMonth(after) {
                    dayOfMonth = value
                } else if let (first, last) = Self.dayRange(after) {
                    dayOfMonth = first; lastDay = last
                } else { return nil }
                month = named; next = i + 2
            } else {
                return numeric(k, at: i, after: reference)
            }
            var year: Int?
            if let value = key(next).flatMap(SearchQuery.year) { year = value; next += 1 }
            guard let dayOfMonth, let start = resolve(year: year, month: month, day: dayOfMonth, after: reference) else { return nil }
            let end = lastDay.flatMap { makeDay(start.year, start.month, $0) }.flatMap { $0 > start ? $0 : nil }
            return (start, end, next)
        }

        func numeric(_ key: String, at i: Int, after reference: Day) -> (Day, Day?, Int)? {
            guard case let .pattern(year, month, dayOfMonth)? = SearchQuery.numericDate(key, dayFirst: names.dayFirst),
                  let month, let dayOfMonth, let day = resolve(year: year, month: month, day: dayOfMonth, after: reference) else { return nil }
            return (day, nil, i + 1)
        }

        static func dayRange(_ key: String) -> (Int, Int)? {
            let parts = key.split(whereSeparator: { "-–—".contains($0) }).map(String.init)
            guard parts.count == 2, let first = SearchQuery.dayOfMonth(parts[0]), let last = SearchQuery.dayOfMonth(parts[1]), last > first else { return nil }
            return (first, last)
        }
        static func count(_ key: String) -> Int? {
            if let value = Int(key), (1...400).contains(value) { return value }
            return ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10][key]
        }
        static func calendarUnit(_ key: String) -> (Calendar.Component, Int)? {
            switch key {
            case "day", "days": return (.day, 1)
            case "week", "weeks": return (.day, 7)
            case "month", "months": return (.month, 1)
            default: return nil
            }
        }

        // MARK: Times

        /// "at 18:00", "18:00-20:00", "from 9 to 11", "6-8pm", "at 6.30pm", "noon".
        func time(at i: Int) -> (Int, Int?, Int)? {
            var j = i, loose = false
            if let k = key(j), ["at", "from", "around", "@"].contains(k) { j += 1; loose = true }
            guard let k = key(j) else { return nil }
            if let (start, end) = clockRange(k, loose: loose) { return (start, end, j + 1) }
            guard let (start, startMeridiem, next) = clock(at: j, loose: loose) else { return nil }
            if let k = key(next), ["-", "–", "—", "to", "until", "till", "til"].contains(k),
               let (end, endMeridiem, after) = clock(at: next + 1, loose: true) {
                return (start, Self.end(start, startMeridiem, end, endMeridiem), after)
            }
            return (start, nil, next)
        }

        /// A clock time at a token, with an "am" or "pm" in the token or the next one.
        func clock(at i: Int, loose: Bool) -> (Int, Bool, Int)? {
            guard let k = key(i) else { return nil }
            if let meridiem = key(i + 1), ["am", "pm", "a.m", "p.m"].contains(meridiem),
               let minute = Self.clock(k + meridiem, loose: loose) {
                return (minute, true, i + 2)
            }
            guard let minute = Self.clock(k, loose: loose) else { return nil }
            return (minute, Self.meridiem(k) != nil, i + 1)
        }

        func clockRange(_ key: String, loose: Bool) -> (Int, Int)? {
            let parts = key.split(whereSeparator: { "-–—".contains($0) }).map(String.init)
            guard parts.count == 2 else { return nil }
            // Bare numbers either side ("9-17") are only a time after "at" or "from".
            let marked = parts.contains { $0.contains(":") || Self.meridiem($0) != nil }
            guard loose || marked, let start = Self.clock(parts[0], loose: true), let end = Self.clock(parts[1], loose: true) else { return nil }
            return (start, Self.end(start, Self.meridiem(parts[0]) != nil, end, Self.meridiem(parts[1]) != nil))
        }

        /// The end in minutes after the start's midnight. "6-8pm" shares the pm, and an end
        /// before the start is the next day.
        static func end(_ start: Int, _ startMeridiem: Bool, _ end: Int, _ endMeridiem: Bool) -> Int {
            var start = start
            if endMeridiem, !startMeridiem, start < 720, end >= 720, start + 720 < end { start += 720 }
            return end > start ? end : end + 1440
        }

        static func meridiem(_ key: String) -> Bool? {
            for suffix in ["a.m", "am"] where key.hasSuffix(suffix) { return false }
            for suffix in ["p.m", "pm"] where key.hasSuffix(suffix) { return true }
            return nil
        }

        /// "18:00", "9:30", "6pm", "6.30pm", "18h", "18h30", "18u"; bare "18" or "18.30" only
        /// when `loose`, after "at" or "from". Without am or pm, an hour of 1 to 6 written
        /// without a leading zero is in the afternoon: "at 5" is 17:00, "05:00" is early.
        static func clock(_ key: String, loose: Bool) -> Int? {
            if key == "noon" || key == "midday" { return 720 }
            if key == "midnight" { return 0 }
            var text = key, pm: Bool? = nil
            for (suffix, value) in [("a.m", false), ("p.m", true), ("am", false), ("pm", true)] where text.hasSuffix(suffix) {
                text.removeLast(suffix.count); pm = value; break
            }
            guard !text.isEmpty, text.first?.isNumber == true else { return nil }
            var hour: Int?, minute = 0
            if let separator = text.firstIndex(where: { ":.hu".contains($0) }) {
                let symbol = text[separator]
                let before = String(text[..<separator]), after = String(text[text.index(after: separator)...])
                // "18.30" reads as a date unless something says it's a time.
                if symbol == ".", !loose, pm == nil { return nil }
                guard before.count <= 2, let h = Int(before) else { return nil }
                // "18h" stands alone, but "1h" is more likely a length.
                if "hu".contains(symbol), !loose, before.count < 2 { return nil }
                hour = h
                if after.isEmpty {
                    guard "hu".contains(symbol) else { return nil }
                } else {
                    guard after.count == 2, let m = Int(after) else { return nil }
                    minute = m
                }
            } else {
                guard text.count <= 2, let h = Int(text), loose || pm != nil else { return nil }
                hour = h
            }
            guard var hour, (0...59).contains(minute) else { return nil }
            if let pm {
                guard (1...12).contains(hour) else { return nil }
                hour = hour % 12 + (pm ? 12 : 0)
            } else {
                guard (0...23).contains(hour) else { return nil }
                if (1...6).contains(hour), !text.hasPrefix("0") { hour += 12 }
            }
            return hour * 60 + minute
        }

        // MARK: Lengths

        /// "for 2 hours", "for 90 min", "for 1h30", "for an hour", "for half an hour", "for 1.5 hours".
        func length(at i: Int) -> (Int, Int)? {
            guard key(i) == "for", let k = key(i + 1) else { return nil }
            if k == "half", key(i + 2) == "an", key(i + 3) == "hour" { return (30, i + 4) }
            if let minutes = Self.compactLength(k) { return (minutes, i + 2) }
            let amount = Self.count(k).map(Double.init) ?? Double(k.replacingOccurrences(of: ",", with: "."))
            guard let amount, amount > 0, let unit = key(i + 2), let scale = Self.lengthUnit(unit) else { return nil }
            let minutes = Int((amount * Double(scale)).rounded())
            return (1...(24 * 60)).contains(minutes) ? (minutes, i + 3) : nil
        }
        static func lengthUnit(_ key: String) -> Int? {
            if ["h", "hr", "hrs", "hour", "hours", "uur", "u"].contains(key) { return 60 }
            if ["m", "min", "mins", "minute", "minutes", "minuten"].contains(key) { return 1 }
            return nil
        }
        /// "2h", "90m", "1h30", "1h30m", "45min".
        static func compactLength(_ key: String) -> Int? {
            var total = 0, rest = Substring(key), any = false
            while !rest.isEmpty {
                let digits = rest.prefix(while: \.isNumber)
                guard !digits.isEmpty, let value = Int(digits) else { return nil }
                rest = rest.dropFirst(digits.count)
                let unit = rest.prefix(while: \.isLetter)
                rest = rest.dropFirst(unit.count)
                // A trailing number counts as minutes: "1h30".
                let scale = unit.isEmpty ? (any ? 1 : nil) : lengthUnit(String(unit))
                guard let scale else { return nil }
                total += value * scale; any = true
            }
            return any && (1...(24 * 60)).contains(total) ? total : nil
        }

        // MARK: Repeats

        /// "daily", "every weekday", "weekly", "every monday", "every mon and wed", "on mondays".
        func repeats(at i: Int) -> (RepeatRule, [Int], Int)? {
            guard let k = key(i) else { return nil }
            if ["daily", "everyday"].contains(k) { return (.daily, [], i + 1) }
            if k == "weekly" { return (.weekly, [], i + 1) }
            if k == "weekdays" { return (.weekdays, [], i + 1) }
            if k == "on", key(i + 1) == "weekdays" { return (.weekdays, [], i + 2) }
            // "on mondays" repeats; "on monday" is a day.
            if k == "on", let plural = key(i + 1), plural.hasSuffix("s"), names.weekdays[plural] == nil,
               let value = weekdayValue(plural) {
                return (.weekly, [value], i + 2)
            }
            guard ["every", "each"].contains(k), let next = key(i + 1) else { return nil }
            if next == "day" { return (.daily, [], i + 2) }
            if next == "week" { return (.weekly, [], i + 2) }
            if ["weekday", "weekdays"].contains(next) { return (.weekdays, [], i + 2) }
            var days: [Int] = [], j = i + 1, end = i + 1
            while let k = key(j) {
                if let value = weekdayValue(k) {
                    if !days.contains(value) { days.append(value) }
                    j += 1; end = j
                } else if !days.isEmpty, ["and", "&", "or"].contains(k) {
                    j += 1
                } else { break }
            }
            guard !days.isEmpty else { return nil }
            return (days.count == 1 ? .weekly : .custom, days.count == 1 ? days : days.sorted(), end)
        }

        // MARK: Personas, people and places

        /// "#work", or the start of one: "#fam".
        func persona(at i: Int) -> Persona? {
            guard tokens[i].hasPrefix("#") else { return nil }
            let name = String(keys[i].drop { $0 == "#" })
            guard name.count >= 2 else { return nil }
            let candidates = Persona.allCases.filter { SearchQuery.key($0.title).hasPrefix(name) || $0.rawValue.hasPrefix(name) }
            return candidates.count == 1 ? candidates[0] : nil
        }

        /// "with Mollie and Sam", "with Anna Smith, Bo & Cas", "@Mollie".
        func people(at i: Int) -> ([String], Int)? {
            if tokens[i].hasPrefix("@"), tokens[i].count > 1 {
                let name = Self.trimmed(String(tokens[i].dropFirst()))
                guard !name.isEmpty else { return nil }
                return ([knownPeople[[SearchQuery.key(name)]] ?? name], i + 1)
            }
            guard key(i) == "with" else { return nil }
            var names: [String] = [], j = i + 1, end = i + 1
            while let (name, next) = properName(at: j, known: knownPeople, maxWords: 3) {
                names.append(name); end = next; j = next
                // A comma, "and" or "&" leads to the next name, if there is one.
                if tokens[next - 1].hasSuffix(",") { continue }
                if let k = key(j), ["and", "&"].contains(k), properName(at: j + 1, known: knownPeople, maxWords: 3) != nil { j += 1; continue }
                break
            }
            return names.isEmpty ? nil : (names, end)
        }

        /// "at Café de Klos", "in Amsterdam", "at the Hilton", "at Kalverstraat 12".
        func place(at i: Int) -> (String, Int)? {
            guard let k = key(i), ["at", "in"].contains(k) else { return nil }
            var j = i + 1
            if key(j) == "the", tokens.indices.contains(j + 1), tokens[j + 1].first?.isUppercase == true { j += 1 }
            // A month or weekday on its own ("in January") isn't a place.
            if let first = key(j), names.months[first] != nil || names.weekdays[first] != nil { return nil }
            guard let (name, end) = properName(at: j, known: knownPlaces, maxWords: 6, numbers: true) else { return nil }
            return (name, end)
        }

        /// Capitalised words from `i`, or a name already used in any case. Lowercase joining
        /// words ("de", "van", "of") are part of it when a capital follows; a comma or the start
        /// of a day or time ends it.
        func properName(at i: Int, known: [[String]: String], maxWords: Int, numbers: Bool = false) -> (String, Int)? {
            guard tokens.indices.contains(i), !startsDetail(at: i) else { return nil }
            for (words, name) in known.sorted(by: { $0.key.count > $1.key.count })
            where i + words.count <= keys.count && Array(keys[i..<(i + words.count)]) == words {
                return (name, i + words.count)
            }
            let joining: Set<String> = ["de", "van", "der", "den", "het", "the", "of", "la", "le", "du", "des", "del", "da", "op", "aan"]
            var words: [String] = [], j = i
            while tokens.indices.contains(j), words.count < maxWords {
                let token = tokens[j]
                if j > i, startsDetail(at: j) { break }
                if token.first?.isUppercase == true {
                    words.append(token)
                } else if !words.isEmpty, joining.contains(keys[j]), tokens.indices.contains(j + 1),
                          tokens[j + 1].first?.isUppercase == true, !tokens[j].hasSuffix(",") {
                    words.append(token)
                } else if numbers, !words.isEmpty, token.count <= 5, token.first?.isNumber == true,
                          token.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "," }) {
                    words.append(token)
                } else { break }
                j += 1
                if token.hasSuffix(",") { break }
            }
            guard !words.isEmpty else { return nil }
            return (Self.trimmed(words.joined(separator: " ")), j)
        }

        /// Whether a day, time, length or repeat starts here, which ends a name before it.
        func startsDetail(at i: Int) -> Bool {
            repeats(at: i) != nil || day(at: i) != nil || time(at: i) != nil || length(at: i) != nil
                || tokens[i].hasPrefix("#") || tokens[i].hasPrefix("@")
        }

        static func trimmed(_ text: String) -> String {
            text.trimmingCharacters(in: CharacterSet(charactersIn: ",;:!?.()\"").union(.whitespaces))
        }
    }
}
