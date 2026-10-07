import SwiftUI

/// SwiftUI wrapper of the discovery rings.
struct PairRadar: UIViewRepresentable {
    var isSearching: Bool

    func makeUIView(context: Context) -> PairRadarView { PairRadarView() }
    func updateUIView(_ uiView: PairRadarView, context: Context) { uiView.isSearching = isSearching }
}
