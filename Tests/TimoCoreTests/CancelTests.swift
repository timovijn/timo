import XCTest
@testable import TimoCore

final class CancelTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return value
    }
    func date(_ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    func day(_ value: Int) -> Day { Day(date(value), calendar: calendar) }

    func testCancellingClearsCompletionAndRestoringLeavesItOpen() {
        var item = PlanItem(title: "Call Mum", day: day(26))
        item.completedAt = date(26, hour: 10)
        item.suggestionDismissed = true
        Planner.setCancelled(true, &item, on: day(26), now: date(26, hour: 12), calendar: calendar)
        XCTAssertTrue(item.isCancelled)
        XCTAssertFalse(item.isComplete)
        XCTAssertTrue(item.isSettled)
        XCTAssertFalse(item.suggestionDismissed)
        Planner.setCancelled(false, &item, on: day(26), now: date(26, hour: 12), calendar: calendar)
        XCTAssertFalse(item.isCancelled)
        XCTAssertFalse(item.isComplete)
        XCTAssertFalse(item.isSettled)
    }
    func testCancelledItemDoesNotCarryOnAndStaysOnTheDayItWasCancelledFrom() {
        var item = PlanItem(title: "Shop", day: day(26))
        let now = date(29, hour: 12)
        XCTAssertEqual(item.liveDay(now: now, calendar: calendar), day(29))
        // Cancelled while viewing the 27th, it stops there.
        Planner.setCancelled(true, &item, on: day(27), now: now, calendar: calendar)
        XCTAssertEqual(item.cancelledAt, date(27, hour: 12))
        XCTAssertEqual(item.liveDay(now: now, calendar: calendar), day(27))
        XCTAssertTrue(item.shows(on: day(27), now: now, calendar: calendar))
        XCTAssertFalse(item.shows(on: day(29), now: now, calendar: calendar))
        XCTAssertTrue(item.movedAway(from: day(26), now: now, calendar: calendar))
        // Cancelled on its own day, it is shown there only.
        Planner.setCancelled(true, &item, on: day(26), now: now, calendar: calendar)
        XCTAssertFalse(item.isCarried(now: now, calendar: calendar))
        XCTAssertTrue(Planner.movedItems(from: day(26), in: [item], now: now, calendar: calendar).isEmpty)
    }
    func testCancelledItemIsNeitherElapsedNorInProgressNorReminded() {
        var item = PlanItem(title: "Sport", day: day(26), minute: 17 * 60, end: date(26, hour: 18),
                            reminders: [date(26, hour: 16)])
        XCTAssertTrue(item.isInProgress(now: date(26, hour: 17) + 60, calendar: calendar))
        XCTAssertTrue(item.isElapsed(now: date(26, hour: 19), calendar: calendar))
        XCTAssertEqual(Planner.upcomingReminders(in: [item], now: date(26, hour: 8)).count, 1)
        Planner.setCancelled(true, &item, on: day(26), now: date(26, hour: 8), calendar: calendar)
        XCTAssertFalse(item.isInProgress(now: date(26, hour: 17) + 60, calendar: calendar))
        XCTAssertFalse(item.isElapsed(now: date(26, hour: 19), calendar: calendar))
        XCTAssertTrue(Planner.upcomingReminders(in: [item], now: date(26, hour: 8)).isEmpty)
        // The reminder itself is kept, so restoring the item brings it back.
        Planner.setCancelled(false, &item, on: day(26), now: date(26, hour: 8), calendar: calendar)
        XCTAssertEqual(Planner.upcomingReminders(in: [item], now: date(26, hour: 8)).count, 1)
    }
    func testCancellingIsPerOccurrenceAndSurvivesSeriesEdits() {
        var work = PlanItem(title: "Work", day: day(26), minute: 540, end: date(26, hour: 17), movesToNextDay: false)
        work.repeatRule = .daily
        var series = [RepeatingPlan(template: work)]
        var items: [PlanItem] = []
        Planner.materialize(series, in: &items, from: day(26), through: day(28), calendar: calendar)
        Planner.setCancelled(true, &items[1], on: day(27), now: date(26), calendar: calendar)
        var edited = items[0]
        edited.title = "Office"
        Planner.saveRepeating(edited, items: &items, series: &series, calendar: calendar)
        let byDay = Dictionary(uniqueKeysWithValues: items.map { ($0.day, $0) })
        XCTAssertEqual(byDay[day(27)]?.title, "Office")
        XCTAssertEqual(byDay[day(27)]?.isCancelled, true)
        XCTAssertEqual(byDay[day(26)]?.isCancelled, false)
        XCTAssertEqual(byDay[day(28)]?.isCancelled, false)
        XCTAssertNil(series[0].template.cancelledAt)
        // Newly generated occurrences start uncancelled even from a cancelled definition.
        series[0].template.cancelledAt = date(26)
        Planner.materialize(series, in: &items, from: day(29), through: day(29), calendar: calendar)
        XCTAssertEqual(items.first { $0.day == day(29) }?.isCancelled, false)
    }
    func testCancellationPersistsAndOlderItemsOpenUncancelled() throws {
        var item = PlanItem(title: "Read", day: day(26))
        Planner.setCancelled(true, &item, on: day(26), now: date(26), calendar: calendar)
        let decoded = try JSONDecoder().decode(PlanItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.cancelledAt, item.cancelledAt)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json["cancelledAt"] = nil
        XCTAssertFalse(try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: json)).isCancelled)
        // Uncancelled items don't write the key at all, so the saved format is unchanged for them.
        let open = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PlanItem(title: "Open", day: day(26)))) as? [String: Any])
        XCTAssertNil(open["cancelledAt"])
    }
}
