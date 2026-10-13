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
    var sticky = TerminalStickyModifiers()

    // Composer
    public var composerText = ""
    var composerFocused = false
    /// Incremented to ask the composer field to take focus.
    var composerFocusRequest = 0
    public internal(set) var attachments: [ComposerAttachment] = []
    var showPhotoPicker = false
    var showFileImporter = false

    // Artifacts
    public internal(set) var artifacts: [TerminalArtifact] = []
    var showArtifacts = false
    var artifactPath: [TerminalArtifact] = []
    /// Previews of HTML and Markdown show their source.
    var previewShowsSource = false
    private var extractor = ArtifactExtractor()

    let joystickEngine = JoystickEngine()

    /// Set by the controller.
    weak var controller: TerminalViewController?

    public init(session: any TerminalSession, artifactSource: any ArtifactSource, title: String = "zsh") {
        self.session = session
        self.artifactSource = artifactSource
        self.title = title
        self.programName = session.programName
        joystickEngine.send = { [weak self] direction in self?.joystick(direction) }
    }

    func ingest(_ event: TerminalSessionEvent) {
        switch event {
        case .output(let data):
            let found = extractor.scan(data)
            if !found.isEmpty { artifacts.append(contentsOf: found) }
        case .alternateScreen(let on):
            isTUI = on
            programName = session.programName
        case .title(let text):
            title = text
            programName = session.programName
        case .exited:
            break
        }
    }

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

    public func focusComposer() {
        directTyping = false
        composerFocusRequest += 1
    }

    /// The send button: text plus Return; empty is a bare Return (Enter).
    public func send() {
        let paths = attachments.map(\.remotePath)
        var text = composerText
        if !paths.isEmpty {
            text = (paths.joined(separator: " ") + (text.isEmpty ? "" : " " + text))
        }
        controller?.surface.sendText(text, pressReturn: true)
        composerText = ""
        attachments.removeAll()
    }

    func sendWithoutReturn() {
        controller?.surface.sendText(composerText, pressReturn: false)
        composerText = ""
    }

    func addAttachment(_ attachment: ComposerAttachment) {
        attachments.append(attachment)
    }

    func removeAttachment(_ id: ComposerAttachment.ID) {
        attachments.removeAll { $0.id == id }
    }

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

/// A photo, video or file waiting in the composer.
public struct ComposerAttachment: Identifiable, Sendable {
    public enum Kind: Sendable { case image, video, file }
    public let id = UUID()
    public var kind: Kind
    public var name: String
    public var thumbnail: UIImage?
    public var byteCount: Int?

    public init(kind: Kind, name: String, thumbnail: UIImage? = nil, byteCount: Int? = nil) {
        self.kind = kind
        self.name = name
        self.thumbnail = thumbnail
        self.byteCount = byteCount
    }

    /// Where the upload lands on the Mac (the mock does not upload).
    var remotePath: String {
        "~/.cnx/uploads/" + name.replacingOccurrences(of: " ", with: "_")
    }
}
#endif
