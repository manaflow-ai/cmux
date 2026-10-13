#if os(iOS)
import CnxDesign
import SwiftUI

/// iMessage-style quote of the message an event answers. Your own message
/// is outgoing: right-aligned, tail at its bottom-trailing corner, like a
/// sent bubble, with the agent's reply left-aligned below. A message the
/// agent asked you sits on the leading side with a thread line curving down
/// into the reply. Tap toggles the full text.
struct QuoteBubble: View {
    let quote: FeedItem.Quote
    @State private var expanded = false

    private var outgoing: Bool { quote.author == .you }

    var body: some View {
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: outgoing ? "arrowshape.turn.up.left.fill" : "sparkle")
                    .font(.system(size: 9, weight: .semibold))
                Text(outgoing ? "You" : "Asked you")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 3)
            HStack(spacing: 0) {
                if outgoing { Spacer(minLength: 28) }
                Text(quote.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        BubbleWithTail()
                            .foregroundStyle(Color.cnxBubble)
                            .scaleEffect(x: outgoing ? -1 : 1)
                    }
                if !outgoing { Spacer(minLength: 28) }
            }
            .padding(.bottom, outgoing ? 10 : 6)
            if !outgoing {
                ThreadLine()
                    .stroke(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 14, height: 12)
                    .padding(.top, -4)
            }
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
        .contentShape(.rect)
        .onTapGesture { withAnimation(.cnxSmooth) { expanded.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(outgoing ? "In reply to your message: \(quote.text)" : "In reply to: \(quote.text)"))
        .accessibilityAddTraits(.isButton)
    }
}

/// Rounded rect (radius 16) plus an iMessage tail at the bottom-leading corner, filled as one color.
struct BubbleWithTail: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
            BubbleTail()
                .frame(width: 22, height: 18)
                .offset(x: -6, y: 1)
        }
    }
}

/// The tail: leaves the bubble's side, sweeps out to a point below-left, and returns along the bottom edge.
struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: rect.minX + 8, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY),
                      control1: CGPoint(x: rect.minX + 8, y: rect.minY + h * 0.65),
                      control2: CGPoint(x: rect.minX + 4, y: rect.maxY - 2))
        path.addCurve(to: CGPoint(x: rect.minX + w, y: rect.maxY - 3),
                      control1: CGPoint(x: rect.minX + 7, y: rect.maxY + 0.5),
                      control2: CGPoint(x: rect.minX + w * 0.6, y: rect.maxY - 1))
        path.addLine(to: CGPoint(x: rect.minX + w, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The 12 pt connector from the quote down into the reply body.
struct ThreadLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.minX + 2, y: rect.maxY))
        return path
    }
}
#endif
