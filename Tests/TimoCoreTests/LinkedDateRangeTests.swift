import XCTest
@testable import TimoCore

final class LinkedDateRangeTests: XCTestCase {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }
    func date(_ d: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour))!
    }
    func day(_ d: Int) -> Day { Day(date(d), calendar: calendar) }
    func event() -> PlanItem { PlanItem(title: "Weekend", day: day(6), endDay: day(8), movesToNextDay: false) }
    func save(_ item: PlanItem, _ items: inout [PlanItem], _ series: inout [RepeatingPlan]) {
        Planner.saveDateRange(item, items: &items, series: &series, calendar: calendar)
    }
    func testCreatesSeparateLinkedFullDaysWithIndependentCompletion() throws {
        let original = event()
        var items: [PlanItem] = [], series: [RepeatingPlan] = []
        save(original, &items, &series)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.isDateRange, true)
        XCTAssertEqual(Set(items.map(\.day)), Set([day(6), day(7), day(8)]))
        XCTAssertTrue(items.allSatisfy { $0.endDay == $0.day && $0.minute == nil })
        XCTAssertEqual(items.first { $0.day == day(6) }?.id, original.id)
        XCTAssertTrue(items.allSatisfy { $0.seriesID == series.first?.id })
        let index = try XCTUnwrap(items.firstIndex { $0.day == day(7) })
        items[index].completedAt = date(7, 12)
        for d in 6...8 {
            let progress = DayProgress(items: items, day: day(d), now: date(7, 12), calendar: calendar)
            XCTAssertEqual(progress.total, 1)
            XCTAssertEqual(progress.done, d == 7 ? 1 : 0)
        }
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(5), through: day(12), calendar: calendar))
        XCTAssertEqual(items.count, 3)
    }
    func testWholeEventEditRetainsDailyCompletionAndCancellation() throws {
        var edited = event(), items: [PlanItem] = [], series: [RepeatingPlan] = []
        save(edited, &items, &series)
        let ids = Dictionary(uniqueKeysWithValues: items.map { ($0.day, $0.id) })
        items[try XCTUnwrap(items.firstIndex { $0.day == day(7) })].completedAt = date(7, 12)
        items[try XCTUnwrap(items.firstIndex { $0.day == day(8) })].cancelledAt = date(8, 12)
        edited.title = "Friends weekend"
        edited.notes = "Bring games"
        edited.endDay = day(9)
        save(edited, &items, &series)
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.allSatisfy { $0.title == edited.title && $0.notes == edited.notes })
        for d in 6...8 { XCTAssertEqual(items.first { $0.day == day(d) }?.id, ids[day(d)]) }
        XCTAssertTrue(try XCTUnwrap(items.first { $0.day == day(7) }).isComplete)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.day == day(8) }).isCancelled)
        XCTAssertFalse(try XCTUnwrap(items.first { $0.day == day(9) }).isSettled)
        XCTAssertEqual(Planner.dateRange(of: try XCTUnwrap(items.first), in: series, calendar: calendar), day(6)...day(9))
        edited.endDay = day(7)
        save(edited, &items, &series)
        XCTAssertEqual(Set(items.map(\.day)), Set([day(6), day(7)]))
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(8), through: day(10), calendar: calendar))
    }
    func testMigrationPreservesOriginalAndCompletedStatesAndReminderDates() throws {
        var old = event()
        old.completedAt = date(8, 14)
        old.reminders = [date(6, 9), date(7, 9), date(8, 9)]
        old.deadline = date(8, 17)
        var items = [old], series: [RepeatingPlan] = []
        XCTAssertTrue(Planner.splitDateRanges(items: &items, series: &series, calendar: calendar))
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy(\.isComplete))
        XCTAssertEqual(items.first { $0.day == day(6) }?.id, old.id)
        XCTAssertEqual(items.flatMap(\.reminders).sorted(), old.reminders)
        XCTAssertEqual(items.compactMap(\.deadline), [old.deadline!])
        XCTAssertFalse(Planner.splitDateRanges(items: &items, series: &series, calendar: calendar))
        XCTAssertEqual(items.count, 3)
        let middle = try XCTUnwrap(items.firstIndex { $0.day == day(7) })
        items[middle].completedAt = nil
        XCTAssertEqual(items.filter(\.isComplete).count, 2)
    }
    func testSingleDayEditDetachesAndGroupEditLeavesItAlone() throws {
        let original = event()
        var items: [PlanItem] = [], series: [RepeatingPlan] = []
        save(original, &items, &series)
        var middle = try XCTUnwrap(items.first { $0.day == day(7) })
        middle.title = "A different plan"
        Planner.detach(middle, items: &items, series: &series, calendar: calendar)
        var edited = original
        edited.title = "Updated weekend"
        save(edited, &items, &series)
        XCTAssertEqual(items.first { $0.id == middle.id }?.title, "A different plan")
        XCTAssertNil(items.first { $0.id == middle.id }?.seriesID)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.filter { $0.title == "Updated weekend" }.count, 2)
    }
    func testPersistenceAndLegacySeriesCompatibility() throws {
        var items: [PlanItem] = [], series: [RepeatingPlan] = []
        save(event(), &items, &series)
        XCTAssertEqual(try JSONDecoder().decode([PlanItem].self, from: JSONEncoder().encode(items)), items)
        XCTAssertEqual(try JSONDecoder().decode([RepeatingPlan].self, from: JSONEncoder().encode(series)), series)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(series[0])) as? [String: Any])
        object.removeValue(forKey: "isDateRange")
        XCTAssertNil(try JSONDecoder().decode(RepeatingPlan.self, from: JSONSerialization.data(withJSONObject: object)).isDateRange)
    }
    func testMigrationOnTwoDevicesDerivesTheSameGroupAndItemIDs() {
        let original = event()
        var firstItems = [original], secondItems = [original]
        var firstSeries: [RepeatingPlan] = [], secondSeries: [RepeatingPlan] = []
        Planner.splitDateRanges(items: &firstItems, series: &firstSeries, calendar: calendar)
        Planner.splitDateRanges(items: &secondItems, series: &secondSeries, calendar: calendar)
        XCTAssertEqual(firstSeries.map(\.id), secondSeries.map(\.id))
        XCTAssertEqual(Set(firstItems.map(\.id)), Set(secondItems.map(\.id)))
    }
    func testOrdinaryMetadataSavePreservesDateRangeGroup() throws {
        let original = event()
        var items: [PlanItem] = [], series: [RepeatingPlan] = []
        save(original, &items, &series)
        var stored = try XCTUnwrap(items.first { $0.id == original.id })
        stored.notes = "Updated details"
        Planner.saveRepeating(stored, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(series.first?.isDateRange, true)
        XCTAssertEqual(Planner.dateRange(of: stored, in: series, calendar: calendar), day(6)...day(8))
        XCTAssertTrue(items.allSatisfy { $0.notes == stored.notes })
    }
    func testMovingGroupKeepsDailyStateAndShiftsBounds() throws {
        var original = event(), items: [PlanItem] = [], series: [RepeatingPlan] = []
        save(original, &items, &series)
        let middle = try XCTUnwrap(items.firstIndex { $0.day == day(7) })
        let completedID = items[middle].id
        items[middle].completedAt = date(7, 12)
        Planner.updateStart(&original, day: day(13), minute: nil, calendar: calendar)
        save(original, &items, &series)
        XCTAssertEqual(Set(items.map(\.day)), Set([day(13), day(14), day(15)]))
        XCTAssertEqual(items.first { $0.id == completedID }?.day, day(14))
        XCTAssertTrue(try XCTUnwrap(items.first { $0.id == completedID }).isComplete)
    }
}
