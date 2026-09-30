import SwiftUI
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var snapshots: [ProviderSnapshot] = []
    private var performances: [String: LocalModelPerformance] = [:]
    private var localMetricsEnabled = false

    func setLocalMetricsEnabled(_ enabled: Bool) {
        localMetricsEnabled = enabled
        if !enabled { performances = [:]; thinkingModels = [:] }
        snapshots = snapshots.map(withPerformance)
    }

    func updateSnapshots(_ providerSnapshots: [ProviderSnapshot]) {
        let hoveredID = hoveredSnapshot?.id
        let next = ProviderOrder.cells(from: providerSnapshots, keeping: snapshots).map(withPerformance)
        let nextHoveredIndex = hoveredID.flatMap { id in next.firstIndex { $0.id == id } }
        if hoveredIndex != nextHoveredIndex { hoveredIndex = nextHoveredIndex }
        snapshots = next
    }

    func updatePerformances(_ measurements: [String: LocalModelPerformance]) {
        performances = measurements
        snapshots = snapshots.map(withPerformance)
    }

    private func withPerformance(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
        guard let model = snapshot.localModel else { return snapshot }
        var snapshot = snapshot
        snapshot.showsLocalPerformance = localMetricsEnabled
        snapshot.localPerformance = localMetricsEnabled
            ? performances[OllamaThinkingStream.modelKey(model.name)] : nil
        return snapshot
    }
    @Published var thinkingModels: [String: Date] = [:]

    /// Live agent sessions, keyed by the provider they belong to. They surface
    /// inside that provider's own ring rather than as a cell of their own — one
    /// ring per provider, so nothing in the notch looks like a ring without
    /// being one.
    @Published var sessions: [String: [AgentSession]] = [:]

    /// Which cell the cursor is over, if any. Driven from the window controller
    /// rather than SwiftUI's `.onHover`: the panel ignores mouse events until
    /// the cursor is over it, so SwiftUI cannot see the crossing that turns
    /// event handling on in the first place.
    @Published var hoveredIndex: Int?
    /// Ticked on refresh so the "Resets in N min" copy stays honest.
    @Published var now: Date = Date()
    @Published var resetTimeFormat: ResetTimeFormat = .automatic

    /// Whether the notch is open or folded away to its pill.
    @Published var isExpanded = false
    /// Clicked open, so it stays open until clicked shut again. A gesture,
    /// not a setting: it lasts as long as this session of looking at it.
    @Published var isPinned = false

    /// The standing choice from Settings — "Always show".
    ///
    /// Separate from `isPinned` because the two are not the same claim, and
    /// sharing one flag is what let a click on the bar undo a setting. Clicking
    /// toggles a pin; only Settings moves this.
    @Published var isAlwaysOn = false

    /// Held open, by either route. What the folding logic actually asks.
    var staysOpen: Bool { isPinned || isAlwaysOn }
    /// Providers with a fetch in flight, driven by the store.
    @Published var refreshing: Set<String> = []
    /// Bumped each time the settings orb is clicked, by either route.
    ///
    /// A count rather than a flag: the gear turns to `spins * 360`, so a
    /// second click while the first turn is still running carries on round
    /// instead of restarting from wherever it had got to.
    @Published var settingsSpins = 0

    @Published private(set) var refreshingCells: Set<String> = []

    func isRefreshing(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.localModel == nil
            ? refreshing.contains(snapshot.providerID)
            : refreshingCells.contains(snapshot.id)
    }

    func refresh(_ snapshot: ProviderSnapshot, using refreshProvider: (String) async -> Void) async {
        guard snapshot.localModel != nil else {
            await refreshProvider(snapshot.providerID)
            return
        }
        guard refreshingCells.insert(snapshot.id).inserted else { return }
        defer { refreshingCells.remove(snapshot.id) }
        // A shared inventory fetch is not activity in every loaded model.
        // Only the clicked cell presses in, even when it joins an existing poll.
        async let feedback: Void = Task.sleep(nanoseconds: 380_000_000)
        await refreshProvider(snapshot.providerID)
        _ = try? await feedback
    }
    /// The settings handle is under the cursor.
    @Published var isHoveringSettings = false
    @Published var isHoveringMove = false
    @Published var isBeingDragged = false
    @Published var carry: Carry?
    @Published var handlesTuckedAway = false
    @Published var holdsOffTheCutout = false
    /// A direct SwiftUI tap on the settings orb, independent of the panel's
    /// own AppKit-level click routing (`NotchPanel.mouseDown` →
    /// `NotchWindowController.handleClick`). That path relies on the panel's
    /// `ignoresMouseEvents` toggle and a custom `hitTest` staying in exact
    /// agreement with this model's own geometry on every click; this gives
    /// the one action people actually get stuck without a second, ordinary
    /// route that only needs SwiftUI's own gesture recognition to work.
    var onOpenSettings: (() -> Void)?
    /// Which screen edge the notch is welded to. Everything geometric reads
    /// this through `placement` rather than assuming an axis.
    @Published var edge: NotchEdge = .right
    /// A user-chosen nudge along that edge, in screen points from the centred
    /// default — set live while ⌥-dragging the pill, and by
    /// `NotchGeometry.panelFrame` from there. Reset to whatever was stored for
    /// the new edge whenever `edge` changes; this type does not own that
    /// persistence, only the live value.
    @Published var alongOffset: CGFloat = 0
    /// What every measured distance is multiplied by before it reaches the
    /// screen — the Appearance size choice, as a number.
    ///
    /// Everything in this type stays in **unscaled** points, the size the
    /// design frame is drawn at, and so does `NotchLayout`. Scaling at the
    /// source would mean threading a factor through forty constants and
    /// leaving each one no longer comparable to the frame it is quoted from.
    /// The multiplication happens once, at the two places that touch the
    /// screen: the panel's frame and the drawn content.
    @Published private var requestedSizeScale: CGFloat = 1
    var sizeScale: CGFloat {
        get { mergedScale ?? requestedSizeScale }
        set { requestedSizeScale = newValue }
    }
    /// Mirrors the persisted Appearance choice so the separate notch window
    /// redraws immediately when Settings changes it.
    @Published var accentColor: AccentColorChoice = .system
    /// Whether a provider's weekly limit gets a ring of its own, and where.
    /// Mirrored here for the same reason `accentColor` is: the notch is a
    /// separate window, and it has to redraw the moment Settings changes this.
    @Published var weeklyRing: WeeklyRing = .off
    /// Mirrors the persisted Appearance choice so the separate notch window
    /// redraws immediately when Settings changes it.
    @Published var surfaceStyle: NotchSurfaceStyle = .glass
    /// The display's own notch, when this edge has to share the bezel with one.
    ///
    /// Set by the window controller from the screen the panel is on, because
    /// that is the only thing that knows which screen that is.
    @Published var hardwareNotch: HardwareNotch?
    @Published private(set) var cutout: CutoutProximity?

    var plainBarLength: CGFloat {
        NotchLayout.shapeLength(cellCount: snapshots.count, edge: edge,
                                flare: NotchLayout.curlRadius, spacing: cellSpacing)
            * requestedSizeScale
    }

    /// How much screen there is to spend on the panel.
    ///
    /// The tooltip's budget comes out of this: how many sessions a card can
    /// list before the panel holding it would run off the display. Zero until
    /// the controller says otherwise, which reads as "no screen known yet".
    @Published var screenSize: CGSize = .zero

    /// Visible slice of the panel along its edge, in local stack coordinates.
    @Published var visibleAlongRange: ClosedRange<CGFloat>?

    func tooltipAlong(index: Int, length: CGFloat) -> CGFloat {
        let centre = ringPanelCenter(index: index)
        guard let range = visibleAlongRange else { return centre }
        let lower = range.lowerBound + length / 2
        let upper = range.upperBound - length / 2
        guard lower <= upper else { return (range.lowerBound + range.upperBound) / 2 }
        return min(max(centre, lower), upper)
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Language change leaves snapshots untouched; tick `now` so copy
        // already on screen is redrawn against the new catalog.
        NotificationCenter.default.publisher(for: L10n.didChange)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.now = Date() }
            }
            .store(in: &cancellables)
    }

    /// Take the notch geometry of whichever screen the panel is on.
    func adopt(screen: ScreenDescribing) {
        let proximity = NotchGeometry.cutoutProximity(
            for: screen, edge: edge, alongOffset: alongOffset,
            heldBar: holdsOffTheCutout ? plainBarLength : nil
        )
        if cutout != proximity { cutout = proximity }
        let merging = proximity?.joined == true ? screen.hardwareNotch : nil
        if hardwareNotch != merging { hardwareNotch = merging }
        // `frame`, not `visibleFrame`: the panel is centred on the full screen
        // and may sit under the menu bar, so the menu bar is not room lost.
        let size = screen.frameValue.size
        if screenSize != size { screenSize = size }
    }

    var contentInset: CGFloat { 0 }
    var mergesWithCutout: Bool { cutout?.joined == true }
    var contentDepth: CGFloat {
        guard mergesWithCutout else { return NotchLayout.bodyDepth(for: edge) }
        return NotchLayout.cellExtent + 2 * NotchLayout.ringMargin(for: edge)
    }
    var mergedScale: CGFloat? {
        guard let cutout, cutout.joined, contentDepth > 0 else { return nil }
        return (cutout.depth + NotchRootView.bezelBleed) / contentDepth
    }
    var cutoutBleed: CGFloat {
        guard mergesWithCutout else { return 0 }
        return (cutout?.overlap ?? 0) / max(sizeScale, 0.0001)
    }
    var flare: CGFloat { NotchLayout.curlRadius }
    var isFlushWithHardware: Bool { mergesWithCutout }
    var joinedNotch: HardwareNotch? { mergesWithCutout ? hardwareNotch : nil }
    var drawnCornerRadius: CGFloat { NotchLayout.cornerRadius }
    var carriedOnTheLeft: Bool { mergesWithCutout && cutout?.atTrailingEnd == true }
    var leavesTheCutoutAtItsTrailingEnd: Bool { cutout?.atTrailingEnd == true }

    struct Wing: Identifiable, Equatable {
        var id: Int
        var lead: CGFloat
        var onTheLeft: Bool
        var carriesCells: Bool
        var length: CGFloat
        var depth: CGFloat
    }

    var cellWing: Wing { wings.first(where: \.carriesCells)! }
    var handleWing: Wing { cellWing }

    var wings: [Wing] {
        let drawn = notchLength * sizeScale
        guard let cutout else {
            return [Wing(id: 0, lead: slack + (shapeLength * sizeScale - drawn) / 2,
                         onTheLeft: false, carriesCells: true, length: drawn, depth: notchDepth)]
        }
        let middle = (cutoutSpan + 2 * slack) / 2
        let half = cutout.width / 2
        func lead(left: Bool, overlap: CGFloat, length: CGFloat) -> CGFloat {
            left ? overlap - half - length + middle : half - overlap + middle
        }
        let left = mergesWithCutout ? cutout.atTrailingEnd
            : (holdsOffTheCutout ? false : cutout.atTrailingEnd)
        let carrying = Wing(id: 0, lead: lead(left: left, overlap: cutout.overlap, length: drawn),
                            onTheLeft: left, carriesCells: true, length: drawn, depth: notchDepth)
        let otherLeft = !carryingSide
        let otherLength = mergesWithCutout || revealsTheOtherCopy
            ? (readsAcrossTheCutout ? min(drawn, readingAcrossLength * sizeScale) : drawn) : 0
        let other = Wing(id: 1,
                         lead: lead(left: otherLeft,
                                    overlap: mergesWithCutout ? cutout.overlap : NotchGeometry.cutoutOverlap,
                                    length: otherLength),
                         onTheLeft: otherLeft, carriesCells: false, length: otherLength,
                         depth: (cutout.depth + NotchRootView.bezelBleed) / max(sizeScale, 0.0001))
        return otherLeft ? [other, carrying] : [carrying, other]
    }

    var readsAcrossTheCutout: Bool {
        mergesWithCutout && snapshots.count == 1 && snapshots[0].providerID.hasPrefix("codex")
    }

    private var carryingSide: Bool {
        guard let cutout else { return false }
        if mergesWithCutout || !holdsOffTheCutout { return cutout.atTrailingEnd }
        let bar = shapeLength * sizeScale
        return cutout.width / 2 - cutout.overlap + bar / 2 < 0
    }
    var showsCellReading: Bool { !readsAcrossTheCutout }
    var readingAcrossTextWidth: CGFloat {
        guard let snapshot = snapshots.first else { return 0 }
        return ProviderReading(snapshot: snapshot, showsRemaining: true).acrossWidth
    }
    var readingAcrossLength: CGFloat {
        let wall = (cutout?.overlap ?? NotchGeometry.cutoutOverlap) / max(sizeScale, 0.0001)
        return wall + 2 * NotchLayout.ringMargin(for: edge) + readingAcrossTextWidth + flare
    }
    var readingAcrossRun: ClosedRange<CGFloat> {
        let from = (cutout?.overlap ?? NotchGeometry.cutoutOverlap) / max(sizeScale, 0.0001)
            + NotchLayout.ringMargin(for: edge)
        let room = cellWing.length / max(sizeScale, 0.0001) - flare - drawnCornerRadius
        return from...max(from, min(from + readingAcrossTextWidth, room))
    }
    var cellsLeadIn: CGFloat { flare + NotchLayout.padStart(for: edge) + cutoutBleed }

    func notchShape(for wing: Wing) -> SideNotchShape {
        var shape = SideNotchShape(edge: edge)
        shape.cornerRadius = drawnCornerRadius
        shape.bezelHidden = NotchRootView.bezelBleed / max(sizeScale, 0.0001)
        guard let cutout else { return shape }
        shape.reflected = wing.onTheLeft
        if wing.carriesCells {
            shape.reflected = false
            shape.dip = carryingDip
            if holdsOffTheCutout, let (nearIn, farIn) = carryingEndsInTheHole, nearIn, farIn {
                shape.leadingJoin = 1
                shape.trailingJoin = 1
            }
            return shape
        }
        shape.leadingJoin = 1
        let scale = max(sizeScale, 0.0001)
        shape.emergesFrom = .init(
            buried: (mergesWithCutout ? cutout.overlap : NotchGeometry.cutoutOverlap) / scale,
            corner: cutout.depth * 31.2 / 90 / scale
        )
        return shape
    }

    /// What the orb scales to as it folds away. Nestled in a flare it grows
    /// **The one curve goo takes between the hole and a dragged notch.**
    ///
    /// Flat along the hole's foot to the wall, then easing down to the bar's
    /// own foot on the smoother step — flat at both ends, so there is no crease
    /// against the hole and none against the bar — over the distance from the
    /// wall to a flare-and-a-corner past the bar's near end. Everything that
    /// shapes the notch near the hole while it is in the hand follows this: the
    /// bar's own dip where it reaches into the hole, and the strand across a
    /// gap. There used to be a mask cutting the bar as well, and wherever its
    /// cut crossed the bar's own curved end it left a point.
    var gooReach: CGFloat { (flare + drawnCornerRadius) * sizeScale }

    /// Whether each end of the bar in the hand is inside the hole's width.
    private var carryingEndsInTheHole: (near: Bool, far: Bool)? {
        guard let cutout else { return nil }
        let bar = cellWing
        let middle = (cutoutSpan + 2 * slack) / 2
        let left = middle - cutout.width / 2, right = middle + cutout.width / 2
        let near = bar.lead, far = bar.lead + bar.length
        // An end *at* a wall is not in yet: the glide stops there with its end
        // still curved, and it closes up square only as the join takes it in
        // past the wall — closing up outside, its corner shrank to a point in
        // plain view. (Its dip, on the other hand, is already under way.)
        let e: CGFloat = -0.5
        return (near > left - e && near < right + e, far > left - e && far < right + e)
    }

    /// **Where the bar dips to pass through the hole** — see
    /// `SideNotchShape.Dip`. In the bar's own measure, from its leading tip,
    /// eased out past a wall only where the bar reaches across that wall.
    ///
    /// There whenever the bar is beside the hole, in the hand or joined, and
    /// only its `amount` says whether any of the bar is over the hole — so that
    /// letting go, gliding onto the wall and taking the hole are one animation
    /// of the same numbers, rather than a dip that appears or vanishes in a
    /// frame. Joined, the bar is exactly as deep as the hole and the dip
    /// changes nothing.
    var carryingDip: SideNotchShape.Dip? {
        guard let cutout else { return nil }
        let bar = cellWing
        let middle = (cutoutSpan + 2 * slack) / 2
        let half = cutout.width / 2
        let left = middle - half, right = middle + half
        let near = bar.lead, far = bar.lead + bar.length
        // An end *at* a wall counts as over the hole and across that wall, so
        // the glide onto the wall lifts its foot toward the hole's under the
        // strand, and the join is left only the bar going in.
        let e: CGFloat = 0.5
        let over = far > left - e && near < right + e
        // Clear of the hole, eased on the side it will come in from.
        let before = near < left - e && far > left - e || !over && far <= left
        let after = near < right + e && far > right + e || !over && near >= right
        let from = left - near, to = right - near
        let scale = max(sizeScale, 0.0001)
        return SideNotchShape.Dip(from: from / scale,
                                  to: to / scale,
                                  depth: (cutout.depth + NotchRootView.bezelBleed) / scale,
                                  reach: gooReach / scale,
                                  easesBefore: before,
                                  easesAfter: after,
                                  // Measured: a circular arc of 31.2px on a 90px-deep cutout.
                                  corner: cutout.depth * 31.2 / 90 / scale,
                                  // Folded, the bar is the notch at rest and
                                  // nothing of it squeezes anywhere.
                                  amount: over && isExpanded ? 1 : 0,
                                  closes: NotchGeometry.cutoutOverlap / scale)
    }

    /// **The strand of black between a dragged notch and the hole.**
    ///
    /// Goo pulled off a surface does not part from it: it stretches, thins in
    /// the middle, and lets go, and at no moment does it meet either surface at
    /// an angle. So the strand's underside always leaves the hole *along the
    /// hole's own outline* — its foot, then its rounded corner, then its wall —
    /// and arrives on the bar along the bar's own outline — its foot, its
    /// corner, its side, its flare — each time heading the way that outline is
    /// heading, so where one stops and the other starts there is nothing to
    /// see. Pulled away, the two points it leaves from climb those outlines, its
    /// middle thins up into the bezel, and each half draws back into the thing
    /// it came from until nothing is left.
    ///
    /// It used to be one curve scaled toward the bezel as it went. Scaled, its
    /// end at the hole was shallower than the hole's foot: it cut across the
    /// Mac's rounded corner, or met the hole's wall square, and it ran into the
    /// bar's side the same way — the points, and the corner that looked like
    /// it had lost its radius. Worked out from where the bar is, so it follows
    /// the hand with nothing to catch up on.
    struct Neck: Equatable {
        /// Along the panel: the hole's wall nearest the bar, and the bar's end
        /// facing it. `side` is 1 when the bar is right of the wall, −1 left.
        var wall: CGFloat
        var tip: CGFloat
        var side: CGFloat
        /// Down from the top of the screen: the hole's foot, and the radius of
        /// its corner.
        var holeDepth: CGFloat
        var holeCorner: CGFloat
        /// The bar's foot, and its end: the flare's reach and the corner's.
        var barDepth: CGFloat
        var barFlare: CGFloat
        var barCorner: CGFloat
        /// How far it has been pulled apart, 0 where the two touch to 1 where
        /// it lets go.
        var apart: CGFloat
        /// How far the bar's end facing the hole has closed up square, and how
        /// much of the bar's dip there is — the same two numbers the bar is
        /// drawn with, easing on the same animation, so the strand always
        /// meets the bar's end as it actually is. Meeting the end it would
        /// have had, it left the bar's bottom corner poking out beneath it
        /// while the bar went in.
        var barJoin: CGFloat = 0
        var dipAmount: CGFloat = 0
    }

    var neck: Neck? {
        // Joined as well as in the hand: joined, it lies flat along the joined
        // bar's own foot where nothing of it shows — but it is *there*, so
        // taking the hole eases it flat rather than dropping it in a frame.
        guard holdsOffTheCutout || mergesWithCutout, isExpanded, let cutout else { return nil }
        let carrying = cellWing
        let middle = (cutoutSpan + 2 * slack) / 2
        let half = cutout.width / 2
        // The wall nearest the bar, the bar's end that faces it, and its other.
        let onTheRight = carrying.lead + carrying.length / 2 >= middle
        let wall = onTheRight ? middle + half : middle - half
        let tip = onTheRight ? carrying.lead : carrying.lead + carrying.length
        let far = onTheRight ? carrying.lead + carrying.length : carrying.lead
        // A bar gone all the way into the hole has nothing out on this side.
        guard onTheRight ? far > wall : far < wall else { return nil }
        let gap = onTheRight ? tip - wall : wall - tip
        let stretch = NotchGeometry.cutoutStretch
        guard gap < stretch else { return nil }
        // The bar's end as `SideNotchShape` draws it, with no more room than
        // the bar has for it.
        let depth = max(cutout.depth, carrying.depth * sizeScale - NotchRootView.bezelBleed)
        let flare = min(self.flare * sizeScale, depth)
        let corner = max(0, min(drawnCornerRadius * sizeScale, depth - flare,
                                (carrying.length - 2 * flare) / 2))
        let shape = notchShape(for: carrying)
        return Neck(wall: wall, tip: tip, side: onTheRight ? 1 : -1,
                    holeDepth: cutout.depth,
                    // Measured: a circular arc of 31.2px on a 90px-deep cutout.
                    holeCorner: cutout.depth * 31.2 / 90,
                    barDepth: depth, barFlare: flare, barCorner: corner,
                    apart: max(0, gap) / stretch,
                    barJoin: onTheRight ? shape.leadingJoin : shape.trailingJoin,
                    dipAmount: shape.dip?.amount ?? 0)
    }

    /// **Whether the other copy is coming out of the hole ahead of the join.**
    ///
    /// Set the moment a dragged notch is let go near the hole, so the other copy
    /// starts flowing out of its wall *while* the carrying copy glides to its
    /// own, rather than after it has arrived. The join then finds it already on
    /// its way and simply carries on.
    @Published var revealsTheOtherCopy = false

    /// outward along the normal and is swallowed by the notch's black; hanging
    /// off a corner there is nothing to be swallowed by, so it draws in on
    /// itself and leaves by the fade.
    var orbMergeScale: CGFloat { NotchLayout.orbMergeScale }

    /// The circle the resting arc follows.
    var orbArcRadius: CGFloat {
        orbHugsCorner
            ? NotchLayout.orbConvexArcRadius(corner: drawnCornerRadius)
            : NotchLayout.orbArcRadius
    }

    /// Extra length at each end of the body so the notch has something to open
    /// out *into*.
    ///
    /// A single ring makes a body about 117pt across; this Mac's notch is 220.
    /// Left alone the hardware would be wider than the bar it is supposed to
    /// grow into, which reads as a mistake. Matching it exactly is not enough
    /// either — a bar the same width as the notch is a straight column, and the
    /// notch appears not to have opened at all. So the floor is the notch plus
    /// a fillet's worth of opening at each side, and a corner's worth beyond
    /// that for the bar's own rounding to live in.
    var endSpread: CGFloat { endSpread(cellCount: snapshots.count) }

    func endSpread(cellCount: Int) -> CGFloat {
        guard let hardwareNotch, !mergesWithCutout else { return 0 }
        // Expressed against the whole shape, not just its body: with no flares
        // the drawn width *is* the shape's length, and that is what has to
        // clear the hardware.
        let drawn = NotchLayout.shapeLength(
            cellCount: cellCount, edge: edge, flare: flare
        )
        let wanted = hardwareNotch.width / max(sizeScale, 0.0001)
            + 2 * NotchLayout.cornerRadius
        return max(0, (wanted - drawn) / 2)
    }

    /// Where the settings orb sits.
    ///
    /// Ordinarily it is concentric with the far flare, one radius in from the
    /// bezel and level with the end of the shape. A flush bar has no flare, so
    /// it hugs the bar's own bottom-end corner from outside instead — same
    /// idea, turned inside out. Left where it was it becomes a dot on the
    /// bar's flat edge.
    var orbHugsCorner: Bool { false }

    var orbAlong: CGFloat {
        carriedOnTheLeft ? 0 : shapeLength
    }

    /// Reserve the full hit area even while only the resting arc is visible,
    /// so revealing the settings button cannot put it beyond the screen.
    var trailingExtent: CGFloat {
        max(0, orbAlong - shapeLength + NotchLayout.orbHotZone / 2,
            gripAlong - shapeLength + NotchLayout.gripHotZone / 2).rounded(.up)
    }

    var freeTrailingExtent: CGFloat {
        (max(NotchLayout.orbHotZone / 2,
             gripReach + NotchLayout.gripHotZone / 2) * sizeScale).rounded(.up)
    }

    var gripAlong: CGFloat {
        let away: CGFloat = orbAlong <= 0 ? -1 : 1
        return orbAlong + away * gripReach
    }

    var gripReach: CGFloat {
        NotchLayout.orbDiameter / 2 + NotchLayout.gripGap + NotchLayout.gripWidth / 2
    }

    var gripPoint: CGPoint { CGPoint(x: gripAlong, y: orbInset) }

    func isOnGrip(along: CGFloat, across: CGFloat) -> Bool {
        hypot(along - gripPoint.x, across - gripPoint.y) <= NotchLayout.gripHotZone / 2
    }

    /// Where the bar's far corner actually turns, along the stack.
    ///
    /// Inset from the bar's end by the *flare* as well as by the corner's own
    /// radius — the shape's body starts a flare in from each end, and the
    /// corner is rounded off that body, not off the shape's outer bound.
    /// Leaving the flare out slid the arc a whole fillet down the bar, and the
    /// gap it is supposed to hold opened from 9pt at one end to 19pt at the
    /// other.
    var cornerCentreAlong: CGFloat {
        shapeLength - flare - drawnCornerRadius
    }

    var orbInset: CGFloat { mergesWithCutout ? flare : NotchLayout.orbInsetFromEdge }
    var orbScale: CGFloat { 1 }
    var orbArcRadiusInOrbSpace: CGFloat { orbArcRadius }
    var orbArcOffsetInOrbSpace: CGSize { orbArcOffset }

    /// Where the resting arc sits relative to the button.
    ///
    /// Inside a flare's pocket the two are one object — the arc is just the
    /// outer edge of the same orb, and this is zero. Hanging off a convex
    /// corner they part company: the button has to be clear of the bar, but the
    /// arc's whole job is to trace the bar's contour, so it stays back on the
    /// corner the button hangs from.
    var orbArcOffset: CGSize {
        guard orbHugsCorner else { return .zero }
        let inward = CGPoint(x: -edge.outward.x, y: -edge.outward.y)
        let back = -NotchLayout.orbCornerOffset(corner: drawnCornerRadius)
        return CGSize(width: back * (edge.alongDirection.x + inward.x),
                      height: back * (edge.alongDirection.y + inward.y))
    }

    /// The points the settings handle answers around: the button you are
    /// reaching for, and — where it has parted company with it — the arc you
    /// can actually see.
    var orbHandlePoints: [CGPoint] {
        let button = CGPoint(x: orbAlong, y: orbInset)
        let arcCentre = CGPoint(x: orbAlong + orbArcOffset.width,
                                y: orbInset + orbArcOffset.height)
        let arcOffset = FlareArc.point(
            0.5,
            offset: NotchLayout.orbClearance,
            flare: orbArcRadius + NotchLayout.orbGap,
            centre: .zero,
            trim: SettingsOrb.restingTrim(for: edge, convex: orbHugsCorner,
                                          reversed: carriedOnTheLeft),
            edge: edge
        )
        return [CGPoint(x: arcCentre.x + arcOffset.x, y: arcCentre.y + arcOffset.y), button]
    }

    /// Whether a point in stack space is on the settings handle.
    ///
    /// A circle around each of those points, rather than one box around the
    /// pair. The handle is a round thing in two places, and the bounding box of
    /// the two takes in a great deal of ground that is near neither — which is
    /// why the button used to appear well before the pointer reached the arc.
    func isOnOrbHandle(along: CGFloat, across: CGFloat) -> Bool {
        let radius = NotchLayout.orbHotZone / 2
        return orbHandlePoints.contains {
            hypot(along - $0.x, across - $0.y) <= radius
        }
    }


    /// Where the tooltip's tail tip sits, measured in from the bezel: just off
    /// the inner face of a shape that the extension has made deeper.
    var tooltipInset: CGFloat {
        notchDrawnDepth + NotchLayout.tailGap
    }

    /// How deep the notch body reaches on screen — the design-frame depth at
    /// the size it is actually drawn.
    ///
    /// Where the notch ends is where the tooltip begins, and the tooltip is not
    /// drawn at that size, so this is the seam between the two spaces rather
    /// than a measurement either of them owns.
    var notchDrawnDepth: CGFloat {
        contentDepth * sizeScale
    }

    /// The straight part of the shape, flares excluded.
    var bodyLength: CGFloat { NotchLayout.bodyLength(cellCount: snapshots.count, edge: edge, spacing: cellSpacing) }

    /// Distance along the stack to cell `index`'s ring centre, widening
    /// included so the readings stay in the middle of the bar.
    func ringCenter(index: Int) -> CGFloat {
        NotchLayout.ringCenter(index: index, edge: edge, flare: flare,
                              spacing: cellSpacing) + cutoutBleed
    }

    func ringPanelCenter(index: Int) -> CGFloat {
        return ringAlong(index: index, in: cellWing)
    }

    func ringAlong(index: Int, in wing: Wing) -> CGFloat {
        wing.lead + ringCenter(index: index) * sizeScale
    }

    struct TravelSize {
        var length: CGFloat
        var depth: CGFloat
        var ringCenters: [CGFloat]
        var ringAcross: CGFloat
        var cellShift: CGFloat
    }

    func travelSize(on edge: NotchEdge) -> TravelSize {
        let scale = requestedSizeScale
        let count = snapshots.count
        let spacing = cellSpacing(cellCount: count, on: edge)
        let depth = NotchLayout.bodyDepth(for: edge)
        return TravelSize(
            length: NotchLayout.shapeLength(cellCount: count, edge: edge,
                                            flare: flare, spacing: spacing) * scale,
            depth: depth * scale,
            ringCenters: snapshots.indices.map {
                NotchLayout.ringCenter(index: $0, edge: edge, flare: flare, spacing: spacing) * scale
            },
            ringAcross: depth / 2 * scale,
            cellShift: edge.isVertical && showsCellReading
                ? (NotchLayout.cellExtent - NotchLayout.ringDiameter) / 2 * scale : 0)
    }

    func alongWithin(_ along: CGFloat, of wing: Wing) -> CGFloat? {
        guard along >= wing.lead - 0.001, along <= wing.lead + wing.length + 0.001 else { return nil }
        return (along - wing.lead) / max(sizeScale, 0.0001)
    }

    var cellSpacing: CGFloat { cellSpacing(cellCount: snapshots.count) }
    var cellPitch: CGFloat { NotchLayout.cellAlong(for: edge) + cellSpacing }

    private func cellSpacing(cellCount: Int, on edge: NotchEdge? = nil) -> CGFloat {
        let edge = edge ?? self.edge
        guard edge.isVertical, screenSize.height > 0, cellCount > 1 else {
            return NotchLayout.cellSpacing
        }
        // Extra model cells spend the gaps first. Reserve the cards actually
        // present; assuming four quota windows for every local model overflows laptops.
        let slack = NotchLayout.slack(for: edge,
            maxCardHeight: snapshots.isEmpty ? NotchLayout.maxCardHeight(sessionCap: 0)
                : contentCardHeight(sessionCap: 0),
            notchScale: sizeScale)
        let packed = NotchLayout.shapeLength(cellCount: cellCount, edge: edge,
                                             flare: flare, spacing: 0)
        return min(NotchLayout.cellSpacing,
                   max(0, ((screenSize.height - 2 * slack) / sizeScale - packed) / CGFloat(cellCount - 1)))
    }

    /// A provider with no activity source gets none, rather than borrowing
    /// somebody else's.
    func activity(for snapshot: ProviderSnapshot) -> ActivitySummary? {
        guard let model = snapshot.localModel else { return activity(for: snapshot.providerID) }
        guard let since = thinkingModels[OllamaThinkingStream.modelKey(model.name)] else { return nil }
        return ActivitySummary(sessions: [AgentSession(id: snapshot.id, name: "Thinking",
            detail: "Ollama", state: .busy, waitingFor: nil, since: since)])
    }

    func activity(for providerID: String) -> ActivitySummary? {
        ActivitySummary(sessions: sessions[providerID] ?? [])
    }

    var hoveredSnapshot: ProviderSnapshot? {
        guard let hoveredIndex, snapshots.indices.contains(hoveredIndex) else { return nil }
        return snapshots[hoveredIndex]
    }

    var shapeLength: CGFloat { shapeLength(cellCount: snapshots.count) }

    var panelSize: CGSize { panelSize(cellCount: snapshots.count) }

    /// How stack space maps onto the panel right now.
    var placement: NotchPlacement { NotchPlacement(edge: edge, panelSize: panelSize) }

    /// Room at each end of the stack, for this edge.
    var slack: CGFloat { slack(cellCount: snapshots.count) }

    func slack(cellCount: Int) -> CGFloat {
        NotchLayout.slack(for: edge,
                          maxCardHeight: maxCardHeight(cellCount: cellCount),
                          notchScale: sizeScale)
    }

    /// How many sessions a tooltip may list here before it has to summarise
    /// the rest — as many as this screen has room for.
    var sessionCap: Int { sessionCap(cellCount: snapshots.count) }

    private var hasTokenUsage: Bool {
        snapshots.contains { $0.tokenUsage != nil }
    }

    func sessionCap(cellCount: Int) -> Int {
        guard screenSize != .zero else { return NotchLayout.defaultSessionCap }
        return NotchLayout.sessionsFitting(cardBudget: cardBudget(cellCount: cellCount),
                                           windowCount: NotchLayout.maxWindowCount,
                                           hasTokenUsage: hasTokenUsage)
    }

    private func contentCardHeight(sessionCap: Int) -> CGFloat {
        snapshots.map { snapshot in
            NotchLayout.cardHeight(windowCount: snapshot.windows.count,
                groupCount: Set(snapshot.windows.compactMap(\.group)).count,
                sessionCount: snapshot.localModel == nil ? sessionCap + 1 : 0,
                sessionCap: sessionCap,
                statusMessage: snapshot.statusMessage,
                blockMessage: snapshot.block?.summary(now: now),
                hasTokenUsage: snapshot.tokenUsage != nil,
                localModelName: snapshot.localModel?.name,
                showsLocalPerformance: snapshot.showsLocalPerformance,
                compactRowCount: snapshot.compactRowCount)
        }.max() ?? 0
    }

    func maxCardHeight(cellCount: Int) -> CGFloat {
        let cap = sessionCap(cellCount: cellCount)
        return snapshots.isEmpty
            ? NotchLayout.maxCardHeight(sessionCap: cap, hasTokenUsage: hasTokenUsage)
            : contentCardHeight(sessionCap: cap)
    }

    /// How tall the tallest card may be before the panel runs off the screen.
    ///
    /// Which way it runs out differs by orientation, because the card's height
    /// is spent on a different axis: along a side edge it is spent *along* the
    /// stack, half of it past each end, so the stack itself takes its share
    /// first. Along a horizontal edge the card hangs *inward* instead, and what
    /// it competes with is the depth already spent on the notch body and tail.
    /// The screen is measured in real points, and everything it is compared
    /// against here is unscaled. Dividing brings the screen into the same space
    /// rather than scaling the four constants below it: at `large` a card sized
    /// against the raw height would be drawn a quarter taller than it was
    /// budgeted for, and run off the bottom of a small display.
    private func cardBudget(cellCount: Int) -> CGFloat {
        if edge.isVertical {
            return screenSize.height / sizeScale
                - shapeLength(cellCount: cellCount)
                - 2 * NotchLayout.cardCorner
        }
        return screenSize.height / sizeScale
            - contentInset
            - NotchLayout.bodyDepth(for: edge)
            - NotchLayout.tailLength
            - NotchLayout.tailGap
    }

    /// The drawn extent of the notch body right now, along the stack.
    ///
    /// Where it is joining the display's own notch, folding away means becoming
    /// exactly that notch — same width, same height. The resting pill is the
    /// wrong object there: it hangs below the hardware as a separate little
    /// tab, which is the very seam this placement exists to remove. Matching
    /// the hardware instead means nothing shows at rest at all, and reaching
    /// for it makes the notch itself grow.
    var notchLength: CGFloat {
        if isExpanded { return shapeLength }
        return hardwareNotch == nil ? NotchLayout.pillHeight : restingLength
    }

    /// And across it.
    var notchDepth: CGFloat {
        if mergesWithCutout { return contentDepth }
        if isExpanded { return NotchLayout.bodyDepth(for: edge) }
        return hardwareNotch?.height ?? NotchLayout.pillWidth
    }

    /// What the notch folds away to, whether or not it is open right now —
    /// the hit region has to know that while the notch is still open.
    var restingLength: CGFloat { NotchLayout.pillHeight + cutoutBleed }
    var restingDepth: CGFloat { mergesWithCutout ? contentDepth : NotchLayout.pillWidth }

    /// What wakes the folded notch, in panel points: the resting shape and a
    /// band around it, or the resting shape alone.
    ///
    /// The band is for the pill. A 10pt sliver on a screen edge is a fiddly
    /// target, and the only cost of surrounding it is that it opens a little
    /// eagerly. Joined to the hardware notch the band is a different matter:
    /// the notch is already a generous target, and a band around it reached
    /// 34pt *below* the menu bar — across the title bar of a window tiled
    /// against the centre of the screen, whose close, minimise and zoom
    /// buttons then opened the notch on approach and disappeared under it.
    /// Flush with the hardware, what wakes the notch is the notch.
    var wakeLength: CGFloat {
        mergesWithCutout ? (hardwareNotch?.width ?? 0) : max(restingLength * sizeScale, wakeBand)
    }
    var wakeDepth: CGFloat {
        mergesWithCutout ? (hardwareNotch?.height ?? 0) : restingDepth * sizeScale + wakeBand
    }
    private var wakeBand: CGFloat { isFlushWithHardware ? 0 : NotchLayout.pillHotZone }

    func wakeRect(panelSize: CGSize) -> CGRect {
        let placement = NotchPlacement(edge: edge, panelSize: panelSize)
        let along = mergesWithCutout
            ? panelSize.width / 2 - wakeLength / 2
            : slack + (shapeLength * sizeScale - wakeLength) / 2
        return placement.rect(along: along, across: 0, length: wakeLength, depth: wakeDepth)
    }

    /// The drawn size of the notch body, in panel axes.
    var notchSize: CGSize {
        NotchPlacement.panelSize(edge: edge, length: notchLength, depth: notchDepth)
    }

    /// Where the notch starts along the stack. Both states share a centre line,
    /// so folding away does not slide the notch along the edge as it shrinks.
    var notchLeadingInset: CGFloat {
        slack + (shapeLength - notchLength) / 2
    }

    /// Sized from an explicit count rather than from `snapshots`.
    ///
    /// `@Published` notifies its subscribers in `willSet`, so a sink reacting to
    /// a change in the provider list still sees the *old* array if it reads the
    /// model back. Taking the count as an argument is the only way to be sure
    /// the panel is sized for the list that caused the change.
    func shapeLength(cellCount: Int) -> CGFloat {
        NotchLayout.bodyLength(cellCount: cellCount, edge: edge,
                               spacing: cellSpacing(cellCount: cellCount))
            + 2 * flare + cutoutBleed
    }

    /// The panel as it lands on screen, size choice included.
    ///
    /// Two spaces, added rather than multiplied together: the notch is drawn at
    /// `sizeScale`, and the tooltip is drawn at one size whatever the notch is
    /// set to — its text has a legible size of its own, and shrinking the
    /// reading you opened the notch to read is the opposite of the point.
    ///
    /// So the notch's share scales and the card's share does not. Scaling the
    /// whole panel instead left the card cropped at the small end, where the
    /// panel had shrunk around a card that had not.
    func panelSize(cellCount: Int) -> CGSize {
        let card = maxCardHeight(cellCount: cellCount)
        let length = cutout == nil ? shapeLength(cellCount: cellCount) * sizeScale : cutoutSpan
        return NotchPlacement.panelSize(
            edge: edge,
            length: length + 2 * NotchLayout.slack(for: edge, maxCardHeight: card, notchScale: sizeScale),
            depth: contentDepth * sizeScale
                + NotchLayout.tooltipDepth(for: edge, maxCardHeight: card)
        )
    }

    var cutoutSpan: CGFloat {
        guard let cutout else { return shapeLength * sizeScale }
        let plain = NotchLayout.shapeLength(cellCount: snapshots.count, edge: edge,
                                            flare: flare, spacing: cellSpacing)
        return cutout.width - 2 * NotchGeometry.cutoutOverlap
            + 2 * (plain * requestedSizeScale + 2 * NotchGeometry.cutoutDeepest)
    }
}
