#if os(iOS)
import CnxDesign
import SwiftUI

/// iMessage-style quote of the message an event answers: a small `bubble`
/// with a tail at its bottom-leading corner and a thin thread line curving
/// down into the reply. Tap toggles the full text.
struct QuoteBubble: View {
    let quote: FeedItem.Quote
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: quote.author == .you ? "arrowshape.turn.up.left.fill" : "sparkle")
                    .font(.system(size: 9, weight: .semibold))
                Text(quote.author == .you ? "You" : "Asked you")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.tertiary)
            .padding(.leading, 12)
            .padding(.bottom, 3)
            HStack(spacing: 0) {
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
                    BubbleWithTail().foregroundStyle(Color.cnxBubble)
                }
                Spacer(minLength: 28)
            }
            .padding(.bottom, 6)
            ThreadLine()
                .stroke(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 14, height: 12)
                .padding(.leading, 0)
                .padding(.top, -4)
        }
        .contentShape(.rect)
        .onTapGesture { withAnimation(.cnxSmooth) { expanded.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("In reply to: \(quote.text)"))
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
