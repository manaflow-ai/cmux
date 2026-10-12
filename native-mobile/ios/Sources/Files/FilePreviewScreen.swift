import AVKit
import SwiftUI
import UIKit

/// Previews a file on the Mac: images, video/audio, PDF, HTML, Markdown,
/// SVG, JSON, text/code, and QuickLook for anything else. Push inside a
/// NavigationStack.
struct FilePreviewScreen: View {
    enum Mode: String, CaseIterable, Identifiable {
        case preview, code
        var id: String { rawValue }
        var title: String {
            switch self {
            case .preview: String(localized: "Preview")
            case .code: String(localized: "Code")
            }
        }
    }

    let path: String
    @State private var model: FilePreviewModel
    @State private var mode: Mode = .preview
    @State private var exporting = false
    @State private var safariURL: PresentedURL?
    @AppStorage("files.wrapLines") private var wrap = true

    init(path: String, services: ServiceClient) {
        self.path = path
        _model = State(initialValue: FilePreviewModel(path: path, services: services))
    }

    var body: some View {
        content
            .background(Theme.background)
            .navigationTitle(model.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await model.start() }
            .onDisappear { if !exporting { model.cleanUp() } }
            .sheet(isPresented: $exporting) {
                if let url = model.fileURL { FileExporter(url: url).ignoresSafeArea() }
            }
            .sheet(item: $safariURL) { item in
                SafariView(url: item.url).ignoresSafeArea()
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .checking:
            DiffLoadingState(label: String(localized: "Opening file"))
        case .downloading:
            VStack(spacing: 14) {
                Image(systemName: FileSymbol.symbol(path: path))
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.secondaryInk)
                Text(model.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: model.progress)
                    .tint(Theme.ink)
                    .frame(maxWidth: 220)
                Text(model.progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Downloading \(model.fileName)"))
        case .confirmLarge(let size):
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.bottom, 4)
                Text(String(localized: "Download \(FileFormat.size(size) ?? "")?"))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "This file is large. Downloading it from your Mac may take a while and use data."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await model.confirmDownload() }
                } label: {
                    Text(String(localized: "Download"))
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                }
                .buttonStyle(CapsuleCTAStyle())
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            DiffFailureState(title: String(localized: "Couldn't load file"), message: message) {
                Task { await model.retry() }
            }
        case .ready(let content):
            ready(content)
        }
    }

    @ViewBuilder private func ready(_ content: FilePreviewModel.Content) -> some View {
        switch content {
        case .image(let image):
            ZoomableImageView(image: image)
                .ignoresSafeArea(edges: .bottom)
        case .media(let url, let isAudio):
            MediaPreview(url: url, isAudio: isAudio, name: model.fileName)
        case .pdf(let url):
            PDFPreview(url: url)
                .ignoresSafeArea(edges: .bottom)
        case .web(let source, let code):
            if mode == .preview {
                WebPreview(source: source) { safariURL = PresentedURL(url: $0) }
                    .ignoresSafeArea(edges: .bottom)
            } else {
                CodePreviewView(document: code, wrap: wrap)
            }
        case .code(let document):
            CodePreviewView(document: document, wrap: wrap)
        case .quickLook(let url):
            QuickLookPreview(url: url)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var showsModePicker: Bool {
        if case .ready(.web) = model.phase { return true }
        return false
    }

    private var showsWrapToggle: Bool {
        switch model.phase {
        case .ready(.code): true
        case .ready(.web): mode == .code
        default: false
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if showsModePicker {
            ToolbarItem(placement: .principal) {
                Picker(String(localized: "View"), selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let url = model.fileURL {
                ShareLink(item: url) {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                }
            }
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(String(localized: "Copy Path"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = path
                    Haptics.success()
                }
                if model.fileURL != nil {
                    Button(String(localized: "Save to Files"), systemImage: "folder") { exporting = true }
                }
                if showsWrapToggle {
                    Toggle(String(localized: "Wrap Lines"), systemImage: "text.word.spacing", isOn: $wrap)
                }
            } label: {
                Label(String(localized: "More"), systemImage: "ellipsis")
            }
        }
    }
}

/// AVKit player for video and audio temp files.
private struct MediaPreview: View {
    let url: URL
    let isAudio: Bool
    let name: String
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player) {
                    if isAudio {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.system(size: 48))
                                .foregroundStyle(Theme.secondaryInk)
                            Text(name)
                                .font(.headline)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .onAppear { if player == nil { player = AVPlayer(url: url) } }
        .onDisappear { player?.pause() }
    }
}
