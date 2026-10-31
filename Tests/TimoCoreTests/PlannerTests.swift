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
    func testUnfinishedTaskShowsOnTodayWithoutMovingItsSchedule() {
        let item = task(20, minute: 540)
        func day(_ d: Int) -> Day { Day(date(d), calendar: calendar) }
        XCTAssertEqual(item.liveDay(now: date(29), calendar: calendar), day(29))
        XCTAssertTrue(item.shows(on: day(29), now: date(29), calendar: calendar))
        XCTAssertFalse(item.shows(on: day(20), now: date(29), calendar: calendar))
        XCTAssertTrue(item.isCarried(now: date(29), calendar: calendar))
        // The schedule itself is untouched.
        XCTAssertEqual(item.day, day(20)); XCTAssertEqual(item.minute, 540)
    }
    func testEventsCompletedTasksAndFutureTasksStayPut() {
        var completed = task(20); completed.completedAt = date(20)
        let event = PlanItem(title: "Work", day: Day(date(20), calendar: calendar), minute: 540, end: date(20, 17), movesToNextDay: false)
        let future = task(30)
        for item in [completed, event, future] {
            XCTAssertEqual(item.liveDay(now: date(29), calendar: calendar), item.day)
            XCTAssertFalse(item.isCarried(now: date(29), calendar: calendar))
        }
    }
    func testMidnightAndDaylightSavingUseLocalDays() {
        // Amsterdam moves back to winter time on 25 October 2026.
        let item = task(24, minute: 540)
        XCTAssertEqual(item.liveDay(now: date(25, 0), calendar: calendar), Day(date(25), calendar: calendar))
        XCTAssertEqual(item.liveDay(now: date(25, 23), calendar: calendar), Day(date(25), calendar: calendar))
        XCTAssertEqual(item.liveDay(now: date(26, 0), calendar: calendar), Day(date(26), calendar: calendar))
        let utc = ISO8601DateFormatter().date(from: "2026-10-28T23:30:00Z")!
        XCTAssertEqual(task(28).liveDay(now: utc, calendar: calendar), Day(date(29), calendar: calendar))
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
        var item = task(20, minute: 540)
        let original = item.originalDay
        Planner.reschedule(&item, to: Day(date(30), calendar: calendar), minute: 1200)
        XCTAssertEqual(item.day, Day(date(30), calendar: calendar)); XCTAssertEqual(item.originalDay, original)
        let items = [item]
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
        XCTAssertEqual(flexible.liveDay(now: date(29), calendar: calendar), Day(date(29), calendar: calendar))
        XCTAssertEqual(fixedPoint.liveDay(now: date(29), calendar: calendar), day)
        XCTAssertEqual(fixedRange.liveDay(now: date(29), calendar: calendar), day)
    }
    func testOngoingOvernightRangeDoesNotCarryUntilItEnds() {
        let item = PlanItem(title: "Overnight", day: Day(date(28), calendar: calendar), minute: 23 * 60, end: date(29, 2))
        XCTAssertFalse(item.isCarried(now: date(29, 1), calendar: calendar))
        XCTAssertTrue(item.shows(on: Day(date(29), calendar: calendar), now: date(29, 1), calendar: calendar))
        XCTAssertTrue(item.isCarried(now: date(29, 3), calendar: calendar))
        XCTAssertTrue(item.movedAway(from: Day(date(28), calendar: calendar), now: date(29, 3), calendar: calendar))
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

    func testReminderPersistenceAndOlderItemsMigrate() throws {
        let item = PlanItem(title: "Read", day: Day(date(29), calendar: calendar), reminders: [date(29, 19), date(29, 20)])
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(PlanItem.self, from: data), item)
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedReminders = try XCTUnwrap(older.removeValue(forKey: "reminders") as? [Any])
        let unset = try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertEqual(unset.reminders, [])
        XCTAssertEqual(unset.id, item.id)
        // The single-reminder format becomes a one-element list.
        older["reminderAt"] = encodedReminders[1]
        let migrated = try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertEqual(migrated.reminders, [date(29, 20)])
    }
    func testDeadlinePersistsAndOnlyMarksUnfinishedItems() throws {
        var item = task(29)
        XCTAssertFalse(item.hasOpenDeadline)
        item.deadline = date(31, 17)
        XCTAssertEqual(try JSONDecoder().decode(PlanItem.self, from: JSONEncoder().encode(item)).deadline, date(31, 17))
        XCTAssertTrue(item.hasOpenDeadline)
        item.completedAt = date(30)
        XCTAssertFalse(item.hasOpenDeadline)
    }
    func testUpcomingReminderQueueExcludesPastAndCompletedAndKeepsNearest() {
        let day = Day(date(29), calendar: calendar)
        let first = PlanItem(title: "First", day: day, reminders: [date(29, 16), date(29, 13)])
        let later = PlanItem(title: "Later", day: day, reminders: [date(29, 14)])
        let past = PlanItem(title: "Past", day: day, reminders: [date(29, 10)])
        var completed = PlanItem(title: "Done", day: day, reminders: [date(29, 15)])
        completed.completedAt = date(29)
        let unset = PlanItem(title: "No reminder", day: day)
        let all = [later, past, completed, unset, first]
        func queue(_ now: Date, limit: Int = 64) -> [String] {
            Planner.upcomingReminders(in: all, now: now, limit: limit).map { "\($0.item.title) \(calendar.component(.hour, from: $0.date))" }
        }
        XCTAssertEqual(queue(date(29)), ["First 13", "Later 14", "First 16"])
        XCTAssertEqual(queue(date(29), limit: 1), ["First 13"])
        XCTAssertTrue(queue(date(29), limit: 0).isEmpty)
        XCTAssertEqual(queue(date(29, 13)), ["Later 14", "First 16"])
    }
    func testDisplayedReminderPrefersNextUpcoming() {
        let item = PlanItem(title: "Read", day: Day(date(29), calendar: calendar), reminders: [date(29, 18), date(29, 12), date(29, 15)])
        XCTAssertEqual(item.displayedReminder(now: date(29, 13)), date(29, 15))
        XCTAssertEqual(item.displayedReminder(now: date(29, 19)), date(29, 18))
        XCTAssertNil(PlanItem(title: "None", day: item.day).displayedReminder(now: date(29)))
    }
    func testMovingStartAlsoMovesRemindersAndRemovingTimeKeepsThem() {
        var item = PlanItem(title: "Read", day: Day(date(29), calendar: calendar), minute: 20 * 60, reminders: [date(29, 19), date(29, 18)])
        Planner.updateStart(&item, day: item.day, minute: 21 * 60, calendar: calendar)
        XCTAssertEqual(item.reminders, [date(29, 20), date(29, 19)])
        Planner.updateStart(&item, day: item.day, minute: nil, calendar: calendar)
        XCTAssertEqual(item.reminders, [date(29, 20), date(29, 19)])
        Planner.updateStart(&item, day: Day(date(30), calendar: calendar), minute: nil, calendar: calendar)
        XCTAssertEqual(item.reminders, [date(30, 20), date(30, 19)])
    }
    func testCarriedItemsOnlyRemindAboutUpcomingTimes() {
        let day = Day(date(28), calendar: calendar)
        let item = PlanItem(title: "Read", day: day, reminders: [date(28, 20), date(29, 18)])
        XCTAssertEqual(Planner.upcomingReminders(in: [item], now: date(29)).map(\.date), [date(29, 18)])
    }
    func testMultipleLocationsAndPeoplePersist() throws {
        let item = PlanItem(title: "Dinner", day: Day(date(28), calendar: calendar),
                            locations: ["Home", "Market, Amsterdam"], people: ["Mum", "Merel"])
        let decoded = try JSONDecoder().decode(PlanItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.locations, item.locations)
        XCTAssertEqual(decoded.people, item.people)
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
    func testCarriedItemStaysVisibleAsMovedOnEveryEarlierDay() {
        var item = task(20, minute: 540)
        func day(_ d: Int) -> Day { Day(date(d), calendar: calendar) }
        func moved(_ d: Int, now: Date) -> [UUID] { Planner.movedItems(from: day(d), in: [item], now: now, calendar: calendar).map(\.id) }
        XCTAssertEqual(moved(20, now: date(21)), [item.id])
        XCTAssertTrue(moved(21, now: date(21)).isEmpty)
        for d in 20...23 { XCTAssertEqual(moved(d, now: date(24)), [item.id], "day \(d)") }
        XCTAssertTrue(moved(19, now: date(24)).isEmpty)
        XCTAssertTrue(moved(24, now: date(24)).isEmpty)
        // Only the live day shows the item itself, so it is counted once.
        XCTAssertEqual((19...25).filter { item.shows(on: day($0), now: date(24), calendar: calendar) }, [24])
        // Completed on the 24th, it stays there and the trail shows it as done.
        item.completedAt = date(24)
        XCTAssertEqual((19...26).filter { item.shows(on: day($0), now: date(26), calendar: calendar) }, [24])
        XCTAssertEqual(moved(22, now: date(26)), [item.id])
        XCTAssertTrue(moved(25, now: date(26)).isEmpty)
    }
    func testCompletingOnTheScheduledDayEndsTheTrailThere() {
        // An event added after the fact, then ticked off on the day it happened.
        var item = PlanItem(title: "Tonsillectomy", day: Day(date(26), calendar: calendar))
        func day(_ d: Int) -> Day { Day(date(d), calendar: calendar) }
        let now = date(30, 15)
        XCTAssertEqual(item.liveDay(now: now, calendar: calendar), day(30))
        item.completedAt = Planner.completionDate(on: day(26), now: now, calendar: calendar)
        XCTAssertEqual(item.liveDay(now: now, calendar: calendar), day(26))
        XCTAssertEqual((25...31).filter { item.shows(on: day($0), now: now, calendar: calendar) }, [26])
        XCTAssertTrue((25...31).allSatisfy { !item.movedAway(from: day($0), now: now, calendar: calendar) })
        XCTAssertEqual(item.day, day(26))
        // Ticked off on the 28th instead, the 26th and 27th show where it went.
        item.completedAt = Planner.completionDate(on: day(28), now: now, calendar: calendar)
        XCTAssertEqual((25...31).filter { item.movedAway(from: day($0), now: now, calendar: calendar) }, [26, 27])
        XCTAssertEqual((25...31).filter { item.shows(on: day($0), now: now, calendar: calendar) }, [28])
    }
    func testCompletionDateFollowsTheViewedDay() {
        let now = date(30, 15)
        XCTAssertEqual(Planner.completionDate(on: Day(date(26), calendar: calendar), now: now, calendar: calendar), date(26, 15))
        XCTAssertEqual(Planner.completionDate(on: Day(date(30), calendar: calendar), now: now, calendar: calendar), now)
        XCTAssertEqual(Planner.completionDate(on: Day(date(31), calendar: calendar), now: now, calendar: calendar), now)
    }
    func testLegacyCarriedPlansGetTheirScheduledDayBack() {
        var moved = PlanItem(title: "Read", day: Day(date(29), calendar: calendar), minute: 20 * 60, end: date(29, 21))
        moved.carriedFrom = Day(date(20), calendar: calendar)
        let untouched = task(25)
        var items = [moved, untouched]
        XCTAssertTrue(Planner.restoreScheduledDays(&items, calendar: calendar))
        XCTAssertEqual(items[0].day, Day(date(20), calendar: calendar))
        XCTAssertEqual(items[0].minute, 20 * 60)
        XCTAssertEqual(items[0].end, date(20, 21))
        XCTAssertNil(items[0].carriedFrom)
        XCTAssertEqual(items[1], untouched)
        XCTAssertFalse(Planner.restoreScheduledDays(&items, calendar: calendar))
    }
    func testMovedEntriesSkipItemsThatNeverCarried() {
        var completed = task(20); completed.completedAt = date(20)
        let fixed = PlanItem(title: "Dentist", day: Day(date(20), calendar: calendar), minute: 540, movesToNextDay: false)
        let items = [completed, fixed, task(30)]
        for d in 19...30 { XCTAssertTrue(Planner.movedItems(from: Day(date(d), calendar: calendar), in: items, now: date(29), calendar: calendar).isEmpty) }
    }
    func testCarriedOvernightRangeShowsOnceOnItsLiveDay() {
        let item = PlanItem(title: "Overnight", day: Day(date(27), calendar: calendar), minute: 23 * 60, end: date(28, 2))
        let now = date(29, 3)
        func day(_ d: Int) -> Day { Day(date(d), calendar: calendar) }
        XCTAssertEqual((26...30).filter { item.movedAway(from: day($0), now: now, calendar: calendar) }, [27, 28])
        XCTAssertEqual((26...30).filter { item.shows(on: day($0), now: now, calendar: calendar) }, [29])
    }
    func testRescheduledItemsTakeTheirTrailAlong() {
        var item = task(20)
        let now = date(22)
        func day(_ d: Int) -> Day { Day(date(d), calendar: calendar) }
        XCTAssertTrue(item.movedAway(from: day(21), now: now, calendar: calendar))
        Planner.updateStart(&item, day: item.day, minute: 600, calendar: calendar)
        XCTAssertTrue(item.movedAway(from: day(21), now: now, calendar: calendar))
        // Planned for a later day, earlier days let it go.
        Planner.updateStart(&item, day: day(25), minute: 600, calendar: calendar)
        XCTAssertFalse(item.movedAway(from: day(21), now: now, calendar: calendar))
        XCTAssertEqual(item.liveDay(now: now, calendar: calendar), day(25))
    }
    func testMovedEntriesAddNoReminders() {
        var item = task(20); item.reminders = [date(23, 9)]
        XCTAssertEqual(Planner.upcomingReminders(in: [item], now: date(22)).count, 1)
    }
}
