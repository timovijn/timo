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

    func testFollowsUnfinishedTimedItemsInOrder() {
        var done = range("Done", 8, 9); done.completedAt = at(8, 30)
        var cancelled = range("Cancelled", 9, 10); cancelled.cancelledAt = at(8)
        let items = [range("Sport", 18, 19), PlanItem(title: "Call Mum", day: today), range("Work", 9, 17),
                     PlanItem(title: "Shave", day: today, minute: 8 * 60), done, cancelled]
        let stops = DayGuide.stops(in: items, now: at(7))
        XCTAssertEqual(stops.map(\.item.title), ["Shave", "Work", "Sport"])
        XCTAssertNil(stops.first?.end)
        XCTAssertEqual(stops.first?.finish, at(8))
    }

    func testKeepsMomentsThatPassedTodayUntilTicked() {
        let yesterday = Day(calendar.date(byAdding: .day, value: -1, to: Date())!)
        let items = [PlanItem(title: "Shave", day: today, minute: 8 * 60, movesToNextDay: false),
                     PlanItem(title: "Old call", day: yesterday, minute: 23 * 60, movesToNextDay: false)]
        XCTAssertEqual(DayGuide.stops(in: items, now: at(20)).map(\.item.title), ["Shave"])
    }

    func testOverlappingRangesEachGetAStop() {
        let items = [range("Lunch", 12, 13), range("Work", 9, 17)]
        XCTAssertEqual(DayGuide.stops(in: items, now: at(12, 30)).map(\.item.title), ["Work", "Lunch"])
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
