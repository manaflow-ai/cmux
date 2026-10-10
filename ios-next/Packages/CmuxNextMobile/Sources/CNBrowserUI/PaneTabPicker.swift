#if os(iOS)
import CNCore
import CNDesign
import SwiftUI
import UIKit

/// The pane's tabs as a horizontal paged list over the dimmed canvas.
struct PaneTabPicker: View {
    var tabsModel: TabsModel
    var state: PaneTabPickerState
    var shown: Double
    var size: CGSize
    var safeTop: CGFloat
    var onTapCard: (Int) -> Void
    var onDismiss: () -> Void
    var onDrag: (_ dx: CGFloat, _ predicted: CGFloat?, _ base: Int) -> Void

    @State private var dragBase: Int?
    private let style = BrowserStyle.shared

    var body: some View {
        let layout = PaneTabPickerLayout(size: size, safeTop: safeTop)
        let s = CGFloat(min(1, max(0, shown)))
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.22 * s)
                .contentShape(.rect)
                .onTapGesture(perform: onDismiss)
                .accessibilityLabel("Close tab list")
                .accessibilityAddTraits(.isButton)
            if !state.launched {
                ForEach(Array(state.tabs.enumerated()), id: \.element.id) { k, tab in
                    let r = layout.card(k, position: state.position, shown: s, pane: state.paneFrame)
                    let near = abs(CGFloat(k) - state.position) < 2.5
                    if near || k == state.startIndex {
                        card(tab, k: k, rect: r, s: s)
                    }
                }
                caption(layout: layout, s: s)
            }
        }
        .frame(width: size.width, height: size.height)
        .gesture(pagerDrag(layout), including: state.holding ? .subviews : .all)
    }

    private func card(_ tab: LayoutTab, k: Int, rect r: CGRect, s: CGFloat) -> some View {
        let item = tabsModel.item(for: tab)
        let isStart = k == state.startIndex
        let radius = 14 + 10 * s
        return TabItemThumbnail(tabs: tabsModel, item: item, pageSize: size, safeTop: safeTop)
            .frame(width: max(1, r.width), height: max(1, r.height))
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.18 * s), radius: 16, y: 6)
            .opacity(isStart ? 1 : Double(s))
            .contentShape(.rect(cornerRadius: radius))
            .onTapGesture { onTapCard(k) }
            .position(x: r.midX, y: r.midY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(k == state.index ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Opens this tab")
    }

    private func caption(layout: PaneTabPickerLayout, s: CGFloat) -> some View {
        let tab = state.tabs.indices.contains(state.index) ? state.tabs[state.index] : nil
        let item = tab.map(tabsModel.item(for:))
        return VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: item?.symbol ?? "square").font(.system(size: 14, weight: .semibold))
                Text(item?.title ?? "").font(.system(size: 17, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 4)
            .contentTransition(.opacity)
            .padding(.horizontal, 24)
            if state.tabs.count > 1 {
                HStack(spacing: 7) {
                    ForEach(state.tabs.indices, id: \.self) { i in
                        Circle().fill(.white.opacity(i == state.index ? 1 : 0.4)).frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .frame(width: size.width)
        .position(x: size.width / 2, y: layout.center.maxY + 40)
        .opacity(Double(s))
        .allowsHitTesting(false)
    }

    /// After a hold lifted without sliding: swipe the list.
    private func pagerDrag(_ layout: PaneTabPickerLayout) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                let base = dragBase ?? state.index
                dragBase = base
                onDrag(v.translation.width, nil, base)
            }
            .onEnded { v in
                onDrag(v.translation.width, v.predictedEndTranslation.width, dragBase ?? state.index)
                dragBase = nil
            }
    }
}
#endif
