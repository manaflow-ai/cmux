#if os(iOS)
import CnxArtifacts
import CnxDesign
import SwiftUI
import UIKit

/// An image opened full screen from the transcript: pinch or double-tap to zoom, swipe
/// down or Done to close, Share.
public struct ImageViewerItem: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let data: Data

    public init(id: String, name: String, data: Data) {
        self.id = id
        self.name = name
        self.data = data
    }
}

struct FullScreenImageViewer: View {
    let item: ImageViewerItem
    @Environment(\.dismiss) private var dismiss
    @State private var drag: CGFloat = 0

    var body: some View {
        let image = UIImage(data: item.data)
        NavigationStack {
            ZoomableImage(image: image)
                .offset(y: drag)
                .ignoresSafeArea(edges: .bottom)
                .gesture(DragGesture(minimumDistance: 20)
                    .onChanged { value in if value.translation.height > 0 { drag = value.translation.height } }
                    .onEnded { value in
                        if value.translation.height > 120 { dismiss() } else { withAnimation(.cnxSnap) { drag = 0 } }
                    })
                .background(Color.black.opacity(1 - min(drag / 400, 0.6)).ignoresSafeArea())
                .navigationTitle(item.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done", systemImage: "xmark") { dismiss() }
                    }
                    if let image {
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: Image(uiImage: image), preview: SharePreview(item.name, image: Image(uiImage: image))) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share")
                        }
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
