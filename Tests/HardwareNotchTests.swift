import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
    var hardwareNotch: HardwareNotch?
}

private let builtInScreen = FakeScreen(
    frameValue: CGRect(x: 0, y: 0, width: 1710, height: 1112),
    visibleFrameValue: CGRect(x: 0, y: 0, width: 1710, height: 1074.5),
    hardwareNotch: HardwareNotch(width: 208, height: 37.5)
)

private let externalScreen = FakeScreen(
    frameValue: CGRect(x: -397, y: 1112, width: 2560, height: 1440),
    visibleFrameValue: CGRect(x: -397, y: 1112, width: 2560, height: 1440)
)

@MainActor
final class HardwareNotchTests: XCTestCase {
    private func codexSnapshot() -> ProviderSnapshot {
        ProviderSnapshot(
            id: "codex-profile", displayName: "Codex", glyph: .openai,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "five-hour", label: "5h", usedFraction: 0.2),
                      LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.3)],
            headlineID: "five-hour", weeklyID: "weekly", sourceProviderID: "codex"
        )
    }

    private func model(screen: ScreenDescribing, cells: Int = 1) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.isExpanded = true
        model.surfaceStyle = .solid
        model.accentColor = .blue
        model.snapshots = (0..<cells).map { _ in codexSnapshot() }
        model.weeklyRing = .inside
        model.adopt(screen: screen)
        return model
    }

    func testBuiltInTopPanelReachesThePhysicalScreenTop() {
        let panel = NotchGeometry.panelFrame(
            for: builtInScreen, panelSize: CGSize(width: 700, height: 220), edge: .top
        )
        XCTAssertEqual(panel.midX, 855, accuracy: 0.5)
        XCTAssertEqual(panel.maxY, 1112, accuracy: 0.001)
    }

    func testJoinedScaleFitsTheWholeCodexCellInsideTheMeasuredCutoutDepth() {
        let model = model(screen: builtInScreen)
        XCTAssertTrue(model.mergesWithCutout)
        XCTAssertEqual(model.contentDepth,
                       NotchLayout.cellExtent + 2 * NotchLayout.ringMargin(for: .top),
                       accuracy: 0.001)
        XCTAssertEqual(model.contentDepth * model.sizeScale,
                       37.5 + NotchRootView.bezelBleed, accuracy: 0.001)
        XCTAssertTrue(model.readsAcrossTheCutout)
        XCTAssertFalse(model.showsCellReading)
        XCTAssertEqual(model.wings.filter(\.carriesCells).count, 1)
        XCTAssertEqual(model.wings.filter { !$0.carriesCells && $0.length > 0 }.count, 1)
    }

    func testMergedNotchHoverRequiresThePointerToBeInTheCellWingOrItsTooltip() {
        let controller = NotchWindowController()
        let model = controller.model
        model.edge = .top
        model.isExpanded = true
        model.snapshots = [codexSnapshot()]
        model.adopt(screen: builtInScreen)
        XCTAssertTrue(model.mergesWithCutout)

        let placement = NotchPlacement(edge: .top, panelSize: model.panelSize)
        let ringAlong = model.ringPanelCenter(index: 0)
        let ringAcross = (NotchLayout.ringMargin(for: .top) + NotchLayout.ringDiameter / 2)
            * model.sizeScale
        let ring = placement.point(along: ringAlong, across: ringAcross)
        XCTAssertEqual(controller.hoverTarget(at: ring), 0)

        let outsideWing = placement.point(along: ringAlong,
                                          across: model.notchDrawnDepth + 1)
        XCTAssertNil(controller.hoverTarget(at: outsideWing),
                      "same along-coordinate beyond the notch must not reveal a usage tooltip")

        let wings = model.wings.filter { $0.length > 0 }.sorted { $0.lead < $1.lead }
        XCTAssertEqual(wings.count, 2)
        let gapAlong = (wings[0].lead + wings[0].length + wings[1].lead) / 2
        let betweenWings = placement.point(along: gapAlong, across: ringAcross)
        XCTAssertNil(controller.hoverTarget(at: betweenWings),
                      "the hardware-cutout gap is not an interactive provider cell")

        model.hoveredIndex = 0
        let tooltipAlong = model.tooltipAlong(index: 0, length: NotchLayout.cardWidth)
        let tooltip = placement.point(
            along: tooltipAlong,
            across: model.notchDrawnDepth + NotchLayout.tailGap + NotchLayout.tailLength + 1
        )
        XCTAssertEqual(controller.hoverTarget(at: tooltip), 0,
                       "moving from the ring onto its tooltip should retain that provider")
    }

    func testMergedTopSettingsArcIsASettingsHoverTarget() {
        let model = model(screen: builtInScreen)
        XCTAssertTrue(model.mergesWithCutout)

        let arc = FlareArc.point(
            0.5,
            offset: NotchLayout.orbClearance,
            flare: model.orbArcRadius + NotchLayout.orbGap,
            centre: .zero,
            trim: SettingsOrb.restingTrim(for: model.edge, convex: model.orbHugsCorner,
                                          reversed: model.carriedOnTheLeft),
            edge: model.edge
        )
        let point = CGPoint(x: model.orbAlong + model.orbArcOffset.width + arc.x,
                            y: model.orbInset + model.orbArcOffset.height + arc.y)
        XCTAssertTrue(model.isOnOrbHandle(along: point.x, across: point.y))
    }

    func testParkedPointerOnHardwareWakeRegionKeepsOnHoverExpanded() async throws {
        let controller = NotchWindowController()
        let model = controller.model
        model.edge = .top
        model.snapshots = [codexSnapshot()]
        model.adopt(screen: builtInScreen)
        XCTAssertTrue(model.mergesWithCutout)

        let wake = model.wakeRect(panelSize: model.panelSize)
        let hardwarePoint = CGPoint(x: wake.midX, y: wake.midY)
        controller.apply(.onHover)
        XCTAssertFalse(model.isExpanded)

        controller.cursorMoved(at: hardwarePoint)
        XCTAssertTrue(model.isExpanded, "the folded hardware wake region should open the notch")
        XCTAssertNil(controller.hoverTarget(at: hardwarePoint),
                      "the hardware opening must not become a provider hit target")

        controller.cursorMoved(at: hardwarePoint)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(model.isExpanded,
                      "the parked hardware pointer must keep the opened notch from scheduling a fold")
        controller.stop()
    }

    func testOnHoverFoldsAwayFromWakeWhileAlwaysShowStillHoldsOpen() async throws {
        let controller = NotchWindowController()
        let model = controller.model
        model.edge = .top
        model.snapshots = [codexSnapshot()]
        model.adopt(screen: builtInScreen)
        let outside = CGPoint(x: model.panelSize.width / 2, y: model.panelSize.height - 1)

        model.isExpanded = true
        controller.cursorMoved(at: outside)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(model.isExpanded, "a pointer outside the wake region should fold the notch")

        controller.apply(.alwaysShow)
        controller.cursorMoved(at: outside)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(model.isExpanded, "Always show must continue to override hover folding")
        XCTAssertTrue(model.isAlwaysOn)
        controller.stop()
    }

    func testUpstreamCutoutDipAndNeckDetachAndReattachWithTheNotch() {
        let model = model(screen: builtInScreen)
        model.holdsOffTheCutout = true
        model.adopt(screen: builtInScreen)
        XCTAssertFalse(model.mergesWithCutout)
        XCTAssertNotNil(model.carryingDip)
        XCTAssertNotNil(model.neck)
        XCTAssertNotNil(model.notchShape(for: model.cellWing).dip)

        model.holdsOffTheCutout = false
        model.revealsTheOtherCopy = true
        model.adopt(screen: builtInScreen)
        XCTAssertTrue(model.mergesWithCutout)
        XCTAssertEqual(model.wings.filter { !$0.carriesCells && $0.length > 0 }.count, 1)
    }

    func testActualRootRendersBothCodexRingsBesideTheCutoutAndAcrossReading() throws {
        let model = model(screen: builtInScreen)
        let size = model.panelSize
        let renderer = ImageRenderer(content: NotchRootView(model: model)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .environment(\.codenotchReduceTransparency, true))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let hole = CGRect(x: builtInScreen.frameValue.midX - 104,
                          y: builtInScreen.frameValue.maxY - 37.5,
                          width: 208, height: 37.5)
        let panel = NotchGeometry.panelFrame(
            for: builtInScreen, panelSize: size, edge: .top,
            alongOffset: model.alongOffset, slack: model.slack,
            trailingExtent: model.trailingExtent
        )
        var ringInk: [CGRect] = []
        for y in stride(from: 0, to: image.height, by: 1) {
            for x in stride(from: 0, to: image.width, by: 1) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.8,
                      color.blueComponent > color.redComponent + 0.12 else { continue }
                let local = CGPoint(x: CGFloat(x) / 2, y: CGFloat(y) / 2)
                let global = CGPoint(x: panel.minX + local.x, y: panel.maxY - local.y)
                let pixel = CGRect(x: global.x, y: global.y, width: 0.5, height: 0.5)
                ringInk.append(pixel)
            }
        }
        XCTAssertGreaterThan(ringInk.count, 30, "the root view must paint the Codex quota rings")
        for pixel in ringInk {
            XCTAssertFalse(pixel.intersects(hole), "rendered quota-ring pixels enter the physical cutout")
        }

        let across = try XCTUnwrap(model.wings.first { !$0.carriesCells && $0.length > 0 })
        let textWidth = model.readingAcrossTextWidth * model.sizeScale
        XCTAssertGreaterThan(textWidth, 0)
        XCTAssertGreaterThan(across.length, textWidth,
                             "the opposite upstream wing must have room for measured remaining text")
        var acrossTextPixels = 0
        for y in stride(from: 0, to: image.height, by: 1) {
            for x in stride(from: 0, to: image.width, by: 1) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.8,
                      color.redComponent > 0.7, color.greenComponent > 0.7,
                      color.blueComponent > 0.7 else { continue }
                let localX = CGFloat(x) / 2
                guard localX >= across.lead, localX <= across.lead + across.length else { continue }
                let localY = CGFloat(y) / 2
                if localY < model.contentDepth * model.sizeScale + 2 { acrossTextPixels += 1 }
            }
        }
        XCTAssertGreaterThan(acrossTextPixels, 0,
                             "the actual opposite wing must render the upstream measured remaining text")

        let output = URL(fileURLWithPath: "/tmp/Codenotch-Visual-20260929/codex-cutout-root.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try XCTUnwrap(NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:])).write(to: output)
    }

    func testNoCutoutOnExternalDisplayPreservesUserScaleAndCenteredPlacement() {
        let model = model(screen: externalScreen)
        model.sizeScale = 1.25
        XCTAssertFalse(model.mergesWithCutout)
        XCTAssertEqual(model.sizeScale, 1.25, accuracy: 0.001)
        let panel = NotchGeometry.panelFrame(for: externalScreen,
                                             panelSize: model.panelSize, edge: .top)
        XCTAssertEqual(panel.midX, externalScreen.frameValue.midX, accuracy: 0.5)
    }

    func testScaleChoiceRestoresAfterLeavingTheHardwareCutout() {
        let model = model(screen: builtInScreen)
        model.sizeScale = 1.25
        model.adopt(screen: externalScreen)
        XCTAssertEqual(model.sizeScale, 1.25, accuracy: 0.001)
        XCTAssertFalse(model.mergesWithCutout)
    }

    func testFoldedWakeBoundsMatchThePhysicalCutout() {
        let model = model(screen: builtInScreen)
        model.isExpanded = false
        XCTAssertEqual(model.wakeLength, 208, accuracy: 0.001)
        XCTAssertEqual(model.wakeDepth, 37.5, accuracy: 0.001)
        let frame = NotchGeometry.panelFrame(for: builtInScreen,
                                             panelSize: model.panelSize, edge: .top)
        let local = model.wakeRect(panelSize: model.panelSize)
        let global = CGRect(x: frame.minX + local.minX,
                            y: frame.maxY - local.maxY,
                            width: local.width, height: local.height)
        let hardware = CGRect(x: builtInScreen.frameValue.midX - 104,
                              y: builtInScreen.frameValue.maxY - 37.5,
                              width: 208, height: 37.5)
        XCTAssertEqual(global.minX, hardware.minX, accuracy: 0.5)
        XCTAssertEqual(global.maxX, hardware.maxX, accuracy: 0.5)
        XCTAssertEqual(global.minY, hardware.minY, accuracy: 0.001)
        XCTAssertEqual(global.maxY, hardware.maxY, accuracy: 0.001)
    }
}
