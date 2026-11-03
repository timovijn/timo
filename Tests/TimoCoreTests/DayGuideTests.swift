import XCTest
@testable import TimoCore

final class DayGuideTests: XCTestCase {
    private let calendar = Calendar.current
    private var today: Day { Day(Date()) }
    private func at(_ hour: Int, _ minute: Int = 0, on day: Day? = nil) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: (day ?? today).date())!
    }
    private func range(_ title: String, _ start: Int, _ end: Int, on day: Day? = nil) -> PlanItem {
        let day = day ?? today
        return PlanItem(title: title, day: day, minute: start * 60, end: at(end, on: day), movesToNextDay: false)
    }

    func testFollowsOnlyUnfinishedRangesInOrder() {
        var done = range("Done", 8, 9); done.completedAt = at(8, 30)
        var cancelled = range("Cancelled", 9, 10); cancelled.cancelledAt = at(8)
        let items = [range("Sport", 18, 19), PlanItem(title: "Call Mum", day: today), range("Work", 9, 17),
                     PlanItem(title: "Shave", day: today, minute: 8 * 60), done, cancelled]
        XCTAssertEqual(DayGuide.stops(in: items, now: at(7)).map(\.item.title), ["Work", "Sport"])
    }

    func testNextIsTheFollowingTimedItemToday() {
        let tomorrow = Day(calendar.date(byAdding: .day, value: 1, to: Date())!)
        let items = [range("Work", 9, 17), PlanItem(title: "Read", day: today, minute: 21 * 60),
                     range("Sport", 17, 18), range("Run", 7, 8, on: tomorrow)]
        let stops = DayGuide.stops(in: items, now: at(10))
        XCTAssertEqual(stops.map { $0.next?.title }, ["Sport", "Read"])
        XCTAssertEqual(stops.last?.nextStart, at(21))
    }

    func testOverlappingRangeIsNext() {
        let items = [range("Work", 9, 17), range("Lunch", 12, 13)]
        let stops = DayGuide.stops(in: items, now: at(12, 30))
        XCTAssertEqual(stops.map(\.item.title), ["Work", "Lunch"])
        XCTAssertEqual(stops.first?.next?.title, "Lunch")
        XCTAssertNil(stops.last?.next)
    }

    func testKeepsRangesThatEndedTodayUntilTicked() {
        let items = [range("Sport", 8, 9)]
        XCTAssertEqual(DayGuide.stops(in: items, now: at(20)).map(\.item.title), ["Sport"])
    }

    func testIncludesOvernightRangeStillRunning() {
        let yesterday = Day(calendar.date(byAdding: .day, value: -1, to: Date())!)
        var night = PlanItem(title: "Night shift", day: yesterday, minute: 22 * 60, movesToNextDay: false)
        night.end = at(6)
        let ended = range("Yesterday's sport", 18, 19, on: yesterday)
        XCTAssertEqual(DayGuide.stops(in: [night, ended], now: at(5)).map(\.item.title), ["Night shift"])
    }

    func testLeavesOutRangesOfSeveralDays() {
        let earlier = Day(calendar.date(byAdding: .day, value: -3, to: Date())!)
        var trip = PlanItem(title: "Trip", day: earlier, minute: 9 * 60, movesToNextDay: false)
        trip.end = calendar.date(byAdding: .day, value: 4, to: at(18))
        XCTAssertTrue(DayGuide.stops(in: [trip], now: at(10)).isEmpty)
    }
}
