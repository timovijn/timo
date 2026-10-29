import XCTest
@testable import TimoCore

final class PlannerTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }
    func date(_ day: Int, _ hour: Int = 12, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func task(_ day: Int, minute: Int? = nil) -> PlanItem { PlanItem(title: "Task", day: Day(date(day), calendar: calendar), minute: minute) }
    func testMissedDaysMoveExistingTaskToTodayAndClearTime() {
        let original = task(20, minute: 540); var items = [original]
        XCTAssertTrue(Planner.reconcile(&items, now: date(29), calendar: calendar))
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0].id, original.id)
        XCTAssertEqual(items[0].day, Day(date(29), calendar: calendar)); XCTAssertNil(items[0].minute)
        XCTAssertEqual(items[0].originalDay, original.day); XCTAssertEqual(items[0].carriedFrom, original.day)
        XCTAssertFalse(Planner.reconcile(&items, now: date(29), calendar: calendar))
        Planner.reconcile(&items, now: date(30), calendar: calendar)
        XCTAssertEqual(items[0].carriedFrom, original.day)
    }
    func testEventsCompletedTasksAndFutureTasksStayPut() {
        var completed = task(20); completed.completedAt = date(20)
        let event = PlanItem(kind: .event, title: "Work", day: Day(date(20), calendar: calendar), minute: 540, end: date(20, 17))
        let future = task(30); var items = [completed, event, future]
        XCTAssertFalse(Planner.reconcile(&items, now: date(29), calendar: calendar))
        XCTAssertEqual(items, [completed, event, future])
    }
    func testCarryOverKeepsCompletedParentAndPastEventLinks() {
        var parent = task(20); parent.completedAt = date(20)
        let event = PlanItem(kind: .event, title: "Dinner", day: Day(date(21), calendar: calendar), minute: 540, end: date(21, 17))
        var first = task(22); first.parentID = parent.id
        var second = task(23); second.parentID = event.id
        var items = [parent, event, first, second]
        Planner.reconcile(&items, now: date(29), calendar: calendar)
        XCTAssertEqual(items[2].parentID, parent.id); XCTAssertEqual(items[3].parentID, event.id)
        XCTAssertEqual(items[2].day, Day(date(29), calendar: calendar)); XCTAssertEqual(items[3].day, items[2].day)
        XCTAssertEqual(items[0], parent); XCTAssertEqual(items[1], event)
    }
    func testMidnightAndDaylightSavingUseLocalDays() {
        // Amsterdam moves back to winter time on 25 October 2026.
        var items = [task(24, minute: 540)]
        Planner.reconcile(&items, now: date(25, 0), calendar: calendar)
        XCTAssertEqual(items[0].day, Day(date(25), calendar: calendar))
        XCTAssertFalse(Planner.reconcile(&items, now: date(25, 23), calendar: calendar))
        XCTAssertTrue(Planner.reconcile(&items, now: date(26, 0), calendar: calendar))
        let utc = ISO8601DateFormatter().date(from: "2026-10-28T23:30:00Z")!
        items = [task(28)]
        Planner.reconcile(&items, now: utc, calendar: calendar)
        XCTAssertEqual(items[0].day, Day(date(29), calendar: calendar))
    }
    func testSuggestionsNeverCompleteAndUntimedTasksHaveNone() {
        let untimed = task(29); let timed = task(29, minute: 540)
        XCTAssertFalse(untimed.isElapsed(now: date(29), calendar: calendar))
        XCTAssertTrue(timed.isElapsed(now: date(29), calendar: calendar))
        XCTAssertFalse(timed.isComplete)
        var event = PlanItem(kind: .event, title: "Work", day: timed.day, minute: 540, end: date(29, 17))
        XCTAssertFalse(event.isElapsed(now: date(29), calendar: calendar))
        XCTAssertTrue(event.isElapsed(now: date(29, 18), calendar: calendar))
        event.completedAt = date(29, 18)
        XCTAssertFalse(event.isElapsed(now: date(29, 19), calendar: calendar))
    }
    func testIndependentSubtaskDayAndOvernightEvents() {
        let parent = task(30); var child = task(29); child.parentID = parent.id
        XCTAssertTrue(child.appears(on: Day(date(29), calendar: calendar), calendar: calendar))
        XCTAssertFalse(parent.appears(on: child.day, calendar: calendar))
        let event = PlanItem(kind: .event, title: "Overnight", day: child.day, minute: 23 * 60, end: date(30, 2))
        XCTAssertTrue(event.appears(on: child.day, calendar: calendar))
        XCTAssertTrue(event.appears(on: parent.day, calendar: calendar))
        XCTAssertFalse(event.appears(on: Day(date(31), calendar: calendar), calendar: calendar))
        let midnightEnd = PlanItem(kind: .event, title: "Until midnight", day: child.day, minute: 23 * 60, end: date(30, 0))
        XCTAssertFalse(midnightEnd.appears(on: parent.day, calendar: calendar))
    }
    func testParentValidationRejectsCyclesAndGrandchildren() throws {
        let parent = task(29); var child = task(29); child.parentID = parent.id
        try Planner.validate(child, in: [parent, child], calendar: calendar)
        var grandchild = task(29); grandchild.parentID = child.id
        XCTAssertThrowsError(try Planner.validate(grandchild, in: [parent, child], calendar: calendar))
        var cycle = parent; cycle.parentID = child.id
        XCTAssertThrowsError(try Planner.validate(cycle, in: [parent, child], calendar: calendar))
        cycle.parentID = cycle.id
        XCTAssertThrowsError(try Planner.validate(cycle, in: [parent], calendar: calendar))
        var other = task(29); other.parentID = UUID()
        XCTAssertThrowsError(try Planner.validate(other, in: [parent], calendar: calendar))
    }
    func testDeleteParentSupportsBothChoices() {
        let parent = task(29); var child = task(30); child.parentID = parent.id
        var items = [parent, child]; Planner.delete(parent.id, includingChildren: false, from: &items)
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0].id, child.id); XCTAssertNil(items[0].parentID)
        items = [parent, child]; Planner.delete(parent.id, includingChildren: true, from: &items)
        XCTAssertTrue(items.isEmpty)
    }
    func testSubtaskCompletionOnlySuggestsParentCompletion() {
        let parent = task(29); var child = task(29); child.parentID = parent.id
        XCTAssertFalse(Planner.suggestsParentCompletion(parent, in: [parent, child]))
        child.completedAt = date(29)
        XCTAssertTrue(Planner.suggestsParentCompletion(parent, in: [parent, child])); XCTAssertFalse(parent.isComplete)
        var completedParent = parent; completedParent.completedAt = date(29); child.completedAt = nil
        XCTAssertFalse(child.isComplete)
        XCTAssertFalse(Planner.suggestsParentCompletion(completedParent, in: [completedParent, child]))
    }
    func testReschedulingAndPersistenceRoundTrip() throws {
        var item = task(20, minute: 540); item.carriedFrom = item.day
        let original = item.originalDay
        Planner.reschedule(&item, to: Day(date(30), calendar: calendar), minute: 1200)
        XCTAssertNil(item.carriedFrom); XCTAssertEqual(item.originalDay, original)
        var items = [item]; XCTAssertFalse(Planner.reconcile(&items, now: date(29), calendar: calendar))
        let encoded = try JSONEncoder().encode(items)
        XCTAssertEqual(try JSONDecoder().decode([PlanItem].self, from: encoded), items)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plan.json")
        try encoded.write(to: file, options: .atomic)
        XCTAssertEqual(try JSONDecoder().decode([PlanItem].self, from: Data(contentsOf: file)), items)
    }
    func testInvalidEventAndEmptyTitle() {
        var event = PlanItem(kind: .event, title: "Work", day: Day(date(29), calendar: calendar), minute: 540, end: date(29, 8))
        XCTAssertThrowsError(try Planner.validate(event, in: [], calendar: calendar))
        event.end = date(29, 17)
        XCTAssertNoThrow(try Planner.validate(event, in: [], calendar: calendar))
        var empty = task(29); empty.title = "  \n"
        XCTAssertThrowsError(try Planner.validate(empty, in: [], calendar: calendar))
    }
}
