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
    var contentOffset: CGFloat = 0
    var onOpen: () -> Void = {}
    var onClose: () -> Void

    private let style = BrowserStyle.shared

    var body: some View {
        VStack(spacing: 0) {
            snapshot
                .frame(width: width, height: height)
                .background { CardShadow(radius: radius) }
                .opacity(snapshotHidden ? 0 : 1)
            HStack(spacing: 6) {
                Image(systemName: item.isTerminal ? "apple.terminal" : "globe").font(.system(size: 14))
                    .foregroundStyle(style.colors.secondaryLabel)
                Text(startPage ? "Start Page" : item.title)
                    .chromeFont(15, weight: .semibold, cap: ChromeType.cardCap)
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
        // The close button is its own element after the card, as Safari's
        // "Close" (tabs QA #17: it was folded into the card's element).
        .overlay(alignment: .topTrailing) {
            if showsClose {
                Button(action: onClose) {
                    CardCloseGlyph()
                        .padding(4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .opacity(closeOpacity * (snapshotHidden ? 0 : 1))
                .allowsHitTesting(closeOpacity > 0.5 && !snapshotHidden)
                .accessibilityLabel("Close")
                .accessibilityHint(Text("Closes \(startPage ? "Start Page" : item.title)"))
                .accessibilityHidden(closeOpacity < 0.5)
                .accessibilitySortPriority(-1)
            }
        }
        // The card, then its Close (Safari's order).
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var snapshot: some View {
        if let baked {
            Image(uiImage: baked).resizable()
        } else {
            ScaledPage(image: image, topColor: topColor, startPage: startPage, tabs: tabs, pageSize: pageSize,
                       safeTop: safeTop, strip: 0, terminal: item.isTerminal, contentOffset: contentOffset)
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
    /// Page points the terminal's text moves up so its prompt is in the card
    /// (`TabsModel.cardContentOffset`).
    var contentOffset: CGFloat = 0

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
                        .offset(y: -contentOffset)
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
    /// A card's ✕ (the count waits for the reflow's first frame); nil: `onClose`.
    var onCloseTap: ((String) async -> Bool)? = nil
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
    /// A Select Tabs bar action.
    var onSelectionAction: (SelectionAction) -> Void = { _ in }
    /// Long press and drag: move the card to a grid index.
    var onMove: (String, Int) -> Void = { _, _ in }
    /// The grid started (true) or stopped (false) scrolling.
    var onScrolling: (Bool) -> Void = { _ in }

    private let style = BrowserStyle.shared
    @State private var bitmaps = CardBitmaps()
    /// A card dragged from its lifted context-menu preview to another slot.
    @State private var dragging: String?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    /// The card's pre-composited bitmap (nil: draw it live).
    /// A terminal card's content anchor (its prompt in view) for a card `card`.
    private func contentOffset(_ tab: TabItem, card: CGRect) -> CGFloat {
        guard tab.isTerminal, card.width > 0 else { return 0 }
        return tabs.cardContentOffset(tab.id, visibleHeight: layout.size.width * card.height / card.width - layout.safeTop)
    }

    private func baked(_ tab: TabItem, image: UIImage?, topColor: UIColor, startPage: Bool, card: CGRect) -> UIImage? {
        guard let image, !startPage else { return nil }
        let uiStyle: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let background = tab.isTerminal ? CNTheme.shared.palette.terminalBackground : topColor
        let spec = CardBitmapSpec(size: card.size, scale: displayScale, radius: layout.cardRadius, pageSize: layout.size,
                                  topInset: tab.isTerminal ? layout.safeTop : 0,
                                  background: .init(background, style: uiStyle),
                                  contentOffset: contentOffset(tab, card: card))
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
                // Long press, then drag from the lifted preview: the card moves
                // to the slot under the finger (Safari).
                .onDrop(of: [.text], delegate: CardReorderDrop(layout: layout, ids: tabs.items.map(\.id), pinned: layout.pinned,
                                                            dragging: $dragging, move: onMove))
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
                if let d = dragging, !ids.contains(d) { dragging = nil }
            }
            // A drag that ended without a drop never reports back: leaving
            // the settled grid always shows every card again.
            .onChange(of: gridInteractive) { _, _ in dragging = nil }
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            // Safari's top edge: cards scrolled under the status bar and the
            // top controls blur and fade into the background (tabs QA #18).
            .overlay(alignment: .top) {
                let h = layout.safeTop + 52
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                        .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                    LinearGradient(colors: [style.colors.overviewTop, style.colors.overviewTop.opacity(0.6), .clear],
                                   startPoint: .top, endPoint: .bottom)
                }
                .frame(height: h)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .scaleEffect(1.06 - 0.06 * shown)
            .blur(radius: 10 * (1 - shown))
            .allowsHitTesting(gridInteractive || swipeInteractive)

            // Glass ignores inherited opacity; keep hidden controls out of
            // the hierarchy instead.
            // Glass ignores inherited opacity, so the hidden controls are
            // parked off screen (and out of the accessibility tree) instead
            // of leaving the hierarchy: building their glass in the zoom's
            // first frames made those frames late.
            let parked = shown <= 0
            Group {
                Group {
                    if tabs.selecting { selectControls } else { topControls }
                }
                    .opacity(shown)
                    .allowsHitTesting(gridInteractive)
                bottomBar
                    .opacity(shown)
                    .allowsHitTesting(controlsInteractive)
            }
            .offset(y: parked ? layout.size.height * 2 : 0)
            .accessibilityHidden(parked)
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private func cardImage(_ tab: TabItem) -> UIImage? {
        tab.isTerminal ? (tabs.cardImage(tab.id) ?? images[tab.id]) : (images[tab.id] ?? tabs.cardImage(tab.id))
    }

    /// One grid card with its tap, long-press menu, drag and swipe. Pinned
    /// items are capsules in the pinned area.
    @ViewBuilder private func gridCardView(_ card: GridCard) -> some View {
        if card.departed == nil, card.index < layout.pinned {
            pinnedCardView(card.item, index: card.index)
        } else {
            tabCardView(card)
        }
    }

    @ViewBuilder private func tabCardView(_ card: GridCard) -> some View {
        let tab = card.item, index = card.index
        let r = card.departed?.rect ?? layout.card(index)
        let image: UIImage? = card.departed?.image ?? cardImage(tab)
        let top: UIColor = card.departed.map { UIColor($0.topColor) } ?? (tabs.browser.frames[tab.id]?.topColor ?? .white)
        let startPage: Bool = card.departed?.startPage ?? tabs.showsStartPage(tab.id)
        let copy = { DepartingCard(id: tab.id, item: tab, rect: r, image: image, topColor: Color(uiColor: top), startPage: startPage) }
        let selecting = tabs.selecting
        TabCard(item: tab, image: image,
                topColor: Color(uiColor: top),
                startPage: startPage, tabs: tabs.browser.tabs, pageSize: layout.size,
                safeTop: layout.safeTop, width: r.width, height: r.height, radius: layout.cardRadius, showsClose: !selecting,
                closeOpacity: chrome.closeOpacity, titleOpacity: chrome.titleOpacity,
                titleOffset: chrome.titleOffset, snapshotHidden: tab.id == hiddenTabId,
                baked: baked(tab, image: image, topColor: top, startPage: startPage, card: r),
                contentOffset: contentOffset(tab, card: r),
                onOpen: { onSelect(tab.id) },
                onClose: {
                    guard tabs.gridAcceptsCloseTaps else { return }
                    Task { _ = await (onCloseTap ?? onClose)(tab.id) }
                })
            // Under its lifted long-press preview, and while it is dragged to
            // another slot (the dragged card is the card), the card is hidden.
            .opacity(swipes.menuCard == tab.id || dragging == tab.id ? 0 : 1)
            .overlay(alignment: .topLeading) {
                if selecting { SelectionMark(selected: tabs.selection.contains(tab.id), width: r.width, height: r.height, radius: layout.cardRadius) }
            }
            // Tap, swipe, the system context menu (the card lifts into its
            // preview) and a drag from the lifted preview, in UIKit (CardInteraction).
            .overlay(alignment: .topLeading) {
                CardInteraction(
                    card: r.size, radius: layout.cardRadius,
                    passThrough: selecting ? nil : CGRect(x: r.width - 30, y: 0, width: 30, height: 30),
                    menu: { selecting ? [] : menuSections(tab) },
                    preview: { scale in
                        AnyView(CardMenuPreview(item: tab, image: image, topColor: Color(uiColor: top), startPage: startPage,
                                                tabs: tabs.browser.tabs, pageSize: layout.size, safeTop: layout.safeTop,
                                                card: r.size, radius: layout.cardRadius, scale: scale))
                    },
                    dragKey: selecting ? nil : tab.id,
                    onMenu: { open in swipes.menuChanged(tab.id, open) },
                    onTap: {
                        // During the zoom to the grid a tap is kept and opens the
                        // card once the grid has settled (Safari queues it).
                        // Selecting: a tap toggles the card.
                        #if DEBUG
                        MainStallTrace.mark("card tap grid=\(gridInteractive) swipe=\(swipeInteractive)")
                        #endif
                        if selecting { tabs.toggleSelected(tab.id) }
                        else if gridInteractive { onSelect(tab.id) } else if swipeInteractive { onQueueSelect(tab.id) }
                    },
                    onPan: { phase in
                        // The card the zoom is landing on stays put; nothing swipes
                        // while selecting or while a card is dragged to a new slot.
                        guard gridInteractive || tab.id != hiddenTabId, !selecting else { return }
                        let rm = UIAccessibility.isReduceMotionEnabled
                        guard CardGestures.swipeAllowed(card: tab.id, pressed: nil, reordering: dragging) else {
                            if swipes.isRaised(tab.id), !swipes.isDeparting(tab.id) { swipes.cancel(tab.id, reduceMotion: rm) }
                            return
                        }
                        switch phase {
                        case .changed(let dx):
                            swipes.track(tab.id, translation: dx, reduceMotion: rm, cardWidth: r.width,
                                         onFling: { tabs.countHold = $0 ? max(1, tabs.items.count - 1) : nil })
                        case .ended(_, let v):
                            swipes.release(tab.id, velocity: v, card: r, reduceMotion: rm, departing: copy,
                                           onCommit: { tabs.countHold = max(1, tabs.items.count - 1) }) {
                                let closed = await onClose(tab.id)
                                // Safari opens the last tab when a swipe leaves only one.
                                if closed, tabs.items.count == 1, let last = tabs.items.first { onSelect(last.id) }
                                return closed
                            }
                        case .cancelled: swipes.cancel(tab.id, reduceMotion: rm)
                        }
                    },
                    onDragStart: { dragging = tab.id },
                    onDragEnd: { dragging = nil })
                .frame(width: r.width, height: r.height + OverviewLayout.titleRow)
            }
            .opacity(swipes.opacity(tab.id))
            // Lifted about the card's centre while swiped (× 1.093).
            .scaleEffect(swipes.scale(tab.id), anchor: UnitPoint(x: 0.5, y: r.height / 2 / max(1, r.height + 25)))
            // Explicit stacking in grid order (a swiped card on
            // top): cards crossing in a reflow keep their order
            // for the whole move (Safari; audit D9).
            .zIndex(swipes.isDeparting(tab.id) ? 20_000 : swipes.isRaised(tab.id) ? 10_000 : Double(index))
            .offset(x: r.minX + swipes.offset(tab.id), y: r.minY)
            // The (+) tab taking its placeholder's slot appears in place.
            .transition(tab.id == slotTakeover ? .identity
                        : .asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.9))))
    }

    /// A pinned tab: Safari's capsule (globe, title, pin) above the grid.
    @ViewBuilder private func pinnedCardView(_ tab: TabItem, index: Int) -> some View {
        let r = layout.card(index)
        let selecting = tabs.selecting
        PinnedCard(item: tab, width: r.width, height: r.height, selected: selecting ? tabs.selection.contains(tab.id) : nil)
            .opacity(swipes.menuCard == tab.id ? 0 : 1)
            .overlay {
                CardInteraction(
                    card: r.size, radius: r.height / 2, passThrough: nil,
                    menu: { selecting ? [] : menuSections(tab) },
                    preview: { scale in
                        AnyView(PinnedCard(item: tab, width: r.width * scale, height: r.height * scale, selected: nil))
                    },
                    dragKey: nil,
                    onMenu: { open in swipes.menuChanged(tab.id, open) },
                    onTap: { if selecting { tabs.toggleSelected(tab.id) } else if gridInteractive { onSelect(tab.id) } },
                    onPan: { _ in }, onDragStart: {}, onDragEnd: {})
            }
            .zIndex(Double(index))
            .offset(x: r.minX, y: r.minY)
            .transition(.opacity)
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

    /// Safari's card menu (validation round 22): Copy Link, Pin Tab,
    /// Duplicate Tab, Select Tabs, Close Tab, then Close Other Tabs after a
    /// separator. A pinned tab: Copy Link, Unpin Tab, Select Tabs, Close
    /// Tab. Terminals get the items that apply to them. Safari's Move Tab
    /// moves a tab to another tab group; the host has no tab groups and no
    /// way to move a tab between Mac windows, so it is left out.
    private func menuSections(_ tab: TabItem) -> [[CardMenuEntry]] {
        let pinned = tabs.isPinned(tab.id)
        let key = tab.id
        var main: [CardMenuEntry] = []
        if case .browser = tab {
            main.append(CardMenuEntry(title: "Copy Link", symbol: "link") { onCardMenu(.copyLink, key) })
        }
        if pinned {
            main.append(CardMenuEntry(title: "Unpin Tab", symbol: "pin.slash") { onCardMenu(.unpin, key) })
        } else {
            main.append(CardMenuEntry(title: "Pin Tab", symbol: "pin") { onCardMenu(.pin, key) })
        }
        if case .browser = tab, !pinned {
            main.append(CardMenuEntry(title: "Duplicate Tab", symbol: "plus.square.on.square") { onCardMenu(.duplicate, key) })
        }
        main.append(CardMenuEntry(title: "Select Tabs", symbol: "checkmark.circle") { onCardMenu(.select, key) })
        main.append(CardMenuEntry(title: "Close Tab", symbol: "xmark", destructive: true) { onCardMenu(.close, key) })
        var sections = [main]
        if !pinned, tabs.items.count > 1 {
            sections.append([CardMenuEntry(title: "Close Other Tabs", symbol: "xmark", destructive: true) { onCardMenu(.closeOthers, key) }])
        }
        return sections
    }

    /// Select Tabs: Safari's top bar becomes Close (with a confirmation),
    /// More (Pin, Copy Links) and Done, with "N selected" over the grid.
    private var selectControls: some View {
        let d = style.metrics.overviewTopControl
        let y = layout.safeTop + 4 + d / 2
        let sel = tabs.selection
        return GlassEffectContainer(spacing: 0) {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Menu {
                    Button(sel.closeTitle, role: .destructive) { onSelectionAction(.close) }
                } label: {
                    Text("Close").font(.system(size: 17)).padding(.horizontal, 12).frame(height: d).contentShape(.rect)
                }
                .disabled(sel.isEmpty)
                Menu {
                    Button(sel.pinTitle, systemImage: "pin") { onSelectionAction(.pin) }
                    Button(sel.copyTitle, systemImage: "link") { onSelectionAction(.copyLinks) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                        .frame(width: d, height: d).contentShape(.rect)
                }
                .disabled(sel.isEmpty)
                .accessibilityLabel("More")
            }
            .foregroundStyle(style.colors.label)
            .padding(.horizontal, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
            .position(x: 20 + 70, y: y)
            Button { tabs.endSelecting() } label: {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: d, height: d).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(style.colors.accent).interactive(), in: .circle)
            .position(x: layout.size.width - 20 - d / 2, y: y)
            .accessibilityLabel("Done")
            Text(sel.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(style.colors.label)
                .padding(.horizontal, 12).frame(height: 28)
                .glassEffect(.regular, in: .capsule)
                .position(x: layout.size.width / 2, y: layout.top + 14)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
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
        // One glass container for the bar (see `topControls`).
        return GlassEffectContainer(spacing: 0) {
            ZStack(alignment: .topLeading) {
                // Glass ignores inherited opacity: out of the hierarchy while selecting.
                if !tabs.selecting {
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
                // Tabs QA #12: with terminals (+) is a menu, not New Tab itself.
                .accessibilityLabel(onNewTerminal == nil ? "New Tab" : "New")
                .accessibilityHint(onNewTerminal == nil ? "" : "Shows New Tab and New Terminal")
                }

                // One glass shape per control (two nested glass capsules
                // read as a double background).
                TabCountLabel(tabs: tabs)
                    .chromeFont(17, weight: .semibold)
                    .foregroundStyle(style.colors.label)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .glassEffect(.regular, in: .capsule)
                    .position(x: layout.size.width / 2, y: bar.midY)
                    // Safari swaps the count at once (no crossfade), even
                    // inside the reflow's animation.
                    .contentTransition(.identity)
                    .transaction { $0.animation = nil }

                if !tabs.selecting {
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
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        }
    }
}
#endif

#if os(iOS)
/// A card's long-press menu items.
enum CardMenuAction: Equatable, Sendable {
    case copyLink, pin, unpin, duplicate, select, close, closeOthers
}

/// Select Tabs bar actions.
enum SelectionAction: Equatable, Sendable {
    case close, pin, copyLinks
}

/// Safari's context-menu preview of a card: the card's page, scaled to
/// 195.7 / 177 of the card (round 22: the lifted preview is 195.7 x 275 for
/// a 177 x 249 card), with its corner scaled too and no title row.
struct CardMenuPreview: View {
    var item: TabItem
    var image: UIImage?
    var topColor: Color
    var startPage: Bool
    var tabs: [BrowserTab]
    var pageSize: CGSize
    var safeTop: CGFloat
    var card: CGSize
    var radius: CGFloat
    /// 1 for the card as it lifts (UIKit grows it to Safari's 195.7 x 275).
    var scale: CGFloat = 1

    var body: some View {
        let w = card.width * scale, h = card.height * scale
        TabCard(item: item, image: image, topColor: topColor, startPage: startPage, tabs: tabs, pageSize: pageSize,
                safeTop: safeTop, width: w, height: h, radius: radius * scale, showsClose: false,
                closeOpacity: 0, titleOpacity: 0, onClose: {})
            .frame(width: w, height: h, alignment: .top)
            .clipShape(.rect(cornerRadius: radius * scale, style: .continuous))
    }
}

/// Safari's pinned tab: a 30 pt capsule (round 22: 177 x 30, black fill,
/// globe, semibold title, a pin in a 22 pt circle on the right).
struct PinnedCard: View {
    var item: TabItem
    var width: CGFloat
    var height: CGFloat
    /// Select Tabs: whether it is selected; nil outside the mode.
    var selected: Bool?
    private let style = BrowserStyle.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.isTerminal ? "apple.terminal" : "globe").font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
            Text(item.title).chromeFont(15, weight: .semibold, cap: ChromeType.cardCap).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 4)
            ZStack {
                Circle().fill(Color.white.opacity(0.12)).frame(width: 22, height: 22)
                Image(systemName: selected == true ? "checkmark" : "pin.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.leading, 9).padding(.trailing, 4)
        .frame(width: width, height: height)
        .background(Color.black, in: .capsule)
        .overlay { if selected == true { Capsule().strokeBorder(style.colors.accent, lineWidth: 3).padding(-4) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), Pinned")
        .accessibilityAddTraits(.isButton)
    }
}

/// Select Tabs: a selected card gets an accent ring and a filled check;
/// the others an empty circle where the close button was.
struct SelectionMark: View {
    var selected: Bool
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    private let style = BrowserStyle.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if selected {
                RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                    .strokeBorder(style.colors.accent, lineWidth: 3)
                    .frame(width: width + 8, height: height + 8)
                    .offset(x: -4, y: -4)
            }
            Group {
                if selected {
                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                        .foregroundStyle(.white, style.colors.accent)
                } else {
                    Image(systemName: "circle").foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(.system(size: 22))
            .padding(4)
        }
        .frame(width: width, height: height, alignment: .topTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Reorders the grid while a card is dragged from its lifted preview: the
/// card moves into the slot under the finger (the others reflow), as in
/// Safari. Pinned slots are not drop targets.
struct CardReorderDrop: DropDelegate {
    let layout: OverviewLayout
    let ids: [String]
    let pinned: Int
    @Binding var dragging: String?
    let move: (String, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let key = dragging, let slot = layout.slot(at: info.location), slot >= pinned, slot < ids.count, ids[slot] != key {
            let m = BrowserStyle.shared.motion
            withAnimation(m.resolve(m.reflow)) { move(key, slot) }
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}
/// The bar's "N Tabs", apart from the grid's body: it follows the close's
/// own clock (`TabsModel.countHold`) without re-rendering the cards.
struct TabCountLabel: View {
    var tabs: TabsModel

    var body: some View {
        // Never "0 Tabs": closing the last tab opens a fresh one in the next
        // update, and Safari's count goes straight to 1.
        let count = tabs.countHold ?? max(1, tabs.items.count)
        Text(count == 1 ? "1 Tab" : "\(count) Tabs")
    }
}
#endif
