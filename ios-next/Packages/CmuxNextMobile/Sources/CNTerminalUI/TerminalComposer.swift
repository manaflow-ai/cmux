#if os(iOS)
import CNCore
import CNDesign
import CNTransport
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The terminal's GUI input row, above the key bar: a Liquid Glass capsule
/// with `+` (Photos, Camera, Files), a field that grows from one line to four
/// and Send (highlight, the only hue). Send writes the text into the terminal
/// as a paste, then Return; long-press Send to send without Return.
/// Attachments upload to the Mac and their shell-quoted path is inserted into
/// the field.
struct TerminalComposer: View {
    @Bindable var model: TerminalScreenModel
    var onSend: (String, Bool) -> Void
    var onAttach: (TerminalAttachment) -> Void
    var onFocusChange: (Bool) -> Void
    /// The row's height changed (a line was added or removed).
    var onHeightChange: () -> Void = {}

    @FocusState private var focused: Bool
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasText: Bool { !model.composerText.isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            plusMenu
            TextField(TerminalText.composerPlaceholder, text: $model.composerText, axis: .vertical)
                .font(.system(size: 16, design: .monospaced))
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    // Hardware Return sends; Shift-Return keeps the newline.
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    send(submit: true)
                    return .handled
                }
                .padding(.vertical, 9)
                .frame(minHeight: 36)
                .accessibilityIdentifier("terminal.composer.field")
            if model.uploading > 0 {
                ProgressView()
                    .frame(width: 34, height: 36)
                    .accessibilityLabel(TerminalText.uploading)
            }
            sendButton
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive(false), in: .rect(cornerRadius: CNTheme.shared.metrics.composerRadius, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .animation(reduceMotion ? nil : CNTheme.shared.motion.move, value: model.composerText.count > 0)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in onHeightChange() }
        .onChange(of: focused) { _, now in onFocusChange(now) }
        .onChange(of: model.composerFocusRequest) { _, _ in focused = model.composerWantsFocus }
        .onAppear { if model.composerWantsFocus { focused = true } }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { loadFiles(urls) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            TerminalCameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.85) {
                    onAttach(TerminalAttachment(name: "camera.jpg", mimeType: "image/jpeg", source: .data(data)))
                }
            }
            .ignoresSafeArea()
        }
    }

    private var plusMenu: some View {
        Menu {
            Button(TerminalText.photos, systemImage: "photo.on.rectangle") { showPhotos = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(TerminalText.camera, systemImage: "camera") { showCamera = true }
            }
            Button(TerminalText.files, systemImage: "folder") { showFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.cn(\.textPrimary))
                .frame(width: 36, height: 36)
                .background(.cn(\.fillHover), in: .circle)
                .contentShape(.circle)
        }
        .accessibilityLabel(TerminalText.addAttachment)
        .accessibilityIdentifier("terminal.composer.plus")
    }

    private var sendButton: some View {
        Button { send(submit: true) } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.cn(\.highlight).opacity(hasText ? 1 : 0.45), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 1)
        .contextMenu {
            Button(TerminalText.sendWithoutReturn, systemImage: "arrow.up.to.line") { send(submit: false) }
        }
        .accessibilityLabel(TerminalText.send)
        .accessibilityIdentifier("terminal.composer.send")
    }

    private func send(submit: Bool) {
        let text = model.composerText
        // An empty Send is a bare Return (accepts a TUI prompt).
        onSend(text, submit)
        model.composerText = ""
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for (i, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                let ext = type?.preferredFilenameExtension ?? "jpg"
                let mime = type?.preferredMIMEType ?? "image/jpeg"
                onAttach(TerminalAttachment(name: "photo-\(i + 1).\(ext)", mimeType: mime, source: .data(data)))
            }
            photoItems = []
        }
    }

    /// Checks each file's size before reading anything, then copies it out of
    /// its security scope off the main actor; the upload reads the copy in chunks.
    private func loadFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                switch await Self.stageFile(url) {
                case .success(let copy):
                    onAttach(TerminalAttachment(name: url.lastPathComponent, mimeType: type, source: .file(copy), temporary: copy))
                case .failure(let error):
                    model.uploadError = error.localizedDescription
                }
            }
        }
    }

    @concurrent
    private static func stageFile(_ url: URL) async -> Result<URL, any Error> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= fileUploadMaxBytes else { throw FileUploadError.tooLarge(limit: fileUploadMaxBytes) }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-upload-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            return .success(copy)
        } catch {
            return .failure(error)
        }
    }
}

/// A picked photo or file on its way to the Mac.
struct TerminalAttachment: Sendable {
    let name: String
    let mimeType: String
    let source: FileUploadSource
    /// A staged copy to delete once the upload ends.
    var temporary: URL? = nil
}

/// POSIX shell quoting: bare when only safe characters, else single quotes.
func shellQuoted(_ path: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
    if !path.isEmpty, path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct TerminalCameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: TerminalCameraPicker
        init(_ parent: TerminalCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif
