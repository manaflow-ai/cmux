import PhotosUI
import SwiftUI

/// A photo attached to an agent prompt, downscaled and JPEG-encoded for the
/// ACP `image` content block.
struct ComposerImage: Identifiable, Equatable {
    let id = UUID()
    let jpeg: Data
    let thumbnail: UIImage

    /// Longest side capped at 1600 px: enough for an agent to read a
    /// screenshot, small enough for the data channel.
    static func make(from data: Data) -> ComposerImage? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1600 / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        let thumb = resized.preparingThumbnail(of: CGSize(width: 160, height: 160 * size.height / max(size.width, 1))) ?? resized
        return ComposerImage(jpeg: jpeg, thumbnail: thumb)
    }

    var block: [String: String] {
        ["type": "image", "mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]
    }
}

/// The "+" button: picks photos and appends them as attachments.
struct AttachButton: View {
    @Binding var attachments: [ComposerImage]
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $selection, maxSelectionCount: max(1, 4 - attachments.count), matching: .images) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: .circle)
        }
        .tint(.secondary)
        .accessibilityLabel("Attach photos")
        .accessibilityIdentifier("agent.attach")
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items where attachments.count < 4 {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = ComposerImage.make(from: data) {
                        attachments.append(image)
                    }
                }
                selection = []
            }
        }
    }
}

/// Thumbnails of attached photos above the prompt, each removable.
struct AttachmentStrip: View {
    @Binding var attachments: [ComposerImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    Image(uiImage: attachment.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                withAnimation(.snappy) { attachments.removeAll { $0.id == attachment.id } }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .font(.system(size: 18))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                            .accessibilityLabel("Remove photo")
                        }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 6)
        }
    }
}

/// Photos the user sent, right-aligned above their message like ChatGPT.
/// Decoded `UIImage`s for transcript photos (bodies re-run often).
@MainActor
enum DecodedImages {
    private static let cache = NSCache<NSData, UIImage>()

    static func image(_ data: Data) -> UIImage? {
        if let image = cache.object(forKey: data as NSData) { return image }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: data as NSData)
        return image
    }
}

struct UserImagesRow: View {
    let images: [Data]
    @State private var viewing: ViewedImage?
    @Namespace private var zoom

    struct ViewedImage: Identifiable {
        let id: Int
        let image: UIImage
    }

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 48)
            ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                if let image = DecodedImages.image(data) {
                    Button { viewing = ViewedImage(id: index, image: image) } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: images.count == 1 ? 180 : 96, height: images.count == 1 ? 180 : 96)
                            .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: index, in: zoom)
                    .accessibilityLabel("Photo")
                    .accessibilityIdentifier("agent.photo.\(index)")
                }
            }
        }
        .fullScreenCover(item: $viewing) { item in
            ImageViewer(image: item.image)
                .navigationTransition(.zoom(sourceID: item.id, in: zoom))
        }
    }
}

/// Full-screen photo: pinch or double-tap to zoom, drag down or tap Done to close.
struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var drag: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(1 - min(0.6, abs(drag.height) / 400)).ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(scale == 1 ? drag : .zero)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(MagnifyGesture()
                    .onChanged { scale = max(1, min(5, baseScale * $0.magnification)) }
                    .onEnded { _ in baseScale = scale })
                .simultaneousGesture(DragGesture()
                    .onChanged { if scale == 1 { drag = $0.translation } }
                    .onEnded { value in
                        if scale == 1, abs(value.translation.height) > 120 { dismiss() }
                        else { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = .zero } }
                    })
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        scale = scale > 1 ? 1 : 2.5
                        baseScale = scale
                    }
                }
            Button("Done") { dismiss() }
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 16).frame(height: 40)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(16)
                .foregroundStyle(.white)
                .accessibilityIdentifier("viewer.done")
        }
        .environment(\.colorScheme, .dark)
    }
}
