import XCTest
@testable import TimoCore

final class LinkedRestoreTests: XCTestCase {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }
    func date(_ d: Int, _ h: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
    }
    func day(_ d: Int) -> Day { Day(date(d), calendar: calendar) }
    func group() -> ([PlanItem], [RepeatingPlan]) {
        let event = PlanItem(title: "Weekend", notes: "Original details", day: day(6), endDay: day(8), movesToNextDay: false)
        var items: [PlanItem] = [], series: [RepeatingPlan] = []
        Planner.saveDateRange(event, items: &items, series: &series, calendar: calendar)
        return (items, series)
    }
    func overview(_ source: PlanItem, _ items: [PlanItem], _ series: [RepeatingPlan]) -> [LinkedItemEntry] {
        Planner.linkedItems(for: source, in: items, series: series, through: day(15), calendar: calendar)
    }
    func testOverviewShowsLinkedChangedAndDeletedWithoutCreatingItems() throws {
        var (items, series) = group()
        let source = items[0]
        var changed = try XCTUnwrap(items.first { $0.day == day(7) })
        changed.title = "Dinner"
        Planner.updateStart(&changed, day: day(12), minute: 18 * 60, calendar: calendar)
        Planner.detach(changed, items: &items, series: &series, calendar: calendar)
        let deleted = try XCTUnwrap(items.first { $0.day == day(8) })
        Planner.delete(deleted, .occurrence, items: &items, series: &series)
        let before = items
        let entries = overview(source, items, series)
        XCTAssertEqual(entries.map(\.status), [.linked, .changed, .deleted])
        XCTAssertEqual(entries[1].origin.day, day(7))
        XCTAssertEqual(entries[1].item?.day, day(12))
        XCTAssertEqual(items, before)
        let saved = try JSONDecoder().decode([PlanItem].self, from: JSONEncoder().encode(items))
        XCTAssertEqual(overview(source, saved, series), entries)
    }
    func testRestoreChangedDayRejoinsAndPreservesSettlementAndIdentity() throws {
        var (items, series) = group()
        let source = items[0]
        var changed = try XCTUnwrap(items.first { $0.day == day(7) })
        changed.title = "Changed"; changed.notes = "Different"
        changed.completedAt = date(7, 15)
        Planner.updateStart(&changed, day: day(12), minute: 18 * 60, calendar: calendar)
        Planner.detach(changed, items: &items, series: &series, calendar: calendar)
        let otherDays = items.filter { $0.id != changed.id }
        let entry = try XCTUnwrap(overview(source, items, series).first { $0.status == .changed })
        XCTAssertTrue(Planner.restoreLinkedItem(entry, items: &items, series: &series, calendar: calendar))
        let restored = try XCTUnwrap(items.first { $0.id == changed.id })
        XCTAssertEqual(restored.title, source.title)
        XCTAssertEqual(restored.notes, "Original details")
        XCTAssertEqual(restored.day, day(7)); XCTAssertEqual(restored.endDay, day(7))
        XCTAssertNil(restored.minute); XCTAssertNil(restored.detachedFrom)
        XCTAssertEqual(restored.seriesID, source.seriesID)
        XCTAssertEqual(restored.completedAt, changed.completedAt)
        XCTAssertEqual(items.filter { $0.id != changed.id }, otherDays)
        XCTAssertTrue(overview(source, items, series).allSatisfy { $0.status == .linked })
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(6), through: day(8), calendar: calendar))
    }
    func testRestoreDeletedDayReturnsOpenAndDoesNotDuplicate() throws {
        var (items, series) = group()
        let source = items[0]
        let deleted = try XCTUnwrap(items.first { $0.day == day(8) })
        Planner.delete(deleted, .occurrence, items: &items, series: &series)
        let entry = try XCTUnwrap(overview(source, items, series).first { $0.status == .deleted })
        XCTAssertTrue(Planner.restoreLinkedItem(entry, items: &items, series: &series, calendar: calendar))
        let restored = try XCTUnwrap(items.first { $0.day == day(8) })
        XCTAssertEqual(restored.id, deleted.id)
        XCTAssertFalse(restored.isSettled)
        XCTAssertEqual(items.count, 3)
        XCTAssertFalse(Planner.materialize(series, in: &items, from: day(6), through: day(8), calendar: calendar))
    }
    func testRestoreFollowingDeletedDayKeepsOtherDeletedDaysOut() throws {
        let event = PlanItem(title: "Trip", day: day(6), endDay: day(10), movesToNextDay: false)
        var items: [PlanItem] = [], series: [RepeatingPlan] = []
        Planner.saveDateRange(event, items: &items, series: &series, calendar: calendar)
        let source = items[0]
        let target = try XCTUnwrap(items.first { $0.day == day(8) })
        Planner.delete(target, .following, items: &items, series: &series)
        let entries = overview(source, items, series)
        XCTAssertEqual(entries.filter { $0.status == .deleted }.map { $0.origin.day }, [day(8), day(9), day(10)])
        let selected = try XCTUnwrap(entries.first { $0.origin.day == day(10) })
        XCTAssertTrue(Planner.restoreLinkedItem(selected, items: &items, series: &series, calendar: calendar))
        Planner.materialize(series, in: &items, from: day(6), through: day(12), calendar: calendar)
        XCTAssertEqual(Set(items.map(\.day)), Set([day(6), day(7), day(10)]))
    }
    func testLegacyDetachedIDsCanStillBeRestored() throws {
        var (items, series) = group()
        let source = items[0]
        var changed = try XCTUnwrap(items.first { $0.day == day(7) })
        changed.title = "Different"
        Planner.detach(changed, items: &items, series: &series, calendar: calendar)
        let index = try XCTUnwrap(items.firstIndex { $0.id == changed.id })
        items[index].detachedFrom = nil
        let entry = try XCTUnwrap(overview(source, items, series).first { $0.status == .changed })
        XCTAssertTrue(Planner.restoreLinkedItem(entry, items: &items, series: &series, calendar: calendar))
        XCTAssertEqual(items.first { $0.id == changed.id }?.seriesID, source.seriesID)
    }
    func testCompletionIsNotReportedAsChangedAndCancellationSurvivesRestore() throws {
        var (items, series) = group()
        let source = items[0]
        let index = try XCTUnwrap(items.firstIndex { $0.day == day(7) })
        items[index].completedAt = date(7, 12)
        XCTAssertTrue(overview(source, items, series).allSatisfy { $0.status == .linked })
        items[index].completedAt = nil; items[index].cancelledAt = date(7, 12)
        items[index].notes = "Override"
        let entry = try XCTUnwrap(overview(source, items, series).first { $0.status == .changed })
        Planner.restoreLinkedItem(entry, items: &items, series: &series, calendar: calendar)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.day == day(7) }).isCancelled)
    }
    func testOldRecordsWithoutOriginStillDecode() throws {
        let item = PlanItem(title: "Old", day: day(6))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object.removeValue(forKey: "detachedFrom")
        XCTAssertNil(try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: object)).detachedFrom)
    }
    func testRestoringDeletedFormerOriginalDoesNotHijackTheNewOriginal() throws {
        var (items, series) = group()
        let first = items[0]
        Planner.delete(first, .occurrence, items: &items, series: &series)
        var newOriginal = try XCTUnwrap(items.first { $0.day == day(7) })
        newOriginal.title = "Updated"
        Planner.saveRepeating(newOriginal, items: &items, series: &series, calendar: calendar)
        let entries = overview(newOriginal, items, series)
        let deleted = try XCTUnwrap(entries.first { $0.origin.day == day(6) })
        XCTAssertEqual(deleted.status, .deleted)
        XCTAssertNil(deleted.item)
        Planner.restoreLinkedItem(deleted, items: &items, series: &series, calendar: calendar)
        XCTAssertEqual(items.first { $0.id == newOriginal.id }?.day, day(7))
        XCTAssertEqual(items.count, 3)
    }
}
