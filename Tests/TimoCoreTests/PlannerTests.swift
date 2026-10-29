import XCTest
@testable import TimoCore

final class PlannerTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }
    func date(_ day: Int, _ hour: Int = 12, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func task(_ day: Int, minute: Int? = nil) -> PlanItem { PlanItem(title: "Task", day: Day(date(day), calendar: calendar), minute: minute) }
    func testInProgressUsesStartInclusiveAndEndExclusive() {
        let item = PlanItem(title: "Work", day: Day(date(29), calendar: calendar), minute: 540, end: date(29, 17))
        XCTAssertFalse(item.isInProgress(now: date(29, 8), calendar: calendar))
        XCTAssertTrue(item.isInProgress(now: date(29, 9), calendar: calendar))
        XCTAssertTrue(item.isInProgress(now: date(29, 12), calendar: calendar))
        XCTAssertFalse(item.isInProgress(now: date(29, 17), calendar: calendar))
        XCTAssertFalse(task(29, minute: 540).isInProgress(now: date(29, 9), calendar: calendar))
        XCTAssertFalse(task(29).isInProgress(now: date(29), calendar: calendar))
    }
    func testInProgressHandlesOvernightAndCompletedRanges() {
        var overnight = PlanItem(title: "Overnight", day: Day(date(29), calendar: calendar), minute: 23 * 60, end: date(30, 2))
        XCTAssertTrue(overnight.isInProgress(now: date(30, 1), calendar: calendar))
        XCTAssertFalse(overnight.isInProgress(now: date(30, 2), calendar: calendar))
        overnight.completedAt = date(30, 1)
        XCTAssertFalse(overnight.isInProgress(now: date(30, 1), calendar: calendar))
        let zeroLength = PlanItem(title: "Point", day: Day(date(29), calendar: calendar), minute: 540, end: date(29, 9))
        XCTAssertFalse(zeroLength.isInProgress(now: date(29, 9), calendar: calendar))
    }
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
        let event = PlanItem(title: "Work", day: Day(date(20), calendar: calendar), minute: 540, end: date(20, 17), movesToNextDay: false)
        let future = task(30); var items = [completed, event, future]
        XCTAssertFalse(Planner.reconcile(&items, now: date(29), calendar: calendar))
        XCTAssertEqual(items, [completed, event, future])
    }
    func testCarryOverKeepsCompletedParentAndPastEventLinks() {
        var parent = task(20); parent.completedAt = date(20)
        let event = PlanItem(title: "Dinner", day: Day(date(21), calendar: calendar), minute: 540, end: date(21, 17), movesToNextDay: false)
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
        var event = PlanItem(title: "Work", day: timed.day, minute: 540, end: date(29, 17))
        XCTAssertFalse(event.isElapsed(now: date(29), calendar: calendar))
        XCTAssertTrue(event.isElapsed(now: date(29, 18), calendar: calendar))
        event.completedAt = date(29, 18)
        XCTAssertFalse(event.isElapsed(now: date(29, 19), calendar: calendar))
    }
    func testIndependentSubtaskDayAndOvernightEvents() {
        let parent = task(30); var child = task(29); child.parentID = parent.id
        XCTAssertTrue(child.appears(on: Day(date(29), calendar: calendar), calendar: calendar))
        XCTAssertFalse(parent.appears(on: child.day, calendar: calendar))
        let event = PlanItem(title: "Overnight", day: child.day, minute: 23 * 60, end: date(30, 2))
        XCTAssertTrue(event.appears(on: child.day, calendar: calendar))
        XCTAssertTrue(event.appears(on: parent.day, calendar: calendar))
        XCTAssertFalse(event.appears(on: Day(date(31), calendar: calendar), calendar: calendar))
        let midnightEnd = PlanItem(title: "Until midnight", day: child.day, minute: 23 * 60, end: date(30, 0))
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
        var event = PlanItem(title: "Work", day: Day(date(29), calendar: calendar), minute: 540, end: date(29, 8))
        XCTAssertThrowsError(try Planner.validate(event, in: [], calendar: calendar))
        event.end = date(29, 17)
        XCTAssertNoThrow(try Planner.validate(event, in: [], calendar: calendar))
        var empty = task(29); empty.title = "  \n"
        XCTAssertThrowsError(try Planner.validate(empty, in: [], calendar: calendar))
    }
    func testCarryOverIsIndependentOfDuration() {
        let day = Day(date(20), calendar: calendar)
        let flexible = PlanItem(title: "Read", day: day, minute: 20 * 60, end: date(20, 21))
        let fixedPoint = PlanItem(title: "Call", day: day, minute: 9 * 60, movesToNextDay: false)
        let fixedRange = PlanItem(title: "Appointment", day: day, minute: 9 * 60, end: date(20, 10), movesToNextDay: false)
        var items = [flexible, fixedPoint, fixedRange]
        Planner.reconcile(&items, now: date(29), calendar: calendar)
        XCTAssertEqual(items[0].day, Day(date(29), calendar: calendar))
        XCTAssertEqual(items[0].minute, 20 * 60)
        XCTAssertEqual(items[0].end, date(29, 21))
        XCTAssertEqual(items[0].carriedFrom, day)
        XCTAssertEqual(items[1], fixedPoint)
        XCTAssertEqual(items[2], fixedRange)
    }
    func testOngoingOvernightRangeDoesNotCarryUntilItEnds() {
        let item = PlanItem(title: "Overnight", day: Day(date(28), calendar: calendar), minute: 23 * 60, end: date(29, 2))
        var items = [item]
        XCTAssertFalse(Planner.reconcile(&items, now: date(29, 1), calendar: calendar))
        XCTAssertEqual(items[0], item)
        XCTAssertTrue(Planner.reconcile(&items, now: date(29, 3), calendar: calendar))
        XCTAssertEqual(items[0].end, date(30, 2))
    }
    func testChangingStartPreservesDurationAndRemovingTimeClearsEnd() throws {
        var item = PlanItem(title: "Read", day: Day(date(24), calendar: calendar), minute: 23 * 60, end: date(25, 0))
        Planner.updateStart(&item, day: Day(date(25), calendar: calendar), minute: 20 * 60, calendar: calendar)
        XCTAssertEqual(item.end, date(25, 21))
        XCTAssertNoThrow(try Planner.validate(item, in: [], calendar: calendar))
        Planner.updateStart(&item, day: item.day, minute: nil, calendar: calendar)
        XCTAssertNil(item.minute); XCTAssertNil(item.end)
        XCTAssertTrue(item.movesToNextDay)
    }
    func testRangesCanBeLinkedAndSuggestParentCompletion() throws {
        let parent = PlanItem(title: "Dinner", day: Day(date(29), calendar: calendar), minute: 19 * 60, end: date(29, 20))
        var child = PlanItem(title: "Cook", day: parent.day, minute: 18 * 60, end: date(29, 19), parentID: parent.id)
        XCTAssertNoThrow(try Planner.validate(child, in: [parent, child], calendar: calendar))
        child.completedAt = date(29, 19)
        XCTAssertTrue(Planner.suggestsParentCompletion(parent, in: [parent, child]))
    }
    func testLegacyItemsMigrateWithoutLosingIdentityOrSchedule() throws {
        let original = PlanItem(title: "Existing", day: Day(date(29), calendar: calendar), minute: 540, end: date(29, 10))
        let encoded = try JSONEncoder().encode(original)
        for kind in ["task", "event"] {
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            legacy.removeValue(forKey: "movesToNextDay")
            legacy["kind"] = kind
            let decoded = try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertEqual(decoded.id, original.id)
            XCTAssertEqual(decoded.day, original.day)
            XCTAssertEqual(decoded.minute, original.minute)
            XCTAssertEqual(decoded.end, original.end)
            XCTAssertEqual(decoded.movesToNextDay, kind == "task")
            let newData = try JSONEncoder().encode(decoded)
            XCTAssertEqual(try JSONDecoder().decode(PlanItem.self, from: newData), decoded)
            let newJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: newData) as? [String: Any])
            XCTAssertNil(newJSON["kind"])
        }
    }
    func testEndWithoutStartAndOutOfRangeMinutesAreRejected() {
        let day = Day(date(29), calendar: calendar)
        let missingStart = PlanItem(title: "Read", day: day, end: date(29, 20))
        XCTAssertThrowsError(try Planner.validate(missingStart, in: [], calendar: calendar))
        let invalidTime = PlanItem(title: "Read", day: day, minute: 1440)
        XCTAssertThrowsError(try Planner.validate(invalidTime, in: [], calendar: calendar))
    }

    func testReminderPersistenceAndOlderItemsDefaultToNoReminder() throws {
        let item = PlanItem(title: "Read", day: Day(date(29), calendar: calendar), reminderAt: date(29, 20))
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(PlanItem.self, from: data), item)
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        older.removeValue(forKey: "reminderAt")
        let migrated = try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertNil(migrated.reminderAt)
        XCTAssertEqual(migrated.id, item.id)
    }
    func testUpcomingReminderQueueExcludesPastAndCompletedAndKeepsNearest() {
        let day = Day(date(29), calendar: calendar)
        let first = PlanItem(title: "First", day: day, reminderAt: date(29, 13))
        let later = PlanItem(title: "Later", day: day, reminderAt: date(29, 14))
        let past = PlanItem(title: "Past", day: day, reminderAt: date(29, 10))
        var completed = PlanItem(title: "Done", day: day, reminderAt: date(29, 15))
        completed.completedAt = date(29)
        let unset = PlanItem(title: "No reminder", day: day)
        let all = [later, past, completed, unset, first]
        XCTAssertEqual(Planner.upcomingReminders(in: all, now: date(29)), [first, later])
        XCTAssertEqual(Planner.upcomingReminders(in: all, now: date(29), limit: 1), [first])
        XCTAssertTrue(Planner.upcomingReminders(in: all, now: date(29), limit: 0).isEmpty)
        XCTAssertEqual(Planner.upcomingReminders(in: all, now: date(29, 13)), [later])
    }
    func testMovingStartAlsoMovesReminderAndRemovingTimeKeepsReminder() {
        var item = PlanItem(title: "Read", day: Day(date(29), calendar: calendar), minute: 20 * 60, reminderAt: date(29, 19))
        Planner.updateStart(&item, day: item.day, minute: 21 * 60, calendar: calendar)
        XCTAssertEqual(item.reminderAt, date(29, 20))
        Planner.updateStart(&item, day: item.day, minute: nil, calendar: calendar)
        XCTAssertEqual(item.reminderAt, date(29, 20))
        Planner.updateStart(&item, day: Day(date(30), calendar: calendar), minute: nil, calendar: calendar)
        XCTAssertEqual(item.reminderAt, date(30, 20))
    }
    func testCarryOverDoesNotReplayExpiredReminders() {
        let day = Day(date(28), calendar: calendar)
        let expired = PlanItem(title: "Read", day: day, reminderAt: date(28, 20))
        let upcoming = PlanItem(title: "Call", day: day, reminderAt: date(29, 18))
        var items = [expired, upcoming]
        Planner.reconcile(&items, now: date(29), calendar: calendar)
        XCTAssertNil(items[0].reminderAt)
        XCTAssertEqual(items[1].reminderAt, date(29, 18))
    }

    func testMultipleLocationsAndPeoplePersistAndSurviveCarryOver() throws {
        let item = PlanItem(title: "Dinner", day: Day(date(28), calendar: calendar),
                            locations: ["Home", "Market, Amsterdam"], people: ["Mum", "Merel"])
        let encoded = try JSONEncoder().encode(item)
        var decoded = try JSONDecoder().decode(PlanItem.self, from: encoded)
        XCTAssertEqual(decoded, item)
        var items = [decoded]
        Planner.reconcile(&items, now: date(29), calendar: calendar)
        decoded = items[0]
        XCTAssertEqual(decoded.locations, item.locations)
        XCTAssertEqual(decoded.people, item.people)
        XCTAssertEqual(decoded.id, item.id)
        XCTAssertEqual(decoded.day, Day(date(29), calendar: calendar))
    }
    func testExistingItemsWithoutLocationsOrPeopleStillOpen() throws {
        let original = PlanItem(title: "Existing", day: Day(date(29), calendar: calendar))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        old.removeValue(forKey: "locations")
        old.removeValue(forKey: "people")
        let decoded = try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(decoded.locations.isEmpty)
        XCTAssertTrue(decoded.people.isEmpty)
        XCTAssertEqual(decoded, original)
    }

}
