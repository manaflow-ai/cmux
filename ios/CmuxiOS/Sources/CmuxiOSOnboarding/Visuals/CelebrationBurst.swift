import SwiftUI

/// SwiftUI wrapper of the celebrate burst.
struct CelebrationBurst: UIViewRepresentable {
    func makeUIView(context: Context) -> CelebrationBurstView { CelebrationBurstView() }
    func updateUIView(_ uiView: CelebrationBurstView, context: Context) {}
}
