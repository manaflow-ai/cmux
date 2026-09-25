import AppKit
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalColorSchemeQueryTests {
    /// Verifies CSI 996 follows runtime appearance changes with a plain config.
    @Test("996 follows the runtime scheme with a nonconditional config", arguments: [true, false])
    func queryTracksRuntimeScheme(initiallyDark: Bool) async throws {
        // Initialize Ghostty's process-wide facilities through the app host.
        _ = try #require(GhosttyApp.shared.app)
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        let contents = "background = #0d0d17\nforeground = #ffffff"
        contents.withCString { text in
            "/__cmux_test__/color-scheme.conf".withCString { path in
                ghostty_config_load_string(config, text, UInt(contents.utf8.count), path)
            }
        }
        ghostty_config_finalize(config)
        #expect(ghostty_config_diagnostics_count(config) == 0)

        let pair = AsyncStream<Data>.makeStream()
        let sink = InputSink(continuation: pair.continuation)
        defer { pair.continuation.finish() }
        var callbacks = ghostty_runtime_config_s()
        callbacks.wakeup_cb = { _ in }
        // A reload notification may be coalesced by an embedder. Reporting must
        // follow appearance even without the callback reloading a conditional theme.
        callbacks.action_cb = { _, _, _ in true }
        callbacks.read_clipboard_cb = { _, _, _ in false }
        callbacks.confirm_read_clipboard_cb = { _, _, _, _ in }
        callbacks.write_clipboard_cb = { _, _, _, _, _ in }
        let app = try #require(ghostty_app_new(&callbacks, config))
        defer { ghostty_app_free(app) }
        ghostty_app_set_color_scheme(app, Self.scheme(dark: initiallyDark))

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.wantsLayer = true
        var options = ghostty_surface_config_new()
        options.platform_tag = GHOSTTY_PLATFORM_MACOS
        options.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        options.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        options.io_write_userdata = Unmanaged.passUnretained(sink).toOpaque()
        options.io_write_cb = { userdata, bytes, count in
            guard let userdata, let bytes else { return }
            Unmanaged<InputSink>.fromOpaque(userdata).takeUnretainedValue()
                .continuation.yield(Data(bytes: bytes, count: Int(count)))
        }
        let surface = try #require(ghostty_surface_new(app, &options))
        defer {
            ghostty_surface_free(surface)
            withExtendedLifetime((view, sink)) {}
        }

        // The first query covers inheritance before any surface callback.
        let initial = try await query(surface, inputs: pair.stream)
        print("996 initial=\(initial.map { String(format: "%02x", $0) }.joined())")
        #expect(initial.range(of: Self.report(dark: initiallyDark)) != nil)
        for dark in [true, false, true] {
            ghostty_surface_set_color_scheme(surface, Self.scheme(dark: dark))
            let actual = try await query(surface, inputs: pair.stream)
            print("996 transition=\(actual.map { String(format: "%02x", $0) }.joined())")
            #expect(actual.range(of: Self.report(dark: dark)) != nil)
            ghostty_surface_update_config(surface, config)
            // The same-scheme callback is intentionally a no-op. Reloading a
            // plain config must not reset the scheme used by the terminal parser.
            ghostty_surface_set_color_scheme(surface, Self.scheme(dark: dark))
            let reloaded = try await query(surface, inputs: pair.stream)
            print("996 reload=\(reloaded.map { String(format: "%02x", $0) }.joined())")
            #expect(reloaded.range(of: Self.report(dark: dark)) != nil)
        }
    }

    /// Converts the test's Boolean appearance state to Ghostty's C enum.
    private static func scheme(dark: Bool) -> ghostty_color_scheme_e {
        dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    /// Returns the CSI 997 reply expected for the supplied appearance state.
    private static func report(dark: Bool) -> Data {
        Data("\u{1b}[?997;\(dark ? 1 : 2)n".utf8)
    }

    /// Ghostty calls this immutable sink from its IO thread.
    private final class InputSink: Sendable {
        let continuation: AsyncStream<Data>.Continuation
        init(continuation: AsyncStream<Data>.Continuation) {
            self.continuation = continuation
        }
    }

    /// The input barrier orders assertions after all protocol replies without
    /// a settling delay. This exercises Ghostty's real parser and write path.
    /// Sends CSI 996 and a barrier, then returns bytes written before that barrier.
    private func query(_ surface: ghostty_surface_t, inputs: AsyncStream<Data>) async throws -> Data {
        let query = "\u{1b}[?996n"
        let marker = "CMUX_996_BARRIER_\(UUID().uuidString)"
        let markerBytes = Data(marker.utf8)

        // Ghostty's parser can wait on the renderer/IO futex. Keep the parser
        // and barrier write FIFO on a serial queue without blocking MainActor.
        let responseTask = Task {
            await withTaskGroup(of: Data?.self) { group in
                group.addTask {
                    var bytes = Data()
                    for await chunk in inputs {
                        bytes.append(chunk)
                        if let range = bytes.range(of: markerBytes) {
                            return Data(bytes[..<range.lowerBound])
                        }
                    }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.ioQueue.async {
                query.withCString {
                    ghostty_surface_process_output(surface, $0, UInt(query.utf8.count))
                }
                marker.withCString {
                    ghostty_surface_text(surface, $0, UInt(marker.utf8.count))
                }
                continuation.resume()
            }
        }
        let response = await responseTask.value
        return try #require(response, "The terminal did not return the input barrier")
    }

    private static let ioQueue = DispatchQueue(label: "com.cmux.tests.terminal-color-scheme-query")
}
