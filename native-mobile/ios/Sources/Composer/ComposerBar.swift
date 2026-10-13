import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The terminal composer, docked to the keyboard: a `+` menu (Photos,
/// Camera, Files), attachment thumbnails, a growing text capsule with an
/// always-visible keyboard toggle, a terminal keys row, and one primary
/// circle that sends, presses Return, or interrupts a working agent.
struct ComposerBar: View {
    @Bindable var model: ComposerModel
    let session: TerminalSession
    let services: ServiceClient?
    var onTerminalKeyboard: (() -> Void)? = nil
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
            // The keys row rides with the keyboard: it fades in place rather
            // than sliding, so an interactive keyboard dismissal doesn't
            // shove the bar around.
            keysRow
                .opacity(focused ? 1 : 0)
                .frame(height: focused ? nil : 0, alignment: .bottom)
                .clipped()
                .allowsHitTesting(focused)
            card
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.smooth(duration: 0.2), value: focused)
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

    // MARK: Bar (iOS 26 Messages layout, Liquid Glass)

    /// Sibling glass shapes in one container: `+` circle, a growing text
    /// capsule with the keyboard toggle inside it, and the primary circle.
    /// Nothing glass sits on top of other glass.
    private var card: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if !model.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.attachments) { attachment in
                                AttachmentChip(attachment: attachment) { model.remove(attachment) }
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.top, 6)
                    }
                    .scrollClipDisabled()
                }
                HStack(alignment: .bottom, spacing: 10) {
                    plusMenu
                    textCapsule
                    primaryButton
                }
            }
        }
    }

    private var textCapsule: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(placeholder, text: $model.text, axis: .vertical)
                .lineLimit(1...6)
                .font(.body)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.vertical, 10)
                .padding(.leading, 16)
                .accessibilityLabel(String(localized: "Message"))
                .accessibilityIdentifier("composer.text")
            if let progress = model.uploadProgress {
                ProgressView(value: progress).frame(width: 36).tint(.secondary).padding(.bottom, 17)
            }
            keyboardToggle
        }
        .frame(minHeight: 44)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }

    /// Always reachable: shows the keyboard, or hides it while it's up.
    private var keyboardToggle: some View {
        Button { focused.toggle() } label: {
            Image(systemName: focused ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(focused ? String(localized: "Hide keyboard") : String(localized: "Show keyboard"))
        .accessibilityIdentifier("composer.keyboard")
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
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(String(localized: "Add attachment"))
        .accessibilityIdentifier("composer.plus")
    }

    @ViewBuilder
    private var primaryButton: some View {
        if model.isSending {
            circleButton(systemImage: "xmark", prominent: false, label: String(localized: "Cancel upload")) {
                model.cancelSend()
            }
            .accessibilityIdentifier("composer.cancel")
        } else if model.canSend {
            circleButton(systemImage: "arrow.up", prominent: true, label: String(localized: "Send")) {
                model.startSend(to: session, services: services)
            }
            .accessibilityIdentifier("composer.send")
        } else if agentWorking {
            circleButton(systemImage: "stop.fill", prominent: true, label: String(localized: "Interrupt")) {
                session.sendKeys(["escape"])
                Haptics.warning()
            }
            .accessibilityIdentifier("composer.stop")
        } else {
            circleButton(systemImage: "return", prominent: false, label: String(localized: "Return")) {
                session.sendKeys(["enter"])
                Haptics.tap()
            }
            .accessibilityIdentifier("composer.return")
        }
    }

    /// Prominent = tinted glass (the primary action), else clear glass.
    private func circleButton(systemImage: String, prominent: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.primary)
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(prominent ? .regular.tint(.white).interactive() : .regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    // MARK: Keys

    /// Terminal keys while typing. The keyboard toggle lives in the text
    /// capsule, so nothing essential scrolls out of reach here.
    private var keysRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
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
                }
                .padding(.horizontal, 2)
            }
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
                .foregroundStyle(active ? Color.black : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 34)
        }
        .buttonStyle(.plain)
        .glassEffect(active ? .regular.tint(.white).interactive() : .regular.interactive(), in: .rect(cornerRadius: 10))
        .accessibilityLabel(TerminalKeyNames.spoken(title))
        .accessibilityAddTraits(active ? .isSelected : [])
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
            guard var data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let isVideo = type?.conforms(to: .movie) ?? false
            var ext = type?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            // iPhone photos are HEIC, which coding agents can't read; send JPEG.
            if !isVideo, let jpeg = ComposerModel.agentReadableImage(data, ext: ext) {
                data = jpeg
                ext = "jpg"
            }
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
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > ComposerModel.maximumAttachmentBytes {
                model.error = ComposerModel.tooLargeMessage(url.lastPathComponent)
                continue
            }
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
        // ASCII digits and the Gregorian year in every locale (file names
        // end up typed into a shell).
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
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
