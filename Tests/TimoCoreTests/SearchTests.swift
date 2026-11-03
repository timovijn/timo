import XCTest
@testable import TimoCore

final class SearchTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }
    func date(_ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    func day(_ value: Int) -> Day { Day(date(value), calendar: calendar) }
    func search(_ query: String, _ items: [PlanItem], now: Int = 25) -> [PersonaDay] {
        Planner.search(query, in: items, now: date(now), calendar: calendar)
    }

    func testEveryWordMatchesSomeFieldIgnoringCaseAndAccents() {
        let lunch = PlanItem(title: "Lunch", notes: "Try the new café", day: day(25), locations: ["Centrum"], people: ["Sam"])
        let call = PlanItem(title: "Call Sam", day: day(25))
        XCTAssertEqual(search("sam", [lunch, call]).flatMap(\.items).map(\.id), [lunch.id, call.id])
        XCTAssertEqual(search("cafe centrum", [lunch, call]).flatMap(\.items).map(\.id), [lunch.id])
        XCTAssertTrue(search("cafe call", [lunch, call]).isEmpty)
        XCTAssertTrue(search("   ", [lunch, call]).isEmpty)
    }
    func testGroupsByLiveDayNewestFirst() {
        var old = PlanItem(title: "Dentist", day: day(20), movesToNextDay: false)
        old.completedAt = date(20)
        // Unfinished and carrying, so it is shown on today.
        let carried = PlanItem(title: "Dentist bill", day: day(22))
        let later = PlanItem(title: "Dentist again", day: day(30), minute: 9 * 60)
        let days = search("dentist", [old, carried, later])
        XCTAssertEqual(days.map(\.day), [day(30), day(25), day(20)])
        XCTAssertEqual(days[1].items.map(\.id), [carried.id])
    }
    func testPersonaScopesTheResults() {
        var run = PlanItem(title: "Run with Sam", day: day(25))
        run.personas = [.health, .friends]
        var review = PlanItem(title: "Review with Sam", day: day(25))
        review.personas = [.work]
        XCTAssertEqual(Planner.search("sam", in: [run, review], now: date(25), persona: .friends, calendar: calendar)
            .flatMap(\.items).map(\.id), [run.id])
        XCTAssertEqual(Planner.search("sam", in: [run, review], now: date(25), calendar: calendar).flatMap(\.items).count, 2)
    }
    func testRepeatingItemListsItsDaysUpToTheLimit() {
        let series = UUID()
        let gyms = (22...29).map { value -> PlanItem in
            var gym = PlanItem(title: "Gym", day: day(value), minute: 18 * 60, movesToNextDay: false)
            gym.seriesID = series
            return gym
        }
        XCTAssertEqual(Planner.search("gym", in: gyms.shuffled(), now: date(25), repeatsThrough: day(27), calendar: calendar).map(\.day),
                       [day(27), day(26), day(25), day(24), day(23), day(22)])
        XCTAssertEqual(search("gym", gyms).count, 8)
    }
    func testPersonaHistoryListsRepeatsUpToTheLimit() {
        let series = UUID()
        var items = (22...29).map { value -> PlanItem in
            var gym = PlanItem(title: "Gym", day: day(value), movesToNextDay: false)
            gym.seriesID = series
            gym.personas = [.health]
            return gym
        }
        // Something planned further ahead that doesn't repeat is always listed.
        var trip = PlanItem(title: "Trip", day: day(30), movesToNextDay: false)
        trip.personas = [.health]
        items.append(trip)
        XCTAssertEqual(Planner.history(of: .health, in: items, now: date(25), repeatsThrough: day(26), calendar: calendar).map(\.day),
                       [day(30), day(26), day(25), day(24), day(23), day(22)])
    }
    func testRepeatsReportsWhetherASeriesGoesOn() {
        var plan = RepeatingPlan(template: PlanItem(title: "Gym", day: day(22)))
        XCTAssertTrue(Planner.repeats([plan.id], in: [plan], after: day(26), calendar: calendar))
        XCTAssertFalse(Planner.repeats([UUID()], in: [plan], after: day(26), calendar: calendar))
        plan.endBefore = day(27)
        XCTAssertFalse(Planner.repeats([plan.id], in: [plan], after: day(26), calendar: calendar))
        plan.endBefore = day(29)
        XCTAssertTrue(Planner.repeats([plan.id], in: [plan], after: day(26), calendar: calendar))
    }
}
