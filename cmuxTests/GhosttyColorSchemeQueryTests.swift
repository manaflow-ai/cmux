import AppKit
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `CSI ? 996 n` asks the terminal for its color scheme. A surface cmux has
/// marked dark must answer `CSI ? 997 ; 1 n`, also when its config uses a
/// plain (non light:/dark:) theme, which is what cmux always hands Ghostty.
/// https://github.com/manaflow-ai/cmux/issues/14155
@MainActor
@Suite("Ghostty CSI 996 color-scheme query", .serialized)
struct GhosttyColorSchemeQueryTests {
    @Test func darkSurfaceWithPlainThemeReportsDark() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            // A plain dark theme, as cmux's resolved theme override produces.
            // A fresh config keeps the runner's own Ghostty config out.
            let config = try #require(ghostty_config_new())
            let contents = """
            background = #0d0d17
            foreground = #e0e0e0

            """
            contents.withCString { pointer in
                ghostty_config_load_string(
                    config,
                    pointer,
                    UInt(contents.utf8.count),
                    "/__cmux_test__/color-scheme-query.conf"
                )
            }
            ghostty_config_finalize(config)
            defer { ghostty_config_free(config) }

            // Manual IO, not mirror: a mirror suppresses terminal replies.
            let terminal = try ScrollbackTestTerminal(ioMode: .manual)
            defer { terminal.close() }
            try await terminal.launch()
            let runtime = try #require(terminal.surface.surface)

            GhosttyApp.shared.suppressGhosttyReloadActions {
                ghostty_surface_update_config(runtime, config)
            }
            // The config change makes cmux re-push its own app-wide scheme
            // asynchronously (the runner's theme, often light). Let that land
            // before this test pushes the scheme for its dark theme.
            await Self.drainMainQueue()

            // cmux's own scheme push, as for a dark cmux theme. Light first so
            // the dark push is a real change. Suppress the reload it requests,
            // which would re-push the runner's scheme.
            let hostedView = terminal.surface.hostedView
            GhosttyApp.shared.suppressGhosttyReloadActions {
                hostedView.reapplySurfaceColorSchemeAfterGhosttyConfigReload(preferredColorScheme: .light)
                hostedView.reapplySurfaceColorSchemeAfterGhosttyConfigReload(preferredColorScheme: .dark)
            }
            _ = try await terminal.inputBytesBeforeBarrier()

            try terminal.output("\u{1b}[?996n")
            let reply = await terminal.inputBytes(until: Self.containsColorSchemeReport)
            #expect(
                reply == Data("\u{1b}[?997;1n".utf8),
                "CSI 996 on a dark surface replied \(Self.printable(reply))"
            )
        }
    }

    /// Returns after every block already queued on the main queue has run.
    private static func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// True once `bytes` hold a whole `CSI ? 997 ; Ps n` reply.
    private static func containsColorSchemeReport(_ bytes: Data) -> Bool {
        guard let start = bytes.range(of: Data("\u{1b}[?997;".utf8)) else { return false }
        return bytes[start.upperBound...].contains(UInt8(ascii: "n"))
    }

    private static func printable(_ bytes: Data) -> String {
        String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{1b}", with: "ESC")
    }
}
