import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The terminal composer: a Liquid Glass card docked to the keyboard
/// (Claude/ChatGPT/Grok composer shape) with a `+` menu (Photos, Camera,
/// Files), attachment thumbnails, a terminal keys row, and one primary
/// circle that sends, presses Return, or interrupts (Ctrl-C) a working agent.
struct ComposerBar: View {
    @Bindable var model: ComposerModel
    let session: TerminalSession
    let services: ServiceClient?
    var agentWorking: Bool
    var placeholder: String

    @FocusState private var focused: Bool
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var ctrlArmed = false

    var body: some View {
        VStack(spacing: 8) {
            if focused { keysRow.transition(.move(edge: .bottom).combined(with: .opacity)) }
            card
        }
        .padding(.horizontal, 12)
        .padding(.bottom, focused ? 8 : 4)
        .animation(.smooth(duration: 0.28), value: focused)
        .animation(.smooth(duration: 0.24), value: model.attachments)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                if let data {
                    model.add(ComposerAttachment(name: "photo-\(Self.stamp()).jpg", data: data, kind: .image, thumbnail: ComposerModel.thumbnail(for: data)))
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await importPhotos(items) }
        }
        .alert(String(localized: "Couldn't send"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments) { attachment in
                            AttachmentChip(attachment: attachment) { model.remove(attachment) }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollClipDisabled()
            }
            TextField(placeholder, text: $model.text, axis: .vertical)
                .lineLimit(1...6)
                .font(.body)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("composer.text")
            HStack(spacing: 10) {
                plusMenu
                if let progress = model.uploadProgress {
                    ProgressView(value: progress).frame(width: 60).tint(.secondary)
                }
                Spacer(minLength: 0)
                if !focused {
                    Button { focused = true } label: {
                        Image(systemName: "keyboard").font(.system(size: 17, weight: .medium))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Show keyboard"))
                }
                primaryButton
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .padding(.horizontal, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerRadius))
    }

    private var plusMenu: some View {
        Menu {
            Button { showCamera = true } label: { Label(String(localized: "Camera"), systemImage: "camera") }
            Button { showPhotos = true } label: { Label(String(localized: "Photos"), systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label(String(localized: "Files"), systemImage: "paperclip") }
            Divider()
            Button { pasteClipboard() } label: { Label(String(localized: "Paste"), systemImage: "doc.on.clipboard") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Add attachment"))
        .accessibilityIdentifier("composer.plus")
    }

    @ViewBuilder
    private var primaryButton: some View {
        if model.canSend {
            circleButton(systemImage: "arrow.up", filled: true, label: String(localized: "Send")) {
                Task { await model.send(to: session, services: services) }
            }
            .disabled(model.isSending)
            .accessibilityIdentifier("composer.send")
        } else if agentWorking {
            circleButton(systemImage: "stop.fill", filled: true, label: String(localized: "Interrupt")) {
                session.sendKeys(["escape"])
                Haptics.warning()
            }
            .accessibilityIdentifier("composer.stop")
        } else {
            circleButton(systemImage: "return", filled: false, label: String(localized: "Return")) {
                session.sendKeys(["enter"])
                Haptics.tap()
            }
            .accessibilityIdentifier("composer.return")
        }
    }

    private func circleButton(systemImage: String, filled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(filled ? Color(uiColor: .systemBackground) : .primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(filled ? Color.primary : Color.primary.opacity(0.08)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Keys

    private var keysRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc") { session.sendKeys(["escape"]) }
                key("tab") { session.sendKeys(["tab"]) }
                key("ctrl", active: ctrlArmed) { ctrlArmed.toggle() }
                key("⌃C") { session.sendKeys(["ctrl+c"]) }
                keyIcon("arrow.up") { press("up") }
                keyIcon("arrow.down") { press("down") }
                keyIcon("arrow.left") { press("left") }
                keyIcon("arrow.right") { press("right") }
                ForEach(["/", "-", "|", "~", "$", "*"], id: \.self) { symbol in
                    key(symbol) { model.text.append(symbol) }
                }
                keyIcon("keyboard.chevron.compact.down") { focused = false }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }

    private func press(_ key: String) {
        session.sendKeys([ctrlArmed ? "ctrl+\(key)" : key])
        ctrlArmed = false
        Haptics.selection()
    }

    private func key(_ title: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.selection()
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .foregroundStyle(active ? Color(uiColor: .systemBackground) : .primary)
                .background(active ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.clear))
                .clipShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
    }

    private func keyIcon(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 34)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
    }

    // MARK: Importing

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let isVideo = type?.conforms(to: .movie) ?? false
            let ext = type?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            model.add(ComposerAttachment(
                name: "\(isVideo ? "video" : "photo")-\(Self.stamp()).\(ext)",
                data: data,
                kind: isVideo ? .video : .image,
                thumbnail: isVideo ? nil : ComposerModel.thumbnail(for: data)
            ))
        }
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            let isImage = type?.conforms(to: .image) ?? false
            model.add(ComposerAttachment(
                name: url.lastPathComponent,
                data: data,
                kind: isImage ? .image : (type?.conforms(to: .movie) ?? false ? .video : .file),
                thumbnail: isImage ? ComposerModel.thumbnail(for: data) : nil
            ))
        }
    }

    private func pasteClipboard() {
        let board = UIPasteboard.general
        if let image = board.image, let data = image.pngData() {
            model.add(ComposerAttachment(name: "pasted-\(Self.stamp()).png", data: data, kind: .image, thumbnail: ComposerModel.thumbnail(for: data)))
        } else if let string = board.string {
            model.text.append(string)
        }
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// A thumbnail (or file icon) with a remove button, like Claude's composer.
struct AttachmentChip: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = attachment.thumbnail, let image = UIImage(data: thumb) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: attachment.kind == .video ? "film" : "doc")
                            .font(.system(size: 20))
                        Text(attachment.name).font(.caption2).lineLimit(1).padding(.horizontal, 4)
                        Text(attachment.sizeText).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.elevated)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.black.opacity(0.7)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(String(localized: "Remove \(attachment.name)"))
        }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// Camera capture through UIImagePickerController.
struct CameraPicker: UIViewControllerRepresentable {
    let completion: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.completion(image?.jpegData(compressionQuality: 0.9))
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.completion(nil)
            parent.dismiss()
        }
    }
}
