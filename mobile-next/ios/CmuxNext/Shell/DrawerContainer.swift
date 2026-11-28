import SwiftUI

/// ChatGPT-style side drawer: the main screen slides right to reveal the
/// sidebar (both move together, no parallax) and dims ~11%; it follows the
/// finger and settles with a spring that carries the release velocity.
struct DrawerContainer<Drawer: View, Content: View>: View {
    @Binding var isOpen: Bool
    var gestureEnabled: Bool
    /// When set, a closed drawer only opens from drags that start this close
    /// to the left edge (screens whose rows have their own swipe actions).
    var edgeWidth: CGFloat? = nil
    @ViewBuilder var drawer: () -> Drawer
    @ViewBuilder var content: () -> Content

    @State private var dragOffset: CGFloat?
    @State private var dragging = false
    @Environment(\.colorScheme) private var colorScheme

    /// Measured from ChatGPT (docs/ANIMATION-REFERENCE.md): ~280 ms, no overshoot.
    static var settle: Animation { .spring(response: 0.25, dampingFraction: 1.0) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 64
            let offset = dragOffset ?? (isOpen ? width : 0)
            let progress = max(0, min(1, offset / width))

            ZStack(alignment: .leading) {
                drawer()
                    .frame(width: width)
                    .offset(x: offset - width)
                    .accessibilityHidden(!isOpen)

                content()
                    .frame(width: geometry.size.width)
                    .allowsHitTesting(!isOpen && dragOffset == nil)
                    .overlay {
                        Color.black
                            .opacity((colorScheme == .dark ? 0.3 : 0.11) * progress)
                            .ignoresSafeArea()
                            .allowsHitTesting(progress > 0.01)
                            .onTapGesture { withAnimation(Self.settle) { isOpen = false } }
                            .accessibilityHidden(true)
                    }
                    .offset(x: offset)
            }
            .simultaneousGesture(dragGesture(width: width), including: gestureEnabled || isOpen ? .all : .subviews)
            .onChange(of: isOpen) { _, _ in
                if dragOffset == nil { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6) }
            }
            .animation(dragOffset == nil ? Self.settle : nil, value: isOpen)
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if !dragging {
                    // Claim only clearly horizontal drags in the opening direction.
                    guard abs(dx) > abs(dy) * 1.4 else { return }
                    if !isOpen, let edgeWidth, value.startLocation.x > edgeWidth { return }
                    if !isOpen && dx < 0 { return }
                    if isOpen && dx > 0 { return }
                    dragging = true
                }
                let base: CGFloat = isOpen ? width : 0
                var next = base + dx
                if next > width { next = width + (next - width) * 0.15 }
                dragOffset = max(0, next)
            }
            .onEnded { value in
                guard dragging else { return }
                dragging = false
                let base: CGFloat = isOpen ? width : 0
                let projected = base + value.predictedEndTranslation.width
                let open = projected > width / 2
                let distance = abs((open ? width : 0) - (dragOffset ?? base))
                let velocity = abs(value.velocity.width)
                let response = max(0.18, min(0.3, 0.25 - Double(velocity) / 16000 + Double(distance) / 6000))
                withAnimation(.spring(response: response, dampingFraction: 1.0)) {
                    isOpen = open
                    dragOffset = nil
                }
            }
    }
}
