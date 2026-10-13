#if os(iOS)
import CnxDesign
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// SPEC 4.3 composer for agent chat: glass card with a text row over a
/// controls row (`+` menu, model pill, mic, send/stop), attachment previews,
/// queue rows, slash-command suggestions, and the collapsed "Follow up" capsule.
struct ChatComposer: View {
    let store: AgentChatStore
    @Binding var text: String
    @Binding var attachments: [AgentAttachment]
    var focus: FocusState<Bool>.Binding
    var collapsible: Bool
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var sendCount = 0
    @State private var planMode = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasContent: Bool { !trimmed.isEmpty || !attachments.isEmpty }
    private var collapsed: Bool { collapsible && !focus.wrappedValue && !hasContent }

    var body: some View {
        VStack(spacing: 8) {
            if !store.queue.isEmpty {
                queueRows
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !slashMatches.isEmpty {
                slashSuggestions
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            card
        }
        .animation(.cnxSmooth, value: collapsed)
        .animation(.cnxSmooth, value: store.queue)
        .animation(.cnxSnappy, value: attachments)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                attachments += urls.map { AgentAttachment(kind: .file, name: $0.lastPathComponent) }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.85) {
                    attachments.append(AgentAttachment(kind: .image, name: "Camera \(Date().formatted(date: .omitted, time: .shortened))", data: data))
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItems) { _, items in
            Task { await loadPhotos(items) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !collapsed {
                if !attachments.isEmpty {
                    attachmentStrip
                }
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...8)
                    .focused(focus)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    .accessibilityLabel(placeholder)
            }
            HStack(spacing: 8) {
                plusMenu
                if collapsed {
                    Text("Follow up")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture { focus.wrappedValue = true }
                } else {
                    if store.currentModelName != nil { modelPill }
                    Spacer(minLength: 0)
                }
                // No mic button: iOS has no API to start keyboard dictation, and the
                // keyboard's own mic dictates into this field (SPEC open decision).
                primaryButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, collapsed ? 6 : 8)
            .padding(.top, collapsed ? 6 : 0)
        }
        .frame(minHeight: collapsed ? 48 : 96, alignment: .bottom)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, collapsed ? 20 : 12)
    }

    private var placeholder: String { "Reply to \(store.summary.agentName)" }

    // MARK: Controls

    private var plusMenu: some View {
        Menu {
            Section {
                if CameraPicker.isAvailable {
                    Button("Camera", systemImage: "camera") { showCamera = true }
                } else {
                    // Simulators and devices without a camera: say why instead of failing on tap.
                    Button {} label: {
                        Label("Camera", systemImage: "camera")
                        Text("No camera on this device")
                    }
                    .disabled(true)
                }
                Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
                Button("Files", systemImage: "paperclip") { showFiles = true }
            }
            Section {
                Toggle("Plan mode", systemImage: "checklist", isOn: Binding(
                    get: { store.currentModeID == "plan" },
                    set: { store.setMode($0 ? "plan" : "default") }
                ))
                if !store.modes.isEmpty {
                    Menu {
                        Picker("Permission mode", selection: Binding(
                            get: { store.currentModeID ?? "" },
                            set: { store.setMode($0) }
                        )) {
                            ForEach(store.modes) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Permission mode", systemImage: "lock.shield")
                    }
                }
                if !store.availableCommands.isEmpty {
                    Menu {
                        ForEach(store.availableCommands) { command in
                            Button {
                                text = "/\(command.name) "
                                focus.wrappedValue = true
                            } label: {
                                Text("/\(command.name)")
                                Text(command.description)
                            }
                        }
                    } label: {
                        Label("Commands", systemImage: "slash.circle")
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(collapsed ? Color.clear : Color.cnxFill, in: .circle)
                .contentShape(.circle)
        }
        .accessibilityLabel("Add")
    }

    private var modelPill: some View {
        Menu {
            Section("Model") {
                Picker("Model", selection: Binding(get: { store.currentModelID ?? "" }, set: { store.setModel($0) })) {
                    ForEach(store.models) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
            }
            if let effort = store.effortOption {
                Section("Effort") {
                    Picker("Effort", selection: Binding(get: { effort.currentValue ?? "" }, set: { store.setConfig(effort.id, value: $0) })) {
                        ForEach(effort.options, id: \.value) { Text($0.name ?? $0.value).tag($0.value) }
                    }
                    .pickerStyle(.inline)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.currentModelName ?? "")
                if let effort = store.effortOption, let value = effort.options.first(where: { $0.value == effort.currentValue }) {
                    Text(value.name ?? value.value).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.cnxFill, in: .capsule)
        }
        .accessibilityLabel("Model")
    }

    private enum PrimaryState { case empty, send, stop, queue }

    private var primaryState: PrimaryState {
        if store.isRunning { return hasContent ? .queue : .stop }
        return hasContent ? .send : .empty
    }

    private var primaryButton: some View {
        let state = primaryState
        return Button {
            switch state {
            case .stop: store.cancel()
            case .send, .queue: send(steer: false)
            case .empty: break
            }
        } label: {
            Image(systemName: state == .stop ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state == .empty ? Color(uiColor: .tertiaryLabel) : Color.cnxOnAccent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .background(state == .empty ? Color.cnxFill : Color.cnxAccent, in: .circle)
                .overlay {
                    if state == .queue {
                        Circle().strokeBorder(.secondary, lineWidth: 2).padding(-4)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(state == .empty)
        .animation(.cnxSnap, value: state)
        .contextMenu {
            if state == .queue {
                Button("Queue (send after this turn)", systemImage: "text.line.last.and.arrowtriangle.forward") { send(steer: false) }
                Button("Steer now (interrupt)", systemImage: "arrow.uturn.right") { send(steer: true) }
            }
        }
        .accessibilityLabel(state == .stop ? "Stop" : "Send")
    }

    private func send(steer: Bool) {
        store.send(prompt: text, attachments: attachments, steer: steer)
        text = ""
        attachments = []
        sendCount += 1
        focus.wrappedValue = false
    }

    // MARK: Attachments, queue, slash commands

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentThumb(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var queueRows: some View {
        VStack(spacing: 4) {
            ForEach(store.queue) { item in
                HStack(spacing: 8) {
                    Image(systemName: "clock").font(.footnote).foregroundStyle(.secondary)
                    Text(item.text).font(.subheadline).lineLimit(1)
                    Spacer()
                    Button {
                        store.removeQueued(item.id)
                        text = item.text
                    } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove queued message")
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.horizontal, 20)
    }

    private var slashMatches: [ACPAvailableCommand] {
        guard text.hasPrefix("/"), !text.contains(" ") else { return [] }
        let query = text.dropFirst().lowercased()
        let prefix = store.availableCommands.filter { $0.name.lowercased().hasPrefix(query) }
        return prefix.isEmpty ? store.availableCommands.filter { $0.name.lowercased().contains(query) } : prefix
    }

    private var slashSuggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slashMatches) { command in
                Button {
                    text = "/\(command.name) "
                } label: {
                    HStack {
                        Text("/\(command.name)").font(.body.monospaced())
                        Text(command.description).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                attachments.append(AgentAttachment(kind: .image, name: "Photo", data: data))
            }
        }
        photoItems = []
    }
}

/// 56 x 56 thumbnail (images) or a 56 h chip (files) with an X badge.
struct AttachmentThumb: View {
    let attachment: AgentAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.kind == .image, let data = attachment.data, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56)
                } else if attachment.kind == .image {
                    LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay { Image(systemName: "photo").foregroundStyle(.white) }
                        .frame(width: 56, height: 56)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").font(.title3)
                        Text(attachment.name).font(.footnote).lineLimit(2).frame(maxWidth: 110, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 56)
                    .background(Color.cnxFill)
                }
            }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.cnxOnAccent)
                    .frame(width: 20, height: 20)
                    .background(Color.cnxAccent, in: .circle)
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }
}
/// UIImagePickerController's camera (SwiftUI has no camera picker).
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
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
