#if os(iOS)
import CNCore
import CNDesign
import SwiftUI
import UIKit

/// Type scale for the chat. Body follows the HIG 17 pt so replies read like
/// the iOS AI apps; secondary rows use 15 pt (subheadline).
enum AgentType {
    static let body = Font.body
    static let bodyLineSpacing: CGFloat = 5
    static let row = Font.subheadline
    static let mono = Font.system(.footnote, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
}

/// A band of the text color sweeping across a muted label ("Thinking",
/// a running tool). Static and muted under Reduce Motion.
struct Shimmer: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .foregroundStyle(.cn(\.textTertiary))
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0), .init(color: .cn(\.textPrimary), location: 0.5), .init(color: .clear, location: 1)],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.6 - geo.size.width * 0.3)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    phase = -0.4
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { phase = 1 }
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

/// Light haptics for send, approvals and disclosures.
@MainActor
enum Haptics {
    static func send() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

/// SF Symbol per tool kind (the Mac pane's glyphs).
func toolSymbol(_ kind: ToolKind) -> String {
    switch kind {
    case .read: "book"
    case .edit: "pencil"
    case .delete: "trash"
    case .search: "magnifyingglass"
    case .execute: "terminal"
    case .fetch: "globe"
    case .think: "brain"
    case .other: "wrench.and.screwdriver"
    }
}

/// A chevron that turns to point down when open.
struct DisclosureChevron: View {
    var open: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.cn(\.textTertiary))
            .rotationEffect(.degrees(open ? 90 : 0))
    }
}

/// A tappable full-width row label with a chevron (worked fold, tool group,
/// thought, tool with output).
struct DisclosureRow<Label: View>: View {
    var open: Bool
    var showsChevron = true
    var action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label
                if showsChevron { DisclosureChevron(open: open) }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Copy-to-clipboard button that confirms with a checkmark.
struct CopyButton: View {
    var text: String
    var label: String? = nil
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            Haptics.select()
            withAnimation(CNTheme.shared.motion.fade) { copied = true }
            Task {
                // A bounded, intentional confirmation delay (not synchronization).
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(CNTheme.shared.motion.fade) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                if let label { Text(copied ? "Copied" : label) }
            }
            .font(.footnote)
            .foregroundStyle(.cn(\.textSecondary))
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy")
    }
}

/// Harness avatar: the harness initial on its group hue.
struct HarnessBadge: View {
    var harnessId: String
    var name: String
    var size: CGFloat = 36

    var body: some View {
        let hue = Color(uiColor: CNTheme.shared.palette.groupHue(for: harnessId))
        Circle()
            .fill(hue.opacity(0.28))
            .overlay(Circle().strokeBorder(hue.opacity(0.5), lineWidth: 0.5))
            .overlay {
                Text(Self.initials(name))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.cn(\.textPrimary))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(name.prefix(1)).uppercased()
    }
}
#endif
