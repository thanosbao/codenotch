import XCTest
@testable import Codenotch

final class CodexRemainingTests: XCTestCase {
    private func snapshot(id: String = "codex", used: Double? = nil,
                          weekly: Double? = nil) -> ProviderSnapshot {
        var windows = [LimitWindow(id: "primary", label: "5h", usedFraction: used)]
        if let weekly {
            windows.append(LimitWindow(id: "secondary", label: "Weekly", usedFraction: weekly))
        }
        return ProviderSnapshot(id: id, displayName: "Codex", glyph: .openai,
                                fidelity: .official, status: .ok, windows: windows,
                                headlineID: "primary", weeklyID: "secondary")
    }

    func testCodexHeadlineAndTooltipUseRemainingWithoutChangingUsedData() {
        let reading = snapshot(used: 0.15, weekly: 0.58)
        XCTAssertEqual(reading.usedFraction, 0.15)
        XCTAssertEqual(reading.headlineText, "85%")
        XCTAssertEqual(reading.headline?.summary(asRemaining: true), "85% left")
        XCTAssertEqual(reading.weeklyWindow?.summary(asRemaining: true), "42% left")
    }

    func testZeroFullAndUnknownStayHonest() {
        XCTAssertEqual(snapshot(used: 0).headlineText, "100%")
        XCTAssertEqual(snapshot(used: 1).headlineText, "0%")
        XCTAssertEqual(snapshot(used: nil).headlineText, "—")
        XCTAssertNil(snapshot(used: nil).remainingFraction)
    }

    func testRiskBandStillUsesUsedFraction() {
        XCTAssertEqual(UsageBand.band(for: 0.85), .critical)
        XCTAssertEqual(UsageBand.band(for: 0.15), .ample)
    }

    func testCodexWeeklyRingIsNotSuppressedByActivity() {
        let session = AgentSession(id: "task", name: "task", detail: "Codex",
                                   state: .busy, waitingFor: nil, since: Date())
        let activity = ActivitySummary(sessions: [session])
        XCTAssertFalse(ProviderRing.shouldDrawWeeklyRing(
            weeklyRing: .inside, weeklyFraction: 0.58, activity: activity,
            showsActivityArc: true))
        XCTAssertTrue(ProviderRing.shouldDrawWeeklyRing(
            weeklyRing: .inside, weeklyFraction: 0.58, activity: activity,
            showsActivityArc: false))
    }
}
