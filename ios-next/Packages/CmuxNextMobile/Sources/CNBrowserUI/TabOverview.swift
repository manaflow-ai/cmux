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
    var onClose: () -> Void

    private let style = BrowserStyle.shared

    var body: some View {
        VStack(spacing: 0) {
            ScaledPage(image: image, topColor: topColor, startPage: startPage, tabs: tabs, pageSize: pageSize,
                       safeTop: safeTop, strip: 0, terminal: item.isTerminal)
                .frame(width: width, height: height)
                .clipShape(.rect(cornerRadius: radius, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The card's close button: a 22 pt circle with a light 9.5 pt cross,
/// 4 pt from the card's top and trailing edges (measured). The zoom draws
/// the same glyph on the moving card.
struct CardCloseGlyph: View {
    private let style = BrowserStyle.shared
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 12, weight: .medium))
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
    var images: [String: UIImage]
    var layout: OverviewLayout
    /// 0 while the page is full screen, 1 with the grid at rest.
    var shown: Double
    var chrome: CardChrome
    /// Card hidden while a zoom overlay stands in for it.
    var hiddenTabId: String?
    /// Cards take taps and pinches (the grid is settled).
    var gridInteractive: Bool
    /// The bottom bar takes taps (settled, or a zoom heading here: Done reverses it).
    var controlsInteractive: Bool
    @Binding var scrollOffset: CGFloat
    @Binding var position: ScrollPosition
    var leadingItem: AnyView?
    var onSelect: (String) -> Void
    var onClose: (String) -> Void
    var onNewTab: () -> Void
    /// Set when the grid also holds terminals: (+) offers both.
    var onNewTerminal: (() -> Void)?
    var onDone: () -> Void
    var onCloseAll: () -> Void
    /// A tab being created with (+): its start-page card is already in the
    /// grid (at index tabs.count) so the zoom can land on its real frame.
    var placeholderId: String?
    var placeholderTerminal = false
    /// Origin of the grid's scroll content in the screen's coordinate space
    /// (moves with the scroll offset). A card's screen frame is its content
    /// frame (`OverviewLayout.card`) offset by it.
    var onContentOrigin: (CGPoint) -> Void = { _ in }

    private let style = BrowserStyle.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [style.colors.overviewTop, style.colors.overviewBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: layout.size.width, height: layout.contentHeight)
                    ForEach(Array(tabs.items.enumerated()), id: \.element.id) { index, tab in
                        let r = layout.card(index)
                        TabCard(item: tab, image: tab.isTerminal ? (tabs.cardImage(tab.id) ?? images[tab.id]) : (images[tab.id] ?? tabs.cardImage(tab.id)),
                                topColor: Color(uiColor: tabs.browser.frames[tab.id]?.topColor ?? .white),
                                startPage: tabs.showsStartPage(tab.id), tabs: tabs.browser.tabs, pageSize: layout.size,
                                safeTop: layout.safeTop, width: r.width, height: r.height, radius: layout.cardRadius, showsClose: true,
                                closeOpacity: chrome.closeOpacity, titleOpacity: chrome.titleOpacity,
                                titleOffset: chrome.titleOffset, snapshotHidden: tab.id == hiddenTabId, onClose: { onClose(tab.id) })
                            .contentShape(.rect)
                            .onTapGesture { onSelect(tab.id) }
                            .offset(x: r.minX, y: r.minY)
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.9))))
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
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: layout.size.width, height: layout.contentHeight, alignment: .topLeading)
                .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named(browserScreenSpace)).origin }) { onContentOrigin($0) }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in scrollOffset = y }
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .scaleEffect(1.06 - 0.06 * shown)
            .blur(radius: 10 * (1 - shown))
            .allowsHitTesting(gridInteractive)

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

    private var topControls: some View {
        let y = layout.safeTop + 4 + style.metrics.overviewTopControl / 2
        return ZStack(alignment: .topLeading) {
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

    private var bottomBar: some View {
        let bar = layout.barRect
        let count = tabs.items.count
        return ZStack(alignment: .topLeading) {
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
                    .contentTransition(.numericText())
                    .animation(.default, value: count)

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
