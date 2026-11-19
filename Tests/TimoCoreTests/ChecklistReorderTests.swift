import XCTest
import CoreGraphics
@testable import TimoCore

final class ChecklistReorderTests: XCTestCase {
    private let ids = (0..<7).map { _ in UUID() }

    private func layout(width: CGFloat = 300) -> ChecklistReorderLayout {
        let widths: [CGFloat] = [64, 190, 85, 148, 72, 230, 96]
        return ChecklistReorderLayout(sizes: Dictionary(uniqueKeysWithValues:
            zip(ids, widths).map { ($0, CGSize(width: $1, height: 36)) }), width: width)
    }

    func testMovesBothWaysAndPreservesNeighbours() throws {
        let layout = layout(width: 900)
        let target = try XCTUnwrap(layout.slots(ids)[ids[3]])
        let moved = try XCTUnwrap(layout.placement(of: ids[0], in: ids,
                                                  at: CGPoint(x: target.midX, y: target.midY)))
        XCTAssertNotEqual(moved, ids)
        XCTAssertEqual(moved.filter { $0 != ids[0] }, Array(ids.dropFirst()))
        XCTAssertEqual(Set(moved), Set(ids))
        let back = layout.placement(of: ids[0], in: moved, at: CGPoint(x: 20, y: 18))
        XCTAssertEqual(back, ids)
    }

    func testStationaryFingerCannotTriggerAnotherReorderAfterRewrapping() {
        var moves = 0
        for width: CGFloat in [220, 300, 420] {
            let layout = layout(width: width)
            for id in ids {
                for x in stride(from: CGFloat(-12), through: width + 12, by: 17) {
                    for y in stride(from: CGFloat(-12), through: 320, by: 19) {
                        let point = CGPoint(x: x, y: y)
                        guard let moved = layout.placement(of: id, in: ids, at: point) else { continue }
                        moves += 1
                        XCTAssertNil(layout.placement(of: id, in: moved, at: point),
                                     "A stationary finger caused repeated reorders at \(point)")
                        XCTAssertEqual(moved.filter { $0 != id }, ids.filter { $0 != id })
                    }
                }
            }
        }
        XCTAssertGreaterThan(moves, 100)
    }

    func testSmallFingerJitterDoesNotReverseAReorder() {
        let layout = layout()
        var moves = 0
        for id in ids {
            for x in stride(from: CGFloat(0), through: 300, by: 13) {
                for y in stride(from: CGFloat(0), through: 300, by: 13) {
                    let point = CGPoint(x: x, y: y)
                    guard let moved = layout.placement(of: id, in: ids, at: point) else { continue }
                    moves += 1
                    for dx: CGFloat in [-1.5, 0, 1.5] {
                        for dy: CGFloat in [-1.5, 0, 1.5] {
                            XCTAssertNil(layout.placement(of: id, in: moved,
                                at: CGPoint(x: x + dx, y: y + dy)))
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(moves, 100)
    }

    func testBoundaryToleranceKeepsCurrentSlot() throws {
        let layout = layout()
        let slot = try XCTUnwrap(layout.slots(ids)[ids[0]])
        for offset: CGFloat in [0, 1, 3, 5] {
            XCTAssertNil(layout.placement(of: ids[0], in: ids,
                at: CGPoint(x: slot.maxX + offset, y: slot.midY)))
            XCTAssertNil(layout.placement(of: ids[0], in: ids,
                at: CGPoint(x: slot.midX, y: slot.maxY + offset)))
        }
    }

    func testWrappingAndWidthClampingMatchFlowLayout() {
        let layout = layout(width: 220)
        let slots = layout.slots(ids)
        XCTAssertEqual(slots[ids[0]], CGRect(x: 0, y: 0, width: 64, height: 36))
        XCTAssertEqual(slots[ids[1]], CGRect(x: 0, y: 44, width: 190, height: 36))
        XCTAssertEqual(slots[ids[5]]?.width, 220)
        XCTAssertEqual(slots[ids[5]]?.minX, 0)
    }

    func testWaitsForMeasurementsAndHandlesMissingEntry() {
        var layout = layout()
        layout.sizes[ids[2]] = nil
        XCTAssertNil(layout.placement(of: ids[0], in: ids, at: CGPoint(x: 100, y: 180)))
        XCTAssertNil(layout.placement(of: UUID(), in: ids, at: .zero))
        XCTAssertNil(layout.placement(of: ids[0], in: [], at: .zero))
    }
}
