#if os(iOS)
import CNCore
import CNDesign
import SwiftUI
import UIKit

/// The Tabs screen's overview: the Mac's workspaces as regions on a canvas
/// that scrolls both ways, each pane a card showing its focused tab. Tap a
/// pane to open its tab; press and hold to pick another tab of the pane.
struct PaneCanvas: View {
    var tabs: TabsModel
    var geometry: PaneCanvasLayout
    var size: CGSize
    var safeTop: CGFloat
    /// The bottom controls' row (the tab grid's).
    var barRect: CGRect
    var shown: Double
    var detailsOpacity: Double
    /// Pane hidden while a zoom or the tab picker stands in for it.
    var hiddenPaneId: String?
    var interactive: Bool
    @Binding var position: ScrollPosition
    @Binding var scroll: CGPoint
    var leadingItem: AnyView?
    var onTap: (String) -> Void
    var onHold: (String, PaneHoldPhase) -> Void
    var onNewTab: () -> Void
    var onNewTerminal: () -> Void
    var onDone: () -> Void
    var onContentOrigin: (CGPoint) -> Void

    private let style = BrowserStyle.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [style.colors.overviewTop, style.colors.overviewBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: geometry.contentSize.width, height: geometry.contentSize.height)
                    ForEach(geometry.regions, id: \.workspaceId) { region in
                        Text(region.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(style.colors.secondaryLabel)
                            .lineLimit(1)
                            .frame(width: region.titleFrame.width, height: region.titleFrame.height, alignment: .leading)
                            .position(x: region.titleFrame.midX, y: region.titleFrame.midY)
                            .opacity(detailsOpacity)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(panes(of: region.workspaceId), id: \.id) { pane in
                            if let r = region.panes[pane.id] {
                                PaneCard(tabs: tabs, pane: pane, size: r.size, pageSize: size, safeTop: safeTop,
                                         detailsOpacity: detailsOpacity)
                                    .opacity(pane.id == hiddenPaneId ? 0 : 1)
                                    .contentShape(.rect(cornerRadius: 14))
                                    .onTapGesture { onTap(pane.id) }
                                    .gesture(PaneHoldGesture { onHold(pane.id, $0) })
                                    .position(x: r.midX, y: r.midY)
                            }
                        }
                    }
                }
                .frame(width: geometry.contentSize.width, height: geometry.contentSize.height, alignment: .topLeading)
                .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named(browserScreenSpace)).origin }) { onContentOrigin($0) }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGPoint.self, of: {
                CGPoint(x: $0.contentOffset.x + $0.contentInsets.leading, y: $0.contentOffset.y + $0.contentInsets.top)
            }) { _, p in scroll = p }
            .scrollDisabled(!interactive)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .scaleEffect(1.06 - 0.06 * shown)
            .blur(radius: 10 * (1 - shown))
            .allowsHitTesting(interactive)

            if shown > 0 {
                controls
                    .opacity(shown)
                    .allowsHitTesting(interactive)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func panes(of workspaceId: String) -> [LayoutPane] {
        tabs.layout?.workspaces.first { $0.id == workspaceId }?.panes ?? []
    }

    private var controls: some View {
        let bar = barRect
        let y = safeTop + 4 + style.metrics.overviewTopControl / 2
        return ZStack(alignment: .topLeading) {
            if let leadingItem {
                leadingItem
                    .buttonStyle(ShellCircleButtonStyle(diameter: style.metrics.overviewTopControl))
                    .glassEffect(.regular, in: .circle)
                    .position(x: 20 + 18, y: y)
            }
            Menu {
                Button("New Browser Tab", systemImage: "safari", action: onNewTab)
                Button("New Terminal", systemImage: "apple.terminal", action: onNewTerminal)
            } label: {
                Image(systemName: "plus").font(.system(size: 22, weight: .regular))
                    .foregroundStyle(style.colors.label)
                    .frame(width: 48, height: 48).contentShape(.circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .position(x: 38 + 24, y: bar.midY)
            .accessibilityLabel("New Tab")

            let count = tabs.layout?.workspaces.reduce(0) { $0 + $1.panes.count } ?? 0
            Text(count == 1 ? "1 Pane" : "\(count) Panes")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(style.colors.label)
                .padding(.horizontal, 22)
                .frame(height: 48)
                .glassEffect(.regular, in: .capsule)
                .position(x: size.width / 2, y: bar.midY)

            Button(action: onDone) {
                Image(systemName: "checkmark").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(style.colors.accent).interactive(), in: .circle)
            .position(x: size.width - 38 - 24, y: bar.midY)
            .accessibilityLabel("Done")
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// Press and hold (0.35 s, within 12 pt), then slide without lifting: a
/// UIKit long press, so moving before it fires leaves the touch to the
/// canvas's scroll view (a SwiftUI long-press-then-drag sequence held it).
struct PaneHoldGesture: UIGestureRecognizerRepresentable {
    var onPhase: (PaneHoldPhase) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0.35
        g.allowableMovement = 12
        g.cancelsTouchesInView = true
        return g
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        let x = context.converter.location(in: .named(browserScreenSpace)).x
        switch g.state {
        case .began:
            context.coordinator.startX = x
            onPhase(.began)
        case .changed:
            onPhase(.moved(x - context.coordinator.startX))
        case .ended, .cancelled, .failed:
            onPhase(.ended(x - context.coordinator.startX))
        default:
            break
        }
    }

    final class Coordinator {
        var startX: CGFloat = 0
    }
}

enum PaneHoldPhase: Equatable {
    case began
    /// Horizontal finger travel since the hold began (points).
    case moved(CGFloat)
    case ended(CGFloat)
}

/// A pane: its focused tab's live image (or snippet / placeholder), the
/// tab's title, and a count badge when the pane has several tabs.
struct PaneCard: View {
    var tabs: TabsModel
    var pane: LayoutPane
    var size: CGSize
    var pageSize: CGSize
    var safeTop: CGFloat
    var detailsOpacity: Double

    private let style = BrowserStyle.shared

    var body: some View {
        let tab = pane.focusedTab
        let item = tab.map(tabs.item(for:))
        ZStack(alignment: .bottomLeading) {
            if let item { TabItemThumbnail(tabs: tabs, item: item, pageSize: pageSize, safeTop: safeTop) }
            HStack(spacing: 5) {
                Image(systemName: item?.symbol ?? "square").font(.system(size: 11, weight: .semibold))
                Text(item?.title ?? "Empty pane").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(style.colors.label)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .glassEffect(.regular, in: .capsule)
            .padding(6)
            .opacity(detailsOpacity)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if pane.tabs.count > 1 {
                Text("\(pane.tabs.count)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(style.colors.label)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, 3)
                    .glassEffect(.regular, in: .capsule)
                    .padding(6)
                    .opacity(detailsOpacity)
                    .accessibilityLabel("\(pane.tabs.count) tabs")
            }
        }
        .overlay {
            if pane.active {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(style.colors.accent.opacity(0.7), lineWidth: 2)
            }
        }
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// What a tab looks like small: the page or terminal laid out at full page
/// size and scaled into the frame (top-aligned), an agent's latest message,
/// or a Mac-only placeholder.
struct TabItemThumbnail: View {
    var tabs: TabsModel
    var item: TabItem
    var pageSize: CGSize
    var safeTop: CGFloat

    private let style = BrowserStyle.shared

    var body: some View {
        switch item {
        case .browser(let t):
            ScaledPage(image: tabs.cardImage(t.id), topColor: Color(uiColor: tabs.browser.frames[t.id]?.topColor ?? .white),
                       startPage: tabs.showsStartPage(t.id), tabs: tabs.browser.tabs, pageSize: pageSize, safeTop: safeTop, strip: 0)
                .overlay {
                    // The Mac draws only the tab its pane shows: offer to switch it.
                    if tabs.hiddenOnMac(t.id) != nil {
                        ZStack {
                            Color.black.opacity(0.25)
                            ShowOnMacPill { tabs.showOnMac(t.id) }
                        }
                    }
                }
                .onAppear { tabs.requestThumbnail(t.id) }
        case .terminal(let t):
            ScaledPage(image: tabs.cardImage(item.id), topColor: .black, startPage: false, tabs: [], pageSize: pageSize,
                       safeTop: safeTop, strip: 0, terminal: true)
                .onAppear { tabs.showTerminalCards?([t.id]) }
        case .agent(_, let title, let preview):
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: "sparkles").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(preview ?? "No messages yet").font(.system(size: 12)).foregroundStyle(style.colors.secondaryLabel)
                    .lineLimit(8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(style.colors.label)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.cn(\.elevated))
        case .macOnly(let t):
            MacOnlyCard(tab: t, status: tabs.browserAccess)
        }
    }
}
#endif
