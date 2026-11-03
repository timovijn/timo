import XCTest
@testable import TimoCore

final class DayProgressTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }
    func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }
    func day(_ value: Int) -> Day { Day(date(value, 12), calendar: calendar) }

    func testCountsWhatTheDayShowsWithoutCancelledItems() {
        var run = PlanItem(title: "Run", day: day(2), minute: 9 * 60, movesToNextDay: false)
        run.completedAt = date(2, 10)
        var dentist = PlanItem(title: "Dentist", day: day(2), minute: 14 * 60, movesToNextDay: false)
        dentist.cancelledAt = date(2, 8)
        let items = [run, dentist, PlanItem(title: "Lunch", day: day(2), minute: 12 * 60, movesToNextDay: false),
                     PlanItem(title: "Email Joost", day: day(1)), PlanItem(title: "Tomorrow", day: day(3))]
        // Email Joost carries on from yesterday, so today counts it too.
        XCTAssertEqual(DayProgress(items: items, day: day(2), now: date(2, 11), calendar: calendar),
                       DayProgress(done: 1, total: 3))
    }
}
