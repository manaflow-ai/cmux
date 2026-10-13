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
    @State private var tabs: TabsModel

    public init(connection: HostConnection) {
        self.connection = connection
        _tabs = State(initialValue: TabsModel(connection: connection, includesTerminals: false))
    }

    public var body: some View {
        TabsScreenHost(tabs: tabs, connection: connection)
    }
}

/// Hosts `BrowserScreen` for a `TabsModel`: geometry, loading, events.
/// Shared by `BrowserRoot` (browser tabs) and `TabsRoot` (browser tabs and
/// terminals).
struct TabsScreenHost: View {
    let tabs: TabsModel
    let connection: HostConnection
    var terminalContent: (String, CGSize?) -> AnyView = { _, _ in AnyView(Color.black) }
    var terminalFontStep: (Int) -> Void = { _ in }
    /// A terminal's composer row and key bar, placed above the toolbar.
    var terminalAccessory: (String) -> AnyView = { _ in AnyView(EmptyView()) }

    private var model: BrowserModel { tabs.browser }

    var body: some View {
        // The outermost reader respects the keyboard: SwiftUI changes its
        // bottom inset inside the keyboard's own animation, so the address
        // field rides exactly with the keyboard (no notification lag).
        GeometryReader { withKeyboard in
            GeometryReader { outer in
                GeometryReader { full in
                    let kb = withKeyboard.safeAreaInsets.bottom
                    BrowserScreen(tabs: tabs, size: full.size, safeTop: outer.safeAreaInsets.top,
                                  safeBottom: outer.safeAreaInsets.bottom,
                                  keyboard: kb > outer.safeAreaInsets.bottom + 1 ? kb : 0,
                                  terminalContent: terminalContent,
                                  terminalAccessory: terminalAccessory, terminalFontStep: terminalFontStep)
                }
                .ignoresSafeArea()
            }
            .ignoresSafeArea(.keyboard)
        }
        .task(id: connection.generation) { await tabs.reload() }
        #if DEBUG
        .onChange(of: model.activeFrame != nil) { _, hasFrame in
            if hasFrame { Task { await model.simulateDisplacementIfRequested() } }
        }
        #endif
        .task {
            for await push in connection.pushes() { tabs.handle(push) }
        }
        .task {
            for await event in connection.events(topic: HostTopic.browserDetached.rawValue) {
                if let detached = try? event.decode(BrowserDetachedEvent.self) { model.handleDetached(detached) }
            }
        }
        .task {
            guard tabs.includesTerminals else { return }
            for await event in connection.events(topic: HostTopic.layoutChanged.rawValue) {
                if let changed = try? event.decode(LayoutResult.self) { tabs.applyLayout(changed.layout) }
            }
        }
        .task {
            guard tabs.includesTerminals else { return }
            for await event in connection.events(topic: HostTopic.browserMacStatus.rawValue) {
                if let status = try? event.decode(BrowserMacStatus.self) { tabs.browserAccess = status }
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
    let tabs: TabsModel
    /// Browser-specific state (page stream, navigation, viewport).
    private var model: BrowserModel { tabs.browser }
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
    /// The pending (+) item is a terminal.
    @State private var newTabIsTerminal = false
    /// The pinch that drives the zoom (page -> grid, card -> page, or grabbing a running zoom).
    @State private var pinchSession = ZoomPinchSession()
    /// While true the page's own touches are cancelled on the host.
    @State private var zoomPinchActive = false
    #if DEBUG
    /// Synthetic fingers drawn by the DEBUG pinch driver (for recordings).
    @State private var debugFingers: [CGPoint] = []
    private var debugPinchMode: String? { ProcessInfo.processInfo.environment["CMUX_NEXT_BROWSER_PINCH"] }
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

    private var displaced: Bool { tabs.activeTerminalKey == nil && model.displacedTabId != nil && model.displacedTabId == model.activeTabId }

    /// Live terminal content for a terminal tab (from the tabs root).
    var terminalContent: (String, CGSize?) -> AnyView = { _, _ in AnyView(Color.black) }
    /// The open terminal's composer row and key bar (from the tabs root).
    var terminalAccessory: (String) -> AnyView = { _ in AnyView(EmptyView()) }

    @Environment(\.cnHostedInTabBar) private var hostedInTabBar

    /// Bottom inset of a page's chrome. In the tab shell the safe area ends
    /// at the tab bar's status accessory; the floating toolbar keeps a gap
    /// above it (the accessory, tab bar and toolbar read as three separate
    /// glass rows, as Safari's toolbar over its own bottom edge).
    private var pageBottom: CGFloat { hostedInTabBar ? safeBottom + 10 : safeBottom }

    private var showsStartPage: Bool { creatingTab || tabs.showsStartPage(tabs.activeKey) }

    private static let newTabMarker = "\u{0}new"
    private var zoomState: TabZoomState { zoomDriver.state }
    /// The overview is on screen (settled, opening, closing or pinched).
    private var overviewVisible: Bool { zoomState.showsOverview }
    /// 0 = page, 1 = grid, clamped (the spring may overshoot slightly).
    private var overviewShown: Double { min(1, max(0, zoomState.progress)) }

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
            index = tabs.items.count
        } else {
            index = zoomTabId.flatMap { id in tabs.items.firstIndex { $0.id == id } } ?? (tabs.activeIndex ?? 0)
        }
        let grid = OverviewLayout(size: size, safeTop: safeTop, safeBottom: pageBottom, count: max(tabs.items.count, index + 1))
        return grid.zoomEndpoint(index, contentOrigin: gridContentOrigin, fallbackOffset: overviewScroll)
    }

    private var activeLocalTitle: LocalPageTitle? {
        switch tabs.activeItem {
        case .terminal(let t)?:
            let host = tabs.connection.hostInfo?.hostName ?? ""
            let cwd = t.cwd.isEmpty ? host : (host.isEmpty ? t.cwd : "\(host)  \(t.cwd)")
            return LocalPageTitle(title: t.title.isEmpty ? "Terminal" : t.title, subtitle: cwd, monospaced: true)
        case .macOnly(let t)?:
            return LocalPageTitle(title: t.title.isEmpty ? "Untitled" : t.title, subtitle: t.url.flatMap { URL(string: $0)?.host() } ?? "On your Mac")
        default:
            return nil
        }
    }

    var body: some View {
        let layout = ToolbarLayout.make(size: size, safeBottom: pageBottom, keyboard: keyboard, bar: chrome.bar,
                                        pillBottom: hostedInTabBar ? pageBottom : nil,
                                        editing: chrome.editing, splitBack: model.activeTab?.canGoForward == true, labelWidth: 69,
                                        noBack: tabs.activeTerminalKey != nil)
        ZStack(alignment: .topLeading) {
            pageLayer
                .frame(width: size.width, height: size.height)

            if chrome.editing {
                editingBackground
                    .transition(.opacity.animation(.easeInOut(duration: 0.1).delay(0.03)))
            }

            // Kept mounted (hidden) so opening it does not pay for building
            // the grid on the first animation frame.
            if tabs.loaded {
                TabOverview(tabs: tabs, images: overviewImages, layout: overviewLayout, shown: overviewShown, chrome: zoomDriver.chrome,
                            hiddenTabId: zoomState.phase == .overview ? nil : zoomTabId,
                            gridInteractive: zoomState.gridInteractive,
                            controlsInteractive: overviewVisible && zoomState.headingToOverview,
                            scrollOffset: $overviewScroll, position: $overviewPosition,
                            leadingItem: leadingItem,
                            onSelect: { closeOverview(selecting: $0) },
                            onClose: { id in withAnimation(motion.resolve(motion.reflow)) { tabs.close(id) } },
                            onNewTab: newTabFromOverview,
                            onNewTerminal: tabs.includesTerminals ? { newTerminalFromOverview() } : nil,
                            onDone: { closeOverview(selecting: tabs.activeKey) },
                            onCloseAll: closeAll,
                            placeholderId: newTabPending ? Self.newTabMarker : nil,
                            placeholderTerminal: newTabIsTerminal,
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
                Group {
                    if let item = zoomTabId.flatMap(tabs.item), case .macOnly(let t) = item {
                        localPageScaled(MacOnlyPage(tab: t, status: tabs.browserAccess, hostName: hostName, safeTop: safeTop, safeBottom: pageBottom), g.rect)
                    } else if content.terminal, let id = zoomTabId.flatMap(TabItem.terminalId(fromKey:)) {
                        // The live terminal laid out at full page size, scaled to the rect.
                        let scale = size.width > 0 ? max(0.01, g.rect.width / size.width) : 1
                        terminalContent(id, CGSize(width: size.width, height: size.height - safeTop - pageBottom - 64))
                            .padding(.top, safeTop)
                            .frame(width: size.width, height: size.height, alignment: .top)
                            .background(Color.cn(\.terminalBackground))
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: max(1, g.rect.width), height: max(1, g.rect.height), alignment: .topLeading)
                            .clipped()
                    } else {
                        ScaledPage(image: content.image, topColor: content.topColor, startPage: content.startPage, tabs: model.tabs,
                                   pageSize: size, safeTop: safeTop, strip: g.strip, terminal: content.terminal)
                    }
                }
                    .frame(width: max(1, g.rect.width), height: max(1, g.rect.height))
                    .clipShape(.rect(cornerRadius: g.radius, style: .continuous))
                    // The card's close button rides its corner at full size
                    // and fades in with the zoom's progress (CardChrome).
                    .overlay(alignment: .topTrailing) {
                        if zoomTabId != Self.newTabMarker {
                            CardCloseGlyph()
                                .padding(4)
                                .opacity(CardChrome.zoomCloseOpacity(progress: zoomState.progress, headingToOverview: zoomState.phase == .interactive || zoomState.headingToOverview))
                        }
                    }
                    #if DEBUG
                    // Recordings: outline the zoom rect so a frame-by-frame
                    // check can find it exactly (DEBUG pinch driver only).
                    .overlay {
                        if !debugFingers.isEmpty || debugPinchMode != nil {
                            Rectangle().strokeBorder(Color(red: 0, green: 1, blue: 0), lineWidth: 2)
                        }
                    }
                    #endif
                    .offset(x: g.rect.minX, y: g.rect.minY)
                    .allowsHitTesting(false)
            }

            if case .terminal(let t)? = tabs.activeItem, zoomState.phase == .page, !chrome.swiping, !chrome.editing {
                // Above the toolbar, riding the keyboard while it is up.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    terminalAccessory(t.id)
                }
                .padding(.bottom, keyboard > 0 ? keyboard : size.height - layout.capsule.minY + 8)
                .frame(width: size.width, height: size.height)
                .opacity(1 - overviewShown)
            }

            BrowserToolbar(chrome: chrome, tab: model.activeTab, local: activeLocalTitle,
                           showsStartPage: showsStartPage, size: size, safeBottom: pageBottom,
                           pillBottom: hostedInTabBar ? pageBottom : nil,
                           keyboard: keyboard,
                           onBack: model.goBack, onForward: model.goForward, onReload: model.reloadOrStop,
                           onMenu: openMenu, onTabs: openOverview, onBeginEditing: beginEditing,
                           onEndEditing: { endEditing() }, onGo: go,
                           onSwipeChanged: swipeChanged, onSwipeEnded: swipeEnded,
                           navigationHistory: model.activeTabId.flatMap { model.histories[$0] },
                           onHistory: model.goToHistory,
                           onHistoryMenu: { model.refreshHistory() })
                .opacity(1 - overviewShown)
                // Usable on the page, and while a zoom heads back to the page
                // (the tabs button then reverses it).
                .allowsHitTesting(!chrome.menuOpen && (zoomState.pageInteractive || (zoomState.phase == .animating && !zoomState.headingToOverview)))

            // Kept mounted (transparent) so the droplet starts growing on
            // the first frame after the tap instead of after its first layout.
            if tabs.loaded && !overviewVisible {
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

            if let error = model.errorText, tabs.items.isEmpty {
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
            guard let route = shellRoute, let raw = route.id else { return }
            let id: String
            switch route.kind {
            case .browserTab: id = raw
            case .terminal where tabs.includesTerminals: id = TabItem.terminalPrefix + raw
            default: return
            }
            if chrome.editing { endEditing() }
            if chrome.menuOpen { closeMenu() }
            if overviewVisible { closeOverview(selecting: id) }
            tabs.open(key: id)
        }
        .onChange(of: model.thumbnails) { _, _ in if overviewVisible { captureOverviewImages() } }
        #if DEBUG
        .task(id: model.activeFrame != nil) { await debugPinchScript() }
        .task(id: model.activeFrame != nil) { await debugOverviewScript() }
        #endif
        .onChange(of: size.width, initial: true) { _, w in zoomDriver.span = Double(w - overviewLayout.cardWidth) }
        .onAppear {
            zoomDriver.onSettle = { phase in
                if phase == .page {
                    zoomTabId = nil
                    chrome.expand(tap: true)
                }
            }
        }
        .onChange(of: tabs.items.isEmpty) { _, empty in
            // Closing the last tab opens a fresh start page, as Safari does.
            if empty, tabs.loaded, !overviewVisible { Task { await tabs.newBrowserTab() } }
        }
    }

    // MARK: Page

    private var hostName: String { tabs.connection.hostInfo?.hostName ?? "" }

    /// A local page (Mac-only) laid out at full size, scaled into `rect`.
    private func localPageScaled(_ page: some View, _ rect: CGRect) -> some View {
        let scale = size.width > 0 ? max(0.01, rect.width / size.width) : 1
        return page
            .frame(width: size.width, height: size.height, alignment: .top)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: max(1, rect.width), height: max(1, rect.height), alignment: .topLeading)
            .clipped()
    }

    @ViewBuilder private var pageLayer: some View {
        if case .macOnly(let t)? = tabs.activeItem, !chrome.swiping {
            if zoomState.phase == .page {
                MacOnlyPage(tab: t, status: tabs.browserAccess, hostName: hostName, safeTop: safeTop, safeBottom: pageBottom)
            } else {
                style.colors.startBackground
            }
        } else if let terminal = tabs.activeTerminal, !chrome.swiping {
            // A terminal tab: its live terminal fills the page (the terminal
            // module's embeddable view), under the same floating toolbar.
            // While a zoom runs the overlay draws it instead (one view per
            // terminal at a time).
            if zoomState.phase == .page {
                terminalContent(terminal.id, nil)
                    .padding(.top, safeTop)
                    .padding(.bottom, pageBottom + 64)
                    .frame(width: size.width, height: size.height)
                    .background(Color.cn(\.terminalBackground))
            } else {
                Color.cn(\.terminalBackground)
            }
        } else {
            browserPageLayer
        }
    }

    @ViewBuilder private var browserPageLayer: some View {
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
            if let key = tabs.activeKey, tabs.hiddenOnMac(key) != nil, !showsStartPage, !chrome.swiping, !displaced {
                HiddenOnMacOverlay(hostName: hostName, safeTop: safeTop, onShow: { tabs.showOnMac(key) })
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
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
        guard let index = tabs.activeIndex, offset != 0 else { return nil }
        let next = offset < 0 ? index + 1 : index - 1
        guard next >= 0 else { return nil }
        guard next < tabs.items.count else {
            return ZoomOverlay(tabId: "", image: nil, topColor: style.colors.startBackground, startPage: true, rect: fullRect, radius: 0, strip: 0)
        }
        let tab = tabs.items[next]
        let frame = model.frames[tab.id]
        return ZoomOverlay(tabId: tab.id, image: tabs.cardImage(tab.id), topColor: Color(uiColor: frame?.topColor ?? .white),
                           startPage: tabs.showsStartPage(tab.id), rect: fullRect, radius: 0, strip: 0)
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
                                   tabs.select(id)
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
        if let terminal = tabs.activeTerminal, let key = tabs.activeKey {
            return [
                [
                    PageMenuItem(title: "Rename", symbol: "pencil", action: menuAction { renameTerminal(key: key, current: terminal.title) }),
                    PageMenuItem(title: "Close Terminal", symbol: "xmark.square", action: menuAction { tabs.close(key) }),
                ],
                [
                    PageMenuItem(title: "Larger Text", symbol: "textformat.size.larger", action: menuAction { terminalFontStep(1) }),
                    PageMenuItem(title: "Smaller Text", symbol: "textformat.size.smaller", action: menuAction { terminalFontStep(-1) }),
                ],
            ]
        }
        if case .macOnly(let t)? = tabs.activeItem {
            let url = t.url.flatMap { URL(string: $0) }
            return [[
                PageMenuItem(title: "Share", symbol: "square.and.arrow.up", enabled: url != nil, action: menuAction {
                    if let url { ShareSheetPresenter().share(url) }
                }),
                PageMenuItem(title: "Copy URL", symbol: "doc.on.doc", enabled: url != nil, action: menuAction {
                    UIPasteboard.general.string = t.url
                }),
            ]]
        }
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
                PageMenuItem(title: desktop ? "Request Mobile Website" : "Request Desktop Website",
                             symbol: desktop ? "iphone" : "desktopcomputer", action: menuAction(model.toggleDesktop)),
                PageMenuItem(title: "Open on Mac", symbol: "macbook", action: menuAction(model.openOnMac)),
                PageMenuItem(title: "Close Tab", symbol: "xmark.square", enabled: tab != nil, action: menuAction {
                    if let id = tabs.activeKey { tabs.close(id) }
                }),
            ],
        ]
    }

    // MARK: Tab overview

    private var overviewLayout: OverviewLayout {
        OverviewLayout(size: size, safeTop: safeTop, safeBottom: pageBottom, count: tabs.items.count + (newTabPending ? 1 : 0))
    }

    /// What the zooming rect shows: the same image the card shows (or the
    /// live frame for the page), or the start page.
    private func zoomContent() -> (image: UIImage?, topColor: Color, startPage: Bool, terminal: Bool) {
        guard let id = zoomTabId, id != Self.newTabMarker else {
            return (nil, style.colors.startBackground, !newTabIsTerminal, newTabIsTerminal)
        }
        if TabItem.terminalId(fromKey: id) != nil {
            return (overviewImages[id] ?? tabs.cardImage(id), .black, false, true)
        }
        let frame = model.frames[id]
        let image = id == model.activeTabId ? (frame?.uiImage ?? overviewImages[id]) : (overviewImages[id] ?? tabs.cardImage(id))
        return (image, Color(uiColor: frame?.topColor ?? .white), tabs.showsStartPage(id) || (creatingTab && id == tabs.activeKey), false)
    }

    /// Prepares the grid when it is about to appear from the page.
    private func prepareOverview(revealing index: Int, count: Int) {
        chrome.pageKeyboard = false
        tabs.refreshThumbnails()
        captureOverviewImages()
        // Safari: before the page shrinks into its card, the grid jumps (no
        // animation) so the card is fully on screen (OverviewLayout.offset(revealing:from:)).
        let grid = OverviewLayout(size: size, safeTop: safeTop, safeBottom: pageBottom, count: count)
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
            zoomTabId = tabs.activeKey
            prepareOverview(revealing: tabs.activeIndex ?? 0, count: tabs.items.count)
        }
        zoomDriver.go(toOverview: true)
    }

    private func captureOverviewImages() {
        var images: [String: UIImage] = [:]
        for tab in model.tabs { images[tab.id] = tabs.cardImage(tab.id) }
        overviewImages = images
    }

    /// Done or a card: grid -> page, or reverse a zoom heading to the grid.
    private func closeOverview(selecting tabId: String?) {
        guard overviewVisible else { return }
        if zoomState.phase == .overview {
            guard let tabId, tabs.items.contains(where: { $0.id == tabId }) else {
                if tabs.items.isEmpty { newTabFromOverview() } else { zoomTabId = tabs.activeKey; zoomDriver.go(toOverview: false) }
                return
            }
            if tabId != tabs.activeKey { tabs.select(tabId) }
            zoomTabId = tabId
        }
        zoomDriver.go(toOverview: false)
    }

    /// (+): the new tab's start page grows from the grid slot its card will
    /// take (index = tab count). The grid first scrolls so that slot is on
    /// screen, as the overview does for the active card.
    private func newTabFromOverview() {
        guard zoomState.phase == .overview, !newTabPending else { return }
        // The new tab's card goes into the grid at once (placeholder in its
        // slot); the zoom starts only once the host created the tab, from
        // that slot. A refused create leaves the grid as it was, with a
        // toast; it never opens some other tab instead.
        newTabIsTerminal = false
        newTabPending = true
        Task {
            let id = await tabs.newBrowserTab()
            withAnimation(motion.resolve(motion.reflow)) { newTabPending = false }
            guard let id else { return }
            openCreated(id)
        }
    }

    /// Zooms from a just-created tab's card into it (grid only).
    private func openCreated(_ key: String) {
        guard zoomState.phase == .overview, tabs.items.contains(where: { $0.id == key }) else { return }
        zoomTabId = key
        zoomDriver.go(toOverview: false)
    }

    /// (+) > New Terminal: the terminal's card goes into the grid at once and
    /// the zoom grows from it into the terminal.
    private func newTerminalFromOverview() {
        guard zoomState.phase == .overview, !newTabPending else { return }
        newTabIsTerminal = true
        newTabPending = true
        Task {
            let key = await tabs.newTerminal()
            withAnimation(motion.resolve(motion.reflow)) { newTabPending = false }
            newTabIsTerminal = false
            guard let key else { return }
            openCreated(key)
        }
    }

    // MARK: Terminal tabs

    /// Font step for the active terminal (the tabs root wires the terminal module).
    var terminalFontStep: (Int) -> Void = { _ in }

    private func renameTerminal(key: String, current: String) {
        let alert = UIAlertController(title: "Rename Terminal", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = current; $0.clearButtonMode = .whileEditing }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak alert] _ in
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            if !text.isEmpty { tabs.rename(terminalKey: key, to: text) }
        })
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        top.present(alert, animated: true)
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
        if session.movementStart == nil, abs(sample.scale - 1) > 0.005 { session.movementStart = sample.time }
        let elapsed = session.movementStart.map { sample.time - $0 } ?? 0
        switch zoomState.phase {
        case .animating, .interactive:
            engage()
        case .page:
            guard !chrome.editing, !chrome.menuOpen, tabs.activeKey != nil || showsStartPage else {
                session.decision = .rejected; return
            }
            // Local decision, no round trip: a pinch-in that reaches 0.96
            // within 40 ms of the fingers starting to move, or any pinch-in
            // when the last frame shows the page at its minimum zoom (start
            // pages and blank tabs count as that). Pinch-out and a slow
            // pinch-in on a zoomed-in page go to the page.
            let atMinimumZoom = showsStartPage || (model.activeFrame?.pageScale ?? 1) <= 1.02
            let moving = session.movementStart.map { sample.time - $0 } ?? 0
            if sample.scale <= ZoomPinchSession.engageIn, atMinimumZoom || moving <= ZoomPinchSession.decisionWindow {
                zoomTabId = tabs.activeKey
                prepareOverview(revealing: tabs.activeIndex ?? 0, count: tabs.items.count)
                engage()
            } else if sample.scale > 1.005 || (!atMinimumZoom && moving > ZoomPinchSession.decisionWindow) {
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
        if !toOverview, let id = zoomTabId, id != tabs.activeKey, tabs.items.contains(where: { $0.id == id }) {
            tabs.select(id)
        }
        zoomDriver.release(toOverview: toOverview)
    }

    /// The tab whose card is under `point` (screen coordinates).
    private func cardTab(at point: CGPoint) -> String? {
        let grid = overviewLayout
        for (i, tab) in tabs.items.enumerated()
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
    /// DEBUG (`CMUX_NEXT_BROWSER_AUTO=<n>`): n times, open the grid with the
    /// tabs button and close it with Done (1.5 s apart), for recordings
    /// without taps.
    private func debugOverviewScript() async {
        guard model.activeFrame != nil || showsStartPage,
              let n = ProcessInfo.processInfo.environment["CMUX_NEXT_BROWSER_AUTO"].flatMap(Int.init) else { return }
        try? await Task.sleep(for: .seconds(3))  // recording lead-in (test script only)
        for _ in 0..<n {
            openOverview()
            try? await Task.sleep(for: .seconds(1.5))
            closeOverview(selecting: tabs.activeKey)
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

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
        let ids = tabs.items.map(\.id)
        withAnimation(motion.resolve(motion.reflow)) { for id in ids { tabs.close(id) } }
        newTabFromOverview()
    }

    // MARK: Toolbar swipe

    private func swipeChanged(_ dx: CGFloat) {
        if !chrome.swiping {
            chrome.swiping = true
            if let i = tabs.activeIndex {
                if i > 0 { tabs.requestThumbnail(tabs.items[i - 1].id) }
                if i + 1 < tabs.items.count { tabs.requestThumbnail(tabs.items[i + 1].id) }
            }
        }
        let atFirst = (tabs.activeIndex ?? 0) == 0
        chrome.swipeOffset = dx > 0 && atFirst ? dx * 0.25 : dx
    }

    private func swipeEnded(_ dx: CGFloat, _ predicted: CGFloat) {
        let pitch = size.width + 12
        let index = tabs.activeIndex ?? 0
        let commit = abs(predicted) > size.width * 0.35 || abs(dx) > size.width * 0.5
        var target: CGFloat = 0
        var destination: String?? = nil  // .some(nil) = new tab
        if commit, dx < 0 {
            target = -pitch
            destination = index + 1 < tabs.items.count ? .some(tabs.items[index + 1].id) : .some(nil)
        } else if commit, dx > 0, index > 0 {
            target = pitch
            destination = .some(tabs.items[index - 1].id)
        }
        withAnimation(motion.resolve(motion.swipe)) { chrome.swipeOffset = target } completion: {
            switch destination {
            case .some(.some(let id)): tabs.select(id)
            case .some(.none):
                creatingTab = true
                Task {
                    await tabs.newBrowserTab()
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
