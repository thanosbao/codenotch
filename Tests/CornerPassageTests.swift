import SwiftUI
import XCTest
@testable import Codenotch

final class CornerPassageTests: XCTestCase {
    private let track = BorderTrack(width: 1710, height: 1112)

    func testBorderTrackMapsEachCornerContinuouslyToTheNextEdge() {
        let transitions: [(BorderTrack.Corner, NotchEdge, NotchEdge, CGFloat)] = [
            (.topRight, .top, .right, 1710),
            (.bottomRight, .right, .bottom, 2822),
            (.bottomLeft, .bottom, .left, 4532),
            (.topLeft, .left, .top, 0)
        ]
        for (corner, before, after, position) in transitions {
            XCTAssertEqual(track.position(of: corner), position, accuracy: 0.001)
            XCTAssertEqual(BorderTrack.edges(of: corner).before, before)
            XCTAssertEqual(BorderTrack.edges(of: corner).after, after)
            XCTAssertEqual(track.place(at: position - 0.01).edge, before)
            XCTAssertEqual(track.place(at: position + 0.01).edge, after)
        }
    }

    func testUpstreamCornerPassageMorphUsesTwoActualShapeParts() {
        let view = CornerPassageView(
            track: track, corner: .topRight, before: 82, after: 138,
            depth: 72, bleed: 2, cornerRadius: 24, flare: 32,
            place: track.position(of: .topRight) + 28
        )
        XCTAssertGreaterThan(view.goo, 0)
        XCTAssertEqual(view.parts.count, 2)
        XCTAssertTrue(view.parts.allSatisfy { !$0.isEmpty })
    }

    func testOnlyStraightRunUsesWholeNotchShape() {
        let straight = CornerPassageView(
            track: track, corner: .topRight, before: 100, after: 120,
            depth: 70, bleed: 2, cornerRadius: 20, flare: 30,
            place: 1710, straight: .top
        )
        let corner = CornerPassageView(
            track: track, corner: .topRight, before: 100, after: 120,
            depth: 70, bleed: 2, cornerRadius: 20, flare: 30,
            place: 1710, straight: nil
        )
        XCTAssertEqual(straight.parts.count, 1)
        XCTAssertEqual(corner.parts.count, 2)
    }

    @MainActor
    func testUpstreamDragReadingStaysContinuousThroughCornerAndUsesSpringFollow() {
        let before = CGPoint(x: 1700, y: 8)
        let around = CGPoint(x: 1708, y: 8)
        let first = NotchWindowController.reading(of: before, on: track, nearest: .top)
        let second = NotchWindowController.reading(of: around, on: track, nearest: .right)
        XCTAssertEqual(first, .corner(.topRight))
        XCTAssertEqual(second, .corner(.topRight))
        let a = NotchWindowController.place(of: before, on: track, by: first)
        let b = NotchWindowController.place(of: around, on: track, by: second)
        XCTAssertGreaterThan(b, a)
        XCTAssertLessThan(b - a, 32)

        let step = NotchWindowController.spring(
            gap: 80, velocity: 0, elapsed: 1.0 / 60,
            response: NotchWindowController.followResponse,
            damping: NotchWindowController.followDamping
        )
        XCTAssertGreaterThan(step.moved, 0)
        XCTAssertLessThan(step.moved, 80)
        XCTAssertGreaterThan(step.velocity, 0)
    }

    @MainActor
    func testUpstreamStickyEdgeAvoidsEdgeFlappingUntilMarginIsCrossed() {
        let frame = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        XCTAssertEqual(NotchWindowController.stickyEdge(
            current: .top, pointer: CGPoint(x: 1690, y: 1080), frame: frame
        ), .top)
        XCTAssertEqual(NotchWindowController.stickyEdge(
            current: .top, pointer: CGPoint(x: 1690, y: 1040), frame: frame
        ), .right)
    }
}
