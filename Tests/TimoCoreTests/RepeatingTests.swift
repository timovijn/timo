import XCTest
@testable import TimoCore

final class RepeatingTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return value
    }
    func date(_ day: Int, hour: Int = 9, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func day(_ value: Int, month: Int = 10) -> Day { Day(date(value, month: month), calendar: calendar) }
    func template(_ rule: RepeatRule, day value: Int = 26) -> PlanItem {
        var item = PlanItem(title: "Work", day: day(value), minute: 540, end: date(value, hour: 17), movesToNextDay: false)
        item.repeatRule = rule
        return item
    }
    func testWeekdaysSkipWeekendAndRevisitingDoesNotDuplicateOrResetCompletion() {
        let plan = RepeatingPlan(template: template(.weekdays))
        var items: [PlanItem] = []
        XCTAssertTrue(Planner.materialize([plan], in: &items, from: day(26), through: day(1, month: 11), calendar: calendar))
        XCTAssertEqual(items.map(\.day), (26...30).map { day($0) })
        items[0].completedAt = date(26, hour: 18)
        let saved = items
        XCTAssertFalse(Planner.materialize([plan], in: &items, from: day(26), through: day(1, month: 11), calendar: calendar))
        XCTAssertEqual(items, saved)
        XCTAssertFalse(items[1].isComplete)
    }
    func testOccurrencesAreDueAsLongAfterTheirOwnDay() {
        var item = template(.daily)
        item.deadline = date(27, hour: 12)
        var items: [PlanItem] = []
        Planner.materialize([RepeatingPlan(template: item)], in: &items, from: day(26), through: day(28), calendar: calendar)
        XCTAssertEqual(items.map(\.deadline), [date(27, hour: 12), date(28, hour: 12), date(29, hour: 12)])
    }
    func testWeeklyCustomAndDailyPatterns() {
        for (rule, weekdays, expected) in [
            (RepeatRule.daily, [], [26, 27, 28, 29, 30, 31]),
            (.weekly, [], [26]),
            (.custom, [2, 4, 6], [26, 28, 30])
        ] {
            var item = template(rule); item.repeatWeekdays = weekdays
            let plan = RepeatingPlan(template: item)
            var items: [PlanItem] = []
            Planner.materialize([plan], in: &items, from: day(26), through: day(31), calendar: calendar)
            XCTAssertEqual(items.map(\.day), expected.map { day($0) })
        }
    }
    func testDistantDayCanBeGeneratedWithoutFillingIntermediateYears() {
        let plan = RepeatingPlan(template: template(.daily))
        var items: [PlanItem] = []
        let future = Day(calendar.date(from: DateComponents(year: 2030, month: 2, day: 1))!, calendar: calendar)
        Planner.materialize([plan], in: &items, from: future, through: future, calendar: calendar)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].day, future)
        XCTAssertEqual(items[0].originalDay, future)
    }
    func testTimeDurationReminderAndDetailsAcrossDST() {
        var item = template(.daily, day: 24)
        item.reminders = [date(24, hour: 8)]
        item.people = ["Timo"]; item.locations = ["Office"]
        let plan = RepeatingPlan(template: item)
        var items: [PlanItem] = []
        Planner.materialize([plan], in: &items, from: day(24), through: day(26), calendar: calendar)
        for occurrence in items {
            XCTAssertEqual(calendar.component(.hour, from: occurrence.start(calendar: calendar)!), 9)
            XCTAssertEqual(calendar.component(.hour, from: occurrence.end!), 17)
            XCTAssertEqual(calendar.component(.hour, from: occurrence.reminders[0]), 8)
            XCTAssertEqual(occurrence.people, item.people)
            XCTAssertEqual(occurrence.locations, item.locations)
            XCTAssertNil(occurrence.carriedFrom)
        }
        XCTAssertEqual(Set(items.map(\.id)).count, 3)
    }
    func testScheduledRepeatingOccurrencesStayOnTheirScheduledDays() {
        let plan = RepeatingPlan(template: template(.daily))
        var items: [PlanItem] = []
        Planner.materialize([plan], in: &items, from: day(26), through: day(28), calendar: calendar)
        XCTAssertEqual(items.map { $0.liveDay(now: date(29), calendar: calendar) }, [day(26), day(27), day(28)])
    }
    func testCarryPreferenceIsPreservedForEveryRepeatingSchedule() throws {
        for timed in [false, true] {
            for carries in [false, true] {
                var master = PlanItem(title: "Read", day: day(26), minute: timed ? 540 : nil, movesToNextDay: carries)
                master.repeatRule = .daily
                var series: [RepeatingPlan] = []
                var items: [PlanItem] = []
                Planner.saveRepeating(master, items: &items, series: &series, calendar: calendar)
                Planner.materialize(series, in: &items, from: day(26), through: day(28), calendar: calendar)
                XCTAssertEqual(series[0].template.carries, carries)
                XCTAssertTrue(items.allSatisfy { $0.carries == carries })
                XCTAssertEqual(items[0].liveDay(now: date(30), calendar: calendar), carries ? day(30) : day(26))
                var edited = items[0]
                edited.movesToNextDay = !carries
                Planner.saveRepeating(edited, items: &items, series: &series, calendar: calendar)
                XCTAssertEqual(series[0].template.carries, !carries)
                XCTAssertTrue(items.allSatisfy { $0.carries == !carries })
                let saved = try JSONDecoder().decode([PlanItem].self, from: JSONEncoder().encode(items))
                XCTAssertEqual(saved, items)
                Planner.materialize(series, in: &items, from: day(29), through: day(29), calendar: calendar)
                XCTAssertEqual(items.last?.carries, !carries)
            }
        }
    }
    func testAnytimeRepeatsCarryIndependentlyUntilCompletedOrCancelled() throws {
        var template = PlanItem(title: "Read", day: day(26))
        template.repeatRule = .daily
        let plan = RepeatingPlan(template: template)
        var items: [PlanItem] = []
        Planner.materialize([plan], in: &items, from: day(26), through: day(29), calendar: calendar)
        let firstID = items[0].id
        XCTAssertTrue(items[0].movesToNextDay)
        XCTAssertTrue(items[0].carries)
        for today in [27, 28, 29] {
            XCTAssertTrue(items[0].shows(on: day(today), now: date(today), calendar: calendar))
            XCTAssertTrue(items[0].isCarried(now: date(today), calendar: calendar))
            XCTAssertEqual(items[0].day, day(26))
            XCTAssertEqual(items[0].occurrenceDay, day(26))
        }
        XCTAssertEqual(items.filter { $0.shows(on: day(29), now: date(29), calendar: calendar) }.count, 4)
        XCTAssertTrue(items[0].movedAway(from: day(28), now: date(29), calendar: calendar))
        items[0].completedAt = date(29)
        Planner.setCancelled(true, &items[1], on: day(28), now: date(29), calendar: calendar)
        XCTAssertFalse(items[0].shows(on: day(30), now: date(30), calendar: calendar))
        XCTAssertTrue(items[0].shows(on: day(29), now: date(30), calendar: calendar))
        XCTAssertFalse(items[1].shows(on: day(29), now: date(30), calendar: calendar))
        XCTAssertTrue(items[1].shows(on: day(28), now: date(30), calendar: calendar))
        XCTAssertTrue(items[2].shows(on: day(30), now: date(30), calendar: calendar))
        let saved = try JSONDecoder().decode([PlanItem].self, from: JSONEncoder().encode(items))
        XCTAssertEqual(saved, items)
        XCTAssertFalse(Planner.materialize([plan], in: &items, from: day(26), through: day(29), calendar: calendar))
        XCTAssertEqual(items[0].id, firstID)
        XCTAssertEqual(items, saved)
    }
    func testEditingAnytimeSeriesPreservesCarriedOccurrencesAndTheirSettlement() throws {
        var master = PlanItem(title: "Read", day: day(26))
        master.repeatRule = .daily
        var series: [RepeatingPlan] = []
        var items: [PlanItem] = []
        Planner.saveRepeating(master, items: &items, series: &series, calendar: calendar)
        Planner.materialize(series, in: &items, from: day(26), through: day(28), calendar: calendar)
        items[1].completedAt = date(28)
        Planner.setCancelled(true, &items[2], on: day(28), now: date(29), calendar: calendar)
        let original = items
        master = items[0]
        master.title = "Read a chapter"
        Planner.saveRepeating(master, items: &items, series: &series, calendar: calendar)
        for previous in original {
            let updated = try XCTUnwrap(items.first { $0.id == previous.id })
            XCTAssertEqual(updated.title, master.title)
            XCTAssertEqual(updated.day, previous.day)
            XCTAssertEqual(updated.occurrenceDay, previous.occurrenceDay)
            XCTAssertEqual(updated.completedAt, previous.completedAt)
            XCTAssertEqual(updated.cancelledAt, previous.cancelledAt)
            XCTAssertTrue(updated.carries)
        }
        XCTAssertTrue(items[0].isCarried(now: date(30), calendar: calendar))
    }
    func testLegacyExclusionsPersistAndDeletingSeriesStopsAllGeneration() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar)
        // An occurrence deleted by an older app version stays excluded.
        series[0].excludedDays = [day(27)]
        items.removeAll { $0.day == day(27) }
        // Round-trip the series and items just as the saved plan does.
        series = try JSONDecoder().decode([RepeatingPlan].self, from: JSONEncoder().encode(series))
        items = try JSONDecoder().decode([PlanItem].self, from: JSONEncoder().encode(items))
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar))
        XCTAssertFalse(items.contains { $0.day == day(27) })
        let target = try XCTUnwrap(items.first { $0.day == day(28) })
        Planner.deleteSeries(target, items: &items, series: &series)
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(26), through: day(31), calendar: calendar))
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(series.isEmpty)
    }
    func testEditUpdatesWholeSeriesAndPreservesIndependentCompletions() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar)
        items[0].completedAt = date(26, hour: 18)
        items[4].completedAt = date(26, hour: 18)
        let past = items[0], completedFuture = items[4]
        var edited = items[2]; edited.title = "Office work"
        Planner.saveRepeating(edited, items: &items, series: &series)
        Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar)
        XCTAssertEqual(items.first { $0.id == past.id }?.title, "Office work")
        XCTAssertEqual(items.first { $0.id == past.id }?.completedAt, past.completedAt)
        XCTAssertTrue(items.allSatisfy { $0.title == "Office work" })
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(items.filter { $0.day == day(30) }.count, 1)
        XCTAssertEqual(items.first { $0.id == completedFuture.id }?.completedAt, completedFuture.completedAt)
        XCTAssertEqual(items.first { $0.day == day(29) }?.title, "Office work")
        XCTAssertFalse(try XCTUnwrap(items.first { $0.day == day(29) }).isComplete)
    }
    func testRemovingRepeatFromTheFirstOccurrenceKeepsOnlyIt() {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar)
        var edited = items[0]; edited.repeatRule = .never
        Planner.saveRepeating(edited, items: &items, series: &series)
        Planner.materialize(series, in: &items, from: day(26), through: day(31), calendar: calendar)
        XCTAssertEqual(items.map(\.day), [day(26)])
        XCTAssertTrue(series.isEmpty)
        XCTAssertNil(items.first { $0.id == edited.id }?.seriesID)
    }
    func testWeekdaySeriesStartsOnMondayWhenCreatedOnSaturday() {
        let item = template(.weekdays, day: 31)
        var items: [PlanItem] = []
        var series: [RepeatingPlan] = []
        Planner.saveRepeating(item, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].day, day(2, month: 11))
        XCTAssertEqual(items[0].minute, 540)
        XCTAssertEqual(items[0].end, date(2, hour: 17, month: 11))
        Planner.materialize(series, in: &items, from: day(31), through: day(8, month: 11), calendar: calendar)
        XCTAssertEqual(items.count, 5)
    }
    func testRepeatedEditsAlwaysUpdateEveryOccurrenceWithoutDuplicates() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(31), calendar: calendar)
        var later = try XCTUnwrap(items.first { $0.day == day(29) }); later.title = "First edit"
        Planner.saveRepeating(later, items: &items, series: &series, calendar: calendar)
        Planner.materialize(series, in: &items, from: day(26), through: day(31), calendar: calendar)
        var earlier = try XCTUnwrap(items.first { $0.day == day(27) }); earlier.title = "Second edit"
        Planner.saveRepeating(earlier, items: &items, series: &series, calendar: calendar)
        Planner.materialize(series, in: &items, from: day(26), through: day(31), calendar: calendar)
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.map(\.title), Array(repeating: "Second edit", count: 6))
        XCTAssertEqual(series.count, 1)
        let past = try XCTUnwrap(items.first { $0.day == day(26) })
        Planner.deleteSeries(past, items: &items, series: &series)
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(26), through: day(31), calendar: calendar))
        XCTAssertTrue(items.isEmpty)
    }
    func testSharedTimeDetailsAndRemindersUpdatePastAndFutureWithoutChangingIDs() throws {
        var series = [RepeatingPlan(template: template(.daily, day: 24))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(24), through: day(29), calendar: calendar)
        let originalIDs = Set(items.map(\.id))
        items[0].completedAt = date(24, hour: 18)
        var edited = items[3]
        edited.title = "New work"
        edited.notes = "Shared notes"
        edited.people = ["Timo"]
        edited.locations = ["Office"]
        Planner.updateStart(&edited, day: edited.day, minute: 600, calendar: calendar)
        edited.end = date(27, hour: 18)
        edited.reminders = [date(27, hour: 9)]
        Planner.saveRepeating(edited, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(Set(items.map(\.id)), originalIDs)
        for item in items {
            XCTAssertEqual(item.title, edited.title)
            XCTAssertEqual(item.notes, edited.notes)
            XCTAssertEqual(item.people, edited.people)
            XCTAssertEqual(item.locations, edited.locations)
            XCTAssertEqual(item.minute, 600)
            XCTAssertEqual(calendar.component(.hour, from: item.end!), 18)
            XCTAssertEqual(calendar.component(.hour, from: item.reminders[0]), 9)
        }
        XCTAssertNotNil(items.first { $0.day == day(24) }?.completedAt)
        XCTAssertFalse(items.first { $0.day == day(28) }!.isComplete)
        Planner.materialize(series, in: &items, from: day(30), through: day(30), calendar: calendar)
        let future = try XCTUnwrap(items.first { $0.day == day(30) })
        XCTAssertEqual(future.notes, edited.notes)
        XCTAssertEqual(future.minute, 600)
        XCTAssertFalse(future.isComplete)
    }
    func testRepeatPatternChangesWholeSeriesAndDayChangesShiftEveryOccurrence() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(1, month: 11), calendar: calendar)
        // The first occurrence changes the pattern of the whole series; a later one would split off.
        var edited = try XCTUnwrap(items.first { $0.day == day(26) })
        edited.repeatRule = .weekdays
        Planner.saveRepeating(edited, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(Set(items.map(\.day)), Set((26...30).map { day($0) }))
        XCTAssertEqual(series[0].template.day, day(26))
        edited = try XCTUnwrap(items.first { $0.day == day(28) })
        Planner.updateStart(&edited, day: day(29), minute: edited.minute, calendar: calendar)
        Planner.saveRepeating(edited, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(series[0].template.day, day(27))
        XCTAssertFalse(items.contains { $0.day == day(26) })
        XCTAssertEqual(items.first { $0.id == edited.id }?.day, day(29))
        XCTAssertTrue(items.allSatisfy { $0.repeatRule == .weekdays })
    }
    func testLegacySplitSeriesReuniteAndDeleteTogether() throws {
        var original = RepeatingPlan(template: template(.daily))
        original.endBefore = day(29)
        var splitTemplate = template(.daily, day: 29)
        splitTemplate.title = "Older future edit"
        var split = RepeatingPlan(template: splitTemplate)
        split.familyID = original.familyID
        var series = [original, split]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(31), calendar: calendar)
        let ids = Set(items.map(\.id))
        var edited = try XCTUnwrap(items.first { $0.day == day(30) })
        edited.title = "One connected item"
        Planner.saveRepeating(edited, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].template.day, day(26))
        XCTAssertEqual(Set(items.map(\.id)), ids)
        XCTAssertTrue(items.allSatisfy { $0.title == edited.title })
        series = try JSONDecoder().decode([RepeatingPlan].self, from: JSONEncoder().encode(series))
        let saved = try XCTUnwrap(items.first { $0.id == edited.id })
        Planner.deleteSeries(saved, items: &items, series: &series)
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(series.isEmpty)
    }
    func testOldItemsDecodeWithoutRecurrenceAndCustomRequiresDays() throws {
        let item = template(.never)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        for key in ["repeatRule", "repeatWeekdays", "seriesID", "occurrenceDay"] { json.removeValue(forKey: key) }
        let migrated = try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated, item)
        var custom = template(.custom)
        XCTAssertThrowsError(try Planner.validate(custom, in: [], calendar: calendar))
        custom.repeatWeekdays = [2, 4, 6]
        XCTAssertNoThrow(try Planner.validate(custom, in: [], calendar: calendar))
    }
    func testDeletingOneOccurrenceKeepsTheRestAndIsNotGeneratedAgain() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar)
        let target = try XCTUnwrap(items.first { $0.day == day(28) })
        Planner.delete(target, .occurrence, items: &items, series: &series)
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar))
        XCTAssertEqual(items.map(\.day).sorted(), [26, 27, 29, 30].map { day($0) })
        XCTAssertEqual(series.count, 1)
        // A later edit to the series keeps the deleted day out.
        var edited = try XCTUnwrap(items.first { $0.day == day(27) }); edited.title = "Office"
        Planner.saveRepeating(edited, items: &items, series: &series, calendar: calendar)
        Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar)
        XCTAssertFalse(items.contains { $0.day == day(28) })
        XCTAssertEqual(Set(items.map(\.title)), ["Office"])
    }
    func testDeletingFromAnOccurrenceOnEndsTheSeriesAndKeepsEarlierCompletion() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(31), calendar: calendar)
        items[0].completedAt = date(26, hour: 18)
        let target = try XCTUnwrap(items.first { $0.day == day(29) })
        XCTAssertFalse(Planner.startsSeries(target, in: series))
        Planner.delete(target, .following, items: &items, series: &series)
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(26), through: day(5, month: 11), calendar: calendar))
        XCTAssertEqual(items.map(\.day).sorted(), [26, 27, 28].map { day($0) })
        XCTAssertTrue(try XCTUnwrap(items.first { $0.day == day(26) }).isComplete)
        XCTAssertEqual(series.first?.endBefore, day(29))
    }
    func testDeletingFollowingFromTheFirstOccurrenceIsTheWholeSeries() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(28), calendar: calendar)
        let first = try XCTUnwrap(items.first { $0.day == day(26) })
        XCTAssertTrue(Planner.startsSeries(first, in: series))
        Planner.delete(first, .following, items: &items, series: &series)
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(series.isEmpty)
    }
    func testDeletingAllOccurrencesAndSingleItems() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = [PlanItem(title: "Single", day: day(26))]
        Planner.materialize(series, in: &items, from: day(26), through: day(28), calendar: calendar)
        let middle = try XCTUnwrap(items.first { $0.seriesID != nil && $0.day == day(27) })
        Planner.delete(middle, .all, items: &items, series: &series)
        XCTAssertEqual(items.map(\.title), ["Single"])
        XCTAssertTrue(series.isEmpty)
        // Any scope deletes just the item when it doesn't repeat.
        Planner.delete(items[0], .occurrence, items: &items, series: &series)
        XCTAssertTrue(items.isEmpty)
    }
    func testChangingTheFirstOccurrencesPatternChangesTheWholeSeriesAndDeletionKeepsTheConnection() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar)
        Planner.delete(try XCTUnwrap(items.first { $0.day == day(27) }), .occurrence, items: &items, series: &series)
        var later = try XCTUnwrap(items.first { $0.day == day(29) }); later.title = "Office"
        Planner.saveRepeating(later, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(Set(items.map(\.title)), ["Office"])
        XCTAssertEqual(Planner.seriesStart(of: later, in: series), day(26))
        var first = try XCTUnwrap(items.first { $0.day == day(26) }); first.repeatRule = .weekdays
        Planner.saveRepeating(first, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].template.repeatRule, .weekdays)
    }
    func testUndoingEachKindOfDeletionRestoresThePlan() throws {
        for scope in RepeatDeletion.allCases {
            var series = [RepeatingPlan(template: template(.daily))]
            var items: [PlanItem] = []
            Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar)
            items[0].completedAt = date(26, hour: 18)
            var child = PlanItem(title: "Pack bag", day: day(28)); child.parentID = items[2].id
            items.append(child)
            let before = (items: items, series: series)
            Planner.delete(items[2], scope, items: &items, series: &series)
            let deletion = Planner.deletion(of: "Work", before: before, after: (items, series))
            XCTAssertFalse(deletion.removed.isEmpty)
            XCTAssertEqual(deletion.unlinked[child.id], before.items[2].id)
            Planner.undo(deletion, items: &items, series: &series)
            XCTAssertEqual(Set(items.map(\.id)), Set(before.items.map(\.id)), "\(scope)")
            XCTAssertEqual(series, before.series, "\(scope)")
            XCTAssertEqual(items.first { $0.id == child.id }?.parentID, before.items[2].id)
            XCTAssertTrue(try XCTUnwrap(items.first { $0.id == before.items[0].id }).isComplete)
            XCTAssertFalse(Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar))
        }
    }
    func testUndoingADeletionKeepsLaterChanges() {
        var items = [PlanItem(title: "Read", day: day(26)), PlanItem(title: "Call", day: day(26))]
        var series: [RepeatingPlan] = []
        let before = (items: items, series: series)
        Planner.delete(items[0], .all, items: &items, series: &series)
        let deletion = Planner.deletion(of: "Read", before: before, after: (items, series))
        items[0].title = "Call Mum"
        Planner.undo(deletion, items: &items, series: &series)
        XCTAssertEqual(Set(items.map(\.title)), ["Read", "Call Mum"])
    }
    func testTheOriginalEntryIsTheFirstDayStillInTheSeries() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(29), calendar: calendar)
        let third = try XCTUnwrap(items.first { $0.day == day(28) })
        XCTAssertEqual(Planner.originalDay(of: third, in: series, calendar: calendar), day(26))
        XCTAssertTrue(Planner.isOriginal(try XCTUnwrap(items.first { $0.day == day(26) }), in: series, calendar: calendar))
        XCTAssertFalse(Planner.isOriginal(third, in: series, calendar: calendar))
        // With the first day deleted, the next one becomes the original entry.
        Planner.delete(try XCTUnwrap(items.first { $0.day == day(26) }), .occurrence, items: &items, series: &series)
        XCTAssertEqual(Planner.originalDay(of: third, in: series, calendar: calendar), day(27))
        XCTAssertTrue(Planner.isOriginal(PlanItem(title: "Single", day: day(28)), in: series))
    }
    func testDetachingAnOccurrenceMakesItASingleItemAndLeavesTheOthers() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar)
        var third = try XCTUnwrap(items.first { $0.day == day(28) })
        third.title = "Dentist instead"
        third.completedAt = date(28, hour: 18)
        Planner.detach(third, items: &items, series: &series)
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar))
        let single = try XCTUnwrap(items.first { $0.id == third.id })
        XCTAssertNil(single.seriesID)
        XCTAssertEqual(single.repeatRule, .never)
        XCTAssertEqual(single.title, "Dentist instead")
        XCTAssertTrue(single.isComplete)
        XCTAssertEqual(items.filter { $0.seriesID != nil }.map(\.day).sorted(), [26, 27, 29, 30].map { day($0) })
        XCTAssertEqual(Set(items.filter { $0.seriesID != nil }.map(\.title)), ["Work"])
        // Later edits to the original entry no longer reach the detached day.
        var first = try XCTUnwrap(items.first { $0.day == day(26) }); first.title = "Office"
        Planner.saveRepeating(first, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(items.first { $0.id == third.id }?.title, "Dentist instead")
        XCTAssertFalse(items.contains { $0.seriesID != nil && $0.day == day(28) })
    }
    func testALaterDayWithItsOwnPatternStartsANewMasterBesideTheOriginal() throws {
        // X1–X4 weekly on Mondays; X3 changes to daily.
        var series = [RepeatingPlan(template: template(.weekly))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(16, month: 11), calendar: calendar)
        let x3Day = day(9, month: 11)
        var x3 = try XCTUnwrap(items.first { $0.day == x3Day })
        x3.repeatRule = .daily
        Planner.detach(x3, items: &items, series: &series, calendar: calendar)
        Planner.materialize(series, in: &items, from: day(26), through: day(16, month: 11), calendar: calendar)
        let weekly = try XCTUnwrap(series.first { $0.template.repeatRule == .weekly })
        let daily = try XCTUnwrap(series.first { $0.template.repeatRule == .daily })
        XCTAssertNotEqual(weekly.familyID, daily.familyID)
        // X1, X2 and X4 stay linked to the weekly master; X3 is Y1 of the daily one.
        XCTAssertEqual(items.filter { $0.seriesID == weekly.id }.map(\.day).sorted(), [day(26), day(2, month: 11), day(16, month: 11)])
        let y1 = try XCTUnwrap(items.first { $0.id == x3.id })
        XCTAssertEqual(y1.seriesID, daily.id)
        XCTAssertTrue(Planner.isOriginal(y1, in: series, calendar: calendar))
        XCTAssertEqual(items.filter { $0.seriesID == daily.id }.map(\.day).sorted().first, x3Day)
        XCTAssertEqual(items.filter { $0.seriesID == daily.id }.count, 8)
        // The weekly master still reaches X4, and no longer reaches Y.
        var x1 = try XCTUnwrap(items.first { $0.day == day(26) }); x1.title = "Office"
        Planner.saveRepeating(x1, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(items.first { $0.seriesID == weekly.id && $0.day == day(16, month: 11) }?.title, "Office")
        XCTAssertEqual(items.first { $0.id == x3.id }?.title, "Work")
    }
    func testDetachingWithoutChangingThePatternNeverStartsADuplicateSeries() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar)
        var third = try XCTUnwrap(items.first { $0.day == day(28) }); third.title = "Gym"
        Planner.detach(third, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(items.first { $0.id == third.id }?.repeatRule, .never)
        XCTAssertEqual(items.count, 5)
    }
    func testLinkedCountIsTheTotalWhenTheSeriesEndsOtherwiseSoFar() throws {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(26), calendar: calendar)
        let original = try XCTUnwrap(items.first)
        let soFar = try XCTUnwrap(Planner.linkedCount(of: original, in: series, today: day(30), calendar: calendar))
        XCTAssertEqual(soFar.count, 4)
        XCTAssertFalse(soFar.isTotal)
        series[0].excludedDays = [day(28)]
        series[0].endBefore = day(5, month: 11)
        let total = try XCTUnwrap(Planner.linkedCount(of: original, in: series, today: day(27), calendar: calendar))
        XCTAssertEqual(total.count, 8)
        XCTAssertTrue(total.isTotal)
        XCTAssertNil(Planner.linkedCount(of: PlanItem(title: "Single", day: day(26)), in: series, today: day(27)))
    }
}
