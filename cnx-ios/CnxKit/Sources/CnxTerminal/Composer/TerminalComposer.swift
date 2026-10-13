#if os(iOS)
import AVFoundation
import PhotosUI
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The composer row (SPEC 4.3 collapsed metrics, 10.2): `+` menu (Photos,
/// Files, Paste), a growing text field and the send button, which sends the
/// text plus Return, or a bare Return when the field is empty.
struct TerminalComposer: View {
    @Bindable var model: TerminalModel
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty {
                AttachmentStrip(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 6) {
                plusMenu
                field
                sendButton
            }
        }
        .padding(6)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 8)
        .animation(.smooth(duration: 0.3), value: model.attachments.count)
        .photosPicker(isPresented: $model.showPhotoPicker, selection: $photoItems, maxSelectionCount: 6,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: .compatible)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await loadPhotos(items) }
        }
        .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await loadFiles(urls) }
        }
    }

    private var plusMenu: some View {
        Menu {
            Section {
                Button("Photos", systemImage: "photo.on.rectangle") { model.showPhotoPicker = true }
                Button("Files", systemImage: "folder") { model.showFileImporter = true }
            }
            Section {
                Button("Paste", systemImage: "doc.on.clipboard") { pasteFromClipboard() }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.08), in: .circle)
                .contentShape(.circle)
        }
        .tint(.primary)
        .accessibilityLabel("Add attachment")
    }

    private var field: some View {
        HStack(spacing: 6) {
            if model.directTyping {
                Image(systemName: "keyboard")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            ComposerTextView(
                text: $model.composerText,
                placeholder: model.composerPlaceholder,
                focusRequest: model.composerFocusRequest,
                onFocusChange: { isFocused in
                    model.composerFocused = isFocused
                    if isFocused { model.directTyping = false }
                },
                onReturn: { model.send() }
            )
        }
        .padding(.leading, 4)
        .frame(minHeight: 36)
    }

    private var sendButton: some View {
        let empty = model.composerText.isEmpty && model.attachments.isEmpty
        return Button {
            model.send()
        } label: {
            Image(systemName: empty ? "return" : "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(empty ? Color.primary : Color(uiColor: .systemBackground))
                .frame(width: 36, height: 36)
                .background(empty ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(Color.primary), in: .circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Send without Return", systemImage: "arrow.up.to.line") { model.sendWithoutReturn() }
        }
        .accessibilityLabel(empty ? "Return" : "Send")
        .accessibilityIdentifier("terminal.composer.send")
    }

    private func pasteFromClipboard() {
        if let image = UIPasteboard.general.image {
            model.addAttachment(ComposerAttachment(kind: .image, name: "Pasted image.png", thumbnail: image.preparingThumbnail(of: CGSize(width: 168, height: 168))))
        } else if let text = UIPasteboard.general.string {
            model.composerText += text
        }
    }

    // MARK: Loading attachments

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for (index, item) in items.enumerated() {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if isVideo, let movie = try? await item.loadTransferable(type: MovieFile.self) {
                let thumbnail = await Self.videoThumbnail(movie.url)
                model.addAttachment(ComposerAttachment(kind: .video, name: movie.url.lastPathComponent, thumbnail: thumbnail))
            } else if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                let thumbnail = await image.byPreparingThumbnail(ofSize: CGSize(width: 168, height: 168))
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                model.addAttachment(ComposerAttachment(kind: .image, name: "IMG_\(1000 + index).\(ext)", thumbnail: thumbnail, byteCount: data.count))
            }
        }
    }

    private func loadFiles(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 56, height: 56), scale: 3, representationTypes: .thumbnail)
            let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
            let kind: ComposerAttachment.Kind = type.conforms(to: .image) ? .image : type.conforms(to: .movie) ? .video : .file
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            model.addAttachment(ComposerAttachment(kind: kind, name: url.lastPathComponent, thumbnail: thumbnail, byteCount: size))
        }
    }

    static func videoThumbnail(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 168, height: 168)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image)
    }
}

/// A picked movie, copied out of the Photos sandbox.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}

/// Inline previews: 56 x 56 thumbnails (radius 12) for photos and videos, 56 h
/// chips for files, each with a 20 pt remove badge.
struct AttachmentStrip: View {
    let model: TerminalModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    tile(attachment)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                model.removeAttachment(attachment.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                                    .frame(width: 20, height: 20)
                                    .background(Color.primary, in: .circle)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                            .accessibilityLabel("Remove \(attachment.name)")
                        }
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func tile(_ attachment: ComposerAttachment) -> some View {
        switch attachment.kind {
        case .image, .video:
            ZStack {
                if let thumbnail = attachment.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.primary.opacity(0.08)
                    Image(systemName: attachment.kind == .video ? "video" : "photo").foregroundStyle(.secondary)
                }
                if attachment.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(attachment.name)
        case .file:
            HStack(spacing: 8) {
                Group {
                    if let thumbnail = attachment.thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFit()
                    } else {
                        Image(systemName: "doc.text").font(.system(size: 20)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name).font(.footnote.weight(.medium)).lineLimit(1)
                    if let bytes = attachment.byteCount {
                        Text(Int64(bytes), format: .byteCount(style: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 140, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(height: 56)
            .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        }
    }
}
#endif
