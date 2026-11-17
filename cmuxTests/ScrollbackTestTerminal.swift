import AppKit
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A real Ghostty terminal with an in-memory PTY peer and observable input bytes.
@MainActor
final class ScrollbackTestTerminal {
    let surface: TerminalSurface
    let view: GhosttyNSView
    let window: NSWindow
    private let inputs: AsyncStream<TerminalManualInput>
    private let continuation: AsyncStream<TerminalManualInput>.Continuation

    /// `ioMode: .manual` also delivers parser-generated replies (DSR, CSI 996)
    /// to the input stream; `.manualMirror` suppresses them.
    /// `pinsOnScreenOcclusion` reports `.visible` occlusion so the renderer
    /// presents even when the headless app-host process is not the active
    /// app: the window server then never sets `.visible` and the window never
    /// becomes key.
    init(
        initialInput: String? = nil,
        ioMode: TerminalSurfaceIOMode = .manualMirror,
        pinsOnScreenOcclusion: Bool = false
    ) throws {
        _ = NSApplication.shared
        let pair = AsyncStream<TerminalManualInput>.makeStream()
        inputs = pair.stream
        continuation = pair.continuation
        let sink = continuation
        surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialInput: initialInput,
            focusPlacement: .rightSidebarDock,
            ioMode: ioMode,
            manualInputHandler: { sink.yield($0) }
        )
        view = surface.hostedView.surfaceView
        let windowClass: NSWindow.Type = pinsOnScreenOcclusion ? OnScreenScrollbackTestWindow.self : NSWindow.self
        window = windowClass.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        surface.hostedView.frame = content.bounds
        content.addSubview(surface.hostedView)
        window.orderFront(nil)
        content.layoutSubtreeIfNeeded()
        surface.hostedView.setVisibleInUI(true)
        surface.hostedView.setActive(true)
    }

    func start() async throws {
        try await launch()
        try output("\u{1b}c" + (1...240).map { "history-\($0)\r\n" }.joined())
        let geometry = try scrollbar()
        #expect(geometry.total > geometry.len)
    }

    /// Starts the runtime surface without writing any terminal output.
    func launch() async throws {
        if !surface.hasLiveSurface {
            let ready = AsyncStream<Void> { sink in
                surface.onRuntimeReady = {
                    sink.yield()
                    sink.finish()
                }
            }
            surface.requestInputDemandSurfaceStartIfNeeded()
            for await _ in ready { break }
            surface.onRuntimeReady = nil
        }
        let runtime = try #require(surface.surface, "This regression requires a real Ghostty surface")
        #expect(window.makeFirstResponder(view))
        ghostty_surface_mouse_pos(runtime, 50, 50, GHOSTTY_MODS_NONE)
    }

    func close() {
        surface.hostedView.removeFromSuperview()
        // Manual IO: no shell and no TTY, so nothing to kill first.
        surface.teardownSurface()
        continuation.finish()
        window.orderOut(nil)
        window.close()
    }

    func output(_ text: String) throws {
        let runtime = try #require(surface.surface)
        text.withCString { ghostty_surface_process_output(runtime, $0, UInt(text.utf8.count)) }
    }

    /// Writes raw bytes, which need not be valid UTF-8, as program output.
    func output(_ bytes: Data) throws {
        let runtime = try #require(surface.surface)
        let characters = bytes.map { CChar(bitPattern: $0) }
        characters.withUnsafeBufferPointer {
            ghostty_surface_process_output(runtime, $0.baseAddress, UInt($0.count))
        }
    }

    func scrollbar() throws -> ghostty_surface_scrollbar_s {
        let runtime = try #require(surface.surface)
        var result = ghostty_surface_scrollbar_s()
        #expect(ghostty_surface_scrollbar(runtime, &result))
        return result
    }

    func wheel(up: Bool = true, precise: Bool = false) throws {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 1,
            wheel1: up ? 120 : -120,
            wheel2: 0,
            wheel3: 0
        ))
        // Exercise the same native view entrypoint as AppKit, including the
        // synchronous authoritative scrollbar response used by the wrapper.
        view.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    }

    func page(up: Bool) throws {
        let character = String(UnicodeScalar(up ? NSPageUpFunctionKey : NSPageDownFunctionKey)!)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.function, .numericPad],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: up ? 116 : 121
        ))
        view.keyDown(with: event)
    }

    func selectCopyModeLine() throws {
        let runtime = try #require(surface.surface)
        var column: UInt16 = 0
        var row: UInt16 = 0
        var width: UInt16 = 0
        #expect(ghostty_surface_keyboard_copy_selection_start(
            runtime, true, 1, &column, &row, &width
        ))
        #expect(ghostty_surface_has_selection(runtime))
    }

    /// Reads input bytes until `isComplete` holds for everything read so far.
    /// Parser replies (DSR, CSI 996) reach the PTY peer from Ghostty's IO
    /// thread, after a barrier written with `ghostty_surface_text`, so wait for
    /// the reply itself rather than a barrier.
    func inputBytes(until isComplete: (Data) -> Bool) async -> Data {
        var bytes = Data()
        for await input in inputs {
            guard case let .bytes(chunk) = input else {
                Issue.record("Unexpected transport-owned named key")
                continue
            }
            bytes.append(chunk)
            if isComplete(bytes) { return bytes }
        }
        Issue.record("The terminal I/O peer ended before the expected input")
        return bytes
    }

    /// The I/O mailbox orders this marker after earlier wheel/key writes.
    /// Awaiting its callback proves absence of leaked input without a settling sleep.
    func inputBeforeBarrier() async throws -> String {
        String(decoding: try await inputBytesBeforeBarrier(), as: UTF8.self)
    }

    /// The exact bytes written to the PTY peer before the barrier, including
    /// startup input, which Ghostty writes before any later input.
    func inputBytesBeforeBarrier(orderedManualInput: Bool = false) async throws -> Data {
        let runtime = try #require(surface.surface)
        let marker = "CMUX_SCROLL_BARRIER_\(UUID().uuidString)"
        if orderedManualInput {
            #expect(surface.enqueueManualInputBytes(Data(marker.utf8)))
        } else {
            marker.withCString { ghostty_surface_text(runtime, $0, UInt(marker.utf8.count)) }
        }
        var bytes = Data()
        for await input in inputs {
            guard case let .bytes(chunk) = input else {
                Issue.record("Unexpected transport-owned named key")
                continue
            }
            bytes.append(chunk)
            if let range = bytes.range(of: Data(marker.utf8)) {
                return Data(bytes[..<range.lowerBound])
            }
        }
        Issue.record("The terminal I/O peer ended before the barrier")
        return bytes
    }
}

/// Reports the occlusion state an on-screen window has in the running app;
/// see `OnScreenTestWindow` in SimulatorPanelThemeTests.swift.
private final class OnScreenScrollbackTestWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { .visible }
}
