#if os(iOS)
import CnxDesign
import SwiftUI
import UIKit

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
    /// The page as last seen (a tab coming back from the warm set, or a
    /// dropped link): shown dimmed instead of the skeleton, under the same
    /// label, so the user sees their terminal at once and that it is not live.
    let lastFrame: UIImage?
    /// Whether the glass label shows. A workspace tab says "Reattaching…"
    /// in its title pill instead (SPEC P5), so its page draws no caption.
    let showsLabel: Bool

    public init(state: TerminalConnectionState, topInset: CGFloat = 0, lastFrame: UIImage? = nil, showsLabel: Bool = true) {
        self.state = state
        self.topInset = topInset
        self.lastFrame = lastFrame
        self.showsLabel = showsLabel
    }

    /// Line widths of the skeleton, as fractions of the width: a prompt, some
    /// output, a prompt.
    private static let lines: [CGFloat] = [0.42, 0.78, 0.64, 0.86, 0.52, 0.7, 0.3]

    private var skeleton: some View {
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
    }

    public var body: some View {
        ZStack(alignment: .top) {
            if let lastFrame {
                GeometryReader { proxy in
                    Image(uiImage: lastFrame)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: proxy.size.width,
                               height: proxy.size.width * lastFrame.size.height / max(1, lastFrame.size.width))
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                        .clipped()
                        .opacity(0.55)
                }
                .accessibilityHidden(true)
            } else {
                skeleton
            }
            if showsLabel, let label = state.label {
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
