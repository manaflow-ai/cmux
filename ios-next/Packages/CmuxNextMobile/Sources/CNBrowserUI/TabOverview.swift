#if os(iOS)
import CNCore
import SwiftUI
import UIKit

/// Card grid geometry (section 9.1): two columns of 177 x 249.3 cards with
/// 16 pt insets and gutter, a 23 pt title row and 16 pt between rows.
struct OverviewLayout {
    var size: CGSize
    var safeTop: CGFloat
    var safeBottom: CGFloat
    var count: Int

    private var m: BrowserMetrics { BrowserStyle.shared.metrics }
    var cardWidth: CGFloat { (size.width * m.cardWidthRatio).rounded(.toNearestOrEven) }
    var cardHeight: CGFloat { cardWidth * m.cardAspect }
    var pitch: CGFloat { cardHeight + m.titleRow + m.rowGap }
    var top: CGFloat { safeTop + 52 }
    /// Bottom bar: 48 pt controls whose bottom sits 38 pt above the screen bottom.
    var barRect: CGRect {
        let bottom = size.height - max(safeBottom, 20) - 4
        return CGRect(x: 0, y: bottom - m.control, width: size.width, height: m.control)
    }
    var bottomPadding: CGFloat { size.height - barRect.minY + 12 }
    var rows: Int { (count + 1) / 2 }
    var contentHeight: CGFloat { top + CGFloat(rows) * pitch - m.rowGap + bottomPadding }

    /// Card frame in content coordinates.
    func card(_ index: Int) -> CGRect {
        let col = index % 2, row = index / 2
        let x = col == 0 ? m.gridInset : size.width - m.gridInset - cardWidth
        return CGRect(x: x, y: top + CGFloat(row) * pitch, width: cardWidth, height: cardHeight)
    }

    var maxOffset: CGFloat { max(0, contentHeight - size.height) }

    /// Scroll offset that brings `index` fully into view above the bottom bar.
    func offset(revealing index: Int) -> CGFloat {
        let r = card(index)
        let visibleBottom = barRect.minY - 12
        let needed = r.maxY + m.titleRow - visibleBottom
        return min(maxOffset, max(0, needed))
    }
}

/// One tab card: snapshot with rounded corners, close button, title row.
struct TabCard: View {
    var tab: BrowserTab
    var image: UIImage?
    var startPage: Bool
    var width: CGFloat
    var height: CGFloat
    var showsClose: Bool
    var detailsOpacity: Double
    var onClose: () -> Void

    private let style = BrowserStyle.shared

    var body: some View {
        VStack(spacing: 0) {
            CardSnapshot(image: image, startPage: startPage)
                .frame(width: width, height: height)
                .clipShape(.rect(cornerRadius: style.metrics.cardRadius, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
                .overlay(alignment: .topTrailing) {
                    if showsClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(style.colors.secondaryLabel)
                                .frame(width: style.metrics.cardClose, height: style.metrics.cardClose)
                                .background(style.colors.cardCloseFill, in: .circle)
                                .padding(4)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .opacity(detailsOpacity)
                        .accessibilityLabel("Close \(tab.title)")
                    }
                }
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 14))
                    .foregroundStyle(style.colors.secondaryLabel)
                Text(startPage ? "Start Page" : (tab.title.isEmpty ? tab.displayHost : tab.title))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(style.colors.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: width, height: style.metrics.titleRow)
            .padding(.top, 2)
            .opacity(detailsOpacity)
        }
        .frame(width: width, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The top of a page drawn into a card: image fitted to the width, top aligned.
struct CardSnapshot: View {
    var image: UIImage?
    var startPage: Bool
    private let style = BrowserStyle.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                (startPage ? style.colors.startBackground : Color.white)
                if let image, !startPage {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: geo.size.width, height: geo.size.width * image.size.height / max(1, image.size.width))
                } else {
                    Image(systemName: "safari")
                        .font(.system(size: geo.size.width * 0.25, weight: .thin))
                        .foregroundStyle(style.colors.glyphDisabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
    }
}

/// Tab overview: blurred wallpaper, 2-column grid, top controls and the
/// bottom bar (+, "N Tabs", Done).
struct TabOverview: View {
    var model: BrowserModel
    var images: [String: UIImage]
    var layout: OverviewLayout
    /// 0 while the page is full screen, 1 with the grid at rest.
    var shown: Double
    var detailsOpacity: Double
    /// Card hidden while a zoom overlay stands in for it.
    var hiddenTabId: String?
    @Binding var scrollOffset: CGFloat
    @Binding var position: ScrollPosition
    var leadingItem: AnyView?
    var onSelect: (String) -> Void
    var onClose: (String) -> Void
    var onNewTab: () -> Void
    var onDone: () -> Void
    var onCloseAll: () -> Void

    private let style = BrowserStyle.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [style.colors.overviewTop, style.colors.overviewBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: layout.size.width, height: layout.contentHeight)
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                        let r = layout.card(index)
                        TabCard(tab: tab, image: images[tab.id], startPage: model.showsStartPage(tab.id),
                                width: r.width, height: r.height, showsClose: true,
                                detailsOpacity: detailsOpacity, onClose: { onClose(tab.id) })
                            .opacity(tab.id == hiddenTabId ? 0 : 1)
                            .contentShape(.rect)
                            .onTapGesture { onSelect(tab.id) }
                            .offset(x: r.minX, y: r.minY)
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }
                }
                .frame(width: layout.size.width, height: layout.contentHeight, alignment: .topLeading)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in scrollOffset = y }
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .scaleEffect(1.06 - 0.06 * shown)
            .blur(radius: 10 * (1 - shown))

            // Glass ignores inherited opacity; keep hidden controls out of
            // the hierarchy instead.
            if shown > 0 {
                topControls
                    .opacity(shown)
                bottomBar
                    .opacity(shown)
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
        let count = model.tabs.count
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Button(action: onNewTab) {
                    Image(systemName: "plus").font(.system(size: 22, weight: .regular))
                        .foregroundStyle(style.colors.label)
                        .frame(width: 48, height: 48).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .position(x: 38 + 24, y: bar.midY)
                .accessibilityLabel("New Tab")

                Text(count == 1 ? "1 Tab" : "\(count) Tabs")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(style.colors.label)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .glassEffect(.regular, in: .capsule)
                    .padding(4)
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
