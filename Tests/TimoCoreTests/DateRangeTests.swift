import XCTest
@testable import TimoCore

final class DateRangeTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }
    func date(_ day: Int, hour: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func day(_ value: Int, month: Int = 11) -> Day { Day(date(value, month: month), calendar: calendar) }
    func range(carries: Bool = false) -> PlanItem {
        PlanItem(title: "Trip", day: day(6), endDay: day(8), movesToNextDay: carries)
    }
    func testInclusiveVisibilityAndReviewAfterFinalDay() throws {
        let item = range()
        try Planner.validate(item, in: [item], calendar: calendar)
        for value in 5...9 {
            XCTAssertEqual(item.shows(on: day(value), now: date(7), calendar: calendar), (6...8).contains(value))
        }
        XCTAssertFalse(item.isElapsed(now: date(8, hour: 23), calendar: calendar))
        XCTAssertTrue(item.isElapsed(now: date(9, hour: 1), calendar: calendar))
        XCTAssertFalse(item.isInProgress(now: date(7), calendar: calendar), "Full-day ranges have no clock progress")
    }
    func testCarryStartsAfterFinalDayAndEarlyCompletionKeepsRange() {
        var item = range(carries: true)
        XCTAssertFalse(item.isCarried(now: date(8, hour: 23), calendar: calendar))
        XCTAssertTrue(item.isCarried(now: date(9), calendar: calendar))
        XCTAssertFalse(item.movedAway(from: day(8), now: date(9), calendar: calendar), "Covered dates retain their own daily state")
        item.completedAt = date(7)
        for value in 6...8 { XCTAssertTrue(item.shows(on: day(value), now: date(10), calendar: calendar)) }
        XCTAssertFalse(item.shows(on: day(9), now: date(10), calendar: calendar))
        item.completedAt = nil
        item.cancelledAt = date(7)
        XCTAssertTrue(item.shows(on: day(8), now: date(10), calendar: calendar))
        XCTAssertFalse(item.isElapsed(now: date(10), calendar: calendar))
    }
    func testSingleDayAndInvalidSchedules() throws {
        var item = range()
        item.endDay = item.day
        try Planner.validate(item, in: [item], calendar: calendar)
        item.endDay = day(5)
        XCTAssertThrowsError(try Planner.validate(item, in: [item], calendar: calendar))
        item.endDay = day(8); item.minute = 600
        XCTAssertThrowsError(try Planner.validate(item, in: [item], calendar: calendar))
        item.minute = nil; item.end = date(9)
        XCTAssertThrowsError(try Planner.validate(item, in: [item], calendar: calendar))
    }
    func testMovingRangePreservesCalendarDaysAcrossDST() {
        var item = range()
        Planner.updateStart(&item, day: day(24, month: 10), minute: nil, calendar: calendar)
        XCTAssertEqual(item.endDay, day(26, month: 10))
        XCTAssertEqual(item.scheduleEnd(calendar: calendar), date(27, month: 10))
        XCTAssertEqual(item.scheduleEnd(calendar: calendar)!.timeIntervalSince(item.day.date(calendar: calendar)), 73 * 3600)
    }
    func testAddingAndRemovingTimeKeepsCoveredDates() {
        var item = range()
        Planner.updateStart(&item, day: item.day, minute: 600, calendar: calendar)
        XCTAssertNil(item.endDay)
        XCTAssertEqual(item.end, date(8, hour: 11))
        Planner.updateStart(&item, day: item.day, minute: nil, calendar: calendar)
        XCTAssertNil(item.end)
        XCTAssertEqual(item.endDay, day(8))
        item = PlanItem(title: "Overnight", day: day(6), minute: 1380, end: date(8), movesToNextDay: false)
        Planner.updateStart(&item, day: item.day, minute: nil, calendar: calendar)
        XCTAssertEqual(item.endDay, day(7), "A midnight end excludes the following date")
    }
    func testPersistenceAndOldItems() throws {
        let item = range()
        XCTAssertEqual(try JSONDecoder().decode(PlanItem.self, from: JSONEncoder().encode(item)), item)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object.removeValue(forKey: "endDay")
        let old = try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.endDay)
    }
    func testCloudMergeKeepsScheduleTogether() {
        let base = range()
        var mine = base, theirs = base
        mine.endDay = day(10)
        theirs.title = "Holiday"
        Planner.updateStart(&theirs, day: day(15), minute: 600, calendar: calendar)
        let merged = PlanItem.merged(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.title, "Holiday")
        XCTAssertEqual(merged.day, day(6))
        XCTAssertEqual(merged.endDay, day(10))
        XCTAssertNil(merged.minute)
        XCTAssertNil(merged.end)
    }
    func testHistoryAndDateSearchIncludeMiddleAndFinalDays() {
        var item = range()
        item.personas = [.personal]
        let history = Planner.history(of: .personal, in: [item], now: date(7), calendar: calendar)
        XCTAssertEqual(history.map(\.day), [day(8), day(7), day(6)])
        let results = Planner.search("Trip 8 November 2026", in: [item], now: date(7), calendar: calendar, locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(results.first?.day, day(8))
        XCTAssertEqual(results.first?.items.map(\.id), [item.id])
    }
    func testRepeatingRangePreservesLength() {
        var item = range()
        item.repeatRule = .weekly
        let plan = RepeatingPlan(template: item)
        var items: [PlanItem] = []
        _ = Planner.materialize([plan], in: &items, from: day(13), through: day(13), calendar: calendar)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.day, day(13))
        XCTAssertEqual(items.first?.endDay, day(15))
    }
}
