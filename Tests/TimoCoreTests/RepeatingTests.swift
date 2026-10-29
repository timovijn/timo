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
        item.reminderAt = date(24, hour: 8)
        item.people = ["Timo"]; item.locations = ["Office"]
        let plan = RepeatingPlan(template: item)
        var items: [PlanItem] = []
        Planner.materialize([plan], in: &items, from: day(24), through: day(26), calendar: calendar)
        for occurrence in items {
            XCTAssertEqual(calendar.component(.hour, from: occurrence.start(calendar: calendar)!), 9)
            XCTAssertEqual(calendar.component(.hour, from: occurrence.end!), 17)
            XCTAssertEqual(calendar.component(.hour, from: occurrence.reminderAt!), 8)
            XCTAssertEqual(occurrence.people, item.people)
            XCTAssertEqual(occurrence.locations, item.locations)
            XCTAssertNil(occurrence.carriedFrom)
        }
        XCTAssertEqual(Set(items.map(\.id)).count, 3)
    }
    func testRepeatingOccurrencesNeverCarryOver() {
        let plan = RepeatingPlan(template: template(.daily))
        var items: [PlanItem] = []
        Planner.materialize([plan], in: &items, from: day(26), through: day(28), calendar: calendar)
        items[0].movesToNextDay = true // Even an old preference cannot pile up repeats.
        XCTAssertFalse(Planner.reconcile(&items, now: date(29), calendar: calendar))
        XCTAssertEqual(items.map(\.day), [day(26), day(27), day(28)])
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
    func testRemovingRepeatKeepsOnlyEditedOccurrence() {
        var series = [RepeatingPlan(template: template(.daily))]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(30), calendar: calendar)
        var edited = items[2]; edited.repeatRule = .never
        Planner.saveRepeating(edited, items: &items, series: &series)
        Planner.materialize(series, in: &items, from: day(26), through: day(31), calendar: calendar)
        XCTAssertEqual(items.map(\.day), [day(28)])
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
        edited.reminderAt = date(27, hour: 9)
        Planner.saveRepeating(edited, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(Set(items.map(\.id)), originalIDs)
        for item in items {
            XCTAssertEqual(item.title, edited.title)
            XCTAssertEqual(item.notes, edited.notes)
            XCTAssertEqual(item.people, edited.people)
            XCTAssertEqual(item.locations, edited.locations)
            XCTAssertEqual(item.minute, 600)
            XCTAssertEqual(calendar.component(.hour, from: item.end!), 18)
            XCTAssertEqual(calendar.component(.hour, from: item.reminderAt!), 9)
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
        var edited = try XCTUnwrap(items.first { $0.day == day(29) })
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
}
