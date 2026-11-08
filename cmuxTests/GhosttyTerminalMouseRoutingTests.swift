import AppKit
import CmuxTerminal
import Foundation
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Ghostty terminal mouse routing", .serialized)
struct GhosttyTerminalMouseRoutingTests {
    private struct SentButton: Equatable {
        let state: Int
        let button: Int
        let modifiers: Int
    }

    private final class RecordingSurfaceView: GhosttyNSView {
        private(set) var sentButtons: [SentButton] = []

        override func sendGhosttyMouseButton(
            _ surface: ghostty_surface_t,
            state: ghostty_input_mouse_state_e,
            button: ghostty_input_mouse_button_e,
            mods: ghostty_input_mods_e
        ) -> Bool {
            sentButtons.append(SentButton(
                state: Int(state.rawValue),
                button: Int(button.rawValue),
                modifiers: Int(mods.rawValue)
            ))
            return super.sendGhosttyMouseButton(
                surface,
                state: state,
                button: button,
                mods: mods
            )
        }

        func resetSentButtons() {
            sentButtons.removeAll(keepingCapacity: true)
        }
    }

    @Test("SGR mouse capture owns activation and stale-focus clicks")
    func sgrMouseCaptureOwnsActivationAndStaleFocusClicks() async throws {
#if DEBUG
        try await AppContextSerialGate.withExclusiveAppContext {
            let panel = TerminalPanel(
                workspaceId: UUID(),
                focusPlacement: .rightSidebarDock
            )
            await Self.startAndWaitForLiveSurface(panel.surface)
            let nativeSurface = try #require(panel.surface.surface)
            let window = Self.makeWindow()
            let surfaceView = RecordingSurfaceView(frame: window.contentLayoutRect)
            surfaceView.terminalSurface = panel.surface
            window.contentView?.addSubview(surfaceView)
            window.makeKeyAndOrderFront(nil)
            defer {
                panel.close()
                window.orderOut(nil)
                window.close()
            }

            #expect(!ghostty_surface_mouse_captured(nativeSurface))
            surfaceView.desiredFocus = false
            let plainDown = try Self.mouseEvent(
                type: .leftMouseDown,
                modifiers: [],
                window: window
            )
            let plainUp = try Self.mouseEvent(
                type: .leftMouseUp,
                modifiers: [],
                window: window
            )
            surfaceView.mouseDown(with: plainDown)
            surfaceView.mouseUp(with: plainUp)
            #expect(surfaceView.sentButtons.isEmpty)
            #expect(window.firstResponder === surfaceView)

            Self.setMouseReporting(enabled: true, on: nativeSurface)
            #expect(ghostty_surface_mouse_captured(nativeSurface))

            _ = window.makeFirstResponder(nil)
            surfaceView.desiredFocus = false
            let activationModifiers: NSEvent.ModifierFlags = [.shift, .control]
            let activationDown = try Self.mouseEvent(
                type: .leftMouseDown,
                modifiers: activationModifiers,
                window: window
            )
            let activationDrag = try Self.mouseEvent(
                type: .leftMouseDragged,
                modifiers: activationModifiers,
                window: window
            )
            let activationUp = try Self.mouseEvent(
                type: .leftMouseUp,
                modifiers: activationModifiers,
                window: window
            )
            surfaceView.mouseDown(with: activationDown)
            #expect(surfaceView.forwardPendingLeftMouseDrag(with: activationDrag))
            surfaceView.mouseUp(with: activationUp)
            Self.expectLeftClick(
                surfaceView.sentButtons,
                modifiers: activationModifiers
            )

            surfaceView.resetSentButtons()
            #expect(window.makeFirstResponder(surfaceView))
            surfaceView.desiredFocus = false
            let staleFocusModifiers: NSEvent.ModifierFlags = [.option]
            surfaceView.mouseDown(with: try Self.mouseEvent(
                type: .leftMouseDown,
                modifiers: staleFocusModifiers,
                window: window
            ))
            surfaceView.mouseUp(with: try Self.mouseEvent(
                type: .leftMouseUp,
                modifiers: staleFocusModifiers,
                window: window
            ))
            Self.expectLeftClick(
                surfaceView.sentButtons,
                modifiers: staleFocusModifiers
            )
        }
#else
        Issue.record("Ghostty terminal mouse routing coverage is only available in DEBUG")
#endif
    }

    private static func expectLeftClick(
        _ events: [SentButton],
        modifiers: NSEvent.ModifierFlags
    ) {
        let expectedModifiers = cmuxGhosttyMouseModsFromFlags(
            modifierFlagsRawValue: modifiers.rawValue
        )
        #expect(events == [
            SentButton(
                state: Int(GHOSTTY_MOUSE_PRESS.rawValue),
                button: Int(GHOSTTY_MOUSE_LEFT.rawValue),
                modifiers: Int(expectedModifiers.rawValue)
            ),
            SentButton(
                state: Int(GHOSTTY_MOUSE_RELEASE.rawValue),
                button: Int(GHOSTTY_MOUSE_LEFT.rawValue),
                modifiers: Int(expectedModifiers.rawValue)
            ),
        ])
    }

    private static func setMouseReporting(
        enabled: Bool,
        on surface: ghostty_surface_t
    ) {
        let suffix = enabled ? "h" : "l"
        let sequence = "\u{1B}[?1000\(suffix)\u{1B}[?1006\(suffix)"
        sequence.withCString { bytes in
            ghostty_surface_process_output(
                surface,
                bytes,
                UInt(sequence.utf8.count)
            )
        }
    }

    private static func startAndWaitForLiveSurface(
        _ surface: TerminalSurface
    ) async {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousOnRuntimeReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        surface.requestInputDemandSurfaceStartIfNeeded()
        for await _ in readiness { break }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        return window
    }

    private static func mouseEvent(
        type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags,
        window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 32, y: 32),
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}
