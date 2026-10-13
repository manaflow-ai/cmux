#if os(iOS)
import CNCore
import SwiftUI
import UIKit

struct PageMenuItem: Identifiable {
    var id: String { title }
    var title: String
    var symbol: String
    var enabled = true
    var action: () -> Void
}

/// The ≡ page menu: one glass panel, 250 pt wide, left-aligned with the
/// capsule, that grows out of the menu button like a droplet (section 6.1).
struct PageMenu: View {
    var groups: [[PageMenuItem]]
    /// The ≡ button frame (start of the morph) and the capsule frame.
    var origin: CGRect
    var capsule: CGRect
    var topLimit: CGFloat
    var expanded: Bool
    /// Content fades in over 80-200 ms and unblurs over 260 ms, on its own clock.
    var contentVisible: Bool
    var onDismiss: () -> Void
    /// The shell's leading item (the drawer hamburger), shown as the first row.
    var shellItem: AnyView? = nil

    private let style = BrowserStyle.shared
    @State private var measured: CGFloat?

    private var contentHeight: CGFloat {
        if let measured { return measured }
        let rows = CGFloat(groups.reduce(0) { $0 + $1.count })
        return rows * style.metrics.menuRow + CGFloat(max(0, groups.count - 1)) * style.metrics.menuGroupGap + 20
    }

    var body: some View {
        let bottom = capsule.maxY - 1
        let height = min(contentHeight, bottom - topLimit)
        let full = CGRect(x: capsule.minX, y: bottom - height, width: style.metrics.menuWidth, height: height)
        let r = expanded ? full : origin
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(.rect)
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if let shellItem {
                        shellItem
                            .buttonStyle(ShellMenuRowButtonStyle(title: "Show Sidebar"))
                            .simultaneousGesture(TapGesture().onEnded { onDismiss() })
                        Rectangle().fill(style.colors.separator)
                            .frame(height: 0.5)
                            .padding(.leading, 27).padding(.trailing, 10)
                            .frame(height: style.metrics.menuGroupGap)
                    }
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                        if index > 0 {
                            Rectangle().fill(style.colors.separator)
                                .frame(height: 0.5)
                                .padding(.leading, 27).padding(.trailing, 10)
                                .frame(height: style.metrics.menuGroupGap)
                        }
                        ForEach(group) { item in row(item) }
                    }
                }
                .padding(.vertical, 10)
                .frame(width: style.metrics.menuWidth, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured = $0 }
            }
            .scrollDisabled(contentHeight <= height)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: style.metrics.menuWidth, height: height, alignment: .top)
            .opacity(contentVisible ? 1 : 0)
            .blur(radius: contentVisible ? 0 : 8)
            // The rows scale with the droplet (they are lensed, not clipped).
            .scaleEffect(x: r.width / full.width, y: r.height / full.height, anchor: .topLeading)
            .frame(width: r.width, height: r.height, alignment: .topLeading)
            .clipShape(DropletShape(progress: expanded ? 1 : 0, finalRadius: style.metrics.menuRadius))
            .glassEffect(.regular.interactive(), in: DropletShape(progress: expanded ? 1 : 0, finalRadius: style.metrics.menuRadius))
            .offset(x: r.minX, y: r.minY)
        }
    }

    @ViewBuilder private func row(_ item: PageMenuItem) -> some View {
        Button {
            item.action()
        } label: {
            HStack(spacing: 0) {
                Image(systemName: item.symbol)
                    .font(.system(size: 18))
                    .frame(width: 30)
                    .padding(.leading, 25)
                Text(item.title)
                    .font(.system(size: 17))
                    .padding(.leading, 10)
                    .lineLimit(2)
                Spacer(minLength: 12)
            }
            .foregroundStyle(item.enabled ? style.colors.label : style.colors.glyphDisabled)
            .padding(.vertical, 10)
            .frame(width: style.metrics.menuWidth, alignment: .leading)
            .frame(minHeight: style.metrics.menuRow)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
    }
}

/// Restyles the shell's hamburger button as a page-menu row: its glyph in
/// the icon column and a title, full-row hit area.
struct ShellMenuRowButtonStyle: ButtonStyle {
    var title: String
    private let style = BrowserStyle.shared

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            configuration.label
                .font(.system(size: 18))
                .frame(width: 30)
                .padding(.leading, 25)
            Text(title)
                .font(.system(size: 17))
                .padding(.leading, 10)
            Spacer(minLength: 12)
        }
        .foregroundStyle(style.colors.label)
        .padding(.vertical, 10)
        .frame(width: style.metrics.menuWidth, alignment: .leading)
        .frame(minHeight: style.metrics.menuRow)
        .contentShape(.rect)
        .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// The shell's leading item as a glass circle (tab overview top bar): the
/// whole circle is the hit area.
struct ShellCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat
    private let style = BrowserStyle.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(style.colors.label)
            .frame(width: diameter, height: diameter)
            .contentShape(.circle)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// Rounded rect that stays a capsule (radius = half the short side) while
/// the droplet grows and only settles to the panel radius near the end.
struct DropletShape: Shape {
    var progress: CGFloat
    var finalRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let capsule = min(rect.width, rect.height) / 2
        let t = max(0, min(1, (progress - 0.6) / 0.4))
        let radius = capsule + (min(finalRadius, capsule) - capsule) * t * t * (3 - 2 * t)
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }
}

/// Presents the system share sheet from the top view controller.
@MainActor
struct ShareSheetPresenter {
    func share(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
        }
        top.present(vc, animated: true)
    }
}
#endif
