#if os(iOS)
public import CNTransport
import CNCore
import CNDesign
public import SwiftUI
import UIKit

/// The Mac's browser tabs, streamed over the link and driven like Mobile
/// Safari (compact bottom layout): live page edge to edge, floating glass
/// toolbar, address editing, page menu, tab overview and toolbar swipes.
public struct BrowserRoot: View {
    let connection: HostConnection
    @State private var model: BrowserModel

    public init(connection: HostConnection) {
        self.connection = connection
        _model = State(initialValue: BrowserModel(connection: connection))
    }

    public var body: some View {
        // The outermost reader respects the keyboard: SwiftUI changes its
        // bottom inset inside the keyboard's own animation, so the address
        // field rides exactly with the keyboard (no notification lag).
        GeometryReader { withKeyboard in
            GeometryReader { outer in
                GeometryReader { full in
                    let kb = withKeyboard.safeAreaInsets.bottom
                    BrowserScreen(model: model, size: full.size, safeTop: outer.safeAreaInsets.top,
                                  safeBottom: outer.safeAreaInsets.bottom,
                                  keyboard: kb > outer.safeAreaInsets.bottom + 1 ? kb : 0)
                }
                .ignoresSafeArea()
            }
            .ignoresSafeArea(.keyboard)
        }
        .task(id: connection.generation) { await model.reload() }
        #if DEBUG
        .onChange(of: model.activeFrame != nil) { _, hasFrame in
            if hasFrame { Task { await model.simulateDisplacementIfRequested() } }
        }
        #endif
        .task {
            for await push in connection.pushes() { model.handle(push) }
        }
        .task {
            for await event in connection.events(topic: HostTopic.browserDetached.rawValue) {
                if let detached = try? event.decode(BrowserDetachedEvent.self) { model.handleDetached(detached) }
            }
        }
        .onDisappear { model.detachAll() }
    }
}

/// A page image standing in for the live surface during zooms and swipes.
struct ZoomOverlay {
    var tabId: String
    var image: UIImage?
    var topColor: Color
    var startPage: Bool
    var rect: CGRect
    var radius: CGFloat
    var strip: CGFloat
}

struct BrowserScreen: View {
    let model: BrowserModel
    let size: CGSize
    let safeTop: CGFloat
    let safeBottom: CGFloat
    /// Software keyboard height from the screen bottom (0 when hidden).
    let keyboard: CGFloat

    @State private var chrome = BrowserChromeState()
    /// The page <-> overview transition (one interruptible progress value).
    @State private var zoomDriver = TabZoomDriver()
    /// Tab the zoom shows: the active tab, a tapped card, or `newTabMarker`.
    @State private var zoomTabId: String?
    /// Grid content origin in the screen's coordinate space, reported by the grid.
    @State private var gridContentOrigin: CGPoint?
    /// (+) pressed and the tab not created yet: the grid shows a placeholder card.
    @State private var newTabPending = false
    /// The pinch that drives the zoom (page -> grid, card -> page, or grabbing a running zoom).
    @State private var pinchSession = ZoomPinchSession()
    /// While true the page's own touches are cancelled on the host.
    @State private var zoomPinchActive = false
    #if DEBUG
    /// Synthetic fingers drawn by the DEBUG pinch driver (for recordings).
    @State private var debugFingers: [CGPoint] = []
    #endif
    @State private var overviewScroll: CGFloat = 0
    @State private var overviewPosition = ScrollPosition(y: 0)
    @State private var menuExpanded = false
    @State private var menuContent = false
    @State private var creatingTab = false
    /// Card images, captured when the overview opens so the hidden grid does
    /// not re-render on every live frame.
    @State private var overviewImages: [String: UIImage] = [:]
    @Environment(\.cnLeadingBarItem) private var leadingItem
    @Environment(\.cnShellRoute) private var shellRoute
    @Environment(\.displayScale) private var displayScale

    private let style = BrowserStyle.shared
    private var motion: BrowserMotion { style.motion }
    private var fullRect: CGRect { CGRect(origin: .zero, size: size) }

    private var displaced: Bool { model.displacedTabId != nil && model.displacedTabId == model.activeTabId }

    private var showsStartPage: Bool { creatingTab || model.showsStartPage(model.activeTabId) }

    private static let newTabMarker = "\u{0}new"
    private var zoomState: TabZoomState { zoomDriver.state }
    /// The overview is on screen (settled, opening, closing or pinched).
    private var overviewVisible: Bool { zoomState.showsOverview }
    /// 0 = page, 1 = grid, clamped (the spring may overshoot slightly).
    private var overviewShown: Double { min(1, max(0, zoomState.progress)) }
    /// Card titles and close buttons appear over the last fifth of the way.
    private var overviewDetails: Double { min(1, max(0, (zoomState.progress - 0.8) / 0.2)) }

    /// The zooming tab's rect: full screen at progress 0, its card at 1.
    /// The zooming tab's rect: full screen at progress 0, its card at 1.
    /// The card end is the card's actual frame in the grid, read every frame
    /// (so it follows the grid's scroll offset and layout changes mid-flight);
    /// before the grid has reported it, it is computed from the grid layout
    /// at the grid's current scroll offset.
    private func zoomGeometry() -> (rect: CGRect, radius: CGFloat, strip: CGFloat) {
        let layout = overviewLayout
        let rect = zoomPath().rect(progress: zoomState.progress, offset: zoomState.offset)
        let q = min(1, max(0, CGFloat(zoomState.progress)))
        return (rect, style.metrics.screenRadius + (layout.cardRadius - style.metrics.screenRadius) * q, safeTop * (1 - q))
    }

    private func zoomPath() -> ZoomRectPath { ZoomRectPath(full: fullRect, card: zoomEndpoint()) }

    /// The zoom's card end: the card's frame in the grid's content converted
    /// to the screen through the grid's reported content origin (its actual
    /// scroll position), or the layout at the last known offset before the
    /// grid has reported.
    private func zoomEndpoint() -> CGRect {
        let index: Int
        if zoomTabId == Self.newTabMarker {
            index = model.tabs.count
        } else {
            index = zoomTabId.flatMap { id in model.tabs.firstIndex { $0.id == id } } ?? (model.activeIndex ?? 0)
        }
        let grid = OverviewLayout(size: size, safeTop: safeTop, safeBottom: safeBottom, count: max(model.tabs.count, index + 1))
        return grid.zoomEndpoint(index, contentOrigin: gridContentOrigin, fallbackOffset: overviewScroll)
    }

    var body: some View {
        let layout = ToolbarLayout.make(size: size, safeBottom: safeBottom, keyboard: keyboard, bar: chrome.bar,
                                        editing: chrome.editing, splitBack: model.activeTab?.canGoForward == true, labelWidth: 69)
        ZStack(alignment: .topLeading) {
            pageLayer
                .frame(width: size.width, height: size.height)

            if chrome.editing {
                editingBackground
                    .transition(.opacity.animation(.easeInOut(duration: 0.1).delay(0.03)))
            }

            // Kept mounted (hidden) so opening it does not pay for building
            // the grid on the first animation frame.
            if model.loaded {
                TabOverview(model: model, images: overviewImages, layout: overviewLayout, shown: overviewShown, detailsOpacity: overviewDetails,
                            hiddenTabId: zoomState.phase == .overview ? nil : zoomTabId,
                            gridInteractive: zoomState.gridInteractive,
                            controlsInteractive: overviewVisible && zoomState.headingToOverview,
                            scrollOffset: $overviewScroll, position: $overviewPosition,
                            leadingItem: leadingItem,
                            onSelect: { closeOverview(selecting: $0) },
                            onClose: { id in withAnimation(motion.resolve(motion.reflow)) { model.close(id) } },
                            onNewTab: newTabFromOverview,
                            onDone: { closeOverview(selecting: model.activeTabId) },
                            onCloseAll: closeAll,
                            placeholderId: newTabPending ? Self.newTabMarker : nil,
                            onContentOrigin: { origin in if gridContentOrigin != origin { gridContentOrigin = origin } })
                    .opacity(overviewVisible ? 1 : 0)
                    .allowsHitTesting(overviewVisible)
                    .accessibilityHidden(!zoomState.gridInteractive)
            }

            if zoomState.phase == .animating || zoomState.phase == .interactive {
                // The tab's page laid out at full size, scaled and clipped
                // to the moving rect (the rect is the tab's window).
                let g = zoomGeometry()
                let content = zoomContent()
                ScaledPage(image: content.image, topColor: content.topColor, startPage: content.startPage, tabs: model.tabs,
                           pageSize: size, safeTop: safeTop, strip: g.strip)
                    .frame(width: max(1, g.rect.width), height: max(1, g.rect.height))
                    .clipShape(.rect(cornerRadius: g.radius, style: .continuous))
                    .offset(x: g.rect.minX, y: g.rect.minY)
                    .allowsHitTesting(false)
            }

            BrowserToolbar(chrome: chrome, tab: model.activeTab, showsStartPage: showsStartPage, size: size, safeBottom: safeBottom,
                           keyboard: keyboard,
                           onBack: model.goBack, onForward: model.goForward, onReload: model.reloadOrStop,
                           onMenu: openMenu, onTabs: openOverview, onBeginEditing: beginEditing,
                           onEndEditing: { endEditing() }, onGo: go,
                           onSwipeChanged: swipeChanged, onSwipeEnded: swipeEnded)
                .opacity(1 - overviewShown)
                // Usable on the page, and while a zoom heads back to the page
                // (the tabs button then reverses it).
                .allowsHitTesting(!chrome.menuOpen && (zoomState.pageInteractive || (zoomState.phase == .animating && !zoomState.headingToOverview)))

            // Kept mounted (transparent) so the droplet starts growing on
            // the first frame after the tap instead of after its first layout.
            if model.loaded && !overviewVisible {
                PageMenu(groups: menuGroups,
                         origin: CGRect(x: layout.capsule.minX, y: layout.capsule.minY, width: style.metrics.control, height: style.metrics.control),
                         capsule: layout.capsule, topLimit: safeTop + 8, expanded: menuExpanded, contentVisible: menuContent,
                         onDismiss: closeMenu, shellItem: leadingItem)
                    .opacity(chrome.menuOpen ? 1 : 0)
                    .allowsHitTesting(chrome.menuOpen)
                    .accessibilityHidden(!chrome.menuOpen)
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(style.colors.label)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    .padding(.horizontal, 24)
                    .padding(.top, safeTop + 8)
                    .frame(width: size.width, alignment: .top)
                    .onTapGesture { model.notice = nil }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .task(id: notice) {
                        // Toast lifetime (a UI timeout, not synchronization).
                        try? await Task.sleep(for: .seconds(5))
                        if model.notice == notice { withAnimation { model.notice = nil } }
                    }
                    .accessibilityAddTraits(.isStaticText)
            }

            if let error = model.errorText, model.tabs.isEmpty {
                ContentUnavailableView("Browser Unavailable", systemImage: "safari", description: Text(error))
                    .frame(width: size.width, height: size.height)
                    .background(.background)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(.named(browserScreenSpace))
        .gesture(ZoomPinchGesture { handlePinch($0) })
        #if DEBUG
        .overlay(alignment: .topLeading) {
            ForEach(Array(debugFingers.enumerated()), id: \.offset) { _, p in
                Circle().fill(Color(red: 1, green: 0, blue: 1)).frame(width: 14, height: 14).position(p)
            }
            .allowsHitTesting(false)
        }
        #endif
        .onChange(of: geometryKey, initial: true) { _, _ in pushGeometry() }
        // A browser row in the drawer opens that tab (by id).
        .onChange(of: shellRoute?.nonce, initial: true) { _, _ in
            guard let route = shellRoute, route.kind == .browserTab, let id = route.id else { return }
            if chrome.editing { endEditing() }
            if chrome.menuOpen { closeMenu() }
            if overviewVisible { closeOverview(selecting: id) }
            model.open(tabId: id)
        }
        .onChange(of: model.thumbnails) { _, _ in if overviewVisible { captureOverviewImages() } }
        #if DEBUG
        .task(id: model.activeFrame != nil) { await debugPinchScript() }
        #endif
        .onAppear {
            zoomDriver.onSettle = { phase in
                if phase == .page {
                    zoomTabId = nil
                    chrome.expand(tap: true)
                }
            }
        }
        .onChange(of: model.tabs.isEmpty) { _, empty in
            // Closing the last tab opens a fresh start page, as Safari does.
            if empty, model.loaded, !overviewVisible { Task { await model.newTab() } }
        }
    }

    // MARK: Page

    @ViewBuilder private var pageLayer: some View {
        let frame = model.activeFrame
        let topColor = Color(uiColor: frame?.topColor ?? .systemBackground)
        ZStack(alignment: .topLeading) {
            PageSurface(model: model, frame: frame, topInset: safeTop,
                        viewportCSSWidth: CGFloat(model.viewport(for: model.activeTabId)?.width ?? 0),
                        keyboardActive: chrome.pageKeyboard,
                        wantsHardwareKeys: !chrome.editing && !overviewVisible,
                        onDrag: { chrome.pageDragged($0) },
                        onKeyboardDismissed: { chrome.pageKeyboard = false; pushGeometry() },
                        zoomPinchActive: zoomPinchActive)
                .opacity(chrome.swiping || showsStartPage ? 0 : 1)
                .allowsHitTesting(!chrome.swiping && !showsStartPage && !displaced)
            if displaced && !showsStartPage && !chrome.swiping {
                DisplacedOverlay(safeTop: safeTop, onViewHere: model.reattachDisplaced)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
            if showsStartPage && !chrome.swiping {
                StartPageView(tabs: model.tabs, safeTop: safeTop, onOpen: { model.navigate($0) })
            }
            if chrome.swiping {
                swipeCards(current: frame, topColor: topColor)
            }
        }
        .cnStatusBarStyle(showsStartPage || overviewVisible ? nil : frame.map { CNStatusBarStyle(over: $0.topColor) })
    }

    @ViewBuilder private func swipeCards(current: PageFrame?, topColor: Color) -> some View {
        let pitch = size.width + 12
        let offset = chrome.swipeOffset
        let progress = min(1, abs(offset) / pitch)
        let neighbor = swipeNeighbor(for: offset)
        ZStack(alignment: .topLeading) {
            style.colors.startBackground
            if let neighbor {
                ScaledPage(image: neighbor.image, topColor: neighbor.topColor, startPage: neighbor.startPage, tabs: model.tabs,
                           pageSize: size, safeTop: safeTop, strip: safeTop)
                    .frame(width: size.width, height: size.height)
                    .clipShape(.rect(cornerRadius: style.metrics.screenRadius, style: .continuous))
                    .scaleEffect(0.93 + 0.07 * progress)
                    .blur(radius: 6 * (1 - progress))
                    .offset(x: offset + (offset < 0 ? pitch : -pitch))
            }
            ScaledPage(image: current?.uiImage, topColor: topColor, startPage: showsStartPage, tabs: model.tabs,
                       pageSize: size, safeTop: safeTop, strip: safeTop)
                .frame(width: size.width, height: size.height)
                .clipShape(.rect(cornerRadius: style.metrics.screenRadius, style: .continuous))
                .offset(x: offset)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func swipeNeighbor(for offset: CGFloat) -> ZoomOverlay? {
        guard let index = model.activeIndex, offset != 0 else { return nil }
        let next = offset < 0 ? index + 1 : index - 1
        guard next >= 0 else { return nil }
        guard next < model.tabs.count else {
            return ZoomOverlay(tabId: "", image: nil, topColor: style.colors.startBackground, startPage: true, rect: fullRect, radius: 0, strip: 0)
        }
        let tab = model.tabs[next]
        let frame = model.frames[tab.id]
        return ZoomOverlay(tabId: tab.id, image: model.cardImage(tab.id), topColor: Color(uiColor: frame?.topColor ?? .white),
                           startPage: model.showsStartPage(tab.id), rect: fullRect, radius: 0, strip: 0)
    }

    @ViewBuilder private var editingBackground: some View {
        let original = model.activeTab?.url ?? ""
        if chrome.editText.isEmpty || chrome.editText == original {
            StartPageView(tabs: model.tabs, safeTop: safeTop, onOpen: { url in
                model.navigate(url)
                endEditing()
            })
        } else {
            AddressSuggestions(query: chrome.editText, tabs: model.tabs, activeTabId: model.activeTabId, safeTop: safeTop,
                               onSwitch: { id in
                                   model.select(id)
                                   endEditing()
                               },
                               onGo: go)
        }
    }

    // MARK: Geometry and keyboard

    private struct GeometryKey: Equatable {
        var size: CGSize
        var top: CGFloat
        var keyboard: CGFloat
        var scale: CGFloat
    }

    private var geometryKey: GeometryKey {
        GeometryKey(size: size, top: safeTop, keyboard: chrome.pageKeyboard ? keyboard : 0, scale: displayScale)
    }

    private func pushGeometry() {
        let k = geometryKey
        model.setGeometry(size: k.size, topInset: k.top, bottomObscured: k.keyboard, scale: k.scale)
    }

    // MARK: Address editing

    private func beginEditing() {
        guard !chrome.editing else { return }
        chrome.pageKeyboard = false
        chrome.editText = showsStartPage ? "" : (model.activeTab?.url ?? "")
        withAnimation(motion.resolve(motion.keyboard)) { chrome.editing = true }
    }

    private func endEditing() {
        guard chrome.editing else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(motion.resolve(motion.editEnd)) {
            chrome.editing = false
        }
    }

    private func go(_ text: String) {
        model.navigate(text)
        endEditing()
    }

    // MARK: Page menu

    private func openMenu() {
        chrome.menuOpen = true
        menuExpanded = false
        menuContent = false
        withAnimation(motion.resolve(motion.menu)) { menuExpanded = true }
        withAnimation(.linear(duration: 0.12).delay(0.08)) { menuContent = true }
    }

    private func closeMenu() {
        withAnimation(.linear(duration: 0.1)) { menuContent = false }
        withAnimation(motion.resolve(.spring(response: 0.3, dampingFraction: 0.9))) { menuExpanded = false } completion: {
            chrome.menuOpen = false
        }
    }

    private func menuAction(_ action: @escaping () -> Void) -> () -> Void {
        { closeMenu(); action() }
    }

    private var menuGroups: [[PageMenuItem]] {
        let tab = model.activeTab
        let desktop = model.isDesktop(model.activeTabId)
        return [
            [
                PageMenuItem(title: tab?.loading == true ? "Stop Loading" : "Reload", symbol: tab?.loading == true ? "xmark" : "arrow.clockwise",
                             action: menuAction(model.reloadOrStop)),
                PageMenuItem(title: "Show Keyboard", symbol: "keyboard", action: menuAction {
                    chrome.pageKeyboard = true
                }),
            ],
            [
                PageMenuItem(title: "Share", symbol: "square.and.arrow.up", enabled: tab.flatMap { URL(string: $0.url) } != nil,
                             action: menuAction {
                                 if let url = tab.flatMap({ URL(string: $0.url) }) { ShareSheetPresenter().share(url) }
                             }),
                PageMenuItem(title: "Copy URL", symbol: "doc.on.doc", enabled: tab != nil, action: menuAction {
                    UIPasteboard.general.string = tab?.url
                }),
            ],
            [
                PageMenuItem(title: "Back", symbol: "chevron.backward", enabled: tab?.canGoBack == true, action: menuAction(model.goBack)),
                PageMenuItem(title: "Forward", symbol: "chevron.forward", enabled: tab?.canGoForward == true, action: menuAction(model.goForward)),
            ],
            [
                PageMenuItem(title: desktop ? "Request Mobile Website" : "Request Desktop Website",
                             symbol: desktop ? "iphone" : "desktopcomputer", action: menuAction(model.toggleDesktop)),
                PageMenuItem(title: "Open on Mac", symbol: "macbook", action: menuAction(model.openOnMac)),
                PageMenuItem(title: "Close Tab", symbol: "xmark.square", enabled: tab != nil, action: menuAction {
                    if let id = model.activeTabId { model.close(id) }
                }),
            ],
        ]
    }

    // MARK: Tab overview

    private var overviewLayout: OverviewLayout {
        OverviewLayout(size: size, safeTop: safeTop, safeBottom: safeBottom, count: model.tabs.count + (newTabPending ? 1 : 0))
    }

    /// What the zooming rect shows: the same image the card shows (or the
    /// live frame for the page), or the start page.
    private func zoomContent() -> (image: UIImage?, topColor: Color, startPage: Bool) {
        guard let id = zoomTabId, id != Self.newTabMarker else {
            return (nil, style.colors.startBackground, true)
        }
        let frame = model.frames[id]
        let image = id == model.activeTabId ? (frame?.uiImage ?? overviewImages[id]) : (overviewImages[id] ?? model.cardImage(id))
        return (image, Color(uiColor: frame?.topColor ?? .white), model.showsStartPage(id) || (creatingTab && id == model.activeTabId))
    }

    /// Prepares the grid when it is about to appear from the page.
    private func prepareOverview(revealing index: Int, count: Int) {
        chrome.pageKeyboard = false
        model.refreshThumbnails()
        captureOverviewImages()
        // Safari: before the page shrinks into its card, the grid jumps (no
        // animation) so the card is fully on screen (OverviewLayout.offset(revealing:from:)).
        let grid = OverviewLayout(size: size, safeTop: safeTop, safeBottom: safeBottom, count: count)
        let offset = grid.offset(revealing: index, from: overviewScroll)
        if abs(offset - overviewScroll) > 0.5 {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { overviewPosition = ScrollPosition(y: offset) }
            // Until the scroll view reports it, the fallback endpoint uses it too.
            overviewScroll = offset
        }
    }

    /// Tabs button: page -> grid, or reverse a zoom that is heading to the page.
    private func openOverview() {
        if zoomState.phase == .page {
            zoomTabId = model.activeTabId
            prepareOverview(revealing: model.activeIndex ?? 0, count: model.tabs.count)
        }
        zoomDriver.go(toOverview: true)
    }

    private func captureOverviewImages() {
        var images: [String: UIImage] = [:]
        for tab in model.tabs { images[tab.id] = model.cardImage(tab.id) }
        overviewImages = images
    }

    /// Done or a card: grid -> page, or reverse a zoom heading to the grid.
    private func closeOverview(selecting tabId: String?) {
        guard overviewVisible else { return }
        if zoomState.phase == .overview {
            guard let tabId, model.tabs.contains(where: { $0.id == tabId }) else {
                if model.tabs.isEmpty { newTabFromOverview() } else { zoomTabId = model.activeTabId; zoomDriver.go(toOverview: false) }
                return
            }
            if tabId != model.activeTabId { model.select(tabId) }
            zoomTabId = tabId
        }
        zoomDriver.go(toOverview: false)
    }

    /// (+): the new tab's start page grows from the grid slot its card will
    /// take (index = tab count). The grid first scrolls so that slot is on
    /// screen, as the overview does for the active card.
    private func newTabFromOverview() {
        guard zoomState.phase == .overview else { return }
        // The new start page's card goes into the grid now (placeholder) so
        // the zoom grows from its real frame; the created tab takes its place.
        newTabPending = true
        zoomTabId = Self.newTabMarker
        creatingTab = true
        zoomDriver.start(from: 1, toOverview: false)
        Task {
            let id = await model.newTab(onCreated: { id in
                newTabPending = false
                if zoomTabId == Self.newTabMarker { zoomTabId = id }
            })
            newTabPending = false
            creatingTab = false
            if zoomTabId == Self.newTabMarker { zoomTabId = id ?? model.activeTabId }
        }
    }

    // MARK: Pinch

    /// Every pinch on the screen comes here (the UIKit recognizer and the
    /// DEBUG synthetic driver). The decision is local and immediate: a pinch-in
    /// past 0.96 within 40 ms on the page, a pinch-out past 1.04 on a grid
    /// card, or any pinch while a zoom is running (it grabs the zoom where it
    /// is). Otherwise the pinch belongs to the page (remote zoom) or the grid.
    private func handlePinch(_ sample: PinchSample) {
        let session = pinchSession
        switch sample.phase {
        case .began:
            session.reset()
            session.start = sample
            session.startRect = zoomGeometry().rect
            session.startedFromOverview = zoomState.phase == .overview
            decide(sample)
        case .changed:
            if session.start == nil {
                session.start = sample
                session.startRect = zoomGeometry().rect
                session.startedFromOverview = zoomState.phase == .overview
            }
            if session.decision == .pending { decide(sample) }
            if session.decision == .engaged { track(sample) }
        case .ended:
            if session.decision == .engaged { releasePinch(sample) }
            session.reset()
            zoomPinchActive = false
        }
    }

    private func decide(_ sample: PinchSample) {
        let session = pinchSession
        guard let start = session.start else { return }
        let elapsed = sample.time - start.time
        switch zoomState.phase {
        case .animating, .interactive:
            engage()
        case .page:
            guard !chrome.editing, !chrome.menuOpen, model.activeTabId != nil || showsStartPage else {
                session.decision = .rejected; return
            }
            if sample.scale <= ZoomPinchSession.engageIn {
                zoomTabId = model.activeTabId
                prepareOverview(revealing: model.activeIndex ?? 0, count: model.tabs.count)
                engage()
            } else if elapsed > ZoomPinchSession.decisionWindow || sample.scale > 1 {
                session.decision = .rejected
            }
        case .overview:
            guard let id = cardTab(at: start.centroid) else { session.decision = .rejected; return }
            if sample.scale >= ZoomPinchSession.engageOut {
                zoomTabId = id
                session.startRect = zoomEndpoint()
                engage()
            } else if elapsed > ZoomPinchSession.decisionWindow || sample.scale < 1 {
                session.decision = .rejected
            }
        }
    }

    /// Starts tracking from the gesture's start state: the rect as it was
    /// presented when the fingers came down, under the start centroid.
    private func engage() {
        let session = pinchSession
        guard let start = session.start else { return }
        session.decision = .engaged
        session.tracker = PinchTracker(startRect: session.startRect, startCentroid: start.centroid)
        zoomDriver.beginInteraction()
        if zoomState.phase == .interactive, !zoomState.showsOverview { /* unreachable */ }
        zoomPinchActive = true
    }

    private func track(_ sample: PinchSample) {
        let session = pinchSession
        guard let tracker = session.tracker else { return }
        let s = tracker.state(scale: sample.scale, centroid: sample.centroid, path: zoomPath())
        session.record(sample.time, s.progress, s.offset)
        let v = session.velocity()
        zoomDriver.updateInteraction(progress: s.progress, offset: s.offset, velocity: v.p, offsetVelocity: v.o)
    }

    private func releasePinch(_ sample: PinchSample) {
        let session = pinchSession
        let v = session.velocity()
        let toOverview = PinchTracker.releaseToOverview(progress: zoomState.progress, velocity: v.p,
                                                        startedFromOverview: session.startedFromOverview, path: zoomPath())
        if !toOverview, let id = zoomTabId, id != model.activeTabId, model.tabs.contains(where: { $0.id == id }) {
            model.select(id)
        }
        zoomDriver.release(toOverview: toOverview)
    }

    /// The tab whose card is under `point` (screen coordinates).
    private func cardTab(at point: CGPoint) -> String? {
        let grid = overviewLayout
        for (i, tab) in model.tabs.enumerated()
        where grid.zoomEndpoint(i, contentOrigin: gridContentOrigin, fallbackOffset: overviewScroll).contains(point) {
            return tab.id
        }
        return nil
    }

    #if DEBUG
    /// DEBUG (`CMUX_NEXT_BROWSER_PINCH=page|card|page-cancel|grab`): replays a
    /// two-finger pinch path (scale and centroid over time) through
    /// `handlePinch` on the display clock, and draws the synthetic fingers so
    /// recordings show the rect against them (AXe has no multitouch).
    private func debugPinchScript() async {
        guard model.activeFrame != nil || showsStartPage,
              let mode = ProcessInfo.processInfo.environment["CMUX_NEXT_BROWSER_PINCH"] else { return }
        try? await Task.sleep(for: .seconds(3))  // recording lead-in (test script only)
        if mode == "card" {
            openOverview()
            try? await Task.sleep(for: .seconds(1.5))
        }
        let path = DebugPinchPath(mode: mode, size: size, cardCenter: CGPoint(x: zoomEndpoint().midX, y: zoomEndpoint().midY))
        let clock = DisplayClock()
        var t0: CFTimeInterval?
        var began = false
        for await now in clock.ticks() {
            let start = t0 ?? now
            t0 = start
            let t = now - start
            if mode == "grab", t >= DebugPinchPath.grabAt, zoomState.phase == .page, pinchSession.start == nil {
                openOverview()  // a tap starts the zoom; the pinch below grabs it
            }
            guard let point = path.sample(at: t) else { break }
            if point.centroid == .zero { continue }  // grab mode: before the fingers land
            debugFingers = path.fingers(at: t)
            let phase: PinchSample.Phase = began ? point.phase : .began
            began = true
            handlePinch(PinchSample(phase: phase, scale: point.scale, centroid: point.centroid, time: now))
            if point.phase == .ended { break }
        }
        clock.stop()
        debugFingers = []
    }
    #endif

    private func closeAll() {
        let ids = model.tabs.map(\.id)
        withAnimation(motion.resolve(motion.reflow)) { for id in ids { model.close(id) } }
        newTabFromOverview()
    }

    // MARK: Toolbar swipe

    private func swipeChanged(_ dx: CGFloat) {
        if !chrome.swiping {
            chrome.swiping = true
            if let i = model.activeIndex {
                if i > 0 { model.requestThumbnail(model.tabs[i - 1].id) }
                if i + 1 < model.tabs.count { model.requestThumbnail(model.tabs[i + 1].id) }
            }
        }
        let atFirst = (model.activeIndex ?? 0) == 0
        chrome.swipeOffset = dx > 0 && atFirst ? dx * 0.25 : dx
    }

    private func swipeEnded(_ dx: CGFloat, _ predicted: CGFloat) {
        let pitch = size.width + 12
        let index = model.activeIndex ?? 0
        let commit = abs(predicted) > size.width * 0.35 || abs(dx) > size.width * 0.5
        var target: CGFloat = 0
        var destination: String?? = nil  // .some(nil) = new tab
        if commit, dx < 0 {
            target = -pitch
            destination = index + 1 < model.tabs.count ? .some(model.tabs[index + 1].id) : .some(nil)
        } else if commit, dx > 0, index > 0 {
            target = pitch
            destination = .some(model.tabs[index - 1].id)
        }
        withAnimation(motion.resolve(motion.swipe)) { chrome.swipeOffset = target } completion: {
            switch destination {
            case .some(.some(let id)): model.select(id)
            case .some(.none):
                creatingTab = true
                Task {
                    await model.newTab()
                    creatingTab = false
                }
            case .none: break
            }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                chrome.swipeOffset = 0
                chrome.swiping = false
            }
        }
    }
}

/// Shown when another phone took over this tab's screencast: the last
/// frame stays, dimmed, under a small glass banner with "View here".
struct DisplacedOverlay: View {
    var safeTop: CGFloat
    var onViewHere: () -> Void
    private let style = BrowserStyle.shared

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .contentShape(.rect)
                .accessibilityHidden(true)
            HStack(spacing: 10) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .medium))
                Text("Viewing on another device")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Button("View here", action: onViewHere)
                    .font(.system(size: 15, weight: .semibold))
                    .buttonStyle(.glass)
            }
            .foregroundStyle(style.colors.label)
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(height: 48)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.top, safeTop + 8)
            .accessibilityElement(children: .contain)
        }
    }
}

#endif
