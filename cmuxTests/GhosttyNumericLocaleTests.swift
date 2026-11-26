import AppKit
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The embedded Ghostty runtime must not leave AppKit's numeric locale on a
/// comma-decimal setting, which makes CoreUI's symbol rasterizer unstable on
/// macOS 27.
@Suite("Ghostty numeric locale", .serialized)
struct GhosttyNumericLocaleTests {
    @Test
    /// Pins the process numeric locale without changing the user's other locale settings.
    func pinsNumericLocaleForAppKit() {
        let previous = setlocale(LC_NUMERIC, nil).map { String(cString: $0) }
        defer {
            if let previous {
                _ = setlocale(LC_NUMERIC, previous)
            }
        }

        guard setlocale(LC_NUMERIC, "de_DE.UTF-8") != nil else {
            Issue.record("de_DE.UTF-8 is unavailable on this macOS runner")
            return
        }
        let didPin = GhosttyNumericLocaleController().pinProcessNumericLocale()

        #expect(didPin)
        guard let current = setlocale(LC_NUMERIC, nil) else {
            Issue.record("LC_NUMERIC could not be queried after pinning")
            return
        }
        #expect(String(cString: current) == "C")
    }

    @Test @MainActor
    /// Confirms AppKit can rasterize a system symbol after numeric locale pinning.
    func pinnedLocaleMaterializesSystemSymbol() throws {
        let previous = setlocale(LC_NUMERIC, nil).map { String(cString: $0) }
        defer {
            if let previous {
                _ = setlocale(LC_NUMERIC, previous)
            }
        }

        guard setlocale(LC_NUMERIC, "de_DE.UTF-8") != nil else {
            Issue.record("de_DE.UTF-8 is unavailable on this macOS runner")
            return
        }
        GhosttyNumericLocaleController().pinProcessNumericLocale()

        let image = try #require(NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil))
        var rect = NSRect(x: 0, y: 0, width: 16, height: 16)
        #expect(image.cgImage(forProposedRect: &rect, context: nil, hints: nil) != nil)
    }
}
