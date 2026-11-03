import XCTest
@testable import TimoCore

/// Today is Sunday 25 October 2026.
final class DateSearchTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }
    var now: Date { date(2026, 10, 25) }
    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    func item(_ title: String, _ year: Int, _ month: Int, _ day: Int) -> PlanItem {
        // Doesn't carry, so it stays on its own day.
        PlanItem(title: title, day: Day(date(year, month, day), calendar: calendar), movesToNextDay: false)
    }
    lazy var items: [PlanItem] = [
        item("Dentist", 2026, 10, 20), item("Dentist", 2026, 11, 14), item("Lunch", 2026, 11, 3),
        item("Dinner", 2027, 11, 14), item("Gym", 2026, 10, 23), item("Gym", 2026, 10, 30),
        item("Party", 2026, 10, 26), item("Call", 2026, 10, 24), item("May fair", 2026, 10, 21),
    ]
    func titles(_ query: String, locale: String = "en_US") -> [String] {
        Planner.search(query, in: items, now: now, calendar: calendar, locale: Locale(identifier: locale))
            .flatMap { entry in entry.items.map { "\($0.title) \(entry.day.year)-\(entry.day.month)-\(entry.day.day)" } }
    }

    func testMonthFindsThatMonthInEveryYear() {
        XCTAssertEqual(titles("november"), ["Dinner 2027-11-14", "Dentist 2026-11-14", "Lunch 2026-11-3"])
        XCTAssertEqual(titles("Nov"), titles("november"))
    }
    func testMonthAndYear() {
        XCTAssertEqual(titles("november 2027"), ["Dinner 2027-11-14"])
        XCTAssertEqual(titles("2027 nov"), ["Dinner 2027-11-14"])
        XCTAssertEqual(titles("2027"), ["Dinner 2027-11-14"])
    }
    func testMonthAndDayInEitherOrder() {
        let both = ["Dinner 2027-11-14", "Dentist 2026-11-14"]
        for query in ["november 14", "14 november", "14th of nov", "Nov 14th", "nov. 14"] {
            XCTAssertEqual(titles(query), both, query)
        }
        XCTAssertEqual(titles("nov 14, 2027"), ["Dinner 2027-11-14"])
        XCTAssertEqual(titles("14 November 2026"), ["Dentist 2026-11-14"])
    }
    func testNumericDatesFollowTheLocaleOrder() {
        XCTAssertEqual(titles("14/11", locale: "en_GB"), ["Dinner 2027-11-14", "Dentist 2026-11-14"])
        XCTAssertEqual(titles("11/14"), ["Dinner 2027-11-14", "Dentist 2026-11-14"])
        // An impossible month is read the other way round.
        XCTAssertEqual(titles("14/11"), titles("11/14"))
        XCTAssertEqual(titles("2027-11-14"), ["Dinner 2027-11-14"])
        XCTAssertEqual(titles("14-11-26", locale: "nl_NL"), ["Dentist 2026-11-14"])
        XCTAssertEqual(titles("3/11/2026", locale: "en_GB"), ["Lunch 2026-11-3"])
    }
    func testRelativeDays() {
        XCTAssertEqual(titles("tomorrow"), ["Party 2026-10-26"])
        XCTAssertEqual(titles("yesterday"), ["Call 2026-10-24"])
        XCTAssertEqual(titles("friday"), ["Gym 2026-10-30"])
        XCTAssertEqual(titles("last friday"), ["Gym 2026-10-23"])
        XCTAssertEqual(titles("next week"), ["Lunch 2026-11-3"])
        XCTAssertEqual(titles("this week"), ["Gym 2026-10-30", "Party 2026-10-26"])
        XCTAssertEqual(titles("next month"), ["Dentist 2026-11-14", "Lunch 2026-11-3"])
    }
    func testDatesAndWordsCombine() {
        XCTAssertEqual(titles("dentist november"), ["Dentist 2026-11-14"])
        XCTAssertEqual(titles("gym last friday"), ["Gym 2026-10-23"])
        XCTAssertTrue(titles("dinner october").isEmpty)
    }
    func testADateWordIsAlsoFoundInText() {
        // "May" is a month and a word; the fair is in October.
        XCTAssertEqual(titles("may"), ["May fair 2026-10-21"])
        XCTAssertEqual(titles("may fair"), ["May fair 2026-10-21"])
    }
    func testDutchMonthNames() {
        XCTAssertEqual(titles("14 november", locale: "nl_NL"), titles("14 november"))
        XCTAssertEqual(titles("mei"), [])
        items.append(item("Picnic", 2027, 5, 2))
        XCTAssertEqual(titles("2 mei", locale: "nl_NL"), ["Picnic 2027-5-2"])
    }
    func testACarriedItemIsListedUnderTheDayTheDateNames() {
        // Planned for the 20th and carried on to today, unfinished.
        items = [PlanItem(title: "Taxes", day: Day(date(2026, 10, 20), calendar: calendar))]
        XCTAssertEqual(titles("taxes"), ["Taxes 2026-10-25"])
        XCTAssertEqual(titles("20 oct"), ["Taxes 2026-10-20"])
        XCTAssertEqual(titles("22 oct"), ["Taxes 2026-10-22"])
        // Its own day comes first when both match.
        XCTAssertEqual(titles("october"), ["Taxes 2026-10-25"])
        XCTAssertTrue(titles("19 oct").isEmpty)
    }
    func testADateListsEveryDayOfARepeatingItem() {
        let series = UUID()
        items = (20...40).map { offset in
            var swim = PlanItem(title: "Swim", day: Day(calendar.date(byAdding: .day, value: offset, to: date(2026, 10, 1))!, calendar: calendar),
                               movesToNextDay: false)
            swim.seriesID = series
            return swim
        }
        // Without a date, its days up to the limit; with one, every day of it in that date.
        XCTAssertEqual(Planner.search("swim", in: items, now: now, repeatsThrough: Day(date(2026, 10, 27), calendar: calendar),
                                      calendar: calendar, locale: Locale(identifier: "en_US")).count, 7)
        XCTAssertEqual(titles("swim november").count, 10)
    }
}
