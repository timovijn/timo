import XCTest
@testable import TimoCore

/// The format written by older builds: an ordinary finite daily series, one item per day.
func makeLegacyDateRange(_ event: PlanItem, items: inout [PlanItem], series: inout [RepeatingPlan], calendar: Calendar) {
    var template = event
    template.endDay = template.day
    template.repeatRule = .daily
    var plan = RepeatingPlan(template: template)
    plan.id = PlanItem.occurrenceID(series: event.id, day: event.originalDay)
    plan.familyID = plan.id
    plan.isDateRange = true
    plan.endBefore = Day(calendar.date(byAdding: .day, value: 1, to: event.endDay!.date(calendar: calendar))!, calendar: calendar)
    series.append(plan)
    Planner.materialize([plan], in: &items, from: event.day, through: event.endDay!, calendar: calendar)
    if let first = items.firstIndex(where: { $0.seriesID == plan.id && $0.day == event.day }) { items[first].id = event.id }
}

final class LinkedDateRangeTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return value
    }
    func date(_ d: Int, _ h: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))! }
    func day(_ d: Int) -> Day { Day(date(d), calendar: calendar) }
    func event() -> PlanItem { PlanItem(title: "Weekend", day: day(6), endDay: day(8), movesToNextDay: false) }
    func legacy() -> ([PlanItem], [RepeatingPlan]) {
        var items: [PlanItem] = [], plans: [RepeatingPlan] = []
        makeLegacyDateRange(event(), items: &items, series: &plans, calendar: calendar)
        return (items, plans)
    }
    func testOneEventHasIndependentDailyCompletionCancellationAndCounts() {
        var event = event()
        Planner.setComplete(true, &event, on: day(6), now: date(8, 12), calendar: calendar)
        Planner.setCancelled(true, &event, on: day(7), now: date(8, 12), calendar: calendar)
        XCTAssertTrue(event.on(day(6)).isComplete)
        XCTAssertTrue(event.on(day(7)).isCancelled)
        XCTAssertFalse(event.on(day(8)).isSettled)
        for d in 6...8 {
            XCTAssertEqual(event.on(day(d)).id, event.id)
            let count = DayProgress(items: [event], day: day(d), now: date(8, 12), calendar: calendar)
            XCTAssertEqual(count.done, d == 6 ? 1 : 0)
            XCTAssertEqual(count.total, d == 7 ? 0 : 1)
        }
        Planner.setComplete(false, &event, on: day(6), now: date(8, 12), calendar: calendar)
        XCTAssertFalse(event.on(day(6)).isSettled)
        XCTAssertTrue(event.on(day(7)).isCancelled)
    }
    func testDailyChecksRoundTripWithoutSavingTheDisplayProjection() throws {
        var event = event()
        Planner.setComplete(true, &event, on: day(7), now: date(7, 12), calendar: calendar)
        let data = try JSONEncoder().encode(event.on(day(7)))
        let loaded = try JSONDecoder().decode(PlanItem.self, from: data)
        XCTAssertEqual(loaded, event)
        XCTAssertTrue(loaded.on(day(7)).isComplete)
        XCTAssertFalse(loaded.on(day(8)).isComplete)
        XCTAssertNil(loaded.completedAt)
    }
    func testDifferentDaysMergeAndReopeningDoesNotEraseAnotherDevicesCheck() {
        let base = event()
        var phone = base, pad = base
        Planner.setComplete(true, &phone, on: day(6), now: date(6, 12), calendar: calendar)
        Planner.setComplete(true, &pad, on: day(7), now: date(7, 12), calendar: calendar)
        var merged = PlanItem.merged(base: base, mine: phone, theirs: pad)
        XCTAssertTrue(merged.on(day(6)).isComplete)
        XCTAssertTrue(merged.on(day(7)).isComplete)
        phone = merged; pad = merged
        Planner.setComplete(false, &phone, on: day(6), now: date(8), calendar: calendar)
        Planner.setComplete(true, &pad, on: day(8), now: date(8), calendar: calendar)
        merged = PlanItem.merged(base: merged, mine: phone, theirs: pad)
        XCTAssertFalse(merged.on(day(6)).isComplete)
        XCTAssertTrue(merged.on(day(7)).isComplete)
        XCTAssertTrue(merged.on(day(8)).isComplete)
    }
    func testConvertsLegacyGroupPreservingEveryDailyStatusAndReminder() throws {
        var (items, plans) = legacy()
        let original = try XCTUnwrap(items.first { $0.day == day(6) })
        let groupID = plans[0].id
        items[try XCTUnwrap(items.firstIndex { $0.day == day(6) })].completedAt = date(6, 12)
        items[try XCTUnwrap(items.firstIndex { $0.day == day(7) })].cancelledAt = date(7, 12)
        for i in items.indices { items[i].reminders = [items[i].day.date(calendar: calendar).addingTimeInterval(9 * 3600)] }
        items[1].endDay = nil // The missing field observed in synced device records.
        let reminders = Set(items.flatMap(\.reminders))
        XCTAssertTrue(Planner.consolidateDateRanges(items: &items, series: &plans, calendar: calendar))
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(plans.isEmpty)
        let merged = try XCTUnwrap(items.first)
        XCTAssertEqual(merged.id, original.id)
        XCTAssertEqual(merged.day, day(6))
        XCTAssertEqual(merged.endDay, day(8))
        XCTAssertEqual(merged.repeatRule, .never)
        XCTAssertNil(merged.seriesID)
        XCTAssertEqual(merged.mergedRangeSeriesIDs, [groupID])
        XCTAssertTrue(merged.on(day(6)).isComplete)
        XCTAssertTrue(merged.on(day(7)).isCancelled)
        XCTAssertFalse(merged.on(day(8)).isSettled)
        XCTAssertEqual(Set(merged.reminders), reminders)
        XCTAssertFalse(Planner.consolidateDateRanges(items: &items, series: &plans, calendar: calendar))
    }
    func testMigrationWaitsForSeparateSyncBatchesAndRemovesLateLegacyCopies() {
        let (legacyItems, legacyPlans) = legacy()
        var items = [legacyItems[0]], plans = legacyPlans
        XCTAssertFalse(Planner.consolidateDateRanges(items: &items, series: &plans, calendar: calendar))
        items += legacyItems.dropFirst()
        XCTAssertTrue(Planner.consolidateDateRanges(items: &items, series: &plans, calendar: calendar))
        let merged = items
        items += legacyItems.dropFirst()
        plans = legacyPlans
        XCTAssertTrue(Planner.consolidateDateRanges(items: &items, series: &plans, calendar: calendar))
        XCTAssertEqual(items, merged)
        XCTAssertTrue(plans.isEmpty)
    }
    func testMigrationKeepsSeparatelyEditedDayAndOrdinaryRepeats() throws {
        var (items, plans) = legacy()
        var separate = try XCTUnwrap(items.first { $0.day == day(7) })
        separate.title = "Separate appointment"
        Planner.detach(separate, items: &items, series: &plans, calendar: calendar)
        var ordinary = PlanItem(title: "Repeat", day: day(6))
        ordinary.repeatRule = .daily
        let ordinaryPlan = RepeatingPlan(template: ordinary)
        plans.append(ordinaryPlan)
        XCTAssertTrue(Planner.consolidateDateRanges(items: &items, series: &plans, calendar: calendar))
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.id == separate.id && $0.title == separate.title && $0.seriesID == nil })
        XCTAssertEqual(plans, [ordinaryPlan])
    }
    func testCarryOnlyAfterFinalDayAndDailyReminderSuppression() {
        var event = event()
        event.movesToNextDay = true
        event.reminders = [date(6, 9), date(7, 9), date(8, 9)]
        Planner.setComplete(true, &event, on: day(6), now: date(6, 8), calendar: calendar)
        XCTAssertEqual(Planner.upcomingReminders(in: [event], now: date(6, 8)).map(\.date), [date(7, 9), date(8, 9)])
        XCTAssertEqual(event.liveDay(now: date(7), calendar: calendar), day(6))
        XCTAssertEqual(event.liveDay(now: date(9), calendar: calendar), day(9))
        XCTAssertTrue(event.shows(on: day(6), now: date(9), calendar: calendar))
        XCTAssertFalse(event.movedAway(from: day(6), now: date(9), calendar: calendar))
        Planner.setComplete(true, &event, on: day(9), now: date(9, 12), calendar: calendar)
        XCTAssertTrue(event.on(day(8)).isComplete)
        XCTAssertFalse(event.shows(on: day(9), now: date(10), calendar: calendar))
    }
    func testPersonaHistoryAndDateSearchUseDailyState() throws {
        var event = event()
        event.personas = [.personal]
        Planner.setComplete(true, &event, on: day(7), now: date(7, 12), calendar: calendar)
        let history = Planner.history(of: .personal, in: [event], now: date(8), calendar: calendar)
        XCTAssertTrue(try XCTUnwrap(history.first { $0.day == day(7) }?.items.first).isComplete)
        XCTAssertFalse(try XCTUnwrap(history.first { $0.day == day(8) }?.items.first).isComplete)
        let search = Planner.search("Weekend 7 November 2026", in: [event], now: date(8), calendar: calendar, locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(try XCTUnwrap(search.first?.items.first).isComplete)
    }
    func testLegacyOriginalRecordCannotReplaceConsolidatedEventInAConflict() throws {
        var (items, plans) = legacy()
        let original = try XCTUnwrap(items.first { $0.id == plans[0].template.id })
        Planner.consolidateDateRanges(items: &items, series: &plans, calendar: calendar)
        let event = try XCTUnwrap(items.first)
        XCTAssertEqual(PlanItem.merged(base: original, mine: event, theirs: original), event)
        XCTAssertEqual(PlanItem.merged(base: original, mine: original, theirs: event), event)
    }
    func testMovingEventShiftsDailyKeysAndPreservesRecordedHistoryTimes() throws {
        var event = event()
        Planner.setComplete(true, &event, on: day(7), now: date(7, 12), calendar: calendar)
        Planner.updateStart(&event, day: day(13), minute: nil, calendar: calendar)
        XCTAssertEqual(event.endDay, day(15))
        XCTAssertTrue(event.on(day(14)).isComplete)
        XCTAssertFalse(event.on(day(13)).isComplete)
        XCTAssertEqual(event.on(day(14)).completedAt, date(7, 12))
    }
    func testLegacyWholeEventCompletionCanBeReopenedOnJustOneDay() {
        var event = event()
        event.completedAt = date(7, 12)
        Planner.setComplete(false, &event, on: day(7), now: date(8), calendar: calendar)
        XCTAssertTrue(event.on(day(6)).isComplete)
        XCTAssertFalse(event.on(day(7)).isComplete)
        XCTAssertTrue(event.on(day(8)).isComplete)
    }
    func testExcludedLegacyDateRemainsExcludedAfterMigration() throws {
        var (items, plans) = legacy()
        let removed = try XCTUnwrap(items.first { $0.day == day(7) })
        Planner.delete(removed, .occurrence, items: &items, series: &plans)
        Planner.consolidateDateRanges(items: &items, series: &plans, calendar: calendar)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].shows(on: day(7), now: date(8), calendar: calendar))
        XCTAssertTrue(items[0].shows(on: day(8), now: date(8), calendar: calendar))
    }

}
