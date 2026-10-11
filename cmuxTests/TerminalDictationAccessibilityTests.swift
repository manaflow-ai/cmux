import AppKit
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Third-party dictation tools (Typeless, Wispr Flow, Superwhisper, Willow)
/// insert through the terminal's accessibility element and read `AXValue`
/// back to confirm the text landed.
///
/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/722,
/// https://github.com/manaflow-ai/cmux/issues/4953 and
/// https://github.com/manaflow-ai/cmux/issues/4153.
@MainActor
@Suite("Terminal dictation accessibility", .serialized, .timeLimit(.minutes(2)))
struct TerminalDictationAccessibilityTests {
    @Test("AX value exposes the terminal's active screen")
    func accessibilityValueShowsScreenText() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try DictationTerminalFixture()
            defer { fixture.close() }
            try await fixture.waitUntilReady()

            let value = try #require(fixture.view.accessibilityValue() as? String)
            #expect(value.contains(DictationTerminalFixture.readyMarker))
            let markerRange = (value as NSString).range(of: DictationTerminalFixture.readyMarker)
            #expect(fixture.view.accessibilityString(for: markerRange) == DictationTerminalFixture.readyMarker)
            #expect(fixture.view.accessibilityNumberOfCharacters() == (value as NSString).length)
        }
    }

    @Test("Setting AX selected text types it at the cursor")
    func selectedTextIsTyped() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try DictationTerminalFixture()
            defer { fixture.close() }
            try await fixture.waitUntilReady()
            let recorder = GhosttyKeyPressRecorder()
            defer { recorder.stop() }

            fixture.view.setAccessibilitySelectedText("dictated words")

            #expect(recorder.texts == ["dictated words"])
            #expect(recorder.textlessKeyCodes.isEmpty)
        }
    }

    @Test("Setting AX value to the value read plus an insertion types only the insertion")
    func splicedValueTypesOnlyTheInsertion() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try DictationTerminalFixture()
            defer { fixture.close() }
            try await fixture.waitUntilReady()

            let vended = try #require(fixture.view.accessibilityValue() as? String)
            try #require(vended.contains(DictationTerminalFixture.readyMarker))
            let recorder = GhosttyKeyPressRecorder()
            defer { recorder.stop() }

            fixture.view.setAccessibilityValue(vended + "spliced words")

            #expect(recorder.texts == ["spliced words"])
            #expect(recorder.textlessKeyCodes.isEmpty)
        }
    }

    @Test("Multi-line AX value arrives as one bracketed paste instead of one command per line")
    func multiLineValueIsPasted() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try DictationTerminalFixture()
            defer { fixture.close() }
            try await fixture.waitUntilReady()
            let recorder = GhosttyKeyPressRecorder()
            defer { recorder.stop() }

            fixture.view.setAccessibilityValue("first line\nsecond line")

            let received = try await fixture.receivedHex()
            let expected = Data("\u{1b}[200~first line\nsecond line\u{1b}[201~".utf8)
            #expect(received == expected.map { String(format: "%02x", $0) }.joined())
            #expect(!recorder.textlessKeyCodes.contains(36), "No line may be submitted with Return")
        }
    }

    @Test("A trailing newline after a multi-line AX value submits once, after the paste")
    func multiLineValueWithTrailingNewlineSubmitsOnce() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try DictationTerminalFixture()
            defer { fixture.close() }
            try await fixture.waitUntilReady()
            let recorder = GhosttyKeyPressRecorder()
            defer { recorder.stop() }

            fixture.view.setAccessibilityValue("first line\nsecond line\n")

            let received = try await fixture.receivedHex()
            let expected = Data("\u{1b}[200~first line\nsecond line\u{1b}[201~".utf8)
            #expect(received == expected.map { String(format: "%02x", $0) }.joined())
            #expect(recorder.textlessKeyCodes == [36], "The trailing newline is one Return")
        }
    }

    @Test("A Command chord another process posts does not type into the terminal")
    func foreignUnboundCommandChordIsDropped() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try DictationTerminalFixture()
            defer { fixture.close() }
            try await fixture.waitUntilReady()
            try #require(fixture.window.makeFirstResponder(fixture.view))

            let keyCodeC: UInt16 = 8
            let keyboardEvent = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .option],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: fixture.window.windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: keyCodeC
            ))
            // Superwhisper-style hotkey: the same Cmd+Option+C, posted by
            // another process (PID 1 is launchd, never this test host).
            try #require(!GhosttyNSView.isKeyEventPostedByAnotherProcess(keyboardEvent))
            let postedCGEvent = try #require(keyboardEvent.cgEvent)
            postedCGEvent.setIntegerValueField(.eventSourceUnixProcessID, value: 1)
            let postedEvent = try #require(NSEvent(cgEvent: postedCGEvent))
            try #require(postedEvent.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == 1)

            let recorder = GhosttyKeyPressRecorder()
            defer { recorder.stop() }

            #expect(fixture.view.performKeyEquivalentAfterMenuMiss(with: postedEvent))
            #expect(
                recorder.pressCount(keyCode: UInt32(keyCodeC)) == 0,
                "An unbound chord from another process must not reach the terminal program"
            )

            #expect(fixture.view.performKeyEquivalentAfterMenuMiss(with: keyboardEvent))
            #expect(
                recorder.pressCount(keyCode: UInt32(keyCodeC)) == 1,
                "The same chord from the keyboard still reaches the terminal"
            )
        }
    }
}

/// Records the key presses GhosttyNSView sends to the native surface.
@MainActor
private final class GhosttyKeyPressRecorder {
    private(set) var presses: [(keyCode: UInt32, text: String?)] = []
    private let previousObserver: ((ghostty_input_key_s) -> Void)?

    var texts: [String] { presses.compactMap { $0.text } }
    var textlessKeyCodes: [UInt32] { presses.filter { $0.text == nil }.map { $0.keyCode } }

    init() {
        previousObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { [weak self] keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            let text = keyEvent.text.map { String(cString: $0) }
            self?.presses.append((keyCode: keyEvent.keycode, text: text))
        }
    }

    func pressCount(keyCode: UInt32) -> Int {
        presses.filter { $0.keyCode == keyCode }.count
    }

    func stop() {
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousObserver
    }
}

/// Hosts a live terminal whose program turns on bracketed paste, prints a
/// marker and records the first paste it reads.
@MainActor
private final class DictationTerminalFixture {
    static let readyMarker = "AX_DICTATION_READY"

    let root: URL
    let receipt: URL
    let surface: TerminalSurface
    let window: NSWindow
    var view: GhosttyNSView { surface.hostedView.surfaceView }

    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ax-dictation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        receipt = root.appendingPathComponent("receipt.hex")
        let receiver = root.appendingPathComponent("receiver.py")
        try """
        import os, select, sys, termios, time, tty
        old = termios.tcgetattr(0)
        try:
            tty.setraw(0)
            os.write(1, b'\\x1b[?2004h\(Self.readyMarker)\\r\\n')
            data = b''
            deadline = time.monotonic() + 8
            while b'\\x1b[201~' not in data and time.monotonic() < deadline:
                if select.select([0], [], [], 0.1)[0]:
                    data += os.read(0, 65536)
            with open(sys.argv[1] + '.tmp', 'w') as receipt:
                receipt.write(data.hex())
            os.rename(sys.argv[1] + '.tmp', sys.argv[1])
            time.sleep(600)
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, old)
        """.write(to: receiver, atomically: true, encoding: .utf8)

        surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialCommand: "/usr/bin/python3 \(receiver.path.terminalShellEscaped) \(receipt.path.terminalShellEscaped)"
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let content = try #require(window.contentView)
        let hosted = surface.hostedView
        hosted.frame = content.bounds
        hosted.autoresizingMask = [.width, .height]
        content.addSubview(hosted)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        content.layoutSubtreeIfNeeded()
        hosted.setVisibleInUI(true)
        hosted.setActive(true)
        try #require(window.makeFirstResponder(hosted.surfaceView))
    }

    func waitUntilReady() async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while surface.readText(region: .screen)?.contains(Self.readyMarker) != true,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(surface.readText(region: .screen)?.contains(Self.readyMarker) == true)
    }

    /// Hex of the bytes the program read up to the end of the first paste,
    /// or everything it read in 8 s when no paste ended.
    func receivedHex() async throws -> String {
        let deadline = ContinuousClock.now + .seconds(15)
        while !FileManager.default.fileExists(atPath: receipt.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: receipt.path), Comment(rawValue:
            "No PTY receipt; screen=\(surface.readText(region: .screen) ?? "unavailable")"
        ))
        return try String(contentsOf: receipt, encoding: .utf8)
    }

    func close() {
        surface.teardownHostedSurfaceForTesting()
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
    }
}
