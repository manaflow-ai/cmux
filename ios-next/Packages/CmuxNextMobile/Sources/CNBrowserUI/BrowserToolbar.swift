#if os(iOS)
import CNCore
import SwiftUI
import UIKit

/// Frames of the three glass shapes for the current chrome state, in screen
/// points (section 2.1, 3 and 5.1 of the Safari spec).
struct ToolbarLayout {
    var back: CGRect
    var capsule: CGRect
    var right: CGRect

    static func make(size: CGSize, safeBottom: CGFloat, keyboard: CGFloat, bar: BrowserChromeState.Bar, editing: Bool,
                     splitBack: Bool, labelWidth: CGFloat) -> ToolbarLayout {
        let m = BrowserStyle.shared.metrics
        let w = size.width
        let bottom = size.height - max(safeBottom, 20)
        let backW = m.control + (splitBack ? m.forwardExtra : 0)
        let barY = bottom - m.control
        let back = CGRect(x: m.sideInset, y: barY, width: backW, height: m.control)
        let tabs = CGRect(x: w - m.sideInset - m.control, y: barY, width: m.control, height: m.control)
        if editing {
            if keyboard > 0 {
                let y = size.height - keyboard - m.editInset - m.control
                let close = CGRect(x: w - m.editInset - m.control, y: y, width: m.control, height: m.control)
                let field = CGRect(x: m.editInset, y: y, width: close.minX - m.gap - m.editInset, height: m.control)
                return ToolbarLayout(back: back.offsetBy(dx: 0, dy: y - barY), capsule: field, right: close)
            }
            let field = CGRect(x: m.sideInset, y: barY, width: tabs.minX - m.gap - m.sideInset, height: m.control)
            return ToolbarLayout(back: back, capsule: field, right: tabs)
        }
        let capsule = CGRect(x: back.maxX + m.gap, y: barY, width: tabs.minX - m.gap - back.maxX - m.gap, height: m.control)
        if bar == .collapsed {
            let pillW = labelWidth * m.collapsedScale + 2 * m.pillPadding
            let pill = CGRect(x: (w - pillW) / 2, y: size.height - m.pillBottom - m.pillHeight, width: pillW, height: m.pillHeight)
            // Side circles travel inward with the pill edges while fading.
            let b = CGRect(x: pill.minX - m.gap - back.width, y: pill.midY - m.control / 2, width: back.width, height: m.control)
            let t = CGRect(x: pill.maxX + m.gap, y: pill.midY - m.control / 2, width: m.control, height: m.control)
            return ToolbarLayout(back: b, capsule: pill, right: t)
        }
        return ToolbarLayout(back: back, capsule: capsule, right: tabs)
    }
}

/// Safari's floating bottom toolbar: back circle (split back/forward when
/// there is forward history), address capsule, tabs circle. Collapses to the
/// mini URL pill, and morphs into the address field while editing.
struct BrowserToolbar: View {
    @Bindable var chrome: BrowserChromeState
    var tab: BrowserTab?
    var showsStartPage: Bool
    var size: CGSize
    var safeBottom: CGFloat
    var keyboard: CGFloat
    var onBack: () -> Void
    var onForward: () -> Void
    var onReload: () -> Void
    var onMenu: () -> Void
    var onTabs: () -> Void
    var onBeginEditing: () -> Void
    var onEndEditing: () -> Void
    var onGo: (String) -> Void
    var onSwipeChanged: (CGFloat) -> Void
    var onSwipeEnded: (CGFloat, CGFloat) -> Void

    @State private var labelWidth: CGFloat = 69
    @State private var progressShown: CGFloat = 0
    @State private var progressOpacity: Double = 0
    @Environment(\.colorScheme) private var scheme

    private let style = BrowserStyle.shared

    private var collapsed: Bool { chrome.bar == .collapsed && !chrome.editing }
    private var splitBack: Bool { tab?.canGoForward == true }

    var body: some View {
        let layout = ToolbarLayout.make(size: size, safeBottom: safeBottom, keyboard: keyboard, bar: chrome.bar,
                                        editing: chrome.editing, splitBack: splitBack, labelWidth: labelWidth)
        let sideOpacity: Double = chrome.sidesVisible && !chrome.editing ? 1 : 0
        // Separate glass shapes (no container): a container renders its
        // shapes together and ignores per-shape opacity, which the side
        // circles need for Safari's 80 ms fade while they slide inward.
        ZStack(alignment: .topLeading) {
            backButton(layout.back)
                .scaleEffect(collapsed ? 0.8 : 1)
                .opacity(sideOpacity)
                .position(x: layout.back.midX, y: layout.back.midY)
                .allowsHitTesting(sideOpacity > 0)
                .accessibilityHidden(sideOpacity == 0)
            capsule(layout.capsule)
                .position(x: layout.capsule.midX, y: layout.capsule.midY)
            rightButton(layout.right)
                .scaleEffect(collapsed ? 0.8 : 1)
                .opacity(chrome.editing ? 1 : sideOpacity)
                .position(x: layout.right.midX, y: layout.right.midY)
                .allowsHitTesting(chrome.editing || sideOpacity > 0)
                .accessibilityHidden(!chrome.editing && sideOpacity == 0)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(alignment: .topLeading) {
            // Width of the host label at 17 pt; the pill hugs it.
            Text(labelText).font(.system(size: style.metrics.urlFont, weight: .medium)).fixedSize().hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { labelWidth = $0 }
        }
        .onChange(of: tab?.loading ?? false, initial: true) { _, loading in updateProgress(loading: loading) }
        .onChange(of: tab?.progress ?? 1) { _, _ in updateProgress(loading: tab?.loading ?? false) }
    }

    private var labelText: String {
        guard let tab, !showsStartPage else { return "Search or enter website" }
        return tab.searchQuery ?? tab.displayHost
    }

    // MARK: Back / forward

    @ViewBuilder private func backButton(_ r: CGRect) -> some View {
        let canBack = tab?.canGoBack == true
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .medium))
                    .frame(width: splitBack ? r.width / 2 : r.width, height: r.height)
                    .contentShape(.rect)
            }
            .disabled(!canBack)
            .foregroundStyle(canBack ? style.colors.label : style.colors.glyphDisabled)
            .accessibilityLabel("Back")
            if splitBack {
                Button(action: onForward) {
                    Image(systemName: "chevron.right").font(.system(size: 19, weight: .medium))
                        .frame(width: r.width / 2, height: r.height)
                        .contentShape(.rect)
                }
                .foregroundStyle(style.colors.label)
                .accessibilityLabel("Forward")
            }
        }
        .buttonStyle(.plain)
        .opacity(chrome.menuOpen ? 0.3 : 1)
        .frame(width: r.width, height: r.height)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // MARK: Tabs / close

    @ViewBuilder private func rightButton(_ r: CGRect) -> some View {
        Button {
            if chrome.editing { onEndEditing() } else { onTabs() }
        } label: {
            ZStack {
                Image(systemName: "square.on.square").font(.system(size: 22.2, weight: .regular))
                    .opacity(chrome.editing ? 0 : 1)
                    .accessibilityHidden(chrome.editing)
                Image(systemName: "xmark").font(.system(size: 19, weight: .regular))
                    .opacity(chrome.editing ? 1 : 0)
                    .accessibilityHidden(!chrome.editing)
            }
            .foregroundStyle(style.colors.label)
            .opacity(chrome.menuOpen ? 0.3 : 1)
            .frame(width: r.width, height: r.height)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .frame(width: r.width, height: r.height)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(chrome.editing ? "Cancel" : "Tabs")
    }

    // MARK: Capsule

    @ViewBuilder private func capsule(_ r: CGRect) -> some View {
        let glyphOpacity: Double = (collapsed || chrome.editing ? 0 : 1) * (chrome.menuOpen ? 0.3 : 1)
        ZStack {
            // Leading page-menu slot (48 pt).
            Button(action: onMenu) {
                PageMenuGlyph()
                    .fill(style.colors.label)
                    .frame(width: 16.3, height: 12.3)
                    .offset(x: 0.7)
                    .frame(width: style.metrics.control, height: style.metrics.control)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(style.colors.label)
            .opacity(showsStartPage ? 0 : glyphOpacity)
            .allowsHitTesting(!collapsed && !chrome.editing && !showsStartPage)
            .accessibilityHidden(collapsed || chrome.editing || showsStartPage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Page Menu")

            if !chrome.editing {
                label(r)
            } else {
                AddressField(text: $chrome.editText, onGo: onGo)
                    .padding(.leading, 12)
                    .padding(.trailing, 44)
                    .frame(width: r.width, height: r.height)
                    .transition(.opacity)
                if !chrome.editText.isEmpty {
                    Button { chrome.editText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                            .foregroundStyle(style.colors.label)
                            .frame(width: 44, height: 48).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("Clear text")
                }
            }

            // Trailing reload / stop.
            Button(action: onReload) {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(tab?.loading == true ? 0 : 1)
                        .accessibilityHidden(tab?.loading == true)
                    Image(systemName: "xmark").opacity(tab?.loading == true ? 1 : 0)
                        .accessibilityHidden(tab?.loading != true)
                }
                .offset(y: -1)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: style.metrics.control)
                .contentShape(.rect)
                .animation(.easeInOut(duration: 0.15), value: tab?.loading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(style.colors.label)
            .opacity(showsStartPage ? 0 : glyphOpacity)
            .allowsHitTesting(!collapsed && !chrome.editing && !showsStartPage)
            .accessibilityHidden(collapsed || chrome.editing || showsStartPage)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(tab?.loading == true ? "Stop" : "Reload")
        }
        .frame(width: r.width, height: r.height)
        .overlay(alignment: .bottomLeading) {
            Rectangle().fill(style.colors.accent)
                .frame(width: r.width * progressShown, height: style.metrics.progressHeight)
                .opacity(chrome.editing ? 0 : progressOpacity)
        }
        .clipShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(.capsule)
        .simultaneousGesture(swipe, including: chrome.editing || collapsed ? .subviews : .all)
        .onTapGesture { if collapsed { chrome.expand(tap: true) } }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func label(_ r: CGRect) -> some View {
        // The start page has no menu glyph, so the placeholder may use the leading slot.
        let maxW = max(40, r.width - (showsStartPage ? style.metrics.control + 24 : 2 * style.metrics.control + 8))
        Button {
            if collapsed { chrome.expand(tap: true) } else { onBeginEditing() }
        } label: {
            HStack(spacing: 5) {
                if showsStartPage || tab?.searchQuery != nil {
                    Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
                }
                Text(labelText)
                    .font(.system(size: style.metrics.urlFont, weight: showsStartPage ? .regular : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(showsStartPage ? style.colors.secondaryLabel : style.colors.label)
            .frame(maxWidth: collapsed ? nil : maxW)
            // The label rides with its page during a toolbar swipe.
            .offset(x: chrome.swiping ? chrome.swipeOffset : 0)
            .opacity(chrome.swiping ? 1 - min(1, abs(chrome.swipeOffset) / (size.width * 0.5)) : 1)
            .fixedSize(horizontal: collapsed, vertical: false)
            .scaleEffect(collapsed ? style.metrics.collapsedScale : 1)
            // Expanded, the label owns only the middle; the 48 pt slots
            // at either end belong to the menu and reload buttons.
            .frame(width: collapsed ? r.width : max(0, r.width - (showsStartPage ? style.metrics.control : 2 * style.metrics.control)), height: r.height)
            .contentShape(.rect)
        }
        .buttonStyle(GlassContentButtonStyle())
        .accessibilityLabel(collapsed ? "Show toolbar, \(labelText)" : "Address, \(labelText)")
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { v in
                guard !chrome.editing, !collapsed, abs(v.translation.width) > abs(v.translation.height) || chrome.swiping else { return }
                onSwipeChanged(v.translation.width)
            }
            .onEnded { v in
                guard chrome.swiping else { return }
                onSwipeEnded(v.translation.width, v.predictedEndTranslation.width)
            }
    }

    // MARK: Progress

    private func updateProgress(loading: Bool) {
        if loading {
            let p = max(0.03, CGFloat(tab?.progress ?? 0))
            if progressOpacity == 0 {
                progressShown = 0
                progressOpacity = 1
                withAnimation(.easeOut(duration: 0.25)) { progressShown = p }
            } else {
                withAnimation(.easeOut(duration: 0.25)) { progressShown = max(progressShown, p) }
            }
        } else if progressOpacity > 0 {
            withAnimation(.easeOut(duration: 0.2)) { progressShown = 1 } completion: {
                withAnimation(.easeOut(duration: 0.25)) { progressOpacity = 0 }
            }
        }
    }
}

/// Glass buttons highlight through the interactive glass itself; the
/// label must not dim on press (it would flash during the pill expand).
struct GlassContentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// Safari's page-menu glyph: three left-aligned rounded lines, the last
/// one shorter (16.3 x 12.3 pt, 1.8 pt strokes on a 5.25 pt pitch).
struct PageMenuGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let t: CGFloat = 1.8
        let pitch = (rect.height - t) / 2
        var p = Path()
        for (i, frac) in [1.0, 1.0, 0.675].enumerated() {
            p.addRoundedRect(in: CGRect(x: rect.minX, y: rect.minY + CGFloat(i) * pitch, width: rect.width * frac, height: t),
                             cornerSize: CGSize(width: t / 2, height: t / 2))
        }
        return p
    }
}

/// The address field: full URL selected on focus, Go key navigates.
struct AddressField: UIViewRepresentable {
    @Binding var text: String
    var onGo: (String) -> Void

    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.font = .systemFont(ofSize: 17)
        f.keyboardType = .webSearch
        f.returnKeyType = .go
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.clearButtonMode = .never
        f.textContentType = .URL
        f.placeholder = "Search or enter website"
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        f.text = text
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        DispatchQueue.main.async {
            f.becomeFirstResponder()
            f.selectAll(nil)
        }
        return f
    }

    func updateUIView(_ f: UITextField, context: Context) {
        context.coordinator.parent = self
        // Only push external changes (clear button); echoing our own edits
        // back can drop keystrokes that arrived in between.
        if text != context.coordinator.lastEmitted, f.text != text {
            f.text = text
            context.coordinator.lastEmitted = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressField
        var lastEmitted: String
        init(parent: AddressField) { self.parent = parent; lastEmitted = parent.text }

        @objc func changed(_ f: UITextField) {
            lastEmitted = f.text ?? ""
            parent.text = lastEmitted
        }

        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            parent.onGo(f.text ?? "")
            return false
        }
    }
}
#endif
