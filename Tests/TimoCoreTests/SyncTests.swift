import XCTest
@testable import TimoCore

final class SyncTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return value
    }
    func date(_ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    func day(_ value: Int) -> Day { Day(date(value), calendar: calendar) }
    func daily() -> RepeatingPlan {
        var item = PlanItem(title: "Run", day: day(26), minute: 420, end: date(26, hour: 8), movesToNextDay: false)
        item.repeatRule = .daily
        return RepeatingPlan(template: item)
    }

    func testOccurrenceIDsAreTheSameOnEveryDevice() {
        let plan = daily()
        var phone: [PlanItem] = [], pad: [PlanItem] = []
        Planner.materialize([plan], in: &phone, from: day(26), through: day(30), calendar: calendar)
        Planner.materialize([plan], in: &pad, from: day(28), through: day(30), calendar: calendar)
        Planner.materialize([plan], in: &pad, from: day(26), through: day(27), calendar: calendar)
        XCTAssertEqual(Set(phone.map(\.id)), Set(pad.map(\.id)))
        XCTAssertEqual(Set(phone.map(\.id)).count, 5)
        XCTAssertEqual(phone[0].id, PlanItem.occurrenceID(series: plan.id, day: day(26)))
    }
    func testOccurrenceIDsDifferBySeriesAndDayAndAreValidUUIDs() {
        let series = UUID()
        let id = PlanItem.occurrenceID(series: series, day: day(26))
        XCTAssertEqual(id, PlanItem.occurrenceID(series: series, day: day(26)))
        XCTAssertNotEqual(id, PlanItem.occurrenceID(series: series, day: day(27)))
        XCTAssertNotEqual(id, PlanItem.occurrenceID(series: UUID(), day: day(26)))
        XCTAssertEqual(id.uuidString[id.uuidString.index(id.uuidString.startIndex, offsetBy: 14)], "8")
    }
    func testAnOccurrenceHoldingTheDerivedIDIsNotDuplicated() {
        let plan = daily()
        // An occurrence shifted by a series edit keeps the ID of the day it came from.
        var held = plan.template
        held.id = PlanItem.occurrenceID(series: plan.id, day: day(27))
        held.seriesID = plan.id
        held.occurrenceDay = day(28)
        var items = [held]
        Planner.materialize([plan], in: &items, from: day(26), through: day(29), calendar: calendar)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(Set(items.map(\.id)).count, 4)
    }

    func testDuplicateOccurrencesFoldIntoOneOnEveryDevice() {
        let plan = daily()
        var occurrence = plan.template
        occurrence.seriesID = plan.id
        occurrence.occurrenceDay = day(27)
        var older = occurrence, newer = occurrence
        older.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        newer.id = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        newer.completedAt = date(27, hour: 8)
        var child = PlanItem(title: "Stretch", day: day(27), parentID: newer.id)
        child.id = UUID()
        var phone = [older, newer, child], pad = [child, newer, older]
        XCTAssertTrue(Planner.mergeDuplicateOccurrences(&phone))
        Planner.mergeDuplicateOccurrences(&pad)
        XCTAssertEqual(phone.filter { $0.seriesID != nil }.map(\.id), [older.id])
        XCTAssertEqual(pad.filter { $0.seriesID != nil }.map(\.id), [older.id])
        XCTAssertEqual(phone.first { $0.id == older.id }?.completedAt, date(27, hour: 8))
        XCTAssertEqual(phone.first { $0.id == child.id }?.parentID, older.id)
        XCTAssertFalse(Planner.mergeDuplicateOccurrences(&phone))

        var derived = occurrence
        derived.id = PlanItem.occurrenceID(series: plan.id, day: day(27))
        var items = [older, derived]
        Planner.mergeDuplicateOccurrences(&items)
        XCTAssertEqual(items.map(\.id), [derived.id])
    }
    func testPersonalDetailsRoundTrip() {
        var item = PlanItem(title: "Call", day: day(26))
        item.personal = PersonalDetails(reminders: [date(26)], personas: [.work, .family], suggestionDismissed: true)
        XCTAssertEqual(item.reminders, [date(26)])
        XCTAssertEqual(item.personas, [.work, .family])
        XCTAssertTrue(item.suggestionDismissed)
        XCTAssertEqual(item.personal, PersonalDetails(reminders: [date(26)], personas: Persona.ordered([.work, .family]), suggestionDismissed: true))
    }
    func testMergeKeepsBothSidesEdits() {
        let base = PlanItem(title: "Dinner", day: day(26), minute: 1140, end: date(26, hour: 20), movesToNextDay: false)
        var mine = base
        mine.title = "Dinner with Anna"
        var theirs = base
        theirs.notes = "Book a table"
        theirs.completedAt = date(26, hour: 21)
        let merged = PlanItem.merged(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.title, "Dinner with Anna")
        XCTAssertEqual(merged.notes, "Book a table")
        XCTAssertEqual(merged.completedAt, date(26, hour: 21))
    }
    func testMergeTakesTheScheduleAsOne() {
        let base = PlanItem(title: "Meet", day: day(26), minute: 600, end: date(26, hour: 11), movesToNextDay: false)
        var mine = base
        mine.end = date(26, hour: 12)
        var theirs = base
        theirs.minute = 840
        theirs.end = date(26, hour: 15)
        let merged = PlanItem.merged(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.minute, 600)
        XCTAssertEqual(merged.end, date(26, hour: 12))
    }
    func testMergeTakesCompletionAndCancellingAsOne() {
        let base = PlanItem(title: "Shop", day: day(26))
        var mine = base
        mine.cancelledAt = date(26, hour: 10)
        var theirs = base
        theirs.completedAt = date(26, hour: 11)
        let merged = PlanItem.merged(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.cancelledAt, date(26, hour: 10))
        XCTAssertNil(merged.completedAt)
    }
}
