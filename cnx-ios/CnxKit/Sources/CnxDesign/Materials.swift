#if os(iOS)
import SwiftUI

private let theme = CnxTheme.standard

extension View {
    /// Glass circle for floating controls outside toolbars (SPEC 2.4).
    public func cnxGlassCircle(interactive: Bool = true) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: .circle)
    }

    /// Glass capsule for banners, toasts and secondary CTAs.
    public func cnxGlassCapsule(interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
    }

    /// The composer card: glass, radius 24, with a 1 pt `separator` stroke under
    /// Increase Contrast.
    public func cnxComposerGlass() -> some View {
        modifier(ComposerGlass())
    }

    /// An inset input field background: `surfaceRaised`, radius 14, 52 tall.
    public func cnxInputField() -> some View {
        padding(.horizontal, 16)
            .frame(height: theme.metrics.inputHeight)
            .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: theme.metrics.inputRadius, style: .continuous))
    }
}

private struct ComposerGlass: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.metrics.composerRadius, style: .continuous)
        content
            .glassEffect(.regular, in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(theme.colors.separator, lineWidth: 1)
                }
            }
    }
}

/// Code entry boxes driven by one hidden `TextField` (SPEC 5.4, 5.6). Six digits
/// for email codes; `groups: [4, 4]` with a dash for Mac pairing.
public struct CodeBoxes: View {
    @Binding var text: String
    let groups: [Int]
    let allowed: CharacterSet
    let contentType: UITextContentType?
    let keyboard: UIKeyboardType
    var boxSize: CGSize
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, groups: [Int] = [6], allowed: CharacterSet = .decimalDigits, contentType: UITextContentType? = .oneTimeCode, keyboard: UIKeyboardType = .numberPad, boxSize: CGSize = CnxTheme.standard.metrics.codeBoxSize) {
        _text = text
        self.groups = groups
        self.allowed = allowed
        self.contentType = contentType
        self.keyboard = keyboard
        self.boxSize = boxSize
    }

    private var length: Int { groups.reduce(0, +) }

    public var body: some View {
        ZStack {
            TextField("", text: Binding(get: { text }, set: { newValue in
                let filtered = String(newValue.uppercased().unicodeScalars.filter { allowed.contains($0) }.map(Character.init)).prefix(length)
                text = String(filtered)
            }))
            .textContentType(contentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .focused($isFocused)
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .accessibilityLabel(Text("Code"))

            HStack(spacing: theme.metrics.codeBoxGap) {
                ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, count in
                    if groupIndex > 0 {
                        Text(verbatim: "-").font(theme.type.body).foregroundStyle(theme.colors.label3)
                    }
                    let start = groups.prefix(groupIndex).reduce(0, +)
                    ForEach(start..<(start + count), id: \.self) { index in
                        box(at: index)
                    }
                }
            }
            .contentShape(.rect)
            .onTapGesture { isFocused = true }
            .accessibilityHidden(true)
        }
        .onAppear { isFocused = true }
    }

    private func box(at index: Int) -> some View {
        let characters = Array(text)
        let character = index < characters.count ? String(characters[index]) : ""
        let isCurrent = isFocused && index == min(characters.count, length - 1)
        return Text(character)
            .font(theme.type.codeDigit)
            .foregroundStyle(theme.colors.label)
            .frame(width: boxSize.width, height: boxSize.height)
            .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: theme.metrics.codeBoxRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.codeBoxRadius, style: .continuous)
                    .strokeBorder(theme.colors.label, lineWidth: isCurrent ? 2 : 0)
            }
            .animation(theme.motion.snap.animation, value: isCurrent)
    }
}
#endif
