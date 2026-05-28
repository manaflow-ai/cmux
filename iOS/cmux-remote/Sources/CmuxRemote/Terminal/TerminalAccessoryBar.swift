import SwiftUI
import UIKit
import CmuxKit

/// Accessory toolbar above the iOS software keyboard. Auto-hides when a
/// hardware keyboard is attached. Renders sticky Ctrl/Alt/Shift, Esc, Tab,
/// arrows, function keys, and a special-character strip.
///
/// Mirrors the Blink/Prompt/Termius idiom verified in the in-repo terminal
/// UX research. Sized for one-handed thumb reach on iPhone in portrait.
struct TerminalAccessoryBar: View {
    @ObservedObject var modifiers: TerminalModifierState
    let onKey: (AccessoryKey) -> Void
    let onSpecialCharacter: (String) -> Void
    let onPasteRequest: () -> Void
    let onDismissKeyboard: () -> Void

    private let specialChars = ["|", "~", "/", "\\", "`", "-", "_", "=", "(", ")", "[", "]", "{", "}", "<", ">", "*", "&"]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                modifierCluster
                Divider().frame(height: 32)
                arrowCluster
                Divider().frame(height: 32)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Group {
                            BarKey(label: "F1") { onKey(.functionKey(1)) }
                            BarKey(label: "F2") { onKey(.functionKey(2)) }
                            BarKey(label: "F3") { onKey(.functionKey(3)) }
                            BarKey(label: "F4") { onKey(.functionKey(4)) }
                            BarKey(label: "Home") { onKey(.home) }
                            BarKey(label: "End") { onKey(.end) }
                            BarKey(label: "PgUp") { onKey(.pageUp) }
                            BarKey(label: "PgDn") { onKey(.pageDown) }
                        }
                        Divider().frame(height: 24)
                        ForEach(specialChars, id: \.self) { ch in
                            BarKey(label: ch) { onSpecialCharacter(ch) }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                Divider().frame(height: 32)
                rightCluster
            }
            .frame(height: 44)
            .background(.regularMaterial)
        }
    }

    private var modifierCluster: some View {
        HStack(spacing: 4) {
            ModifierKey(label: "ctrl", status: modifiers.ctrl) { modifiers.tap(.ctrl) }
            ModifierKey(label: "alt", status: modifiers.alt) { modifiers.tap(.alt) }
            BarKey(label: "esc") { onKey(.escape) }
            BarKey(label: "tab") { onKey(.tab) }
        }
        .padding(.leading, 6)
    }

    private var arrowCluster: some View {
        HStack(spacing: 4) {
            BarKey(systemImage: "arrow.left", accessibilityLabel: L10n.string("terminal.key.left", defaultValue: "Left arrow")) { onKey(.arrowLeft) }
            BarKey(systemImage: "arrow.down", accessibilityLabel: L10n.string("terminal.key.down", defaultValue: "Down arrow")) { onKey(.arrowDown) }
            BarKey(systemImage: "arrow.up", accessibilityLabel: L10n.string("terminal.key.up", defaultValue: "Up arrow")) { onKey(.arrowUp) }
            BarKey(systemImage: "arrow.right", accessibilityLabel: L10n.string("terminal.key.right", defaultValue: "Right arrow")) { onKey(.arrowRight) }
        }
    }

    private var rightCluster: some View {
        HStack(spacing: 4) {
            BarKey(systemImage: "doc.on.clipboard", accessibilityLabel: L10n.string("terminal.action.paste", defaultValue: "Paste"), action: onPasteRequest)
            BarKey(systemImage: "keyboard.chevron.compact.down", accessibilityLabel: L10n.string("terminal.action.dismiss_keyboard", defaultValue: "Dismiss keyboard"), action: onDismissKeyboard)
        }
        .padding(.trailing, 6)
    }
}

private struct BarKey: View {
    var label: String?
    var systemImage: String?
    var accessibilityLabel: String?
    var action: () -> Void

    init(label: String, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = nil
        self.accessibilityLabel = label
        self.action = action
    }
    init(systemImage: String, accessibilityLabel: String, action: @escaping () -> Void) {
        self.label = nil
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let label { Text(label).font(.system(size: 13, weight: .medium, design: .monospaced)) }
                else if let systemImage { Image(systemName: systemImage) }
            }
            .frame(minWidth: 32, minHeight: 30)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(accessibilityLabel ?? "")
    }
}

private struct ModifierKey: View {
    let label: String
    let status: TerminalModifierState.Status
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                if status == .locked {
                    Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 4)
                }
            }
            .frame(minWidth: 36, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .tint(color)
        .controlSize(.small)
    }

    private var color: Color {
        switch status {
        case .off: return .secondary
        case .armed: return .accentColor
        case .locked: return .orange
        }
    }
}

/// Helper that wraps the terminal view controller and adds the accessory
/// bar as its `inputAccessoryView`. SwiftTerm's `TerminalView` is a
/// `UIScrollView` and accepts an accessory view on the underlying
/// `UIResponder`. We bridge state changes through the modifier `ObservableObject`.
@MainActor
final class TerminalAccessoryHost {
    private weak var terminalContainer: UIView?
    private let modifiers: TerminalModifierState
    private let bar: UIHostingController<TerminalAccessoryBar>

    init(
        terminalContainer: UIView,
        modifiers: TerminalModifierState,
        onKey: @escaping (AccessoryKey) -> Void,
        onSpecialCharacter: @escaping (String) -> Void,
        onPasteRequest: @escaping () -> Void,
        onDismissKeyboard: @escaping () -> Void
    ) {
        self.terminalContainer = terminalContainer
        self.modifiers = modifiers
        let view = TerminalAccessoryBar(
            modifiers: modifiers,
            onKey: onKey,
            onSpecialCharacter: onSpecialCharacter,
            onPasteRequest: onPasteRequest,
            onDismissKeyboard: onDismissKeyboard
        )
        self.bar = UIHostingController(rootView: view)
        bar.view.backgroundColor = .clear
        bar.view.translatesAutoresizingMaskIntoConstraints = false
        let initialWidth = max(terminalContainer.bounds.width, 320)
        bar.view.frame = CGRect(x: 0, y: 0, width: initialWidth, height: 44)
        bar.view.autoresizingMask = [.flexibleWidth]
    }

    var inputAccessoryView: UIView { bar.view }
}
