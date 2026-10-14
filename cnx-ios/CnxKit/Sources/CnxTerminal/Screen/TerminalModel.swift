#if os(iOS)
import Foundation
import Observation
import UIKit

/// The terminal screen's state, shared by the UIKit controller (surface,
/// scrolling, keyboard tracking) and the SwiftUI chrome (toolbar, composer,
/// key bar, sheets). The session is the data source.
@MainActor
@Observable
public final class TerminalModel {
    public let session: any TerminalSession
    public let artifactSource: any ArtifactSource

    public internal(set) var title: String
    public internal(set) var programName: String
    /// Alternate screen: the program owns scrolling; the frame pins to the composer.
    public internal(set) var isTUI = false
    public internal(set) var keyboardVisible = false
    /// The terminal surface is first responder: keys go to the PTY as typed.
    public internal(set) var directTyping = false
    public internal(set) var isScrolledUp = false
    /// Whether the screen shows the Mac's terminal; anything else draws the
    /// connecting placeholder over it.
    public internal(set) var connectionState: TerminalConnectionState
    var sticky = TerminalStickyModifiers()

    // Composer
    public var composerText = ""
    var composerFocused = false
    /// Incremented to ask the composer field to take focus.
    var composerFocusRequest = 0
    /// Focus asked for before the composer was on screen (a new tab).
    var composerFocusOnAppear = false
    public internal(set) var attachments: [ComposerAttachment] = []
    var showPhotoPicker = false
    var showFileImporter = false
    /// Sends one attachment to the Mac and returns its path there (the
    /// link's `upload` service). Nil hides the attachment menu: without a
    /// Mac to receive them there is nothing honest to attach.
    public var uploader: (@MainActor (_ data: Data, _ name: String) async throws -> String)?
    /// Attachments are being sent; the composer waits.
    public internal(set) var isUploading = false
    /// Why the last send with attachments failed (shown over the composer).
    public internal(set) var attachmentError: String?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?

    // Artifacts
    public internal(set) var artifacts: [TerminalArtifact] = []
    public var showArtifacts = false {
        didSet { if showArtifacts, !oldValue { reconcileArtifactsWithScreen() } }
    }
    var artifactPath: [TerminalArtifact] = []
    /// Previews of HTML and Markdown show their source.
    var previewShowsSource = false
    /// Scans output for files and links off the main thread.
    @ObservationIgnored private var collector: TerminalArtifactCollector!
    private var reconcilePending = false

    let joystickEngine = JoystickEngine()

    /// Embedded (workspace tab): the page as last seen, for the tab grid card.
    public internal(set) var snapshot: UIImage?

    /// Set by the controller.
    weak var controller: TerminalViewController?

    public init(session: any TerminalSession, artifactSource: any ArtifactSource, title: String = "zsh") {
        self.session = session
        self.artifactSource = artifactSource
        self.title = title
        self.programName = session.programName
        self.connectionState = session.connectionState
        joystickEngine.send = { [weak self] direction in self?.joystick(direction) }
        collector = TerminalArtifactCollector { [weak self] list in self?.artifacts = list }
    }

    func ingest(_ event: TerminalSessionEvent) {
        let connection = connectionState.applying(event)
        if connection != connectionState { connectionState = connection }
        switch event {
        case .output:
            // The bytes are scanned once per display frame (`scanOutput`).
            break
        case .alternateScreen(let on):
            isTUI = on
            programName = session.programName
        case .title(let text):
            title = text
            programName = session.programName
        case .exited:
            break
        case .connection:
            break
        }
    }

    /// Files and links in a batch of output (the screen's per-frame batch).
    func scanOutput(_ data: Data) {
        collector.scan(data)
        if showArtifacts { scheduleReconcile() }
    }

    /// The stream scan sees a path the sender broke at the right margin as
    /// two references. The surface's screen text has logical lines (soft
    /// wraps joined, full-width rows continued), so the list is rescanned
    /// against it whenever Files and Links is open.
    func reconcileArtifactsWithScreen() {
        guard let surface = controller?.surface, let text = surface.screenText() else { return }
        let columns = surface.grid.columns
        collector.reconcile(screenText: text, columns: columns > 0 ? columns : nil)
    }

    /// While Files and Links is open, the list is reconciled with the
    /// screen at most every `reconcileInterval` (reading the screen's text
    /// takes the surface lock and walks the scrollback; per output frame it
    /// would cost the main thread under a flood).
    private func scheduleReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        let wait = max(0, Self.reconcileInterval - (CACurrentMediaTime() - lastReconcile))
        Task { @MainActor [weak self] in
            if wait > 0 { try? await ContinuousClock().sleep(for: .seconds(wait)) }
            guard let self else { return }
            reconcilePending = false
            lastReconcile = CACurrentMediaTime()
            if showArtifacts { reconcileArtifactsWithScreen() }
        }
    }

    static let reconcileInterval: CFTimeInterval = 0.5
    @ObservationIgnored private var lastReconcile: CFTimeInterval = 0

    var composerPlaceholder: String {
        directTyping ? "Typing into terminal" : "Send to \(programName)"
    }

    // MARK: Actions

    /// The always-visible keyboard button: hide, or show for the last input target.
    public func toggleKeyboard() {
        if keyboardVisible {
            controller?.hideKeyboard()
        } else if isTUI || directTyping {
            controller?.focusTerminal()
        } else {
            focusComposer()
        }
    }

    public func hideKeyboard() {
        controller?.hideKeyboard()
    }

    /// Opens the files-and-links sheet.
    public func showFilesAndLinks() {
        showArtifacts = true
    }

    public func paste() {
        controller?.surface.paste(nil)
    }

    /// Ctrl-<letter> to the program (`c` interrupts, `l` clears).
    public func sendControl(_ letter: Character) {
        keyBar(.chord(letter))
    }

    #if DEBUG
    /// DEBUG: the controller's layout and viewport state, for demo timelines.
    public var debugState: String { controller?.debugState ?? "-" }
    #endif

    /// Refreshes `snapshot` from the live page (the grid is about to show it).
    public func captureSnapshot() {
        if let image = controller?.snapshot() { snapshot = image }
    }

    public func focusComposer() {
        directTyping = false
        // The field may not exist yet (a new tab whose page just appeared):
        // it then takes focus once it is in a window.
        composerFocusOnAppear = true
        composerFocusRequest += 1
    }

    /// The send button: text plus Return; empty is a bare Return (Enter).
    /// With attachments, each is uploaded to the Mac first, then the real
    /// paths (shell-quoted) and the text are typed without Return, so the
    /// person finishes the command line before running it.
    public func send() {
        guard attachments.isEmpty else {
            sendAttachments()
            return
        }
        controller?.surface.sendText(composerText, pressReturn: true)
        composerText = ""
    }

    public func sendWithoutReturn() {
        guard attachments.isEmpty else {
            sendAttachments()
            return
        }
        controller?.surface.sendText(composerText, pressReturn: false)
        composerText = ""
    }

    private func sendAttachments() {
        guard !isUploading else { return }
        guard let uploader else {
            attachmentError = "Connect to the Mac to send attachments."
            return
        }
        let pending = attachments
        isUploading = true
        attachmentError = nil
        uploadTask = Task { [weak self] in
            var paths: [String] = []
            for attachment in pending {
                do {
                    let data = try attachment.contents()
                    paths.append(try await uploader(data, attachment.name))
                } catch {
                    guard let self else { return }
                    self.isUploading = false
                    self.attachmentError = "Couldn't send \(attachment.name): \(Self.message(error))"
                    return
                }
            }
            guard let self else { return }
            self.isUploading = false
            let line = Self.commandLine(paths: paths, text: self.composerText)
            self.controller?.surface.sendText(line, pressReturn: false)
            self.composerText = ""
            self.attachments.removeAll { attachment in pending.contains { $0.id == attachment.id } }
        }
    }

    static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// The typed line: each path shell-quoted, then the text.
    static func commandLine(paths: [String], text: String) -> String {
        let quoted = paths.map(shellQuoted).joined(separator: " ")
        guard !text.isEmpty else { return quoted + " " }
        return quoted + " " + text
    }

    /// A path as one shell word: bare when it has only safe characters, else single-quoted.
    static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%")
        if !path.isEmpty, path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func addAttachment(_ attachment: ComposerAttachment) {
        attachments.append(attachment)
    }

    func removeAttachment(_ id: ComposerAttachment.ID) {
        attachments.removeAll { $0.id == id }
        if attachments.isEmpty { attachmentError = nil }
    }

    func clearAttachmentError() { attachmentError = nil }

    // MARK: Key bar

    func keyBar(_ key: KeyBarKey) {
        guard let surface = controller?.surface else { return }
        switch key {
        case .escape: surface.sendKey(usage: TerminalHIDUsage.escape)
        case .tab: surface.sendKey(usage: TerminalHIDUsage.tab)
        case .shiftTab: surface.sendKey(usage: TerminalHIDUsage.tab, mods: .shift)
        case .control: surface.tapSticky(.control)
        case .alternate: surface.tapSticky(.alternate)
        case .up: surface.sendKey(usage: TerminalHIDUsage.up)
        case .down: surface.sendKey(usage: TerminalHIDUsage.down)
        case .left: surface.sendKey(usage: TerminalHIDUsage.left)
        case .right: surface.sendKey(usage: TerminalHIDUsage.right)
        case .chord(let letter): surface.sendControl(letter)
        case .symbol(let text): surface.perform(surface.input.insertText(text))
        case .paste: surface.paste(nil)
        case .hideKeyboard: controller?.hideKeyboard()
        }
        sticky = surface.input.sticky
    }

    func joystick(_ direction: JoystickDirection) {
        keyBar(direction.key)
    }

    // MARK: Scrolling

    public func scrollToBottom() {
        controller?.scrollToBottom(animated: true)
    }
}

/// A photo, video or file waiting in the composer, with its bytes (or the
/// local file holding them) to upload.
public struct ComposerAttachment: Identifiable, Sendable {
    public enum Kind: Sendable { case image, video, file }
    public let id = UUID()
    public var kind: Kind
    public var name: String
    public var thumbnail: UIImage?
    public var byteCount: Int?
    public var data: Data?
    /// A local copy (picked videos), read at send.
    public var fileURL: URL?

    public init(kind: Kind, name: String, thumbnail: UIImage? = nil, byteCount: Int? = nil, data: Data? = nil, fileURL: URL? = nil) {
        self.kind = kind
        self.name = name
        self.thumbnail = thumbnail
        self.byteCount = byteCount ?? data?.count
        self.data = data
        self.fileURL = fileURL
    }

    struct Unreadable: Error, LocalizedError {
        var errorDescription: String? { "its contents couldn't be read on this iPhone" }
    }

    func contents() throws -> Data {
        if let data { return data }
        if let fileURL { return try Data(contentsOf: fileURL, options: .mappedIfSafe) }
        throw Unreadable()
    }
}
#endif
