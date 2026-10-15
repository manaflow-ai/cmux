#if os(iOS)
import CNCore
import CNDesign
import SwiftUI
import UIKit


/// One tab card: snapshot with rounded corners, close button, title row.
struct TabCard: View {
    var item: TabItem
    var image: UIImage?
    var topColor: Color
    var startPage: Bool
    var tabs: [BrowserTab]
    var pageSize: CGSize
    var safeTop: CGFloat
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var showsClose: Bool
    /// The grid's close buttons and title rows (`CardChrome`).
    var closeOpacity: Double
    var titleOpacity: Double
    var titleOffset: CGFloat = 0
    /// The zoom draws this card's snapshot and close button; its title row
    /// stays here and fades in with the others.
    var snapshotHidden = false
    /// The card pre-composited at its pixel size (`CardBitmaps`); nil draws
    /// the page live (start pages, or until the bitmap is baked).
    var baked: UIImage?
    var onOpen: () -> Void = {}
    var onClose: () -> Void

    private let style = BrowserStyle.shared

    var body: some View {
        VStack(spacing: 0) {
            snapshot
                .frame(width: width, height: height)
                .background { CardShadow(radius: radius) }
                .overlay(alignment: .topTrailing) {
                    if showsClose {
                        Button(action: onClose) {
                            CardCloseGlyph()
                                .padding(4)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .opacity(closeOpacity)
                        .allowsHitTesting(closeOpacity > 0.5)
                        .accessibilityLabel("Close \(item.title)")
                    }
                }
                .opacity(snapshotHidden ? 0 : 1)
            HStack(spacing: 6) {
                Image(systemName: item.isTerminal ? "apple.terminal" : "globe").font(.system(size: 14))
                    .foregroundStyle(style.colors.secondaryLabel)
                Text(startPage ? "Start Page" : item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(style.colors.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: width, height: style.metrics.titleRow)
            .padding(.top, 2)
            .offset(y: titleOffset)
            .opacity(titleOpacity)
        }
        .frame(width: width, alignment: .top)
        // One element per card, framed to the card and its title row: the
        // scaled page inside reported an unlabeled image framed at the full
        // page size.
        .accessibilityRepresentation {
            Button("\(startPage ? "Start Page" : item.title), tab", action: onOpen)
                .accessibilityAction(named: "Open", onOpen)
                .accessibilityAction(named: "Close", onClose)
        }
    }

    @ViewBuilder private var snapshot: some View {
        if let baked {
            Image(uiImage: baked).resizable()
        } else {
            ScaledPage(image: image, topColor: topColor, startPage: startPage, tabs: tabs, pageSize: pageSize,
                       safeTop: safeTop, strip: 0, terminal: item.isTerminal)
                .clipShape(.rect(cornerRadius: radius, style: .continuous))
        }
    }
}

/// The card's close button: a 22 pt circle with a 9.5 pt semibold cross,
/// 4 pt from the card's top and trailing edges (device screenshot: 66 px
/// circle, 12 px insets at 3x). The zoom draws
/// the same glyph on the moving card.
struct CardCloseGlyph: View {
    private let style = BrowserStyle.shared
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(style.colors.cardCloseGlyph)
            .frame(width: style.metrics.cardClose, height: style.metrics.cardClose)
            .background(style.colors.cardCloseFill, in: .circle)
    }
}

/// A tab's page as a window: the page (status strip + frame image, or the
/// start page) is laid out at full screen size and scaled to this view's
/// width, top aligned and clipped. Cards, the zooming tab and the live page
/// all show the same content, so a zoom is one rect over one layout.
struct ScaledPage: View {
    var image: UIImage?
    var topColor: Color
    var startPage: Bool
    var tabs: [BrowserTab]
    /// Full page (screen) size the content is laid out at.
    var pageSize: CGSize
    var safeTop: CGFloat
    /// Status strip above the page in full-page points (safeTop for the
    /// full page, 0 for a card).
    var strip: CGFloat
    /// A terminal card: the image is the terminal's text, top-aligned on the
    /// terminal background below the status strip.
    var terminal = false

    var body: some View {
        GeometryReader { geo in
            let scale = pageSize.width > 0 ? geo.size.width / pageSize.width : 1
            content
                .frame(width: pageSize.width, height: pageSize.height, alignment: .top)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var content: some View {
        if terminal {
            VStack(spacing: 0) {
                Color.clear.frame(height: max(strip, safeTop))
                if let image {
                    Image(uiImage: image).resizable().interpolation(.medium)
                        .frame(width: pageSize.width, height: pageSize.width * image.size.height / max(1, image.size.width))
                }
                Spacer(minLength: 0)
            }
            .background(Color.cn(\.terminalBackground))
        } else if startPage {
            StartPageView(tabs: tabs, safeTop: strip, onOpen: { _ in })
        } else {
            VStack(spacing: 0) {
                topColor.frame(height: strip)
                if let image {
                    Image(uiImage: image).resizable().interpolation(.medium)
                        .frame(width: pageSize.width, height: pageSize.width * image.size.height / max(1, image.size.width))
                }
                Spacer(minLength: 0)
            }
            .background(image == nil ? Color.white : topColor)
        }
    }
}

/// The browser screen's coordinate space (zoom rects and card frames).
let browserScreenSpace = "cn.browser.screen"

/// Tab overview: blurred wallpaper, 2-column grid, top controls and the
/// bottom bar (+, "N Tabs", Done).
struct TabOverview: View {
    var tabs: TabsModel
    /// Swipe-to-close offsets (shared with the terminal layer).
    var swipes: CardSwipeState
    var images: [String: UIImage]
    var layout: OverviewLayout
    /// 0 while the page is full screen, 1 with the grid at rest.
    var shown: Double
    var chrome: CardChrome
    /// Card hidden while a zoom overlay stands in for it.
    var hiddenTabId: String?
    /// Cards take taps and pinches (the grid is settled).
    var gridInteractive: Bool
    /// Cards take swipes (the grid is settled, or a zoom is heading to it:
    /// Safari closes a card swiped during the zoom-out). Taps still wait
    /// for the grid to settle.
    var swipeInteractive = false
    /// The bottom bar takes taps (settled, or a zoom heading here: Done reverses it).
    var controlsInteractive: Bool
    /// Scroll offset and content origin, written on every scroll frame
    /// (never read by this body, so scrolling does not rebuild the cards).
    var scroll: GridScrollTracker
    @Binding var position: ScrollPosition
    var leadingItem: AnyView?
    var onSelect: (String) -> Void
    /// Closes the card's tab on the host; false when refused (it stays).
    var onClose: (String) async -> Bool
    var onNewTab: () -> Void
    /// Set when the grid also holds terminals: (+) offers both.
    var onNewTerminal: (() -> Void)?
    var onDone: () -> Void
    var onCloseAll: () -> Void
    /// A tab being created with (+): its start-page card is already in the
    /// grid (at index tabs.count) so the zoom can land on its real frame.
    var placeholderId: String?
    var placeholderTerminal = false
    /// The created tab that replaces the placeholder (no insert fade).
    var slotTakeover: String?
    /// A card's long-press menu item was chosen.
    var onCardMenu: (CardMenuAction, String) -> Void = { _, _ in }
    /// A card tapped during the zoom to the grid (open it once settled).
    var onQueueSelect: (String) -> Void = { _ in }
    /// Long press and drag: move the card to a grid index.
    var onMove: (String, Int) -> Void = { _, _ in }
    /// The grid started (true) or stopped (false) scrolling.
    var onScrolling: (Bool) -> Void = { _ in }

    private let style = BrowserStyle.shared
    @State private var bitmaps = CardBitmaps()
    /// A long-pressed card: lifted, the grid dimmed, its menu showing.
    @State private var pressed: String?
    /// Where the press began (window coordinates).
    @State private var pressStart: CGPoint = .zero
    /// A long-pressed card being dragged to another slot.
    @State private var reorder: CardReorder?

    private struct CardReorder: Equatable {
        let id: String
        /// The finger's offset from the card's origin (content coordinates).
        let grab: CGPoint
        /// The finger (content coordinates).
        var point: CGPoint
    }
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    /// The card's pre-composited bitmap (nil: draw it live).
    private func baked(_ tab: TabItem, image: UIImage?, topColor: UIColor, startPage: Bool, card: CGRect) -> UIImage? {
        guard let image, !startPage else { return nil }
        let uiStyle: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let background = tab.isTerminal ? CNTheme.shared.palette.terminalBackground : topColor
        let spec = CardBitmapSpec(size: card.size, scale: displayScale, radius: layout.cardRadius, pageSize: layout.size,
                                  topInset: tab.isTerminal ? layout.safeTop : 0,
                                  background: .init(background, style: uiStyle))
        return bitmaps.image(for: tab.id, source: image, spec: spec)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [style.colors.overviewTop, style.colors.overviewBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: layout.size.width, height: layout.contentHeight)
                    // The listed cards, then any swiped card still flying off
                        // after its tab left the list (the same view keeps going).
                    ForEach(gridCards(), id: \.item.id) { card in gridCardView(card) }
                    if let id = pressed, let index = tabs.items.firstIndex(where: { $0.id == id }) {
                        // The grid dims behind the lifted card; a tap outside closes the menu.
                        Color.black.opacity(CardMenuStyle.dim)
                            .frame(width: layout.size.width, height: max(layout.contentHeight, layout.size.height))
                            .contentShape(.rect)
                            .onTapGesture { closeMenu() }
                            .zIndex(15_000)
                            .transition(.opacity)
                        cardMenuPanel(tabs.items[index], card: layout.card(index))
                            .zIndex(17_000)
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                    }
                    if let placeholderId {
                        let r = layout.card(tabs.items.count)
                        TabCard(item: placeholderTerminal ? .terminal(Terminal(id: placeholderId, title: "Terminal", cwd: "", cols: 80, rows: 24, running: true, createdAt: 0))
                                    : .browser(BrowserTab(id: placeholderId, url: "", title: "")),
                                image: nil, topColor: .white, startPage: !placeholderTerminal,
                                tabs: tabs.browser.tabs, pageSize: layout.size, safeTop: layout.safeTop, width: r.width, height: r.height,
                                radius: layout.cardRadius, showsClose: false, closeOpacity: chrome.closeOpacity,
                                titleOpacity: chrome.titleOpacity, titleOffset: chrome.titleOffset,
                                snapshotHidden: placeholderId == hiddenTabId, onClose: {})
                            .offset(x: r.minX, y: r.minY)
                            .zIndex(Double(tabs.items.count))
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: layout.size.width, height: layout.contentHeight, alignment: .topLeading)
                .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named(browserScreenSpace)).origin }) { [scroll] origin in
                    if scroll.contentOrigin != origin { scroll.contentOrigin = origin }
                }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { [scroll] _, y in
                if scroll.offset != y { scroll.offset = y }
            }
            .onScrollPhaseChange { _, phase in onScrolling(phase.isScrolling) }
            .onChange(of: tabs.items.map(\.id)) { _, ids in
                bitmaps.retain(Set(ids).union(swipes.departing.map(\.id)))
                if let p = pressed, !ids.contains(p) { pressed = nil }
            }
            // A drag that ended without a drop never reports back: leaving
            // the settled grid always shows every card again.
            .onChange(of: gridInteractive) { _, _ in
                pressed = nil
                reorder = nil
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .scaleEffect(1.06 - 0.06 * shown)
            .blur(radius: 10 * (1 - shown))
            .allowsHitTesting(gridInteractive || swipeInteractive)

            // Glass ignores inherited opacity; keep hidden controls out of
            // the hierarchy instead.
            if shown > 0 {
                topControls
                    .opacity(shown)
                    .allowsHitTesting(gridInteractive)
                bottomBar
                    .opacity(shown)
                    .allowsHitTesting(controlsInteractive)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private func cardImage(_ tab: TabItem) -> UIImage? {
        tab.isTerminal ? (tabs.cardImage(tab.id) ?? images[tab.id]) : (images[tab.id] ?? tabs.cardImage(tab.id))
    }

    /// One grid card with its tap, long-press menu, drag and swipe.
    @ViewBuilder private func gridCardView(_ card: GridCard) -> some View {
        let tab = card.item, index = card.index
        let r = card.departed?.rect ?? layout.card(index)
        let image: UIImage? = card.departed?.image ?? cardImage(tab)
        let top: UIColor = card.departed.map { UIColor($0.topColor) } ?? (tabs.browser.frames[tab.id]?.topColor ?? .white)
        let startPage: Bool = card.departed?.startPage ?? tabs.showsStartPage(tab.id)
        let copy = { DepartingCard(id: tab.id, item: tab, rect: r, image: image, topColor: Color(uiColor: top), startPage: startPage) }
        TabCard(item: tab, image: image,
                topColor: Color(uiColor: top),
                startPage: startPage, tabs: tabs.browser.tabs, pageSize: layout.size,
                safeTop: layout.safeTop, width: r.width, height: r.height, radius: layout.cardRadius, showsClose: true,
                closeOpacity: chrome.closeOpacity, titleOpacity: chrome.titleOpacity,
                titleOffset: chrome.titleOffset, snapshotHidden: tab.id == hiddenTabId,
                baked: baked(tab, image: image, topColor: top, startPage: startPage, card: r),
                onOpen: { onSelect(tab.id) },
                onClose: { Task { _ = await onClose(tab.id) } })
            .contentShape(.rect)
            // During the zoom to the grid a tap is kept and opens the card
            // once the grid has settled (Safari queues it).
            .onTapGesture { if gridInteractive { onSelect(tab.id) } else if swipeInteractive { onQueueSelect(tab.id) } }
            // Long press: Safari's card menu; moving the finger then drags
            // the card to another slot.
            .gesture(CardLongPressGesture { phase in press(phase, tab: tab, rect: r) })
            // Swipe left to close (CardSwipe).
            .gesture(CardSwipeGesture { phase in
                // The card the zoom is landing on stays put.
                guard gridInteractive || tab.id != hiddenTabId else { return }
                let rm = UIAccessibility.isReduceMotionEnabled
                // A long press owns the touch (menu or reorder): the swipe never
                // moves the card, and its release can never close it.
                guard CardGestures.swipeAllowed(card: tab.id, pressed: pressed, reordering: reorder?.id) else {
                    if swipes.isRaised(tab.id), !swipes.isDeparting(tab.id) { swipes.cancel(tab.id, reduceMotion: rm) }
                    return
                }
                switch phase {
                case .changed(let dx):
                    swipes.track(tab.id, translation: dx, reduceMotion: rm)
                case .ended(_, let v):
                    swipes.release(tab.id, velocity: v, card: r, reduceMotion: rm, departing: copy) {
                        let closed = await onClose(tab.id)
                        // Safari opens the last tab when a swipe leaves only one.
                        if closed, tabs.items.count == 1, let last = tabs.items.first { onSelect(last.id) }
                        return closed
                    }
                case .cancelled: swipes.cancel(tab.id, reduceMotion: rm)
                }
            })
            .opacity(swipes.opacity(tab.id))
            // Lifted about the card's centre while swiped (× 1.093) or long
            // pressed (× 1.06, Safari's lift).
            .scaleEffect(pressed == tab.id || reorder?.id == tab.id ? CardMenuStyle.lift : swipes.scale(tab.id),
                         anchor: UnitPoint(x: 0.5, y: r.height / 2 / max(1, r.height + 25)))
            // Explicit stacking in grid order (a swiped card on
            // top): cards crossing in a reflow keep their order
            // for the whole move (Safari; audit D9).
            .zIndex(swipes.isDeparting(tab.id) ? 20_000 : pressed == tab.id || reorder?.id == tab.id ? 16_000
                    : swipes.isRaised(tab.id) ? 10_000 : Double(index))
            .offset(cardOffset(tab.id, rect: r))
            // The (+) tab taking its placeholder's slot appears in place.
            .transition(tab.id == slotTakeover ? .identity
                        : .asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.9))))
    
    }

    /// One grid card: a listed tab at its index, or a swiped card that left
    /// the list and is still flying off (drawn where it was).
    private struct GridCard {
        let item: TabItem
        let index: Int
        let departed: DepartingCard?
    }

    private func gridCards() -> [GridCard] {
        let items = tabs.items
        var cards = items.enumerated().map { GridCard(item: $0.element, index: $0.offset, departed: nil) }
        let listed = Set(items.map(\.id))
        for d in swipes.departing where !listed.contains(d.id) {
            cards.append(GridCard(item: d.item, index: items.count, departed: d))
        }
        return cards
    }

    /// Safari's card menu (no Pin, Select or Move yet); terminals only close.
    private func menuItems(_ tab: TabItem) -> [[(title: String, symbol: String, destructive: Bool, action: CardMenuAction)]] {
        var groups: [[(title: String, symbol: String, destructive: Bool, action: CardMenuAction)]] = []
        if case .browser = tab {
            groups.append([("Copy Link", "doc.on.doc", false, .copyLink), ("Duplicate Tab", "plus.square.on.square", false, .duplicate)])
        }
        var close: [(title: String, symbol: String, destructive: Bool, action: CardMenuAction)] = [("Close Tab", "xmark", true, .close)]
        if tabs.items.count > 1 { close.append(("Close Other Tabs", "xmark.square", true, .closeOthers)) }
        groups.append(close)
        return groups
    }

    /// The glass menu under the lifted card (over it when there is no room below).
    @ViewBuilder private func cardMenuPanel(_ tab: TabItem, card: CGRect) -> some View {
        let groups = menuItems(tab)
        let rows = groups.reduce(0) { $0 + $1.count }
        let height = CGFloat(rows) * CardMenuStyle.row + CGFloat(groups.count - 1) * 8
        let width = CardMenuStyle.width
        let below = card.maxY + style.metrics.titleRow + 12
        let screenBottom = (scroll.contentOrigin.map { -$0.y } ?? 0) + layout.size.height - layout.safeBottom - 60
        let y = below + height <= screenBottom ? below : max(8, card.minY - 12 - height)
        let x = min(max(16, card.midX - width / 2), layout.size.width - 16 - width)
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { g, group in
                if g > 0 { Rectangle().fill(style.colors.label.opacity(0.08)).frame(height: 8) }
                ForEach(Array(group.enumerated()), id: \.offset) { _, item in
                    Button {
                        closeMenu()
                        onCardMenu(item.action, tab.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol).frame(width: 22)
                            Text(item.title)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 17))
                        .foregroundStyle(item.destructive ? Color.red : style.colors.label)
                        .padding(.horizontal, 16)
                        .frame(height: CardMenuStyle.row)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: width)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .offset(x: x, y: y)
    }

    private func closeMenu() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { pressed = nil }
    }

    /// A card's offset: its slot plus its swipe, or under the finger while
    /// it is dragged to another slot.
    private func cardOffset(_ id: String, rect r: CGRect) -> CGSize {
        if let drag = reorder, drag.id == id {
            return CGSize(width: drag.point.x - drag.grab.x, height: drag.point.y - drag.grab.y)
        }
        return CGSize(width: r.minX + swipes.offset(id), height: r.minY)
    }

    /// Window point -> grid content point.
    private func contentPoint(_ p: CGPoint) -> CGPoint {
        let o = scroll.contentOrigin ?? .zero
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }

    private func press(_ phase: CardPressPhase, tab: TabItem, rect r: CGRect) {
        switch phase {
        case .began(let p):
            guard gridInteractive, !swipes.isRaised(tab.id) else { return }
            pressStart = p
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pressed = tab.id }
        case .changed(let p):
            guard pressed == tab.id || reorder?.id == tab.id else { return }
            if reorder == nil {
                guard hypot(p.x - pressStart.x, p.y - pressStart.y) > 10 else { return }
                // The finger moved: the menu goes, the card follows the finger.
                let c = contentPoint(p)
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { pressed = nil }
                reorder = CardReorder(id: tab.id, grab: CGPoint(x: c.x - r.minX, y: c.y - r.minY), point: c)
            }
            guard var drag = reorder else { return }
            drag.point = contentPoint(p)
            reorder = drag
            let center = CGPoint(x: drag.point.x - drag.grab.x + r.width / 2, y: drag.point.y - drag.grab.y + r.height / 2)
            if let slot = layout.slot(at: center), slot < tabs.items.count,
               tabs.items.firstIndex(where: { $0.id == tab.id }) != slot {
                withAnimation(style.motion.resolve(style.motion.reflow)) { onMove(tab.id, slot) }
            }
        case .ended, .cancelled:
            if reorder?.id == tab.id {
                withAnimation(style.motion.resolve(style.motion.reflow)) { reorder = nil }
            }
        }
    }

    private var topControls: some View {
        let y = layout.safeTop + 4 + style.metrics.overviewTopControl / 2
        // One container for the glass controls: they share one backdrop
        // capture instead of one each, re-rendered on every scroll frame
        // (spacing 0: they never blend into one shape).
        return GlassEffectContainer(spacing: 0) {
        ZStack(alignment: .topLeading) {
            if let leadingItem {
                // Plain glass (an interactive glass shape over the button
                // swallowed its taps) and a full-circle hit area.
                leadingItem
                    .buttonStyle(ShellCircleButtonStyle(diameter: style.metrics.overviewTopControl))
                    .glassEffect(.regular, in: .circle)
                    .position(x: 20 + 18, y: y)
            }
            Menu {
                Button("Close All Tabs", systemImage: "xmark", role: .destructive, action: onCloseAll)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(style.colors.label)
                    .frame(width: style.metrics.overviewTopControl, height: style.metrics.overviewTopControl)
                    .contentShape(.circle)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .position(x: layout.size.width - 20 - 18, y: y)
            .accessibilityLabel("More")
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        }
    }

    private var bottomBar: some View {
        let bar = layout.barRect
        // Never "0 Tabs": closing the last tab opens a fresh one in the next
        // update, and Safari's count goes straight to 1.
        let count = max(1, tabs.items.count)
        // One glass container for the bar (see `topControls`).
        return GlassEffectContainer(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let onNewTerminal {
                        // Browser tabs and terminals: (+) asks which.
                        Menu {
                            Button("New Tab", action: onNewTab)
                            Button("New Terminal", action: onNewTerminal)
                        } label: {
                            Image(systemName: "plus").font(.system(size: 22, weight: .regular))
                                .foregroundStyle(style.colors.label)
                                .frame(width: 48, height: 48).contentShape(.circle)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                    } else {
                        Button(action: onNewTab) {
                            Image(systemName: "plus").font(.system(size: 22, weight: .regular))
                                .foregroundStyle(style.colors.label)
                                .frame(width: 48, height: 48).contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .position(x: 38 + 24, y: bar.midY)
                .accessibilityLabel("New Tab")

                // One glass shape per control (two nested glass capsules
                // read as a double background).
                Text(count == 1 ? "1 Tab" : "\(count) Tabs")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(style.colors.label)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .glassEffect(.regular, in: .capsule)
                    .position(x: layout.size.width / 2, y: bar.midY)
                    // Safari swaps the count at once (no crossfade), even
                    // inside the reflow's animation.
                    .contentTransition(.identity)
                    .transaction { $0.animation = nil }

                Button(action: onDone) {
                    Image(systemName: "checkmark").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(style.colors.accent).interactive(), in: .circle)
                .position(x: layout.size.width - 38 - 24, y: bar.midY)
                .accessibilityLabel("Done")
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        }
    }
}
#endif

#if os(iOS)
/// A card's long-press menu items.
enum CardMenuAction: Equatable, Sendable {
    case copyLink, duplicate, close, closeOthers
}

/// Safari's long press on a grid card (tabs-parity-audit 5a / re-audit D6):
/// the card lifts to × 1.06 and the other cards dim.
struct CardMenuStyle: Equatable, Sendable {
    static let lift: CGFloat = 1.06
    static let dim = 0.35
    static let width: CGFloat = 250
    static let row: CGFloat = 44
}

#endif
