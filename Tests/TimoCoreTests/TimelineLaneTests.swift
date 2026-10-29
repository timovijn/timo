import XCTest
@testable import TimoCore

final class TimelineLaneTests: XCTestCase {
    func testPartialAndNestedOverlapGetTheirOwnDurationTracks() {
        // Work 09–17, a call 10–11 and another event 16–18.
        XCTAssertEqual(TimelineLanes.assign([540..<1020, 600..<660, 960..<1080]), [0, 1, 1])
    }
    func testSameStartKeepsLongestNearestAxisRegardlessOfInputOrder() {
        XCTAssertEqual(TimelineLanes.assign([540..<600, 540..<1020, 540..<660]), [2, 0, 1])
    }
    func testTouchingEventsReuseTrack() {
        XCTAssertEqual(TimelineLanes.assign([540..<600, 600..<660, 660..<720]), [0, 0, 0])
    }
    func testFullyOverlappingEventsAllRemainDistinct() {
        XCTAssertEqual(TimelineLanes.assign([540..<900, 600..<840, 660..<780, 720..<750]), [0, 1, 2, 3])
    }
    func testUnsortedAndEmptyInput() {
        XCTAssertEqual(TimelineLanes.assign([960..<1080, 600..<660, 540..<1020]), [1, 1, 0])
        XCTAssertEqual(TimelineLanes.assign([]), [])
        XCTAssertEqual(TimelineLanes.assign([540..<540, 540..<600]), [0, 0])
    }
}
