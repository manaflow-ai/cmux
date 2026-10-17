import SwiftUI

/// Fades newly streamed characters in from transparent, so a growing reply
/// reads like ChatGPT's (`.easeOut(0.3)` reveal, a soft gradient over the
/// last few characters) instead of popping in by chunks.
struct StreamingReveal: ViewModifier {
    let length: Int
    @State private var revealed: Double = 0

    func body(content: Content) -> some View {
        content
            .textRenderer(FadeTailRenderer(revealed: revealed))
            .onAppear { revealed = Double(length) }
            .onChange(of: length) { old, new in
                if new < old {
                    revealed = Double(new)
                } else {
                    withAnimation(.easeOut(duration: 0.3)) { revealed = Double(new) }
                }
            }
    }
}

struct FadeTailRenderer: TextRenderer, Animatable {
    var revealed: Double
    /// How many glyphs the gradient spans.
    var fadeWidth: Double = 14

    var animatableData: Double {
        get { revealed }
        set { revealed = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0.0
        for line in layout {
            for run in line {
                for slice in run {
                    let opacity = max(0, min(1, (revealed - index) / fadeWidth + 0.5))
                    if opacity >= 1 {
                        context.draw(slice)
                    } else if opacity > 0 {
                        var copy = context
                        copy.opacity = opacity
                        copy.draw(slice)
                    }
                    index += 1
                }
            }
        }
    }
}
