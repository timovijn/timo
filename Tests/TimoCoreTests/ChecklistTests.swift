import XCTest
@testable import TimoCore

final class ChecklistTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }
    func date(_ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    func day(_ value: Int) -> Day { Day(date(value), calendar: calendar) }
    let milk = ChecklistEntry(title: "Milk"), eggs = ChecklistEntry(title: "Eggs"), bread = ChecklistEntry(title: "Bread")

    func shopping(_ entries: [ChecklistEntry]) -> PlanItem {
        var item = PlanItem(title: "Supermarket", day: day(26))
        item.checklist = entries
        return item
    }
    func weekly(_ entries: [ChecklistEntry]) -> (items: [PlanItem], series: [RepeatingPlan]) {
        var master = PlanItem(title: "Groceries", day: day(26), minute: 600, movesToNextDay: false)
        master.repeatRule = .daily
        master.checklist = entries
        var series: [RepeatingPlan] = [], items: [PlanItem] = []
        Planner.saveRepeating(master, items: &items, series: &series, calendar: calendar)
        Planner.materialize(series, in: &items, from: day(26), through: day(28), calendar: calendar)
        return (items.sorted { $0.day < $1.day }, series)
    }

    func testEncodesOnlyWithEntriesAndReadsOlderItems() throws {
        let plain = PlanItem(title: "Lunch", day: day(26))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("checklist"))
        XCTAssertNil(plain.checklistProgress)
        var item = shopping([milk, eggs])
        Planner.setEntry(milk.id, done: true, in: &item, now: date(26))
        let decoded = try JSONDecoder().decode(PlanItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.checklist, item.checklist)
        XCTAssertEqual(decoded.checklistProgress?.done, 1)
        XCTAssertEqual(decoded.checklistProgress?.total, 2)
    }
    func testTickingAnEntryLeavesTheItemOpen() {
        var item = shopping([milk])
        Planner.setEntry(milk.id, done: true, in: &item, now: date(26, 15))
        XCTAssertEqual(item.checklist[0].doneAt, date(26, 15))
        XCTAssertFalse(item.isComplete)
        Planner.setEntry(milk.id, done: false, in: &item, now: date(26, 16))
        XCTAssertNil(item.checklist[0].doneAt)
        Planner.setEntry(UUID(), done: true, in: &item, now: date(26))
        XCTAssertEqual(item.checklist, [milk])
    }
    func testEveryDayOfARepeatStartsUnticked() {
        var ticked = milk; ticked.doneAt = date(25)
        let (items, series) = weekly([ticked, eggs])
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(series[0].template.checklist.allSatisfy { !$0.isDone })
        // The day it was saved from keeps its tick; the generated days start fresh.
        XCTAssertTrue(items.dropFirst().allSatisfy { $0.checklist == [milk, eggs] })
    }
    func testEditingTheOriginalsEntriesKeepsEachDaysTicks() throws {
        var (items, series) = weekly([milk, eggs])
        Planner.setEntry(milk.id, done: true, in: &items[1], now: date(27))
        var original = items[0]
        original.checklist = [eggs, ChecklistEntry(id: milk.id, title: "Oat milk"), bread]
        Planner.saveRepeating(original, items: &items, series: &series, calendar: calendar)
        let second = try XCTUnwrap(items.first { $0.occurrenceDay == day(27) })
        XCTAssertEqual(second.checklist.map(\.title), ["Eggs", "Oat milk", "Bread"])
        XCTAssertEqual(second.checklist.map(\.isDone), [false, true, false])
        let third = try XCTUnwrap(items.first { $0.occurrenceDay == day(28) })
        XCTAssertFalse(third.checklist.contains(where: \.isDone))
    }
    func testMergeKeepsTicksFromBothSides() {
        let base = shopping([milk, eggs, bread])
        var mine = base, theirs = base
        Planner.setEntry(milk.id, done: true, in: &mine, now: date(26, 10))
        Planner.setEntry(bread.id, done: true, in: &theirs, now: date(26, 11))
        let merged = PlanItem.merged(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.checklist.map(\.isDone), [true, false, true])
    }
    func testMergeKeepsAdditionsAndDeletionsFromBothSides() {
        let butter = ChecklistEntry(title: "Butter"), jam = ChecklistEntry(title: "Jam")
        let base = [milk, eggs, bread]
        let mine = [milk, bread, butter]          // removed eggs, added butter
        let theirs = [jam, milk, eggs]            // added jam, removed bread
        let merged = ChecklistEntry.merged(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.map(\.title), ["Jam", "Milk", "Butter"])
    }
    func testMergeTakesTheReorderAndTheRename() {
        let base = [milk, eggs, bread]
        let mine = [bread, milk, eggs]
        var renamed = eggs; renamed.title = "Free-range eggs"
        let theirs = [milk, renamed, bread]
        XCTAssertEqual(ChecklistEntry.merged(base: base, mine: mine, theirs: theirs).map(\.title),
                       ["Bread", "Milk", "Free-range eggs"])
        XCTAssertEqual(ChecklistEntry.merged(base: base, mine: base, theirs: theirs).map(\.title),
                       ["Milk", "Free-range eggs", "Bread"])
    }
    func testDuplicateStartsUnticked() {
        var item = shopping([milk, eggs])
        Planner.setEntry(milk.id, done: true, in: &item, now: date(26))
        let copy = item.duplicate(now: date(26))
        XCTAssertEqual(copy.checklist.map(\.title), ["Milk", "Eggs"])
        XCTAssertFalse(copy.checklist.contains(where: \.isDone))
    }
    func testCarriedItemKeepsItsTicks() {
        var item = shopping([milk, eggs])
        Planner.setEntry(milk.id, done: true, in: &item, now: date(26))
        XCTAssertEqual(item.liveDay(now: date(28), calendar: calendar), day(28))
        XCTAssertEqual(item.on(day(28)).checklist.map(\.isDone), [true, false])
    }
    func testSearchFindsEntries() {
        let trip = shopping([milk, eggs])
        let other = PlanItem(title: "Lunch", day: day(26))
        XCTAssertEqual(Planner.search("eggs", in: [trip, other], now: date(26), calendar: calendar).flatMap(\.items).map(\.id), [trip.id])
    }
    func testTicksFromCarriesTicksByIDOnly() {
        var ticked = milk; ticked.doneAt = date(26)
        XCTAssertEqual(ChecklistEntry.ticks(from: [ticked], onto: [eggs, milk]).map(\.isDone), [false, true])
        XCTAssertEqual(ChecklistEntry.untouched([ticked]), [milk])
    }
}
