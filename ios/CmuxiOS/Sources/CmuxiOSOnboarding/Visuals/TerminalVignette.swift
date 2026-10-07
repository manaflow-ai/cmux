import SwiftUI

/// SwiftUI wrapper of the welcome vignette.
struct TerminalVignette: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalVignetteView { TerminalVignetteView() }
    func updateUIView(_ uiView: TerminalVignetteView, context: Context) {}
}
