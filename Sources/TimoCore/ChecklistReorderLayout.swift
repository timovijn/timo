import Foundation
import CoreGraphics

/// Resting geometry for checklist drag targeting. Animation remains entirely in SwiftUI.
struct ChecklistReorderLayout {
    var sizes: [UUID: CGSize]
    var width: CGFloat
    var spacing: CGFloat = 8
    private let tolerance: CGFloat = 6

    /// Matches FlowLayout's wrapping, using measured sizes rather than moving screen frames.
    func slots(_ ids: [UUID]) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for id in ids {
            guard var size = sizes[id] else { continue }
            size.width = min(size.width, width)
            if x > 0 && x + size.width > width + 0.5 {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            result[id] = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return result
    }

    /// Choose the nearest possible slot for the held pill, keeping every other pill in order.
    /// For a stationary finger, the same candidate slots remain available after a move, so the
    /// chosen order stays put even when different pill widths cause neighbouring rows to rewrap.
    func placement(of id: UUID, in current: [UUID], at point: CGPoint) -> [UUID]? {
        guard point.x.isFinite, point.y.isFinite,
              current.allSatisfy({ sizes[$0] != nil }),
              let index = current.firstIndex(of: id), let slot = slots(current)[id],
              !slot.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }

        func distance(_ rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - point.x, 0, point.x - rect.maxX),
                  max(rect.minY - point.y, 0, point.y - rect.maxY))
        }
        let others = current.filter { $0 != id }
        let currentDistance = distance(slot)
        var best = (ids: current, distance: currentDistance, steps: 0)
        for position in 0...others.count where position != index {
            var ids = others
            ids.insert(id, at: position)
            guard let rect = slots(ids)[id] else { continue }
            let gap = distance(rect), steps = abs(position - index)
            if gap < best.distance || (gap == best.distance && steps < best.steps) {
                best = (ids, gap, steps)
            }
        }
        // Hysteresis: tiny movements at a boundary must not reverse a completed move.
        guard best.distance < currentDistance - tolerance else { return nil }
        return best.ids
    }
}
