import XCTest
@testable import TimoCore

final class PushTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return value
    }
    func date(_ d: Int, _ h: Int, _ m: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))!
    }
    func day(_ d: Int, month: Int = 11) -> Day { Day(date(d, 0, month: month), calendar: calendar) }

    func testIntervalsCountFromTheShownDay() {
        XCTAssertEqual(PushInterval.day.day(after: day(30), calendar: calendar), day(1, month: 12))
        XCTAssertEqual(PushInterval.week.day(after: day(13), calendar: calendar), day(20))
        XCTAssertEqual(PushInterval.month.day(after: day(13), calendar: calendar), day(13, month: 12))
        // A month on from the 31st lands on the last day of a shorter month.
        XCTAssertEqual(PushInterval.month.day(after: day(31, month: 10), calendar: calendar), day(30))
    }
    func testTimedItemKeepsItsTimeDurationAndReminders() {
        let item = PlanItem(title: "Dentist", day: day(13), minute: 600, end: date(13, 11), reminders: [date(13, 9, 45)])
        var items = [item], series: [RepeatingPlan] = []
        XCTAssertTrue(Planner.push(item.id, from: day(13), by: .week, items: &items, series: &series, calendar: calendar))
        XCTAssertEqual(items[0].id, item.id)
        XCTAssertEqual(items[0].day, day(20))
        XCTAssertEqual(items[0].start(calendar: calendar), date(20, 10))
        XCTAssertEqual(items[0].end, date(20, 11))
        XCTAssertEqual(items[0].reminders, [date(20, 9, 45)])
    }
    func testCarriedItemMovesOnFromTheDayItShowsOn() {
        let item = PlanItem(title: "Call Mum", day: day(10))
        var items = [item], series: [RepeatingPlan] = []
        XCTAssertTrue(Planner.push(item.id, from: day(13), by: .day, items: &items, series: &series, calendar: calendar))
        XCTAssertEqual(items[0].day, day(14))
        XCTAssertNil(items[0].minute)
    }
    func testLinkedOccurrenceMovesAlone() throws {
        var template = PlanItem(title: "Standup", day: day(9), minute: 540, end: date(9, 10), movesToNextDay: false)
        template.repeatRule = .daily
        var series = [RepeatingPlan(template: template)], items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(9), through: day(15), calendar: calendar)
        let occurrence = try XCTUnwrap(items.first { $0.day == day(13) })
        let others = items.filter { $0.id != occurrence.id }
        XCTAssertTrue(Planner.push(occurrence.id, from: day(13), by: .day, items: &items, series: &series, calendar: calendar))
        let moved = try XCTUnwrap(items.first { $0.id == occurrence.id })
        XCTAssertNil(moved.seriesID)
        XCTAssertEqual(moved.repeatRule, .never)
        XCTAssertEqual(moved.start(calendar: calendar), date(14, 9))
        XCTAssertTrue(series[0].excludedDays.contains(day(13)))
        XCTAssertEqual(items.filter { $0.id != occurrence.id }, others)
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(9), through: day(15), calendar: calendar))
    }
    func testSettledAndMissingItemsStay() {
        var done = PlanItem(title: "Done", day: day(13))
        done.completedAt = date(13, 12)
        var items = [done], series: [RepeatingPlan] = []
        XCTAssertFalse(Planner.push(done.id, from: day(13), by: .day, items: &items, series: &series, calendar: calendar))
        XCTAssertFalse(Planner.push(UUID(), from: day(13), by: .day, items: &items, series: &series, calendar: calendar))
        XCTAssertEqual(items, [done])
    }
    func testUndoRestoresScheduleAndRemindersWithoutUndoingContentEdits() throws {
        for interval in PushInterval.allCases {
            let item = PlanItem(title: "Dentist", day: day(13), minute: 600, end: date(13, 11), reminders: [date(13, 9, 45)])
            let other = PlanItem(title: "Call", day: day(13))
            var items = [item, other], series: [RepeatingPlan] = []
            let before = (items: items, series: series)
            XCTAssertTrue(Planner.push(item.id, from: day(13), by: interval, items: &items, series: &series, calendar: calendar))
            let undo = try XCTUnwrap(Planner.pushUndo(for: item.id, before: before, after: (items, series)))
            items[0].title = "Dentist check-up"
            items[1].title = "Call Mum"
            Planner.undo(undo, items: &items, series: &series)
            XCTAssertEqual(items[0].day, item.day)
            XCTAssertEqual(items[0].end, item.end)
            XCTAssertEqual(items[0].reminders, item.reminders)
            XCTAssertEqual(items[0].title, "Dentist check-up")
            XCTAssertEqual(items[1].title, "Call Mum")
        }
    }
    func testUndoCarriedPushRestoresOriginalDayAndFullDayRange() throws {
        for ranged in [false, true] {
            var item = PlanItem(title: "Read", day: day(10))
            if ranged { item.endDay = day(12) }
            var items = [item], series: [RepeatingPlan] = []
            let before = (items: items, series: series)
            XCTAssertTrue(Planner.push(item.id, from: day(13), by: .week, items: &items, series: &series, calendar: calendar))
            let undo = try XCTUnwrap(Planner.pushUndo(for: item.id, before: before, after: (items, series)))
            Planner.undo(undo, items: &items, series: &series)
            XCTAssertEqual(items, before.items)
        }
    }
    func testUndoRejoinsSeriesAndKeepsOtherOccurrenceChanges() throws {
        var template = PlanItem(title: "Standup", day: day(9), minute: 540, end: date(9, 10), movesToNextDay: false)
        template.repeatRule = .daily
        var series = [RepeatingPlan(template: template)], items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(9), through: day(15), calendar: calendar)
        let original = try XCTUnwrap(items.first { $0.day == day(13) })
        let before = (items: items, series: series)
        XCTAssertTrue(Planner.push(original.id, from: day(13), by: .day, items: &items, series: &series, calendar: calendar))
        let undo = try XCTUnwrap(Planner.pushUndo(for: original.id, before: before, after: (items, series)))
        let another = try XCTUnwrap(items.first { $0.day == day(11) })
        XCTAssertTrue(Planner.push(another.id, from: day(11), by: .week, items: &items, series: &series, calendar: calendar))
        let movedOther = try XCTUnwrap(items.first { $0.id == another.id })
        Planner.undo(undo, items: &items, series: &series)
        XCTAssertEqual(items.first { $0.id == original.id }, original)
        XCTAssertFalse(series[0].excludedDays.contains(day(13)))
        XCTAssertTrue(series[0].excludedDays.contains(day(11)))
        XCTAssertEqual(items.first { $0.id == another.id }, movedOther)
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(9), through: day(15), calendar: calendar))
    }
    func testNoUndoOfferForUnchangedPushAndNoResurrectionAfterDeletion() throws {
        let item = PlanItem(title: "Read", day: day(13))
        var items = [item], series: [RepeatingPlan] = []
        let before = (items: items, series: series)
        XCTAssertNil(Planner.pushUndo(for: item.id, before: before, after: before))
        XCTAssertTrue(Planner.push(item.id, from: day(13), by: .day, items: &items, series: &series, calendar: calendar))
        let undo = try XCTUnwrap(Planner.pushUndo(for: item.id, before: before, after: (items, series)))
        items.removeAll()
        Planner.undo(undo, items: &items, series: &series)
        XCTAssertTrue(items.isEmpty)
    }

}
