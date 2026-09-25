import XCTest
import AppKit
import CmuxTerminal
import GhosttyKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension DeadKeyCompositionRegressionTests {
    func exerciseDeadKeyInput(
        expectedOptionPreserved: Bool,
        expectedText: [String]
    ) async {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        _ = await AppKitTestEventPump().waitUntil(timeout: .seconds(5)) { surface.surface != nil }
        XCTAssertNotNil(surface.surface, "Expected native surface before dispatching dead-key input")

        guard let view = findGhosttyNSView(in: hostedView) else {
            XCTFail("Expected hosted GhosttyNSView")
            return
        }

        var interpretedKeyCodes: [UInt16] = []
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, events in
            guard candidateView === view, let event = events.first else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if [14, 32, 34, 45, 50].contains(Int(event.keyCode)) {
                interpretedKeyCodes.append(event.keyCode)
                XCTAssertEqual(
                    flags.contains(.option),
                    expectedOptionPreserved,
                    expectedOptionPreserved
                        ? "Auto-detected Option dead keys must preserve Option for AppKit composition"
                        : "An explicitly claimed Option side must show AppKit Ghostty's translated event"
                )
            }
            return false
        }

        var pressedText: [String] = []
        var pressedKeycodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            if let text = keyEvent.text {
                pressedText.append(String(cString: text))
            } else {
                pressedKeycodes.append(keyEvent.keycode)
            }
        }

        let deadKeyEvents: [(keyCode: UInt16, character: String)] = [
            (14, "e"), (32, "u"), (34, "i"), (45, "n"), (50, "`")
        ]
        let events = deadKeyEvents.enumerated().compactMap { index, item in
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option],
                timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.01,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: item.character,
                isARepeat: false,
                keyCode: item.keyCode
            )
        }
        guard events.count == deadKeyEvents.count else {
            XCTFail("Failed to create dead-key events")
            return
        }

        window.makeFirstResponder(view)
        withExtendedLifetime(surface) {
            events.forEach { view.keyDown(with: $0) }
        }

        XCTAssertEqual(interpretedKeyCodes, deadKeyEvents.map(\.keyCode))
        XCTAssertEqual(pressedText, expectedText)
        XCTAssertEqual(pressedKeycodes, [], "Dead-key handling must not leak raw key events")
    }

    func installOptionAsAltConfiguration(_ value: String?) -> () -> Void {
        guard let app = GhosttyApp.shared.app,
              let config = GhosttyApp.shared.config else {
            XCTFail("Expected Ghostty app configuration")
            return {}
        }

        let key = "macos-option-as-alt"
        let keyLength = UInt(key.utf8.count)
        var originalValue: UnsafePointer<Int8>?
        let hadOriginalValue = ghostty_config_get(config, &originalValue, key, keyLength)
        let original = hadOriginalValue ? originalValue.map { String(cString: $0) } : nil

        func apply(_ setting: String?) {
            let contents = setting.map { "\(key) = \($0)\n" } ?? "\(key) =\n"
            contents.withCString { pointer in
                ghostty_config_load_string(
                    config,
                    pointer,
                    UInt(contents.utf8.count),
                    "/__cmux_test__/option-as-alt.conf"
                )
            }
            ghostty_config_finalize(config)
            ghostty_app_update_config_without_surface_propagation(app, config)
        }

        apply(value)
        return { apply(original) }
    }
}
