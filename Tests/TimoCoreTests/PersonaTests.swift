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
        item.persona = persona
        item.completedAt = date(value)
        return item
    }
    func testPersonaPersistsAndRemovingItClearsIt() throws {
        var saved = item("Run", 20, persona: .health)
        var decoded = try JSONDecoder().decode(PlanItem.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.persona, .health)
        XCTAssertEqual(decoded, saved)
        saved.persona = nil
        decoded = try JSONDecoder().decode(PlanItem.self, from: JSONEncoder().encode(saved))
        XCTAssertNil(decoded.persona)
    }
    func testOlderItemsAndUnknownPersonasOpenWithoutOne() throws {
        let saved = item("Call", 20, persona: .family)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "persona")
        XCTAssertNil(try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: json)).persona)
        json["persona"] = "hobbies"
        let unknown = try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(unknown.persona)
        XCTAssertEqual(unknown.id, saved.id)
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
    func testCarriedItemIsListedOnceOnItsCurrentDay() {
        var physio = item("Book physio", 20, persona: .health)
        physio.completedAt = nil
        let history = Planner.history(of: .health, in: [physio], now: date(23), calendar: calendar)
        XCTAssertEqual(history.map(\.day), [day(23)])
        XCTAssertEqual(history[0].items.count, 1)
        // Done on the 21st, it is listed there instead.
        physio.completedAt = date(21)
        XCTAssertEqual(Planner.history(of: .health, in: [physio], now: date(23), calendar: calendar).map(\.day), [day(21)])
    }
    func testRepeatingItemsShareTheirPersonaAndOnlyListOccurrencesSoFar() {
        var template = PlanItem(title: "Walk", day: day(20), minute: 8 * 60, movesToNextDay: false)
        template.repeatRule = .daily
        template.persona = .health
        var items: [PlanItem] = []
        var series: [RepeatingPlan] = []
        Planner.saveRepeating(template, items: &items, series: &series, calendar: calendar)
        Planner.materialize(series, in: &items, from: day(20), through: day(30), calendar: calendar)
        XCTAssertTrue(items.allSatisfy { $0.persona == .health })
        XCTAssertEqual(Planner.history(of: .health, in: items, now: date(23), calendar: calendar).map(\.day), [day(23), day(22), day(21), day(20)])
        // Changing the persona on one occurrence changes the whole series.
        var edited = items[2]
        edited.persona = .personal
        Planner.saveRepeating(edited, items: &items, series: &series, calendar: calendar)
        XCTAssertTrue(items.allSatisfy { $0.persona == .personal })
        XCTAssertEqual(series.map(\.template.persona), [.personal])
    }
}
