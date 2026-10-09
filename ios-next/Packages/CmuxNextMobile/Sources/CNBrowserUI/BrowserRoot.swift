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
        .task {
            for await push in connection.pushes() { model.handle(push) }
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
    @State private var overviewShown: Double = 0
    @State private var overviewDetails: Double = 0
    @State private var zoom: ZoomOverlay?
    @State private var overviewScroll: CGFloat = 0
    @State private var overviewPosition = ScrollPosition(y: 0)
    @State private var menuExpanded = false
    @State private var menuContent = false
    @State private var newTabZoom: CGFloat?
    @State private var creatingTab = false
    /// Card images, captured when the overview opens so the hidden grid does
    /// not re-render on every live frame.
    @State private var overviewImages: [String: UIImage] = [:]
    @Environment(\.cnLeadingBarItem) private var leadingItem
    @Environment(\.displayScale) private var displayScale

    private let style = BrowserStyle.shared
    private var motion: BrowserMotion { style.motion }
    private var fullRect: CGRect { CGRect(origin: .zero, size: size) }

    private var showsStartPage: Bool { creatingTab || model.showsStartPage(model.activeTabId) }

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
                            hiddenTabId: zoom?.tabId, scrollOffset: $overviewScroll, position: $overviewPosition,
                            leadingItem: leadingItem,
                            onSelect: { closeOverview(selecting: $0) },
                            onClose: { id in withAnimation(motion.resolve(motion.reflow)) { model.close(id) } },
                            onNewTab: newTabFromOverview,
                            onDone: { closeOverview(selecting: model.activeTabId) },
                            onCloseAll: closeAll)
                    .opacity(chrome.overview ? 1 : 0)
                    .allowsHitTesting(chrome.overview && zoom == nil && newTabZoom == nil)
                    .accessibilityHidden(!chrome.overview)
            }

            if let zoom {
                PageSnapshot(image: zoom.image, topColor: zoom.topColor, strip: zoom.strip, startPage: zoom.startPage,
                             tabs: model.tabs, safeTop: safeTop)
                    .frame(width: zoom.rect.width, height: zoom.rect.height)
                    .clipShape(.rect(cornerRadius: zoom.radius, style: .continuous))
                    .offset(x: zoom.rect.minX, y: zoom.rect.minY)
                    .allowsHitTesting(false)
            }

            if let scale = newTabZoom {
                StartPageView(tabs: model.tabs, safeTop: safeTop, onOpen: { _ in })
                    .frame(width: size.width, height: size.height)
                    .clipShape(.rect(cornerRadius: 40 + (style.metrics.screenRadius - 40) * (scale - 0.45) / 0.55, style: .continuous))
                    .blur(radius: 12 * (1 - scale) / 0.55)
                    .scaleEffect(scale)
                    .allowsHitTesting(false)
            }

            BrowserToolbar(chrome: chrome, tab: model.activeTab, showsStartPage: showsStartPage, size: size, safeBottom: safeBottom,
                           keyboard: keyboard,
                           onBack: model.goBack, onForward: model.goForward, onReload: model.reloadOrStop,
                           onMenu: openMenu, onTabs: openOverview, onBeginEditing: beginEditing,
                           onEndEditing: { endEditing() }, onGo: go,
                           onSwipeChanged: swipeChanged, onSwipeEnded: swipeEnded)
                .opacity(1 - overviewShown)
                .allowsHitTesting(!chrome.overview && !chrome.menuOpen)

            // Kept mounted (transparent) so the droplet starts growing on
            // the first frame after the tap instead of after its first layout.
            if model.loaded && !chrome.overview {
                PageMenu(groups: menuGroups,
                         origin: CGRect(x: layout.capsule.minX, y: layout.capsule.minY, width: style.metrics.control, height: style.metrics.control),
                         capsule: layout.capsule, topLimit: safeTop + 8, expanded: menuExpanded, contentVisible: menuContent,
                         onDismiss: closeMenu)
                    .opacity(chrome.menuOpen ? 1 : 0)
                    .allowsHitTesting(chrome.menuOpen)
                    .accessibilityHidden(!chrome.menuOpen)
            }

            if let error = model.errorText, model.tabs.isEmpty {
                ContentUnavailableView("Browser Unavailable", systemImage: "safari", description: Text(error))
                    .frame(width: size.width, height: size.height)
                    .background(.background)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: geometryKey, initial: true) { _, _ in pushGeometry() }
        .onChange(of: model.thumbnails) { _, _ in if chrome.overview { captureOverviewImages() } }
        .onChange(of: model.tabs.isEmpty) { _, empty in
            // Closing the last tab opens a fresh start page, as Safari does.
            if empty, model.loaded, !chrome.overview { Task { await model.newTab() } }
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
                        wantsHardwareKeys: !chrome.editing && !chrome.overview,
                        onDrag: { chrome.pageDragged($0) },
                        onKeyboardDismissed: { chrome.pageKeyboard = false; pushGeometry() })
                .opacity(chrome.swiping || showsStartPage ? 0 : 1)
                .allowsHitTesting(!chrome.swiping && !showsStartPage)
            if showsStartPage && !chrome.swiping {
                StartPageView(tabs: model.tabs, safeTop: safeTop, onOpen: { model.navigate($0) })
            }
            if chrome.swiping {
                swipeCards(current: frame, topColor: topColor)
            }
        }
    }

    @ViewBuilder private func swipeCards(current: PageFrame?, topColor: Color) -> some View {
        let pitch = size.width + 12
        let offset = chrome.swipeOffset
        let progress = min(1, abs(offset) / pitch)
        let neighbor = swipeNeighbor(for: offset)
        ZStack(alignment: .topLeading) {
            style.colors.startBackground
            if let neighbor {
                PageSnapshot(image: neighbor.image, topColor: neighbor.topColor, strip: safeTop, startPage: neighbor.startPage,
                             tabs: model.tabs, safeTop: safeTop)
                    .frame(width: size.width, height: size.height)
                    .clipShape(.rect(cornerRadius: style.metrics.screenRadius, style: .continuous))
                    .scaleEffect(0.93 + 0.07 * progress)
                    .blur(radius: 6 * (1 - progress))
                    .offset(x: offset + (offset < 0 ? pitch : -pitch))
            }
            PageSnapshot(image: current?.uiImage, topColor: topColor, strip: safeTop, startPage: showsStartPage,
                         tabs: model.tabs, safeTop: safeTop)
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
        OverviewLayout(size: size, safeTop: safeTop, safeBottom: safeBottom, count: model.tabs.count)
    }

    private func openOverview() {
        guard !chrome.overview else { return }
        chrome.pageKeyboard = false
        model.refreshThumbnails()
        captureOverviewImages()
        let layout = overviewLayout
        let index = model.activeIndex ?? 0
        let offset = layout.offset(revealing: index)
        overviewPosition = ScrollPosition(y: offset)
        overviewScroll = offset
        overviewShown = 0
        overviewDetails = 0
        if let id = model.activeTabId {
            let frame = model.activeFrame
            zoom = ZoomOverlay(tabId: id, image: frame?.uiImage, topColor: Color(uiColor: frame?.topColor ?? .systemBackground),
                               startPage: showsStartPage, rect: fullRect, radius: style.metrics.screenRadius, strip: safeTop)
        }
        chrome.overview = true
        let card = layout.card(index).offsetBy(dx: 0, dy: -offset)
        withAnimation(motion.resolve(motion.overviewOpen)) {
            zoom?.rect = card
            zoom?.radius = style.metrics.cardRadius
            zoom?.strip = 0
            overviewShown = 1
        } completion: {
            zoom = nil
        }
        withAnimation(.easeOut(duration: 0.15).delay(0.22)) { overviewDetails = 1 }
    }

    private func captureOverviewImages() {
        var images: [String: UIImage] = [:]
        for tab in model.tabs { images[tab.id] = model.cardImage(tab.id) }
        overviewImages = images
    }

    private func closeOverview(selecting tabId: String?) {
        guard chrome.overview else { return }
        guard let tabId, let index = model.tabs.firstIndex(where: { $0.id == tabId }) else {
            withAnimation(.easeOut(duration: 0.2)) { overviewShown = 0 } completion: { chrome.overview = false }
            return
        }
        if tabId != model.activeTabId { model.select(tabId) }
        let card = overviewLayout.card(index).offsetBy(dx: 0, dy: -overviewScroll)
        let frame = model.frames[tabId]
        zoom = ZoomOverlay(tabId: tabId, image: model.cardImage(tabId), topColor: Color(uiColor: frame?.topColor ?? .white),
                           startPage: model.showsStartPage(tabId), rect: card, radius: style.metrics.cardRadius, strip: 0)
        withAnimation(.easeOut(duration: 0.1)) { overviewDetails = 0 }
        withAnimation(motion.resolve(motion.overviewClose)) {
            zoom?.rect = fullRect
            zoom?.radius = style.metrics.screenRadius
            zoom?.strip = safeTop
            overviewShown = 0
        } completion: {
            chrome.overview = false
            zoom = nil
            chrome.expand(tap: true)
        }
    }

    private func newTabFromOverview() {
        creatingTab = true
        newTabZoom = 0.45
        withAnimation(.easeOut(duration: 0.1)) { overviewDetails = 0 }
        withAnimation(motion.resolve(motion.newTab)) {
            newTabZoom = 1
            overviewShown = 0
        } completion: {
            chrome.overview = false
            newTabZoom = nil
        }
        Task {
            await model.newTab()
            creatingTab = false
        }
    }

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

/// A full page or card drawn from a frame image: page-colored status strip
/// above the page, image fitted to the width and top aligned.
struct PageSnapshot: View {
    var image: UIImage?
    var topColor: Color
    var strip: CGFloat
    var startPage: Bool
    var tabs: [BrowserTab]
    var safeTop: CGFloat

    var body: some View {
        if startPage {
            StartPageView(tabs: tabs, safeTop: safeTop, onOpen: { _ in })
        } else {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    topColor.frame(height: strip)
                    if let image {
                        Image(uiImage: image).resizable().interpolation(.medium)
                            .frame(width: geo.size.width, height: geo.size.width * image.size.height / max(1, image.size.width))
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .background(topColor)
                .clipped()
            }
        }
    }
}
#endif
