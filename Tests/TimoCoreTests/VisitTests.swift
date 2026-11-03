import XCTest
@testable import TimoCore

final class VisitTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return value
    }
    func date(_ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    func day(_ value: Int) -> Day { Day(date(value), calendar: calendar) }

    func testReminderOnAnotherDayVisitsThatDayWhileUpcoming() {
        // Scheduled on the 28th, reminded the evening before.
        let item = PlanItem(title: "Dentist", day: day(28), minute: 600, movesToNextDay: false, reminders: [date(27, hour: 20)])
        let now = date(26)
        XCTAssertTrue(item.reminds(on: day(27), now: now, calendar: calendar))
        XCTAssertTrue(item.visits(day(27), now: now, calendar: calendar))
        XCTAssertEqual(item.visitTime(on: day(27), now: now, calendar: calendar), date(27, hour: 20))
        // Its own day shows it as itself, so it doesn't visit there.
        XCTAssertFalse(item.visits(day(28), now: now, calendar: calendar))
        XCTAssertFalse(item.visits(day(26), now: now, calendar: calendar))
        // Once the reminder has gone off it has done its job.
        XCTAssertFalse(item.visits(day(27), now: date(27, hour: 21), calendar: calendar))
    }
    func testOpenDeadlineVisitsItsDayEvenOncePassed() {
        var item = PlanItem(title: "Report", day: day(26), minute: 540, movesToNextDay: false)
        item.deadline = date(29, hour: 17)
        XCTAssertTrue(item.isDue(on: day(29), calendar: calendar))
        XCTAssertTrue(item.visits(day(29), now: date(26), calendar: calendar))
        XCTAssertTrue(item.visits(day(29), now: date(30), calendar: calendar))
        XCTAssertEqual(item.visitTime(on: day(29), now: date(26), calendar: calendar), date(29, hour: 17))
        // A finished item has no open deadline.
        item.completedAt = date(27)
        XCTAssertFalse(item.visits(day(29), now: date(26), calendar: calendar))
    }
    func testTodaysItemWithTomorrowsReminderAndDeadlineHasDatesOnTomorrow() {
        let now = date(26)
        var item = PlanItem(title: "Report", day: day(26), minute: 600, movesToNextDay: false,
                            reminders: [date(27, hour: 10)])
        item.deadline = date(27, hour: 17)

        XCTAssertTrue(item.shows(on: day(26), now: now, calendar: calendar))
        XCTAssertFalse(item.reminds(on: day(26), now: now, calendar: calendar))
        XCTAssertFalse(item.isDue(on: day(26), calendar: calendar))
        XCTAssertTrue(item.reminds(on: day(27), now: now, calendar: calendar))
        XCTAssertTrue(item.isDue(on: day(27), calendar: calendar))
        XCTAssertTrue(item.visits(day(27), now: now, calendar: calendar))
    }
    func testCarriedItemWithTomorrowsReminderAndDeadlineHasDatesOnTomorrow() {
        let now = date(28)
        var item = PlanItem(title: "Report", day: day(26), reminders: [date(29, hour: 10)])
        item.deadline = date(29, hour: 17)

        XCTAssertTrue(item.shows(on: day(28), now: now, calendar: calendar))
        for selected in [day(26), day(27), day(28)] {
            XCTAssertFalse(item.reminds(on: selected, now: now, calendar: calendar))
            XCTAssertFalse(item.isDue(on: selected, calendar: calendar))
        }
        XCTAssertTrue(item.reminds(on: day(29), now: now, calendar: calendar))
        XCTAssertTrue(item.isDue(on: day(29), calendar: calendar))
        XCTAssertTrue(item.visits(day(29), now: now, calendar: calendar))
    }
    func testCarriedItemDoesNotVisitTheDaysItIsShownOn() {
        // Carried on from the 26th to today, the 29th, with a deadline on the 28th.
        var item = PlanItem(title: "Shop", day: day(26))
        item.deadline = date(28, hour: 12)
        let now = date(29, hour: 12)
        // The 28th already has its "Carried to" entry.
        XCTAssertTrue(item.movedAway(from: day(28), now: now, calendar: calendar))
        XCTAssertFalse(item.visits(day(28), now: now, calendar: calendar))
    }
    func testVisitingItemsAreOrderedByWhenTheyFall() {
        var late = PlanItem(title: "Late", day: day(26), minute: 540, movesToNextDay: false)
        late.deadline = date(29, hour: 18)
        let early = PlanItem(title: "Early", day: day(30), minute: 540, movesToNextDay: false, reminders: [date(29, hour: 8)])
        let home = PlanItem(title: "Home", day: day(29), minute: 540, reminders: [date(29, hour: 7)])
        let visiting = Planner.visitingItems(on: day(29), in: [late, home, early], now: date(26), calendar: calendar)
        XCTAssertEqual(visiting.map(\.title), ["Early", "Late"])
    }
}
