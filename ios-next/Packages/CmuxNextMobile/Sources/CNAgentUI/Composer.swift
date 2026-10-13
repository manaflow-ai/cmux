#if os(iOS)
import CNCore
import CNDesign
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The floating Liquid Glass composer: a field that grows from one line to
/// five, then a bar with `+` (photos, camera, files), the model and mode chip,
/// and the trailing action: mic when empty, Send (highlight, the only hue)
/// with text, Stop while the agent runs and the field is empty.
struct Composer: View {
    @Binding var text: String
    @Binding var attachments: [ComposerAttachment]
    var placeholder: String
    var running: Bool
    var models: [NamedOption]
    var modes: [NamedOption]
    var modelId: String?
    var modeId: String?
    var focus: FocusState<Bool>.Binding
    var onSend: () -> Void
    var onStop: () -> Void
    var onModel: (String) -> Void
    var onMode: (String) -> Void

    @State private var dictation = Dictation()
    @State private var dictationBase = ""
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []

    /// Height the field animates toward, measured from a hidden twin with the
    /// same text and width (a vertical TextField resizes itself instantly).
    @State private var fieldHeight: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var field: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .font(AgentType.body)
            .lineLimit(1...5)
            .focused(focus)
            .onKeyPress(.return, phases: .down) { press in
                // Hardware Return sends; Shift-Return keeps the newline.
                guard !press.modifiers.contains(.shift) else { return .ignored }
                if hasContent { send() }
                return .handled
            }
            .accessibilityIdentifier("agent.composer.field")
            .frame(height: fieldHeight, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                TextField("", text: .constant(text.isEmpty ? " " : text), axis: .vertical)
                    .font(AgentType.body)
                    .lineLimit(1...5)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        if fieldHeight.map({ abs($0 - h) > 0.5 }) ?? true { fieldHeight = h }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private var growthAnimation: Animation? { reduceMotion ? nil : CNTheme.shared.motion.move }

    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty { attachmentStrip }
            field
            HStack(spacing: 8) {
                plusMenu
                modelChip
                Spacer(minLength: 0)
                trailingButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .animation(growthAnimation, value: fieldHeight)
        .glassEffect(.regular.interactive(false), in: .rect(cornerRadius: CNTheme.shared.metrics.composerRadius, style: .continuous))
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { loadFiles(urls) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.8) {
                    attachments.append(ComposerAttachment(name: "Photo.jpg", mimeType: "image/jpeg", data: data))
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Pieces

    private var plusMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Camera", systemImage: "camera") { showCamera = true }
            }
            Button("Files", systemImage: "folder") { showFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.cn(\.textPrimary))
                .frame(width: 36, height: 36)
                .background(.cn(\.fillHover), in: .circle)
                .contentShape(.circle)
        }
        .accessibilityLabel("Add attachment")
        .accessibilityIdentifier("agent.composer.plus")
    }

    @ViewBuilder private var modelChip: some View {
        let modelName = models.first { $0.id == modelId }?.name ?? modelId
        let modeName = modes.first { $0.id == modeId }?.name ?? modeId
        if modelName != nil || modeName != nil {
            Menu {
                if !models.isEmpty {
                    Section("Model") {
                        ForEach(models) { m in
                            Button { onModel(m.id) } label: {
                                if m.id == modelId { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                            }
                        }
                    }
                }
                if !modes.isEmpty {
                    Section("Mode") {
                        ForEach(modes) { m in
                            Button { onMode(m.id) } label: {
                                if m.id == modeId { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text([modelName, modeName].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
                .font(.subheadline)
                .foregroundStyle(.cn(\.textSecondary))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(.cn(\.fillHover), in: .capsule)
                .contentShape(.capsule)
            }
            .accessibilityLabel("Model and mode")
            .accessibilityValue([modelName, modeName].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("agent.composer.model")
        }
    }

    @ViewBuilder private var trailingButton: some View {
        Group {
            if running && !hasContent {
                circleButton(symbol: "stop.fill", fill: .cn(\.ink), glyph: .cn(\.background), size: 13, label: "Stop") {
                    Haptics.select()
                    onStop()
                }
                .accessibilityIdentifier("agent.composer.stop")
            } else if !hasContent && Dictation.isAvailable {
                circleButton(symbol: dictation.isRunning ? "waveform" : "mic", fill: dictation.isRunning ? .cn(\.highlight) : .clear,
                             glyph: dictation.isRunning ? .white : .cn(\.textSecondary), size: 17, label: dictation.isRunning ? "Stop dictation" : "Dictate") {
                    toggleDictation()
                }
                .accessibilityIdentifier("agent.composer.mic")
            } else {
                circleButton(symbol: "arrow.up", fill: hasContent ? .cn(\.highlight) : .cn(\.highlight).opacity(0.45),
                             glyph: .white, size: 16, label: running ? "Queue message" : "Send") {
                    send()
                }
                .disabled(!hasContent)
                .accessibilityIdentifier("agent.composer.send")
            }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .animation(CNTheme.shared.motion.appear, value: hasContent)
        .animation(CNTheme.shared.motion.appear, value: running)
    }

    private func circleButton(symbol: String, fill: Color, glyph: Color, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(glyph)
                .frame(width: 34, height: 34)
                .background(fill, in: .circle)
                .contentShape(.circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if a.isImage, let image = UIImage(data: a.data) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "doc").font(.title3)
                                    Text(a.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .foregroundStyle(.cn(\.textSecondary))
                                .padding(6)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .background(.cn(\.fillHover))
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        Button {
                            withAnimation(CNTheme.shared.motion.move) { attachments.removeAll { $0.id == a.id } }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .font(.system(size: 18))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove \(a.name)")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
    }

    // MARK: Actions

    private func send() {
        if dictation.isRunning { dictation.stop() }
        Haptics.send()
        onSend()
    }

    private func toggleDictation() {
        if dictation.isRunning {
            dictation.stop()
            return
        }
        dictationBase = text.isEmpty ? "" : text + " "
        let base = dictationBase
        dictation.start { [binding = $text] spoken in
            binding.wrappedValue = base + spoken
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for (i, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.8) ?? data
                attachments.append(ComposerAttachment(name: "Image \(attachments.count + i + 1).jpg", mimeType: "image/jpeg", data: jpeg))
            }
            photoItems = []
        }
    }

    private func loadFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            attachments.append(ComposerAttachment(name: url.lastPathComponent, mimeType: type, data: data))
        }
    }
}

/// Slash commands matching the draft, above the composer.
struct SlashMenu: View {
    var commands: [SlashCommand]
    var pick: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.prefix(6).enumerated()), id: \.offset) { i, c in
                if i > 0 { Rectangle().fill(.cn(\.hairline)).frame(height: 0.5).padding(.leading, 16) }
                Button { pick(c) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.system(.subheadline, design: .monospaced).weight(.medium)).foregroundStyle(.cn(\.textPrimary))
                        Text(c.description).font(.footnote).foregroundStyle(.cn(\.textSecondary)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("agent.slashMenu")
    }

    static func matches(_ draft: String, in commands: [SlashCommand]) -> [SlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let q = draft.lowercased()
        return commands.filter { $0.name.lowercased().hasPrefix(q) || ("/" + $0.name.lowercased()).hasPrefix(q) }
    }
}

/// Prompts written while the agent works, waiting to send.
struct QueuedStrip: View {
    var queue: [QueuedPrompt]
    var remove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(queue) { q in
                HStack(spacing: 8) {
                    Image(systemName: "clock").font(.caption).foregroundStyle(.cn(\.textTertiary))
                    Text(q.text.isEmpty ? "\(q.attachments.count) attachment(s)" : q.text)
                        .font(.subheadline)
                        .foregroundStyle(.cn(\.textSecondary))
                        .lineLimit(1)
                    Button { remove(q.id) } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.cn(\.textTertiary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove queued message")
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel("Queued messages")
    }
}

/// UIKit camera capture.
struct CameraPicker: UIViewControllerRepresentable {
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
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif
