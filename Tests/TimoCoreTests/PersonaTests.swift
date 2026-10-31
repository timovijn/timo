import XCTest
@testable import TimoCore

final class PersonaTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }
    func date(_ day: Int, _ hour: Int = 12, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func day(_ value: Int) -> Day { Day(date(value), calendar: calendar) }
    func item(_ title: String, _ value: Int, persona: Persona?, minute: Int? = nil) -> PlanItem {
        // Done on its day, so it stays there rather than carrying on to today.
        var item = PlanItem(title: title, day: day(value), minute: minute)
        item.personas = persona.map { [$0] } ?? []
        item.completedAt = date(value)
        return item
    }
    func testPersonasPersistInOrderAndCanAllBeRemoved() throws {
        var saved = item("Run with Sam", 20, persona: nil)
        saved.personas = Persona.ordered([.friends, .health, .friends])
        XCTAssertEqual(saved.personas, [.health, .friends])
        var decoded = try JSONDecoder().decode(PlanItem.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.personas, [.health, .friends])
        XCTAssertEqual(decoded, saved)
        saved.personas = []
        decoded = try JSONDecoder().decode(PlanItem.self, from: JSONEncoder().encode(saved))
        XCTAssertTrue(decoded.personas.isEmpty)
    }
    func testOlderSinglePersonaAndUnknownPersonasOpen() throws {
        let saved = item("Call", 20, persona: .family)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "personas")
        XCTAssertTrue(try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: json)).personas.isEmpty)
        // Version 6 kept one persona under its own key.
        json["persona"] = "family"
        XCTAssertEqual(try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: json)).personas, [.family])
        json["persona"] = "hobbies"
        XCTAssertTrue(try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: json)).personas.isEmpty)
        json.removeValue(forKey: "persona")
        json["personas"] = ["hobbies", "work"]
        let mixed = try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(mixed.personas, [.work])
        XCTAssertEqual(mixed.id, saved.id)
    }
    func testItemInSeveralPersonasIsListedInEach() {
        var run = item("Run with Sam", 20, persona: nil)
        run.personas = [.health, .friends]
        for persona in [Persona.health, .friends] {
            XCTAssertEqual(Planner.history(of: persona, in: [run], now: date(25), calendar: calendar).flatMap(\.items).map(\.id), [run.id])
        }
        XCTAssertTrue(Planner.history(of: .work, in: [run], now: date(25), calendar: calendar).isEmpty)
    }
    func testHistoryGroupsByDayNewestFirstInDayOrder() {
        let late = item("Gym", 20, persona: .health, minute: 18 * 60)
        let early = item("Stretch", 20, persona: .health, minute: 7 * 60)
        let anytime = item("Drink water", 20, persona: .health)
        let older = item("Doctor", 12, persona: .health)
        var upcoming = item("Dentist", 30, persona: .health)
        upcoming.completedAt = nil
        let other = item("Report", 20, persona: .work)
        let none = item("Shave", 20, persona: nil)
        let history = Planner.history(of: .health, in: [late, other, older, early, none, upcoming, anytime], now: date(25), calendar: calendar)
        XCTAssertEqual(history.map(\.day), [day(30), day(20), day(12)])
        XCTAssertEqual(history[1].items.map(\.title), ["Drink water", "Stretch", "Gym"])
        XCTAssertTrue(Planner.history(of: .friends, in: [late, other], now: date(25), calendar: calendar).isEmpty)
    }
    func testCarriedItemIsListedOnItsCurrentDayWithEntriesOnTheDaysBefore() {
        var physio = item("Book physio", 20, persona: .health)
        physio.completedAt = nil
        // As in the day list: itself today, and a "Carried to" entry on each day it was carried on from.
        let history = Planner.history(of: .health, in: [physio], now: date(23), calendar: calendar)
        XCTAssertEqual(history.map(\.day), [day(23), day(22), day(21), day(20)])
        XCTAssertTrue(history.allSatisfy { $0.items.map(\.id) == [physio.id] })
        XCTAssertFalse(physio.movedAway(from: day(23), now: date(23), calendar: calendar))
        // Done on the 21st, it is listed there, with an entry on the 20th.
        physio.completedAt = date(21)
        XCTAssertEqual(Planner.history(of: .health, in: [physio], now: date(23), calendar: calendar).map(\.day), [day(21), day(20)])
    }
    func testRunningRangeIsListedOnItsOwnDayAndOnTodayLikeTheDayList() {
        // From the 20th at 9:00 to the 27th: today's list shows it while it runs.
        var project = PlanItem(title: "Project", day: day(20), minute: 9 * 60, movesToNextDay: false)
        project.personas = [.work]
        project.end = date(27)
        var carried = PlanItem(title: "Report", day: day(21), minute: 10 * 60, movesToNextDay: true)
        carried.personas = [.work]
        let history = Planner.history(of: .work, in: [project, carried], now: date(23), calendar: calendar)
        XCTAssertEqual(history.map(\.day), [day(23), day(22), day(21), day(20)])
        // A carried item comes first, untimed, as in the day list.
        XCTAssertEqual(history[0].items.map(\.title), ["Report", "Project"])
        // On its scheduled day its entry keeps its time, after the range that is also running then.
        XCTAssertEqual(history[2].items.map(\.title), ["Project", "Report"])
        XCTAssertEqual(history[3].items.map(\.title), ["Project"])
    }
    func testRepeatingItemsShareTheirPersonaAndListEveryLinkedItem() {
        var template = PlanItem(title: "Walk", day: day(20), minute: 8 * 60, movesToNextDay: false)
        template.repeatRule = .daily
        template.personas = [.health]
        var items: [PlanItem] = []
        var series: [RepeatingPlan] = []
        Planner.saveRepeating(template, items: &items, series: &series, calendar: calendar)
        Planner.materialize(series, in: &items, from: day(20), through: day(30), calendar: calendar)
        XCTAssertTrue(items.allSatisfy { $0.personas == [.health] })
        // Linked items ahead of today are listed too.
        XCTAssertEqual(Planner.history(of: .health, in: items, now: date(23), calendar: calendar).map(\.day), (20...30).reversed().map(day))
        // Changing the personas on one occurrence changes the whole series.
        var edited = items[2]
        edited.personas = [.health, .personal]
        Planner.saveRepeating(edited, items: &items, series: &series, calendar: calendar)
        XCTAssertTrue(items.allSatisfy { $0.personas == [.health, .personal] })
        XCTAssertEqual(series.map(\.template.personas), [[.health, .personal]])
    }
}
