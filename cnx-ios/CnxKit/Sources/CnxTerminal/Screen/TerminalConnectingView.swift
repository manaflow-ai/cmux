#if os(iOS)
import CnxDesign
import SwiftUI

private let theme = CnxTheme.standard

/// What a terminal tab shows until the Mac's terminal is attached: a
/// skeleton of terminal lines with the shimmer (SPEC 7.1) and a glass
/// capsule with a spinner and the state ("Connecting to Aziz's Mac Studio…",
/// "Reattaching…"), styled like the connection banner (SPEC 7.4). Never
/// made-up output.
public struct TerminalConnectingView: View {
    let state: TerminalConnectionState
    /// The status bar area over the page.
    let topInset: CGFloat

    public init(state: TerminalConnectionState, topInset: CGFloat = 0) {
        self.state = state
        self.topInset = topInset
    }

    /// Line widths of the skeleton, as fractions of the width: a prompt, some
    /// output, a prompt.
    private static let lines: [CGFloat] = [0.42, 0.78, 0.64, 0.86, 0.52, 0.7, 0.3]

    public var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, fraction in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: (proxy.size.width - 24) * fraction, height: 12)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, topInset + 16)
                .cnxShimmer()
            }
            .accessibilityHidden(true)
            if let label = state.label {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: label)
                }
                .font(theme.type.meta.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassEffect(.regular, in: .capsule)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("terminal.connecting")
            }
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}
#endif
