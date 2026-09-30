import AppKit
import SwiftUI
import Combine

@MainActor
final class NotchWindowController {
    let model = NotchViewModel()
    var displayPreference: DisplayPreference = .followActiveWindow

    /// The panel's content view, so a test can check what SwiftUI is and is not
    /// allowed to reach.
    var panelContentViewForTesting: NSView? { panel?.contentView }

    /// What AppKit settled on, for tests that need to see the panel move and
    /// fade rather than take our word for it.
    var panelFrameForTesting: CGRect? { panel?.frame }
    var panelAlphaForTesting: CGFloat { panel?.alphaValue ?? 0 }

    /// Hooked up by the app delegate; drives the menu's "Refresh now".
    var onRefresh: (() -> Void)?
    /// Persists the menu's "Keep open" choice in Preferences.
    var onToggleKeepOpen: (() -> Void)?
    /// One "Sign in to …" item per provider that needs a browser session.
    var signInItems: [(title: String, action: () -> Void)] = []
    /// Refetch a single provider, asked for by clicking its ring.
    var onRefreshProvider: ((String) async -> Void)?
    /// Open the settings window, asked for by clicking the handle.
    var onOpenSettings: (() -> Void)?
    /// An ⌥-drag on the pill settled at a new `model.alongOffset`. The
    /// controller only holds the live value; persisting it per edge is
    /// Preferences' job, the same division `apply(edge:)` already keeps.
    var onReposition: ((CGFloat) -> Void)?
    var onMoveToEdge: ((NotchEdge, CGFloat) -> Void)?

    private var panel: NotchPanel?
    private var hostingView: NotchHostingView<NotchRootView>?

    /// The display this notch belongs to. Nil follows the menu-bar screen,
    /// which is what a single-controller setup did before the fleet existed —
    /// so leaving it unset changes nothing.
    var assignedScreen: NSScreen?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitors: [Any] = []
    private var clearHoverWork: DispatchWorkItem?
    private var clockTimer: Timer?
    private var cursorTimer: Timer?

    /// Hover in is quick; hover out waits, because the pointer has to cross the
    /// gap between the notch and the card without the card vanishing under it.
    private let hoverGrace: TimeInterval = 0.25
    /// Longer than the hover grace: folding shut is a bigger movement than
    /// dismissing a tooltip, and doing it the instant the pointer strays feels
    /// twitchy rather than responsive.
    private let foldGrace: TimeInterval = 0.45
    private var foldWork: DispatchWorkItem?
    /// Folds the notch again after a peek, when nothing else is holding it open.
    private var peekWork: DispatchWorkItem?
    /// The session a peek is currently offering, and how long the offer lasts.
    ///
    /// A click on the open notch normally pins it or refetches a ring; while
    /// this is set and unexpired it jumps to the session instead. The expiry is
    /// what keeps the two apart — without it, the *next* click on the notch,
    /// minutes later and about something else, would still be raising a
    /// terminal window.
    private var pendingFocus: (pid: pid_t, until: Date)?
    /// When the current peek's five seconds are up.
    ///
    /// The hover fold has to be told to leave it alone until then. Without
    /// this the cursor poll — which runs every 0.3s and asks "is the pointer on
    /// the notch?", to which the answer during a peek is almost always no —
    /// scheduled a fold immediately, and the notch opened and shut inside a
    /// second. A peek is not the pointer arriving, so the pointer leaving is
    /// not what should end it.
    private var peekUntil: Date?
    /// The standing visibility choice, so a peek never overrides Hidden.
    private var visibility: NotchVisibility = .onHover
    /// Whether we have pushed the pointing hand onto the cursor stack.
    private var isPointing = false
    private var passage: CornerPassageOverlay?
    private var dragScreen: NSScreen?
    private var dragStartEdge: NotchEdge?
    private var pointerReading: Reading = .edge(.top)
    private var pointerEdge: NotchEdge = .top
    private var grip: CGFloat = 0
    private var travelTarget: CGFloat?
    private var travelShown: CGFloat?
    private var travelVelocity: CGFloat = 0
    private var follower: CADisplayLink?
    private var ticker: DisplayTick?
    private var lastTick: CFTimeInterval?
    private var settling = false
    private var overlaid = false
    private var passing: (corner: BorderTrack.Corner, before: CGFloat, after: CGFloat)?
    private var passageEdge: NotchEdge = .top
    private var travelSizes: [NotchEdge: NotchViewModel.TravelSize] = [:]
    private var heldCutout: HardwareNotch?
    private var heldPointer: CGFloat = 0
    private var restingOnGrip: CGPoint?

    /// Determines whether a full-screen application window is active on this notch's display.
    /// Default implementation queries WindowServer and NSWorkspace; overridable for testing.
    lazy var isFullScreenActive: () -> Bool = { [weak self] in
        FullScreenDetector.isFullScreenAppFrontmost(on: self?.currentScreen())
    }

    /// When a full-screen app is active on the current space, auto-folds the notch.
    /// When returning to a desktop space with `isAlwaysOn`, restores the unfolded state.
    func handleActiveSpaceOrAppChange() {
        if isFullScreenActive() {
            foldForFullScreen()
        } else if model.isAlwaysOn && !model.isExpanded {
            withAnimation(NotchMotion.unfold) {
                model.isExpanded = true
            }
            updateInteractiveRects()
        }
    }

    /// Immediately folds the notch and clears pending peek/hover timers when a full-screen app takes focus.
    func foldForFullScreen() {
        foldWork?.cancel()
        foldWork = nil
        peekWork?.cancel()
        peekWork = nil
        peekUntil = nil
        model.isPinned = false
        guard model.isExpanded else { return }
        withAnimation(NotchMotion.unfold) {
            model.isExpanded = false
            model.hoveredIndex = nil
        }
        setPointing(false)
        updateInteractiveRects()
    }

    func show() {
        relocate()
        startWatchingCursor()
        startClock()

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let dragScreen = self.dragScreen,
                   !NSScreen.screens.contains(where: { $0 === dragScreen }) {
                    self.cancelBorderDrag()
                }
                self.relocate()
            }
        }
        .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.activeSpaceDidChangeNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.handleActiveSpaceOrAppChange() }
        }
        .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.handleActiveSpaceOrAppChange() }
        }
        .store(in: &cancellables)

        model.$hoveredIndex
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateInteractiveRects() }
            }
            .store(in: &cancellables)

        // A model can gain speed rows without changing the cell count. Read
        // after Published's willSet so sizing sees the new card contents too.
        model.$snapshots
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relocate() }
            .store(in: &cancellables)

        // No `receive(on:)`: the appearance has to be on the window before the
        // next draw, or the frame's hexes and the glass would be resolved
        // against the appearance the panel is about to stop having.
        model.$surfaceStyle
            .removeDuplicates()
            .sink { [weak self] style in
                MainActor.assumeIsolated { self?.applyPanelAppearance(style) }
            }
            .store(in: &cancellables)

        // Reduce transparency resolves the glass style to the solid one, so
        // turning it on or off in System Settings changes what the panel's
        // appearance has to be. Nothing else republishes that: the style the
        // model holds has not changed.
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyPanelAppearance(self.model.surfaceStyle)
            }
        }
        .store(in: &cancellables)
    }

    private func applyPanelAppearance(_ style: NotchSurfaceStyle) {
        panel?.appearance = style.panelAppearance(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    func stop() {
        cancelBorderDrag()
        stopFollowing()
        setPointing(false)
        peekUntil = nil
        peekWork?.cancel()
        foldWork?.cancel()
        cursorTimer?.invalidate()
        cursorTimer = nil
        clockTimer?.invalidate()
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        cancellables.removeAll()
    }

    // MARK: - Placement

    /// The screen this notch lives on: its assigned display while that display
    /// is still connected, the menu-bar screen otherwise — so unplugging the
    /// display never strands the panel on a screen that no longer exists.
    /// Assigned first — the fleet has already picked this display for this
    /// controller, which is the whole point of there being more than one
    /// controller. `displayPreference` only comes into play once nothing has
    /// been assigned, which is the single-controller case `.mainDisplay`
    /// scope leaves it in.
    func currentScreen() -> NSScreen? {
        if let dragScreen,
           NSScreen.screens.contains(where: { $0 === dragScreen }) {
            return dragScreen
        }
        if let assigned = assignedScreen,
           NSScreen.screens.contains(where: { $0 === assigned }) {
            return assigned
        }
        return NotchGeometry.preferredScreen(from: NSScreen.screens, preference: displayPreference)
    }

    func relocate(cellCount: Int? = nil) {
        guard let screen = currentScreen() else { return }
        model.adopt(screen: screen)
        let size = model.panelSize(cellCount: cellCount ?? model.snapshots.count)
        let frame = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: model.edge,
            alongOffset: model.alongOffset, slack: model.slack,
            trailingExtent: model.trailingExtent
        )

        if let panel {
            panel.setFrame(frame, display: true)
        } else {
            let panel = NotchPanel(contentRect: frame)
            panel.appearance = model.surfaceStyle.panelAppearance(
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            )
            let hosting = NotchHostingView(rootView: NotchRootView(model: model))
            panel.contextMenuProvider = { [weak self] in self?.contextMenu() }
            panel.onClick = { [weak self] point in self?.handleClick(at: point) }
            panel.onDrag = { [weak self] dx, dy in self?.dragged(dx: dx, dy: dy) }
            panel.onDragStart = { [weak self] in self?.beginBorderDrag() }
            panel.startsDrag = { [weak self] point in
                guard let self, let panel = self.panel, self.model.isExpanded else { return false }
                let local = CGPoint(x: point.x, y: panel.frame.height - point.y)
                return self.isOverGrip(local)
            }
            panel.onDragEnd = { [weak self] in
                guard let self else { return }
                self.endBorderDrag()
            }

            // The hosting view goes *inside* a plain container rather than
            // being the content view itself.
            //
            // As the content view, SwiftUI gets a say in the window's frame: it
            // reports the content's ideal size, and this view's root is a
            // `GeometryReader`, whose ideal size is 10x10. On the side edges
            // that never surfaced. Turned horizontal, AppKit started walking
            // the window down toward it — 522pt of height to 266, to 10, to
            // zero — until nothing was drawn at all and the constraint pass
            // gave up and threw, taking the app with it.
            //
            // A container removes the channel instead of arguing with it. The
            // panel's size comes from `NotchGeometry` and from nowhere else,
            // which is what every hit region in this file already assumes.
            let container = NotchContainerView(frame: CGRect(origin: .zero, size: frame.size))
            container.autoresizingMask = [.width, .height]
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            panel.contentView = container
            panel.ignoresMouseEvents = true
            if !Runtime.isUnderTest { panel.orderFrontRegardless() }
            self.panel = panel
            self.hostingView = hosting
        }
        // Use the actual panel origin: near a corner its transparent padding
        // can extend offscreen, while the tooltip itself must stay visible.
        if let panel {
            let visible = panel.frame.intersection(screen.frame)
            let range: ClosedRange<CGFloat> = model.edge.isVertical
                ? (panel.frame.maxY - visible.maxY)...(panel.frame.maxY - visible.minY)
                : (visible.minX - panel.frame.minX)...(visible.maxX - panel.frame.minX)
            if model.visibleAlongRange != range { model.visibleAlongRange = range }
        }

        // The frame AppKit actually gave us, which is what the flush right-hand
        // edge depends on.
        if let panel {
            Log.usage.debug("panel \(NSStringFromRect(panel.frame), privacy: .public) on screen \(NSStringFromRect(screen.frame), privacy: .public)")
        }
        updateInteractiveRects()
    }

    private func dragged(dx: CGFloat, dy: CGFloat) {
        NSCursor.closedHand.set()
        guard let screen = dragScreen ?? currentScreen() else { return }
        travel(on: screen)
    }

    private func beginBorderDrag() {
        guard dragScreen == nil, !settling, let screen = currentScreen() else { return }
        dragScreen = screen
        dragStartEdge = model.edge
        model.isBeingDragged = true
        let fromHover = model.isExpanded && (model.isHoveringSettings || model.isHoveringMove)
        clearHoverWork?.cancel()
        clearHoverWork = nil
        foldWork?.cancel()
        foldWork = nil
        model.hoveredIndex = nil
        pickUp()
        model.isHoveringSettings = false
        model.isHoveringMove = false
        model.carry = Carry(at: Date(), fromHover: fromHover)
        setPointing(false)
        travelSizes = Dictionary(uniqueKeysWithValues: NotchEdge.allCases.map { ($0, model.travelSize(on: $0)) })
        grip(on: screen)
        let overlay = CornerPassageOverlay(screen: screen)
        overlay.prepare()
        passage = overlay
        travel(on: screen)
        updateInteractiveRects()
    }

    private func endBorderDrag() {
        guard dragScreen != nil, !settling else { return }
        model.carry?.releasedAt = Date()
        guard let screen = dragScreen else { finishDrag(); return }
        let frame = screen.frame
        let track = BorderTrack(width: frame.width, height: frame.height)
        var target = travelTarget ?? travelShown
        if let round = passing {
            let (first, second) = BorderTrack.edges(of: round.corner)
            let toward = round.before >= round.after ? first : second
            let half = travelSize(toward).length / 2 + 1
            target = track.wrapped(track.position(of: round.corner) + (toward == first ? -half : half))
        }
        guard let target else { finishDrag(); return }
        travelTarget = resting(target, on: track)
        settling = true
        startFollowing()
    }

    private func resting(_ place: CGFloat, on track: BorderTrack) -> CGFloat {
        let (edge, along) = track.place(at: place)
        if besideTheHole(place, on: track, screen: dragScreen) { return place }
        let half = travelSize(edge).length / 2
        let extent = edge.isVertical ? track.height : track.width
        let room = model.freeTrailingExtent
        let low = half, high = extent - half - room
        let held = low <= high ? min(max(along, low), high) : extent / 2
        let point = edge.isVertical ? CGPoint(x: 0, y: held) : CGPoint(x: held, y: 0)
        return track.position(on: edge, of: point)
    }

    private func finishDrag() {
        settling = false
        let landed = Date()
        model.carry?.landedAt = landed
        DispatchQueue.main.asyncAfter(deadline: .now() + Carry.settles) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.carry?.landedAt == landed else { return }
                self.model.carry = nil
                self.model.revealsTheOtherCopy = false
            }
        }
        if model.carry?.fromHover == true {
            restingOnGrip = NSEvent.mouseLocation
            model.isHoveringMove = true
        }
        let landing = stopTravelling()
        model.isBeingDragged = false
        if let place = landing, let screen = dragScreen {
            endOverlay(at: place, on: BorderTrack(width: screen.frame.width, height: screen.frame.height), frame: screen.frame)
        }
        let oldEdge = dragStartEdge
        dragStartEdge = nil
        passage?.hide()
        passage = nil
        setPointing(false)
        putDown()
        if let oldEdge, oldEdge != model.edge {
            onMoveToEdge?(model.edge, model.alongOffset)
        } else {
            onReposition?(model.alongOffset)
        }
        dragScreen = nil
        heldCutout = nil
        updateInteractiveRects()
        cursorMoved()
    }

    private func cancelBorderDrag() {
        guard dragScreen != nil || passage != nil else { return }
        stopFollowing()
        passage?.hide()
        passage = nil
        overlaid = false
        passing = nil
        travelTarget = nil
        travelShown = nil
        travelVelocity = 0
        settling = false
        model.isBeingDragged = false
        model.holdsOffTheCutout = false
        model.revealsTheOtherCopy = false
        model.carry = nil
        model.isHoveringMove = false
        dragStartEdge = nil
        dragScreen = nil
        heldCutout = nil
        panel?.alphaValue = 1
        relocate()
        updateInteractiveRects()
    }

    enum Reading: Equatable {
        case edge(NotchEdge)
        case corner(BorderTrack.Corner)
    }

    static let edgeSwitchMargin: CGFloat = 40
    static let cornerReach: CGFloat = 160
    static let followResponse: CGFloat = 0.2
    static let followDamping: CGFloat = 0.84
    static let settleResponse: CGFloat = 0.3
    static let settleDamping: CGFloat = 0.74
    static let maxStretch: CGFloat = 0.14
    static let stretchSpeed: CGFloat = 2600

    static func reading(of point: CGPoint, on track: BorderTrack, nearest: NotchEdge) -> Reading {
        for corner in BorderTrack.Corner.allCases {
            let (before, after) = BorderTrack.edges(of: corner)
            if distance(to: before, of: point, on: track) < cornerReach,
               distance(to: after, of: point, on: track) < cornerReach { return .corner(corner) }
        }
        return .edge(nearest)
    }

    static func place(of point: CGPoint, on track: BorderTrack, by reading: Reading) -> CGFloat {
        switch reading {
        case .edge(let edge): return track.position(on: edge, of: point)
        case .corner(let corner):
            let (before, after) = BorderTrack.edges(of: corner)
            return track.wrapped(track.position(of: corner)
                                 + distance(to: before, of: point, on: track)
                                 - distance(to: after, of: point, on: track))
        }
    }

    static func distance(to edge: NotchEdge, of point: CGPoint, on track: BorderTrack) -> CGFloat {
        switch edge {
        case .top: return max(0, point.y)
        case .bottom: return max(0, track.height - point.y)
        case .left: return max(0, point.x)
        case .right: return max(0, track.width - point.x)
        }
    }

    static func spring(gap: CGFloat, velocity: CGFloat, elapsed: CGFloat,
                       response: CGFloat, damping: CGFloat) -> (moved: CGFloat, velocity: CGFloat) {
        let omega = 2 * .pi / response
        var moved: CGFloat = 0, velocity = velocity
        for _ in 0..<2 {
            let dt = elapsed / 2
            let acceleration = omega * omega * (gap - moved) - 2 * damping * omega * velocity
            velocity += acceleration * dt
            moved += velocity * dt
        }
        return (moved, velocity)
    }

    static func stickyEdge(current: NotchEdge, pointer: CGPoint, frame: CGRect) -> NotchEdge {
        let nearest = NotchEdge.allCases.min {
            distance(from: $0, of: pointer, on: frame) < distance(from: $1, of: pointer, on: frame)
        } ?? current
        return distance(from: nearest, of: pointer, on: frame) + edgeSwitchMargin
            < distance(from: current, of: pointer, on: frame) ? nearest : current
    }

    static func distance(from edge: NotchEdge, of point: CGPoint, on frame: CGRect) -> CGFloat {
        switch edge {
        case .top: return frame.maxY - point.y
        case .bottom: return point.y - frame.minY
        case .left: return point.x - frame.minX
        case .right: return frame.maxX - point.x
        }
    }

    static func offset(along edge: NotchEdge, at point: CGPoint, on frame: CGRect) -> CGFloat {
        edge.isVertical ? frame.midY - point.y : point.x - frame.midX
    }

    private func travel(on screen: NSScreen) {
        let frame = screen.frame
        let track = BorderTrack(width: frame.width, height: frame.height)
        let local = CGPoint(x: NSEvent.mouseLocation.x - frame.minX,
                            y: frame.maxY - NSEvent.mouseLocation.y)
        let edge = Self.stickyEdge(current: pointerEdge, pointer: NSEvent.mouseLocation, frame: frame)
        let reading = Self.reading(of: local, on: track, nearest: edge)
        if reading != pointerReading {
            var step = Self.place(of: local, on: track, by: pointerReading)
                - Self.place(of: local, on: track, by: reading)
            if step > track.perimeter / 2 { step -= track.perimeter }
            if step < -track.perimeter / 2 { step += track.perimeter }
            grip += step
            pointerReading = reading
        }
        pointerEdge = edge
        travelTarget = track.wrapped(Self.place(of: local, on: track, by: pointerReading) + grip)
        startFollowing()
    }

    private func grip(on screen: NSScreen) {
        let frame = screen.frame
        let track = BorderTrack(width: frame.width, height: frame.height)
        pointerEdge = model.edge
        let local = CGPoint(x: NSEvent.mouseLocation.x - frame.minX,
                            y: frame.maxY - NSEvent.mouseLocation.y)
        pointerReading = Self.reading(of: local, on: track, nearest: model.edge)
        guard let panel else { grip = 0; return }
        let wing = model.cellWing
        let middle = model.edge.isVertical
            ? CGPoint(x: 0, y: frame.maxY - panel.frame.maxY + wing.lead + wing.length / 2)
            : CGPoint(x: panel.frame.minX - frame.minX + wing.lead + wing.length / 2, y: 0)
        var distance = track.position(on: model.edge, of: middle)
            - Self.place(of: local, on: track, by: pointerReading)
        if distance > track.perimeter / 2 { distance -= track.perimeter }
        if distance < -track.perimeter / 2 { distance += track.perimeter }
        grip = distance
    }

    private func startFollowing() {
        guard follower == nil, let screen = dragScreen else { return }
        let tick = DisplayTick { [weak self] link in MainActor.assumeIsolated { self?.follow(link) } }
        let link = screen.displayLink(target: tick, selector: #selector(DisplayTick.tick(_:)))
        link.add(to: .main, forMode: .common)
        follower = link
        ticker = tick
        lastTick = nil
    }

    private func stopFollowing() {
        follower?.invalidate()
        follower = nil
        ticker = nil
        lastTick = nil
    }

    private func follow(_ link: CADisplayLink) {
        guard let target = travelTarget, let screen = dragScreen else { return }
        let track = BorderTrack(width: screen.frame.width, height: screen.frame.height)
        let elapsed = CGFloat(min(max(link.timestamp - (lastTick ?? link.timestamp - link.duration), 0), 1.0 / 30))
        lastTick = link.timestamp
        guard let shown = travelShown else {
            travelShown = target
            travelVelocity = 0
            show(at: target, on: screen)
            return
        }
        var gap = target - shown
        if gap > track.perimeter / 2 { gap -= track.perimeter }
        if gap < -track.perimeter / 2 { gap += track.perimeter }
        if abs(gap) < (settling ? 0.3 : 0.05), abs(travelVelocity) < (settling ? 6 : 1) {
            travelVelocity = 0
            if settling { finishDrag() }
            return
        }
        let result = Self.spring(gap: gap, velocity: travelVelocity, elapsed: elapsed,
                                 response: settling ? Self.settleResponse : Self.followResponse,
                                 damping: settling ? Self.settleDamping : Self.followDamping)
        travelVelocity = result.velocity
        let next = track.wrapped(shown + result.moved)
        travelShown = next
        show(at: next, on: screen)
    }

    @discardableResult
    private func stopTravelling() -> CGFloat? {
        stopFollowing()
        let place = travelTarget ?? travelShown
        if let place, let screen = dragScreen { travelShown = place; show(at: place, on: screen) }
        travelTarget = nil
        travelShown = nil
        travelVelocity = 0
        return place
    }

    private func show(at place: CGFloat, on screen: NSScreen) {
        let frame = screen.frame
        let track = BorderTrack(width: frame.width, height: frame.height)
        if besideTheHole(place, on: track, screen: screen) {
            if overlaid {
                endOverlay(at: place, on: track, frame: frame)
            } else {
                put(at: place, on: track, frame: frame)
            }
            return
        }
        let stretch = Self.maxStretch * min(1, abs(travelVelocity) / Self.stretchSpeed)
        showOverlay(at: place, on: track, screen: screen, stretch: stretch,
                    heading: travelVelocity >= 0 ? 1 : -1)
    }

    private func besideTheHole(_ place: CGFloat, on track: BorderTrack, screen: NSScreen?) -> Bool {
        guard let screen, let cutout = screen.hardwareNotch else { return false }
        let (edge, along) = track.place(at: place)
        guard edge == .top else { return false }
        let free = along - track.width / 2 - cutout.width / 2
            + NotchGeometry.cutoutOverlap - model.plainBarLength / 2
        return NotchGeometry.cutoutFreelyNear(alongOffset: free, width: cutout.width, bar: model.plainBarLength)
    }

    private func put(at place: CGFloat, on track: BorderTrack, frame: CGRect) {
        let (edge, along) = track.place(at: place)
        if edge != model.edge { model.hoveredIndex = nil; model.edge = edge }
        if edge == .top, let screen = dragScreen, heldCutout == nil {
            heldCutout = screen.hardwareNotch
        }
        let point = edge.isVertical ? CGPoint(x: frame.minX, y: frame.maxY - along)
                                    : CGPoint(x: frame.minX + along, y: frame.maxY)
        var offset = Self.offset(along: edge, at: point, on: frame)
        if let cutout = heldCutout, edge == .top {
            heldPointer = offset - cutout.width / 2 + NotchGeometry.cutoutOverlap - model.plainBarLength / 2
            model.holdsOffTheCutout = true
            offset = NotchGeometry.magnetised(heldPointer, width: cutout.width, bar: model.plainBarLength)
        }
        model.alongOffset = offset
        relocate()
        updateInteractiveRects()
    }

    private func shape(at place: CGFloat, on track: BorderTrack, stretch: CGFloat = 0)
    -> (round: (corner: BorderTrack.Corner, before: CGFloat, after: CGFloat)?, length: CGFloat, turned: CGFloat) {
        let drawn = 1 + stretch
        var length = travelSize(track.place(at: place).edge).length * drawn
        guard var round = track.corner(for: place, length: length) else { return (nil, length, 0) }
        let (first, second) = BorderTrack.edges(of: round.corner)
        var turned: CGFloat = 0
        for _ in 0..<2 {
            let t = min(max(round.after / max(length, 1), 0), 1)
            turned = t * t * (3 - 2 * t)
            length = (travelSize(first).length + (travelSize(second).length - travelSize(first).length) * turned) * drawn
            guard let again = track.corner(for: place, length: length) else { return (nil, length, turned) }
            round = again
        }
        return (round, length, turned)
    }

    private func showOverlay(at hand: CGFloat, on track: BorderTrack, screen: NSScreen,
                             stretch: CGFloat, heading: CGFloat) {
        guard let overlay = passage else { return }
        if !overlaid { passageEdge = model.edge }
        let bleed = NotchRootView.bezelBleed
        let back = heading * travelSize(track.place(at: hand).edge).length * stretch / 2
        let place = track.wrapped(hand - back)
        let (round, length, turned) = shape(at: place, on: track, stretch: stretch)
        let thin = 1 - stretch * 0.35
        let edges = round.map { BorderTrack.edges(of: $0.corner) }
        let from = travelSize(edges?.before ?? track.place(at: place).edge)
        let to = travelSize(edges?.after ?? track.place(at: place).edge)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * turned }
        let size = model.sizeScale
        overlay.show(CornerPassageView(
            track: track, corner: round?.corner ?? .topLeft,
            before: round?.before ?? length, after: round?.after ?? 0,
            depth: bleed + (from.depth - bleed) * thin,
            depthAfter: bleed + (to.depth - bleed) * thin, bleed: bleed,
            cornerRadius: model.drawnCornerRadius * size, flare: model.flare * size,
            place: place,
            rings: passageRings(from: from, to: to, turned: turned, carriedBy: back),
            ringInset: mix(from.ringAcross, to.ringAcross) - bleed,
            ringScale: size,
            straight: round == nil ? track.place(at: place).edge : nil,
            arcs: passageArcs(at: place, length: length, on: track), carry: model.carry))
        passing = round.map { ($0.corner, $0.before, $0.after) }
        guard !overlaid else { return }
        overlaid = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { guard let self, self.overlaid else { return }; self.panel?.alphaValue = 0 }
        }
    }

    private func endOverlay(at place: CGFloat, on track: BorderTrack, frame: CGRect) {
        guard overlaid else { return }
        overlaid = false
        passing = nil
        put(at: place, on: track, frame: frame)
        panel?.alphaValue = 1
        let overlay = passage
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { guard self?.overlaid == false else { return }; overlay?.clear() }
        }
    }

    private func travelSize(_ edge: NotchEdge) -> NotchViewModel.TravelSize {
        travelSizes[edge] ?? model.travelSize(on: edge)
    }

    private func passageRings(from: NotchViewModel.TravelSize, to: NotchViewModel.TravelSize,
                              turned: CGFloat, carriedBy back: CGFloat) -> [PassageRing] {
        let sign: CGFloat = passageEdge == .top || passageEdge == .right ? 1 : -1
        return model.snapshots.enumerated().map { index, snapshot in
            let a = (from.ringCenters[safe: index] ?? 0) + from.cellShift - from.length / 2
            let b = (to.ringCenters[safe: index] ?? 0) + to.cellShift - to.length / 2
            return PassageRing(
                id: snapshot.id,
                cell: ProviderCell(snapshot: snapshot, activity: model.activity(for: snapshot),
                                   showsActivityArc: !snapshot.providerID.hasPrefix("codex"),
                                   showsRemaining: snapshot.providerID.hasPrefix("codex"),
                                   isRefreshing: model.isRefreshing(snapshot), weeklyRing: model.weeklyRing,
                                   showsReading: model.showsCellReading),
                offset: sign * (a + (b - a) * turned) + back)
        }
    }

    private func passageArcs(at place: CGFloat, length: CGFloat, on track: BorderTrack) -> [PassageArc] {
        let scale = model.sizeScale
        let sign: CGFloat = passageEdge == .top || passageEdge == .right ? 1 : -1
        let flare = model.flare * scale
        let end = track.wrapped(place + sign * length / 2)
        let (edge, along) = track.place(at: end)
        let runs: CGFloat = edge == .top || edge == .right ? 1 : -1
        let bodyToward = runs * -sign
        let trim = bodyToward > 0
            ? MoveHandle.restingTrim(for: edge, convex: false)
            : SettingsOrb.restingTrim(for: edge, convex: false)
        let centre: CGPoint
        switch edge {
        case .top: centre = CGPoint(x: along, y: flare)
        case .bottom: centre = CGPoint(x: along, y: track.height - flare)
        case .left: centre = CGPoint(x: flare, y: along)
        case .right: centre = CGPoint(x: track.width - flare, y: along)
        }
        let away = edge.isVertical ? CGPoint(x: 0, y: -bodyToward) : CGPoint(x: -bodyToward, y: 0)
        return [PassageArc(id: 0, centre: centre, edge: edge, trim: trim,
                           radius: (model.flare - NotchLayout.orbClearance) * scale,
                           gap: NotchLayout.orbClearance * scale,
                           stroke: NotchLayout.orbStroke * scale, away: away, reach: model.gripReach)]
    }

    private func heldCutoutOn(_ screen: NSScreen) -> HardwareNotch? {
        model.edge == .top ? screen.hardwareNotch : nil
    }

    private func pickUp() {
        guard let screen = dragScreen, let cutout = heldCutoutOn(screen), !model.holdsOffTheCutout else { return }
        let free = NotchGeometry.freeOffset(fromStanding: model.alongOffset,
                                            width: cutout.width, bar: model.plainBarLength)
        let joined = model.mergesWithCutout
        heldPointer = free
        heldCutout = cutout
        let lift = {
            self.model.revealsTheOtherCopy = false
            self.model.holdsOffTheCutout = true
            self.model.alongOffset = free
            self.relocate()
        }
        if joined { withAnimation(NotchMotion.lift, lift) } else { lift() }
    }

    private func putDown() {
        guard let screen = dragScreen ?? currentScreen(), let cutout = heldCutout,
              model.edge == .top else {
            model.holdsOffTheCutout = false
            model.revealsTheOtherCopy = false
            heldCutout = nil
            return
        }
        let target = NotchGeometry.cutoutLanding(alongOffset: model.alongOffset,
                                                 width: cutout.width, bar: model.plainBarLength)
        model.holdsOffTheCutout = false
        if let target {
            model.revealsTheOtherCopy = true
            withAnimation(NotchMotion.unfold) { model.alongOffset = target; relocate() }
        } else {
            model.alongOffset = NotchGeometry.standingOffset(fromFree: model.alongOffset,
                                                             width: cutout.width, bar: model.plainBarLength)
            relocate()
        }
        heldCutout = nil
        model.adopt(screen: screen)
    }

    private func nearestEdge(to point: CGPoint, track: BorderTrack) -> NotchEdge {
        let edges = NotchEdge.allCases
        return edges.min { Self.distance(to: $0, of: point, on: track) < Self.distance(to: $1, of: point, on: track) } ?? model.edge
    }

    // MARK: - Hit regions

    /// The panel's real size, which AppKit may have rounded up from the one we
    /// asked for — and which the flush edge depends on.
    private var placement: NotchPlacement {
        NotchPlacement(edge: model.edge, panelSize: panel?.frame.size ?? model.panelSize)
    }

    /// The notch itself, in panel coordinates with a top-left origin.
    private var notchRects: [CGRect] {
        model.wings.filter { $0.length > 0 }.map { wing in
            placement.rect(along: wing.lead, across: 0, length: wing.length,
                           depth: wing.depth * model.sizeScale)
        }
    }

    /// What wakes the folded notch. Larger than the pill it surrounds, and
    /// exactly the hardware notch when it is joined to one — see
    /// `NotchViewModel.wakeLength` for both halves of that.
    private var pillRect: CGRect {
        model.wakeRect(panelSize: panel?.frame.size ?? model.panelSize)
    }

    /// The handle's bounding box, for deciding whether the panel takes events
    /// at all. Whether a point is actually *on* the handle is a finer question
    /// than a box can answer — see `isOverHandle`.
    private var handleRect: CGRect {
        let side = NotchLayout.orbHotZone
        let boxes = (model.orbHandlePoints +
                     ((model.isHoveringSettings || model.isHoveringMove) ? [model.gripPoint] : []))
            .map { point -> CGRect in
            let centre = placement.point(along: model.slack + point.x * model.sizeScale,
                                         across: point.y * model.sizeScale)
            return CGRect(x: centre.x - side / 2, y: centre.y - side / 2,
                          width: side, height: side)
        }
        return boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) }
    }

    /// Whether the pointer is on the handle itself rather than merely inside
    /// the box that contains it.
    private func isOverHandle(_ local: CGPoint) -> Bool {
        // Back into the notch's own measurements, which is what `isOnOrbHandle`
        // is written in — the orb scales with the notch, so its hit test has to
        // be asked in the same space the shape was drawn in.
        model.isOnOrbHandle(
            along: (placement.along(of: local) - model.slack) / model.sizeScale,
            across: placement.across(of: local) / model.sizeScale
        )
    }

    private func isOverGrip(_ local: CGPoint) -> Bool {
        model.isOnGrip(
            along: (placement.along(of: local) - model.slack) / model.sizeScale,
            across: placement.across(of: local) / model.sizeScale
        )
    }

    /// The only region that takes the mouse. Everything else in the panel is a
    /// hole — which matters far more folded than open, since the point of
    /// folding away is to stop being in the way.
    private var liveRects: [CGRect] {
        guard model.isExpanded else { return [pillRect] }
        // Keep separated wings separate: their union would claim the hardware
        // notch between them as interactive space.
        return notchRects + [handleRect]
    }

    private func keepsOpen(at local: CGPoint) -> Bool {
        pillRect.contains(local) || liveRects.contains { $0.contains(local) }
    }

    /// The card, its tail, and the gap between the tail and the notch — so
    /// sliding the pointer off the notch and onto the card never leaves it.
    private func tooltipRect(index: Int) -> CGRect? {
        guard model.snapshots.indices.contains(index) else { return nil }
        let snapshot = model.snapshots[index]
        let cardHeight = NotchLayout.cardHeight(
            windowCount: snapshot.windows.count,
            groupCount: snapshot.windowGroupCount,
            sessionCount: snapshot.localModel == nil ? (model.activity(for: snapshot.id)?.sessions.count ?? 0) : 0,
            sessionCap: model.sessionCap,
            statusMessage: snapshot.statusMessage,
            blockMessage: snapshot.block?.summary(now: model.now),
            hasTokenUsage: snapshot.tokenUsage != nil,
            localModelName: snapshot.localModel?.name,
            showsLocalPerformance: snapshot.showsLocalPerformance,
            compactRowCount: snapshot.compactRowCount
        )
        // Across the stack the region is the card, its tail, and the gap the
        // pointer has to cross. Along it, the card's own extent.
        let cardAcross = model.edge.isVertical ? NotchLayout.cardWidth : cardHeight
        let cardAlong = model.edge.isVertical ? cardHeight : NotchLayout.cardWidth
        let centre = model.tooltipAlong(index: index, length: cardAlong)
        return placement.rect(
            along: centre - cardAlong / 2,
            // The card's own extent does not scale, and it begins where the
            // drawn notch ends.
            across: model.notchDrawnDepth,
            length: cardAlong,
            depth: NotchLayout.tailGap + NotchLayout.tailLength + cardAcross
        )
    }

    private func updateInteractiveRects() {
        var rects = liveRects
        if model.isExpanded, let index = model.hoveredIndex, let card = tooltipRect(index: index) {
            rects.append(card)
        }
        hostingView?.interactiveRects = rects
        if let panel {
            panel.ignoresMouseEvents = !rects.contains { $0.contains(localCursor(in: panel.frame)) }
        }
    }

    // MARK: - Cursor tracking

    /// A global monitor catches the outside-to-inside crossing while the panel
    /// is still ignoring events; a local one catches the way back out.
    ///
    /// A slow poll backs both of them up, because a cursor that never moves
    /// produces no events at all — so a notch that appears, resizes or is
    /// re-anchored underneath a parked pointer would otherwise sit there with
    /// stale hover state until the user jogged the mouse.
    private func startWatchingCursor() {
        let poll = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cursorMoved()
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        cursorTimer = poll

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            handler(event)
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func localCursor(in frame: CGRect) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }

    private func cursorMoved() {
        guard let panel else { return }
        cursorMoved(at: localCursor(in: panel.frame))
    }

    func cursorMoved(at local: CGPoint) {
        guard passage == nil else { return }
        let overTooltip = model.hoveredIndex
            .flatMap(tooltipRect(index:))
            .map { model.isExpanded && $0.contains(local) } ?? false
        setExpanded(keepsOpen(at: local) || overTooltip)

        let target = hoverTarget(at: local)

        var overHandle = model.isExpanded && isOverHandle(local)
        var overMove = model.isExpanded && !overHandle && isOverGrip(local)
        if let rest = restingOnGrip {
            if NSEvent.mouseLocation == rest {
                overHandle = false
                overMove = true
            } else {
                restingOnGrip = nil
            }
        }
        if model.isHoveringSettings != overHandle {
            model.isHoveringSettings = overHandle
        }
        if model.isHoveringMove != overMove {
            model.isHoveringMove = overMove
        }
        setPointing(
            Self.wantsPointingHand(isExpanded: model.isExpanded, cellIndex: target) || overHandle || overMove
        )

        if let target {
            clearHoverWork?.cancel()
            clearHoverWork = nil
            if model.hoveredIndex != target {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                    model.hoveredIndex = target
                }
            }
        } else if model.hoveredIndex != nil, clearHoverWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clearHoverWork = nil
                    withAnimation(.easeOut(duration: 0.18)) { self.model.hoveredIndex = nil }
                }
            }
            clearHoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverGrace, execute: work)
        }

        updateInteractiveRects()
    }

    func hoverTarget(at local: CGPoint) -> Int? {
        guard model.isExpanded else { return nil }
        if notchRects.contains(where: { $0.contains(local) }) {
            return cellIndex(along: placement.along(of: local))
        }
        if let current = model.hoveredIndex,
           let card = tooltipRect(index: current), card.contains(local) {
            return current
        }
        return nil
    }

    /// Opens on contact, folds shut after a pause — unless it has been pinned
    /// open, in which case the pointer is not what decides.
    private func setExpanded(_ wanted: Bool) {
        if wanted {
            foldWork?.cancel()
            foldWork = nil
            guard !model.isExpanded else { return }
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
            return
        }

        // A peek holds the notch open for its own duration; only after that
        // does the pointer get a say again.
        if let peekUntil, peekUntil > Date() { return }
        guard model.isExpanded, !model.staysOpen, foldWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.foldWork = nil
                guard !self.model.staysOpen else { return }
                withAnimation(NotchMotion.unfold) {
                    self.model.isExpanded = false
                    self.model.hoveredIndex = nil
                }
                self.setPointing(false)
                self.updateInteractiveRects()
            }
        }
        foldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + foldGrace, execute: work)
    }

    /// The rings are buttons, so they should say so.
    static func wantsPointingHand(isExpanded: Bool, cellIndex: Int?) -> Bool {
        isExpanded && cellIndex != nil
    }

    /// Pushed and popped rather than `set`, so leaving restores whatever cursor
    /// the app underneath had chosen. Setting `.arrow` on the way out would
    /// stamp an arrow over someone else's text caret.
    private func setPointing(_ wanted: Bool) {
        guard wanted != isPointing else { return }
        isPointing = wanted
        if wanted {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    /// A click on a ring refetches that provider; a click anywhere else on the
    /// open notch pins it. The ring is the more specific target, so it wins.
    func handleClick(at locationInWindow: CGPoint) {
        guard let panel else {
            setExpanded(true)
            return
        }
        // Use the event position even if the pointer has moved since the click.
        let local = CGPoint(x: locationInWindow.x, y: panel.frame.height - locationInWindow.y)

        // The handle sits inside the notch, so it has to be tested before the
        // cells — otherwise the cell band nearest the foot of the stack swallows
        // it and clicking the gear refetches a provider instead.
        if model.isExpanded, isOverHandle(local) {
            // The same turn the SwiftUI tap gives it, so the gear responds
            // however the click reached it — this path and the tap gesture
            // are two routes to one action.
            model.settingsSpins += 1
            onOpenSettings?()
            return
        }
        // A peek is a question — "this one just finished, do you want it?" —
        // and the click that follows is the answer. It outranks pinning and
        // refetching for as long as the offer stands, and for no longer.
        //
        // Tested before the folded case below, not after: the grace period
        // outlives the peek by a couple of seconds precisely so that a hand
        // that arrived late still lands on the session, and answering it by
        // merely re-opening the notch would waste that click.
        if takePendingFocus() {
            peekWork?.cancel()
            peekWork = nil
            peekUntil = nil
            withAnimation(NotchMotion.unfold) {
                model.isExpanded = false
                model.hoveredIndex = nil
            }
            setPointing(false)
            updateInteractiveRects()
            return
        }
        guard model.isExpanded else {
            // Opens it, the same as the pointer arriving would — it must not
            // also pin it. The pill's hot zone is deliberately generous, since
            // it is a small target on a screen edge, so a click aimed at
            // something else nearby can land here without the notch ever
            // having been seen open. Pinning is what a click on a notch that
            // is *already* open does; folding it back in later is exactly
            // the ordinary hover behaviour, which a plain `setExpanded` leaves
            // intact.
            setExpanded(true)
            return
        }
        if (model.mergesWithCutout || notchRects.contains(where: { $0.contains(local) })),
           let index = cellIndex(along: placement.along(of: local)),
           model.snapshots.indices.contains(index) {
            if let onRefreshProvider {
                let snapshot = model.snapshots[index]
                Task { await model.refresh(snapshot, using: onRefreshProvider) }
            }
            return
        }
        togglePinned()
    }

    /// Move the notch to another screen edge.
    ///
    /// It goes out where it was, crosses while there is nothing to see, and
    /// then **opens** where it now is — the same unfold hovering uses, so a
    /// move ends the way reaching for it does rather than with a bar appearing
    /// at full size.
    ///
    /// Changing the placement moves the panel, turns the shape on its side and
    /// relays the whole stack, all in one frame. Done in view that is a jump no
    /// animation can smooth over, and animating a panel across a corner looks
    /// like a bug rather than a choice — hence the crossing rather than a
    /// slide.
    /// A new size choice: set it, then rebuild the panel around it.
    ///
    /// Set-then-relocate rather than a subscription on `model.$sizeScale`,
    /// because `@Published` fires in `willSet` — a sink here would recompute
    /// the panel from the size that is being replaced. `apply(edge:)` is the
    /// same shape for the same reason.
    func apply(scale: CGFloat) {
        guard model.sizeScale != scale else { return }

        // A drag arrives as a stream of tiny deltas; a preset, or a switch
        // between the two controls, arrives as one large one.
        let isDrag = abs(scale - model.sizeScale) < Self.steppedScaleDelta

        // The drawn shape follows every tick — that part is a redraw and it is
        // cheap. Re-laying the *window* out is not: `relocate` recomputes the
        // panel size through `maxCardHeight` and the `sessionCap` search, then
        // asks the compositor to resize a full-height window. Sixty of those a
        // second is what makes a drag feel like it is pulling something heavy.
        model.sizeScale = scale
        if isDrag {
            coalesceRelocate()
        } else {
            pendingRelocate?.cancel()
            pendingRelocate = nil
            relocate()
            updateInteractiveRects()
        }
    }

    /// Above this, a size change was *chosen* rather than dragged. The
    /// smallest gap between two presets is 0.2 and a drag tick is a fraction
    /// of a percent, so there is a wide margin either way.
    private static let steppedScaleDelta: CGFloat = 0.05

    /// The window is re-laid out at most this often while a drag is in
    /// flight. The panel is larger than the notch by the whole tooltip slack,
    /// so it can be a tenth of a second out of date without anything showing.
    private static let relocateInterval: TimeInterval = 0.1

    /// Resize the window on a budget, and always once the drag has stopped.
    private func coalesceRelocate() {
        let now = Date()
        if now.timeIntervalSince(lastRelocate) >= Self.relocateInterval {
            lastRelocate = now
            relocate()
            return
        }
        // Too soon. Replace any pending catch-up with one scheduled from now,
        // so a drag that stops mid-interval still ends up correctly sized.
        pendingRelocate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastRelocate = Date()
            self.relocate()
            self.updateInteractiveRects()
        }
        pendingRelocate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.relocateInterval,
                                      execute: work)
    }

    private var lastRelocate = Date.distantPast
    private var pendingRelocate: DispatchWorkItem?
    func apply(edge: NotchEdge) {
        guard model.edge != edge else { return }
        guard let panel else {   // before there is anything on screen to fade
            model.edge = edge
            relocate()
            return
        }

        let wasOpen = model.isExpanded
        model.hoveredIndex = nil
        setPointing(false)

        // Clicking through the picker starts a move before the last one has
        // landed, and a stale completion would drop the notch on an edge the
        // user has already moved on from.
        edgeChange += 1
        let change = edgeChange

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.edgeCrossfade
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, change == self.edgeChange else { return }

                // Land folded, and at full strength: the opening *is* the
                // animation, and fading in underneath it would be two at once.
                self.model.edge = edge
                self.model.isExpanded = false
                self.relocate()
                self.updateInteractiveRects()
                panel.alphaValue = 1

                guard wasOpen else { return }
                // A beat, then open. Not decoration: setting it shut and open
                // again inside one turn lets SwiftUI coalesce the pair, and the
                // notch arrives at full size having animated nothing.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrivalBeat) {
                    MainActor.assumeIsolated {
                        guard change == self.edgeChange else { return }
                        withAnimation(NotchMotion.unfold) { self.model.isExpanded = true }
                        self.updateInteractiveRects()
                    }
                }
            }
        }
    }

    func apply(displayPreference: DisplayPreference) {
        guard self.displayPreference != displayPreference else { return }
        self.displayPreference = displayPreference
        relocate()
    }

    /// Half the crossing, each way. Short: it is a settings change, not a
    /// flourish, and the notch should be back before you have looked up.
    private static let edgeCrossfade: TimeInterval = 0.16
    /// The pause between landing and opening.
    private static let arrivalBeat: TimeInterval = 0.05
    private var edgeChange = 0

    func apply(_ visibility: NotchVisibility) {
        self.visibility = visibility
        // A standing choice outranks a peek that happens to be in flight.
        peekWork?.cancel()
        peekWork = nil
        peekUntil = nil
        switch visibility {
        case .alwaysShow:
            if !Runtime.isUnderTest { panel?.orderFrontRegardless() }
            model.isAlwaysOn = true
            // Any pin made by hand is subsumed by the setting; leaving it set
            // would outlive a later switch back to hover.
            model.isPinned = false
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        case .onHover:
            if !Runtime.isUnderTest { panel?.orderFrontRegardless() }
            model.isAlwaysOn = false
            model.isPinned = false
            // Fold now rather than waiting for the pointer to leave: it may
            // already be somewhere else, in which case nothing would arrive to
            // close it and "on hover" would look exactly like "always show".
            withAnimation(NotchMotion.unfold) {
                model.isExpanded = false
                model.hoveredIndex = nil
            }
        case .hidden:
            model.isAlwaysOn = false
            model.isPinned = false
            model.isExpanded = false
            model.hoveredIndex = nil
            // Ordered out rather than made transparent. An invisible panel that
            // still takes the screen edge would keep swallowing the pointer.
            panel?.orderOut(nil)
        }
        setPointing(false)
        updateInteractiveRects()
    }

    // MARK: - Peeking

    /// Open the notch by itself for a moment, because something happened.
    ///
    /// Distinct from `setExpanded(true)`, which is the pointer arriving: this
    /// has no pointer to leave again, so it schedules its own close. The close
    /// checks the same two conditions the hover fold does — pinned open, or the
    /// pointer now resting on it — because a peek that arrives while you are
    /// already reading the notch must not yank it shut underneath you.
    ///
    /// `pid` is the agent's process, used only if the peek is clicked; nil
    /// leaves the click doing what it ordinarily does.
    func peek(for duration: TimeInterval, focusing pid: pid_t?) {
        // Hidden is a standing choice that the notch is not to be on screen.
        // Something finishing is not grounds to overrule it — the chime still
        // sounds, which is the part that works with nothing visible.
        guard visibility != .hidden, let panel else {
            Log.usage.debug("peek skipped: notch hidden")
            return
        }
        Log.usage.debug("peek for \(duration, privacy: .public)s, pid \(pid ?? -1, privacy: .public)")

        if let pid {
            pendingFocus = (pid: pid, until: Date().addingTimeInterval(duration + Self.focusGrace))
        }
        peekUntil = Date().addingTimeInterval(duration)

        if !Runtime.isUnderTest { panel.orderFrontRegardless() }
        foldWork?.cancel()
        foldWork = nil
        peekWork?.cancel()
        withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        updateInteractiveRects()

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.peekWork = nil
                self.peekUntil = nil
                guard !self.model.staysOpen else { return }
                // Left open if the peek did its job and the pointer is already
                // there; the ordinary hover fold takes it from here.
                guard !self.keepsOpen(at: self.localCursor(in: panel.frame)) else { return }
                withAnimation(NotchMotion.unfold) {
                    self.model.isExpanded = false
                    self.model.hoveredIndex = nil
                }
                self.setPointing(false)
                self.updateInteractiveRects()
                Log.usage.debug("peek folded")
            }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// How long after a peek folds a click still counts as answering it. Covers
    /// the reach for the mouse that started while the notch was still open.
    private static let focusGrace: TimeInterval = 2

    /// Raise the terminal the peeked session is running in, if the offer stands.
    private func takePendingFocus() -> Bool {
        guard let pending = pendingFocus, pending.until > Date() else {
            pendingFocus = nil
            return false
        }
        pendingFocus = nil
        return SessionFocus.activateApp(owning: pending.pid)
    }

    /// Tear down a controller whose display is gone: hide first so no panel
    /// lingers on a screen that no longer exists, then stop its timers and
    /// monitors — a retired controller that kept polling would relocate
    /// another display's panel underneath a parked pointer.
    func retire() {
        apply(.hidden)
        stop()
    }

    /// Clicking the open notch pins it, so it stays put while you read it.
    /// This is deliberately separate from the menu's standing choice.
    func togglePinned() {
        guard !model.isAlwaysOn else { return }
        model.isPinned.toggle()
        if model.isPinned {
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        }
        updateInteractiveRects()
    }

    /// The menu action changes the persisted visibility preference. Ordinary
    /// notch clicks must never call this path.
    func toggleKeepOpen() {
        onToggleKeepOpen?()
    }

    func cellIndex(along: CGFloat) -> Int? {
        let pitch = model.cellPitch * model.sizeScale
        for index in model.snapshots.indices {
            let centre = model.ringPanelCenter(index: index)
            if abs(along - centre) <= pitch / 2 { return index }
        }
        return nil
    }

    // MARK: - Odds and ends

    private func startClock() {
        // Keeps "Resets in N min" from going stale while the tooltip is open.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func contextMenu() -> NSMenu {
        Log.usage.debug("context menu opened")
        let menu = NSMenu()
        // AppKit otherwise decides enablement itself and overrules the line
        // below. Turning it off means every item has to say so for itself.
        menu.autoenablesItems = false
        let keepOpen = NSMenuItem(
            title: L10n.t("Keep open"),
            action: #selector(MenuActions.toggleKeepOpen(_:)),
            keyEquivalent: ""
        )
        keepOpen.target = menuActions
        keepOpen.state = model.isAlwaysOn ? .on : .off
        keepOpen.isEnabled = true
        menu.addItem(keepOpen)
        menu.addItem(.separator())

        let refresh = NSMenuItem(
            title: L10n.t("Refresh now"),
            action: #selector(MenuActions.refreshNow(_:)),
            keyEquivalent: "r"
        )
        refresh.target = menuActions
        refresh.isEnabled = true
        menu.addItem(refresh)

        for (index, entry) in signInItems.enumerated() {
            let item = NSMenuItem(
                title: entry.title,
                action: #selector(MenuActions.signIn(_:)),
                keyEquivalent: ""
            )
            item.target = menuActions
            item.tag = index
            item.isEnabled = true
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.t("Quit Codenotch"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ).isEnabled = true
        return menu
    }

    private lazy var menuActions = MenuActions(
        refresh: { [weak self] in self?.onRefresh?() },
        signIn: { [weak self] index in self?.signInItems[safe: index]?.action() },
        togglePinned: { [weak self] in self?.togglePinned() },
        toggleKeepOpen: { [weak self] in self?.toggleKeepOpen() }
    )
}


/// A menu item needs an Objective-C target, which a `@MainActor` Swift class
/// with closures cannot be directly.
final class MenuActions: NSObject {
    private let refresh: () -> Void
    private let signIn: (Int) -> Void
    private let pin: () -> Void
    private let keepOpen: () -> Void

    init(
        refresh: @escaping () -> Void,
        signIn: @escaping (Int) -> Void,
        togglePinned: @escaping () -> Void,
        toggleKeepOpen: @escaping () -> Void
    ) {
        self.refresh = refresh
        self.signIn = signIn
        self.pin = togglePinned
        self.keepOpen = toggleKeepOpen
    }

    @objc func refreshNow(_ sender: Any?) { refresh() }
    @objc func togglePinned(_ sender: Any?) { pin() }
    @objc func toggleKeepOpen(_ sender: Any?) { keepOpen() }

    @objc func signIn(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        signIn(item.tag)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

final class DisplayTick: NSObject {
    private let action: (CADisplayLink) -> Void

    init(_ action: @escaping (CADisplayLink) -> Void) {
        self.action = action
    }

    @objc func tick(_ link: CADisplayLink) {
        action(link)
    }
}
