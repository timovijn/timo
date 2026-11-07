import XCTest
@testable import TimoCore

final class StartNowTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return value
    }
    func date(_ d: Int, _ h: Int, _ m: Int = 0, _ seconds: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m, second: seconds))!
    }
    func day(_ d: Int) -> Day { Day(date(d, 0), calendar: calendar) }
    func testPickerUsesLiveClockButKeepsSelectedDateAndDuration() {
        var item = PlanItem(title: "Meeting", day: day(12), minute: 540, end: date(12, 10), reminders: [date(12, 8, 45)])
        Planner.updateStartToNow(&item, now: date(7, 14, 23, 49), on: day(12), calendar: calendar)
        XCTAssertEqual(item.day, day(12))
        XCTAssertEqual(item.minute, 14 * 60 + 23)
        XCTAssertEqual(item.end, date(12, 15, 23))
        XCTAssertEqual(item.reminders, [date(12, 14, 8)])
    }
    func testQuickActionMovesToTodayAndPreservesDurationAcrossMidnight() {
        let item = PlanItem(title: "Work", day: day(12), minute: 540, end: date(12, 11), movesToNextDay: false, reminders: [date(12, 8, 45)])
        var items = [item], series: [RepeatingPlan] = []
        XCTAssertTrue(Planner.startNow(item.id, items: &items, series: &series, now: date(7, 23, 35, 42), calendar: calendar))
        XCTAssertEqual(items[0].id, item.id)
        XCTAssertEqual(items[0].day, day(7))
        XCTAssertEqual(items[0].start(calendar: calendar), date(7, 23, 35))
        XCTAssertEqual(items[0].end, date(8, 1, 35))
        XCTAssertEqual(items[0].reminders, [date(7, 23, 20)])
        XCTAssertFalse(items[0].movesToNextDay)
    }
    func testLinkedOccurrenceMovesAloneAndIsNotRegenerated() throws {
        var template = PlanItem(title: "Work", day: day(6), minute: 540, end: date(6, 10), movesToNextDay: false)
        template.repeatRule = .daily
        var series = [RepeatingPlan(template: template)], items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(6), through: day(8), calendar: calendar)
        let original = try XCTUnwrap(items.first { $0.day == day(6) })
        let unchanged = items.filter { $0.id != original.id }
        XCTAssertTrue(Planner.startNow(original.id, items: &items, series: &series, now: date(7, 14, 23), calendar: calendar))
        let moved = try XCTUnwrap(items.first { $0.id == original.id })
        XCTAssertNil(moved.seriesID)
        XCTAssertEqual(moved.repeatRule, .never)
        XCTAssertEqual(moved.day, day(7))
        XCTAssertEqual(moved.minute, 14 * 60 + 23)
        XCTAssertTrue(series[0].excludedDays.contains(day(6)))
        XCTAssertEqual(items.filter { $0.id != original.id }, unchanged)
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(6), through: day(8), calendar: calendar))
    }
    func testFullDayOccurrenceBecomesTimedWithoutChangingOtherDays() throws {
        let event = PlanItem(title: "Weekend", day: day(6), endDay: day(8), movesToNextDay: false)
        var items: [PlanItem] = [], series: [RepeatingPlan] = []
        Planner.saveDateRange(event, items: &items, series: &series, calendar: calendar)
        let selected = try XCTUnwrap(items.first { $0.day == day(7) })
        let others = items.filter { $0.id != selected.id }
        XCTAssertTrue(Planner.startNow(selected.id, items: &items, series: &series, now: date(7, 15, 12), calendar: calendar))
        let moved = try XCTUnwrap(items.first { $0.id == selected.id })
        XCTAssertNil(moved.endDay)
        XCTAssertNil(moved.seriesID)
        XCTAssertEqual(moved.minute, 15 * 60 + 12)
        XCTAssertEqual(moved.end, date(7, 16, 12))
        XCTAssertEqual(items.filter { $0.id != selected.id }, others)
    }
    func testQuickActionLeavesSettledUntimedAndMissingItemsUntouched() {
        var done = PlanItem(title: "Done", day: day(7), minute: 540)
        done.completedAt = date(7, 10)
        var cancelled = PlanItem(title: "Cancelled", day: day(7), minute: 540)
        cancelled.cancelledAt = date(7, 10)
        let anytime = PlanItem(title: "Read", day: day(7))
        let before = [done, cancelled, anytime]
        var items = before, series: [RepeatingPlan] = []
        for id in before.map(\.id) + [UUID()] {
            XCTAssertFalse(Planner.startNow(id, items: &items, series: &series, now: date(7, 12), calendar: calendar))
        }
        XCTAssertEqual(items, before)
    }
}
