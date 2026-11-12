import XCTest
@testable import TimoCore

/// Today is Monday 9 November 2026.
final class QuickEntryTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))! }
    var today: Day { Day(now, calendar: calendar) }
    func day(_ year: Int, _ month: Int, _ day: Int) -> Day {
        Day(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!, calendar: calendar)
    }
    func entry(_ text: String, ignoring: Set<String> = [], people: [String] = [], places: [String] = []) -> QuickEntry {
        QuickEntry(text, on: today, now: now, ignoring: ignoring, knownPeople: people, knownPlaces: places,
                   calendar: calendar, locale: Locale(identifier: "en_GB"))
    }

    func testTheExample() {
        let e = entry("January 20 Mollie President's Club dinner at 18:00")
        XCTAssertEqual(e.title, "Mollie President's Club dinner")
        XCTAssertEqual(e.day, day(2027, 1, 20))
        XCTAssertEqual(e.minute, 18 * 60)
        XCTAssertNil(e.endMinute)
        XCTAssertTrue(e.people.isEmpty)
        XCTAssertTrue(e.locations.isEmpty)
        let item = e.item(calendar: calendar)
        XCTAssertFalse(item.movesToNextDay)
        XCTAssertEqual(item.start(calendar: calendar), calendar.date(from: DateComponents(year: 2027, month: 1, day: 20, hour: 18)))
    }
    func testPlainTitleKeepsTheDefaultDayAndCarries() {
        let e = entry("buy milk")
        XCTAssertEqual(e.title, "Buy milk")
        XCTAssertEqual(e.day, today)
        XCTAssertNil(e.minute)
        XCTAssertTrue(e.item(calendar: calendar).movesToNextDay)
        XCTAssertEqual(entry("check iPhone").title, "Check iPhone")
        XCTAssertEqual(entry("iPhone repair").title, "iPhone repair")
    }
    func testRelativeDays() {
        XCTAssertEqual(entry("call mum tomorrow").day, day(2026, 11, 10))
        XCTAssertEqual(entry("call mum tomorrow").title, "Call mum")
        XCTAssertEqual(entry("party tonight").day, today)
        XCTAssertEqual(entry("dentist in 3 days").day, day(2026, 11, 12))
        XCTAssertEqual(entry("review in two weeks").day, day(2026, 11, 23))
        XCTAssertEqual(entry("drinks on friday").day, day(2026, 11, 13))
        XCTAssertEqual(entry("drinks on friday").title, "Drinks")
        // Today is Monday: "monday" is today, "next monday" a week on.
        XCTAssertEqual(entry("standup monday").day, today)
        XCTAssertEqual(entry("standup next monday").day, day(2026, 11, 16))
    }
    func testExplicitDates() {
        XCTAssertEqual(entry("trip 20 january").day, day(2027, 1, 20))
        XCTAssertEqual(entry("trip 20th of January 2028").day, day(2028, 1, 20))
        XCTAssertEqual(entry("trip jan 20, 2027").day, day(2027, 1, 20))
        XCTAssertEqual(entry("trip 14/11").day, day(2026, 11, 14))
        XCTAssertEqual(entry("trip 2027-03-02").day, day(2027, 3, 2))
        XCTAssertEqual(entry("pay rent on the 1st").day, day(2026, 12, 1))
        XCTAssertEqual(entry("pay rent on the 1st").title, "Pay rent")
        // The weekday only repeats the date.
        let e = entry("launch Friday 20 November")
        XCTAssertEqual(e.day, day(2026, 11, 20))
        XCTAssertEqual(e.title, "Launch")
        // Later this month stays this year; earlier rolls over.
        XCTAssertEqual(entry("x november 30").day, day(2026, 11, 30))
        XCTAssertEqual(entry("x november 2").day, day(2027, 11, 2))
    }
    func testAMonthWithoutADayIsAWord() {
        let e = entry("may fair planning")
        XCTAssertEqual(e.title, "May fair planning")
        XCTAssertEqual(e.day, today)
    }
    func testDayRanges() {
        let e = entry("ski trip jan 20 until jan 24")
        XCTAssertEqual(e.title, "Ski trip")
        XCTAssertEqual(e.day, day(2027, 1, 20))
        XCTAssertEqual(e.endDay, day(2027, 1, 24))
        XCTAssertFalse(e.item(calendar: calendar).movesToNextDay)
        XCTAssertEqual(entry("conference december 2-4").endDay, day(2026, 12, 4))
    }
    func testTimes() {
        XCTAssertEqual(entry("gym at 7").minute, 7 * 60)
        XCTAssertEqual(entry("gym at 5").minute, 17 * 60)
        XCTAssertEqual(entry("gym at 05:00").minute, 5 * 60)
        XCTAssertEqual(entry("gym 6pm").minute, 18 * 60)
        XCTAssertEqual(entry("gym 6:30 am").minute, 6 * 60 + 30)
        XCTAssertEqual(entry("gym 12am").minute, 0)
        XCTAssertEqual(entry("lunch noon").minute, 12 * 60)
        XCTAssertEqual(entry("dinner 18u").minute, 18 * 60)
        XCTAssertEqual(entry("dinner at 18.30").minute, 18 * 60 + 30)
        XCTAssertEqual(entry("gym at 7").title, "Gym")
        // Without "at", a bare number is part of the title.
        XCTAssertNil(entry("read 20 pages").minute)
        XCTAssertEqual(entry("read 20 pages").title, "Read 20 pages")
    }
    func testTimeRangesAndLengths() {
        let range = entry("meeting 9:00-10:30")
        XCTAssertEqual(range.minute, 9 * 60)
        XCTAssertEqual(range.endMinute, 10 * 60 + 30)
        XCTAssertEqual(entry("work from 9 to 5").endMinute, 17 * 60)
        let shared = entry("party 6-8pm")
        XCTAssertEqual(shared.minute, 18 * 60)
        XCTAssertEqual(shared.endMinute, 20 * 60)
        XCTAssertEqual(entry("party 22:00 until 01:00").endMinute, 25 * 60)
        let length = entry("call at 14:00 for 30 min")
        XCTAssertEqual(length.endMinute, 14 * 60 + 30)
        XCTAssertEqual(length.title, "Call")
        XCTAssertEqual(entry("hike at 9 for 2 hours").endMinute, 11 * 60)
        XCTAssertEqual(entry("hike at 9 for 1h30").endMinute, 10 * 60 + 30)
        XCTAssertEqual(entry("nap at 14:00 for half an hour").endMinute, 14 * 60 + 30)
        let item = entry("party 22:00 until 01:00").item(calendar: calendar)
        XCTAssertEqual(item.end, calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 1)))
    }
    func testALengthWithoutAStartStaysInTheTitle() {
        let e = entry("study for 2 hours")
        XCTAssertNil(e.minute)
        XCTAssertEqual(e.title, "Study for 2 hours")
    }
    func testRepeats() {
        let daily = entry("meditate every day at 7")
        XCTAssertEqual(daily.repeatRule, .daily)
        XCTAssertEqual(daily.title, "Meditate")
        XCTAssertEqual(entry("standup every weekday 9:30").repeatRule, .weekdays)
        let weekly = entry("tennis every thursday at 19:00")
        XCTAssertEqual(weekly.repeatRule, .weekly)
        XCTAssertEqual(weekly.day, day(2026, 11, 12))
        XCTAssertEqual(weekly.title, "Tennis")
        let custom = entry("gym every mon, wed and fri")
        XCTAssertEqual(custom.repeatRule, .custom)
        XCTAssertEqual(custom.repeatWeekdays, [2, 4, 6])
        XCTAssertEqual(custom.day, today)
        XCTAssertEqual(entry("bins on tuesdays").repeatRule, .weekly)
        XCTAssertEqual(entry("bins on tuesdays").day, day(2026, 11, 10))
    }
    func testMonthEndRepeats() {
        for text in ["pay rent every last day of the month", "pay rent on the last day of every month",
                     "pay rent every month end", "pay rent at the end of each month"] {
            let e = entry(text)
            XCTAssertEqual(e.repeatRule, .monthEnd, text)
            XCTAssertEqual(e.day, day(2026, 11, 30), text)
            XCTAssertEqual(e.title, "Pay rent", text)
        }
        // One deadline, not a repeat.
        let once = entry("report by the end of the month")
        XCTAssertEqual(once.repeatRule, .never)
        XCTAssertEqual(once.title, "Report by the end of the month")
    }
    func testPersonas() {
        let e = entry("run 5k #health #fam")
        XCTAssertEqual(e.personas, [.health, .family])
        XCTAssertEqual(e.title, "Run 5k")
        XCTAssertEqual(e.item(personas: [.work], calendar: calendar).personas, [.health, .work, .family])
        // "#f" could be family or friends.
        XCTAssertTrue(entry("x #f").personas.isEmpty)
    }
    func testPeople() {
        let e = entry("lunch with Anna and Bo tomorrow")
        XCTAssertEqual(e.people, ["Anna", "Bo"])
        XCTAssertEqual(e.title, "Lunch")
        XCTAssertEqual(e.day, day(2026, 11, 10))
        XCTAssertEqual(entry("call with Anna Smith, Bo & Cas").people, ["Anna Smith", "Bo", "Cas"])
        XCTAssertEqual(entry("coffee @Mollie").people, ["Mollie"])
        // Known names count in any case and keep their spelling.
        XCTAssertEqual(entry("walk with mum", people: ["Mum"]).people, ["Mum"])
        // Lowercase words after "with" are the title.
        XCTAssertEqual(entry("help with taxes").title, "Help with taxes")
        XCTAssertTrue(entry("help with taxes").people.isEmpty)
    }
    func testPlaces() {
        let e = entry("dinner at Café de Klos at 19:00")
        XCTAssertEqual(e.locations, ["Café de Klos"])
        XCTAssertEqual(e.minute, 19 * 60)
        XCTAssertEqual(e.title, "Dinner")
        XCTAssertEqual(entry("conference in Amsterdam on friday").locations, ["Amsterdam"])
        XCTAssertEqual(entry("conference in Amsterdam on friday").day, day(2026, 11, 13))
        XCTAssertEqual(entry("drinks at the Hilton").locations, ["Hilton"])
        XCTAssertEqual(entry("pick up at Kalverstraat 12").locations, ["Kalverstraat 12"])
        XCTAssertEqual(entry("swim at the gym", places: ["the gym"]).locations, ["the gym"])
        XCTAssertTrue(entry("look at the report").locations.isEmpty)
        XCTAssertEqual(entry("look at the report").title, "Look at the report")
        // A month alone isn't a place.
        XCTAssertTrue(entry("holiday in January").locations.isEmpty)
    }
    func testOnlyTheFirstDayCounts() {
        let e = entry("plan friday drinks on monday")
        XCTAssertEqual(e.day, day(2026, 11, 13))
        XCTAssertEqual(e.title, "Plan drinks on monday")
    }
    func testIgnoredMatchesStayInTheTitle() {
        let first = entry("dinner at Mollie at 18:00")
        let place = try! XCTUnwrap(first.matches.first { $0.kind == .place })
        let e = entry("dinner at Mollie at 18:00", ignoring: [place.id])
        XCTAssertEqual(e.title, "Dinner at Mollie")
        XCTAssertTrue(e.locations.isEmpty)
        XCTAssertEqual(e.minute, 18 * 60)
        let time = try! XCTUnwrap(e.matches.first { $0.kind == .time })
        XCTAssertEqual(entry("dinner at Mollie at 18:00", ignoring: [place.id, time.id]).title, "Dinner at Mollie at 18:00")
    }
    func testTheItemIsValid() throws {
        for text in ["January 20 Mollie President's Club dinner at 18:00", "ski trip jan 20 until jan 24",
                     "gym every mon, wed and fri at 7 for 1h", "party 22:00 until 01:00"] {
            XCTAssertNoThrow(try Planner.validate(entry(text).item(calendar: calendar), in: [], calendar: calendar), text)
        }
    }
}
