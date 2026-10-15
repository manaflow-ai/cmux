#if os(iOS)
public import CNTransport
import CNCore
import Foundation
import CNDesign
public import SwiftUI
import UIKit

/// Where a terminal screen points: an existing terminal, or a new one the
/// screen creates once it knows the grid that fits it.
enum TerminalRoute: Hashable {
    case existing(String)
    case new(UUID)

    var existingId: String? {
        if case .existing(let id) = self { return id }
        return nil
    }
}

/// State of one terminal screen, shared by the SwiftUI chrome and the UIKit
/// controller that hosts the Ghostty surface.
@MainActor
@Observable
final class TerminalScreenModel {
    enum Status: Equatable {
        case attaching, live, reconnecting, exited
        /// The terminal no longer exists on the Mac (host restarted, closed).
        case ended
        case failed(String)
    }

    /// Why a terminal ended: its shell exited, or the Mac no longer has it.
    enum EndReason: Equatable { case exited, gone }
    var endReason: EndReason = .gone

    var terminal: Terminal?
    var status: Status = .attaching {
        didSet { if status != oldValue { controller?.statusChanged() } }
    }
    var grid = ""
    /// The renderer has drawn the host's output at least once (hosts keep
    /// the card image over it until then, so it never shows blank).
    var hasContent = false
    var fontSize = TerminalFontSize.stored
    var keyboardShift: CGFloat = 0
    /// The composer row is shown (else typing goes straight to the terminal).
    var composerMode = false
    var composerText = ""
    /// The composer's desired focus; `composerFocusRequest` bumps to apply it.
    var composerWantsFocus = false
    var composerFocusRequest = 0
    var uploading = 0
    var uploadError: String?
    /// Bumps when the composer or key bar appears, hides or changes height.
    var accessoryRevision = 0
    @ObservationIgnored weak var controller: TerminalViewController?

    init() {}
}

/// Where the composer and key bar go.
public enum TerminalAccessoryPlacement: Sendable {
    /// Inside the terminal content, riding the keyboard.
    case inline
    /// The host places `TerminalAccessory(handle:)` itself (for example above
    /// its own bottom toolbar).
    case external
}

/// One terminal's state and controls, shared by `TerminalContent` (the
/// terminal itself) and `TerminalAccessory` (composer and key bar). Keep one
/// handle per terminal for as long as its card or screen exists: the content
/// view reuses its controller, so moving between a grid card and full screen
/// does not re-create it.
@MainActor
@Observable
public final class TerminalHandle {
    public let connection: HostConnection
    public let accessoryPlacement: TerminalAccessoryPlacement
    /// The terminal shown; nil until a new terminal was created.
    public var terminalId: String? {
        if case .existing(let id) = route { return id }
        return createdId
    }
    /// The host's record (title, cwd, grid, running); live.
    public var terminal: Terminal? { model.terminal }
    public var title: String { model.terminal?.title ?? "" }
    /// True when the terminal belongs to the Mac (`term.mirror.v1`).
    public var isMirrored: Bool { connection.hostInfo?.supports(.terminalMirror) ?? false }

    var route: TerminalRoute
    var createdId: String?
    var model = TerminalScreenModel()
    @ObservationIgnored var controller: TerminalViewController?

    /// `terminalId` nil creates a new terminal (with the grid that fits).
    public init(connection: HostConnection, terminalId: String?, accessoryPlacement: TerminalAccessoryPlacement = .inline) {
        self.connection = connection
        self.accessoryPlacement = accessoryPlacement
        route = terminalId.map(TerminalRoute.existing) ?? .new(UUID())
    }

    init(connection: HostConnection, route: TerminalRoute) {
        self.connection = connection
        self.accessoryPlacement = .inline
        self.route = route
    }

    // MARK: Controls for the host's own toolbar

    public func focusInput() { model.controller?.focusInput() }
    public func endInputFocus() { model.controller?.endInputFocusFromHost() }
    public func paste() { model.controller?.paste() }
    public func copySelection() { model.controller?.copySelection() }
    public func selectAll() { model.controller?.selectAll() }
    public func stepFontSize(by points: Double) { model.controller?.stepFontSize(by: points) }
    public func resetFontSize() { model.controller?.resetFontSize() }
    /// The composer row (true) or typing straight into the terminal (false).
    public var composerMode: Bool {
        get { model.composerMode }
        set { model.controller?.setComposerMode(newValue) }
    }

    /// Drops the Ghostty renderer (the view, its surface and stream) while the
    /// terminal is not on screen; the next `TerminalContent` re-creates it and
    /// re-attaches (the host replays the scrollback; a mirrored terminal
    /// comes back at the Mac's grid). Returns false while it is on screen.
    @discardableResult
    public func releaseRenderer() -> Bool {
        guard let controller else { return true }
        if controller.isOnScreen || controller.view.window != nil { return false }
        self.controller = nil
        if model.controller === controller { model.controller = nil }
        if model.status != .ended { model.status = .attaching }
        model.hasContent = false
        return true
    }

    /// True while this terminal has a live renderer.
    public var hasRenderer: Bool { controller != nil }

    /// Whether the live view draws (true) or keeps showing its last frame
    /// (false: a static card covers or replaces it). Output is still parsed.
    public func setRendering(_ rendering: Bool) {
        controller?.terminalView.rendering = rendering
    }

    /// The live view's last presented frame, `maxPixelWidth` wide at most.
    public func snapshot(maxPixelWidth: CGFloat) -> UIImage? {
        controller?.snapshot(maxPixelWidth: maxPixelWidth)
    }

    /// How far (points of the terminal, top down) a card that shows only the
    /// top `visibleHeight` points of this terminal moves its content up so
    /// the prompt and cursor (the last row with content) are in view; 0 when
    /// they already are or there is no live view. A terminal's card shows
    /// the screen you left, which ends at the prompt, not the top rows.
    public func cardOffset(visibleHeight: CGFloat) -> CGFloat {
        TerminalThumbnails.cardOffset(contentBottom: controller?.contentBottom, visibleHeight: visibleHeight)
    }
    /// True once the renderer has drawn the terminal's output (or shows its
    /// ended/failed state); hosts cover it with the card image until then.
    public var isLive: Bool {
        guard controller != nil else { return false }
        switch model.status {
        case .attaching, .live, .reconnecting: return model.hasContent
        case .exited, .ended, .failed: return true
        }
    }
    /// True while its content is on screen.
    public var isOnScreen: Bool { controller?.isOnScreen ?? false }
    /// True while its view is in a window (on screen, zooming, or covered).
    var isInWindow: Bool { controller?.view.window != nil }

    /// The pool's hook: on screen (true) or off (false).
    @ObservationIgnored var onVisibilityChange: ((TerminalHandle, Bool) -> Void)?

    /// Replaces an ended terminal with a new one in place.
    public func startNewTerminal() {
        controller = nil
        model = TerminalScreenModel()
        createdId = nil
        route = .new(UUID())
    }
}

/// A terminal with no navigation chrome, for hosts that bring their own
/// (the tab grid's zoomed card, its bottom toolbar). Shows the terminal,
/// connection status and the "ended on the Mac" state; follows reconnects,
/// title and grid updates.
///
/// `layoutSize`: lay the terminal out at this size (for example the full
/// page) whatever the proposed size, so a zoom that scales this view draws
/// the real content inside the animating rect. Nil fills the proposal.
public struct TerminalContent: View {
    let handle: TerminalHandle
    let layoutSize: CGSize?
    let onClose: (() -> Void)?

    public init(handle: TerminalHandle, layoutSize: CGSize? = nil, onClose: (() -> Void)? = nil) {
        self.handle = handle
        self.layoutSize = layoutSize
        self.onClose = onClose
    }

    public var body: some View {
        let model = handle.model
        let connection = handle.connection
        let terminalId = handle.terminalId
        content
            .frame(width: layoutSize?.width, height: layoutSize?.height, alignment: .topLeading)
            .task(id: terminalId) {
                guard let terminalId else { return }
                for await push in connection.pushes() {
                    let mirrored = connection.hostInfo?.supports(.terminalMirror) ?? false
                    switch push {
                    case .terminalUpdated(let terminal) where terminal.id == terminalId && model.status != .ended:
                        model.terminal = terminal
                        model.controller?.macGridChanged(terminal)
                        if !terminal.running {
                            model.endReason = .exited
                            model.status = mirrored ? .ended : .exited
                        }
                    case .terminalExited(let id, _) where id == terminalId:
                        // A Mac-owned terminal whose process ended is gone on the
                        // Mac (its tab closes): say so and offer a way forward.
                        // A phone-owned PTY that exited keeps its last screen.
                        model.endReason = .exited
                        model.status = mirrored ? .ended : .exited
                    default:
                        break
                    }
                }
            }
    }

    private var content: some View {
        TerminalSurfaceRepresentable(handle: handle, generation: handle.connection.generation)
            .id(handle.route)
            .ignoresSafeArea(.keyboard)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color.cn(\.terminalBackground).ignoresSafeArea())
            .overlay(alignment: .top) { statusBanner }
            .overlay { if handle.model.status == .ended { endedState } }
    }

    /// The PTY is gone on the Mac: say so and offer a way forward.
    private var endedState: some View {
        ContentUnavailableView {
            Label(TerminalText.endedTitle, systemImage: "apple.terminal")
        } description: {
            Text(handle.model.endReason == .exited ? TerminalText.endedExitedMessage : TerminalText.endedMessage)
        } actions: {
            Button(TerminalText.newTerminal) { handle.startNewTerminal() }
                .buttonStyle(.glassProminent)
                .tint(.cn(\.ink))
                .foregroundStyle(.cn(\.background))
                .accessibilityIdentifier("terminal.ended.new")
            if let onClose {
                Button(TerminalText.backToTerminals) { onClose() }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("terminal.ended.back")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cn(\.terminalBackground))
    }

    @ViewBuilder private var statusBanner: some View {
        let model = handle.model
        let status: String? = switch model.status {
        case .reconnecting: TerminalText.reconnecting
        case .exited: TerminalText.processExited
        case .ended: nil
        case .failed(let message): message
        case .attaching, .live: handle.connection.state.isConnected ? nil : TerminalText.reconnecting
        }
        let text = model.uploadError ?? status
        if let text {
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.cn(\.textSecondary))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.opacity)
                .accessibilityIdentifier("terminal.status")
                .onTapGesture { model.uploadError = nil }
        }
    }
}

/// The composer row and key bar of a handle with `.external` placement, for
/// the host to place (above its bottom toolbar, riding the keyboard). The
/// terminal keeps its visible bottom on this view's top edge. Empty while
/// neither is shown.
public struct TerminalAccessory: View {
    let handle: TerminalHandle

    public init(handle: TerminalHandle) { self.handle = handle }

    public var body: some View {
        TerminalAccessoryRepresentable(handle: handle, revision: handle.model.accessoryRevision)
    }
}

struct TerminalAccessoryRepresentable: UIViewRepresentable {
    let handle: TerminalHandle
    let revision: Int

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        _ = revision
        attach(to: container)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        _ = revision
        guard let stack = handle.controller?.accessoryStack else { return CGSize(width: proposal.width ?? 0, height: 0) }
        let width = proposal.width ?? uiView.window?.bounds.width ?? 390
        let fitted = stack.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                   withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: fitted.height)
    }

    private func attach(to container: UIView) {
        guard let stack = handle.controller?.accessoryStack, stack.superview !== container else { return }
        stack.removeFromSuperview()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// One terminal, full-bleed under a compact navigation bar: Ghostty draws
/// the host's terminal; tap shows the keyboard and the glass key bar; one
/// finger scrolls the scrollback; pinch changes the text size; long press
/// selects and copies. Reconnects re-attach (the host replays scrollback).
public struct TerminalScreenView: View {
    @State private var handle: TerminalHandle
    @Environment(\.dismiss) private var dismiss

    public init(connection: HostConnection, terminalId: String) {
        self.init(connection: connection, route: .existing(terminalId))
    }

    init(connection: HostConnection, route: TerminalRoute) {
        _handle = State(initialValue: TerminalHandle(connection: connection, route: route))
    }

    public var body: some View {
        let connection = handle.connection
        TerminalContent(handle: handle, onClose: { dismiss() })
            .navigationTitle(handle.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        handle.paste()
                    } label: {
                        Label(TerminalText.paste, systemImage: "doc.on.clipboard")
                    }
                    .accessibilityIdentifier("terminal.paste")
                    Menu {
                        Button(TerminalText.copy, systemImage: "doc.on.doc") { handle.copySelection() }
                        Button(TerminalText.selectAll, systemImage: "selection.pin.in.out") { handle.selectAll() }
                        Divider()
                        Button(TerminalText.increaseFontSize, systemImage: "textformat.size.larger") { handle.stepFontSize(by: 1) }
                        Button(TerminalText.decreaseFontSize, systemImage: "textformat.size.smaller") { handle.stepFontSize(by: -1) }
                        Button(TerminalText.resetFontSize, systemImage: "textformat.size") { handle.resetFontSize() }
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["CMUX_NEXT_TERMINAL_DEBUG"] == "1" {
                            // DEBUG: drop the link to exercise reconnect and re-attach.
                            Button("Drop Connection", systemImage: "bolt.horizontal") { connection.client?.close() }
                            // DEBUG: as if the Mac's host restarted (the PTY is gone, then the link drops).
                            Button("Simulate Host Restart", systemImage: "arrow.clockwise") {
                                guard let client = connection.client, let id = handle.terminalId else { return }
                                Task {
                                    try? await client.closeTerminal(id)
                                    client.close()
                                }
                            }
                        }
                        #endif
                    } label: {
                        Label(TerminalText.more, systemImage: "ellipsis")
                    }
                }
            }
    }
}

/// Hosts the UIKit terminal controller; passes connection generation changes on.
struct TerminalSurfaceRepresentable: UIViewControllerRepresentable {
    let handle: TerminalHandle
    let generation: Int

    func makeUIViewController(context: Context) -> TerminalViewController {
        // Reused across view rebuilds (grid card <-> full screen).
        if let controller = handle.controller, controller.parent == nil { return controller }
        let controller = TerminalViewController(connection: handle.connection, terminalId: handle.route.existingId,
                                                model: handle.model, externalAccessory: handle.accessoryPlacement == .external)
        controller.onCreated = { [weak handle] id in handle?.createdId = id }
        controller.onVisibilityChange = { [weak handle] visible in
            guard let handle else { return }
            handle.onVisibilityChange?(handle, visible)
        }
        handle.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: TerminalViewController, context: Context) {
        _ = generation
        controller.sync()
    }
}
#endif
