import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Back-compat + new-schema coverage for `DockControlDefinition` decoding.
///
/// The Dock now reuses the main-area panel system (terminals *and* browsers),
/// so the config schema gained an optional `type`/`url`. Existing terminal-only
/// `dock.json` files must keep decoding unchanged.
@Suite("Dock control definition decoding")
struct DockControlDefinitionDecodingTests {
    private func decode(_ json: String) throws -> DockControlDefinition {
        try JSONDecoder().decode(DockControlDefinition.self, from: Data(json.utf8))
    }

    @Test("Legacy terminal config decodes unchanged")
    func legacyTerminalDecodes() throws {
        let control = try decode(#"{"id":"git","title":"Git","command":"lazygit","cwd":".","height":300}"#)
        #expect(control.id == "git")
        #expect(control.title == "Git")
        #expect(control.kind == .terminal)
        #expect(control.command == "lazygit")
        #expect(control.url == nil)
        #expect(control.cwd == ".")
        #expect(control.height == 300)
    }

    @Test("Terminal config without a title falls back to id")
    func terminalTitleFallsBackToId() throws {
        let control = try decode(#"{"id":"logs","command":"tail -f log"}"#)
        #expect(control.title == "logs")
        #expect(control.kind == .terminal)
    }

    @Test("Terminal config missing command throws")
    func terminalMissingCommandThrows() {
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"git","title":"Git"}"#)
        }
    }

    @Test("Browser config decodes with url and no command")
    func browserDecodes() throws {
        let control = try decode(#"{"id":"docs","title":"Docs","type":"browser","url":"https://example.com"}"#)
        #expect(control.id == "docs")
        #expect(control.kind == .browser)
        #expect(control.url == "https://example.com")
        #expect(control.command == nil)
    }

    @Test("Browser config missing url throws")
    func browserMissingURLThrows() {
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"docs","type":"browser"}"#)
        }
    }

    @Test("Unknown control type throws")
    func unknownTypeThrows() {
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"x","type":"markdown","command":"echo"}"#)
        }
    }

    @Test("Blank id throws")
    func blankIDThrows() {
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"   ","command":"echo"}"#)
        }
    }

    @Test("Terminal entries re-encode without a type key (stable trust fingerprint)")
    func terminalReencodeOmitsType() throws {
        let control = DockControlDefinition(id: "git", title: "Git", command: "lazygit", height: 300)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(data: try encoder.encode(control), encoding: .utf8) ?? ""
        #expect(!encoded.contains("\"type\""))
        #expect(!encoded.contains("\"url\""))
        #expect(encoded.contains("\"command\":\"lazygit\""))
    }

    @Test("Browser entries re-encode with type and url")
    func browserReencodeIncludesTypeAndURL() throws {
        let control = DockControlDefinition(
            id: "docs",
            title: "Docs",
            kind: .browser,
            url: "https://example.com"
        )
        let encoded = String(data: try JSONEncoder().encode(control), encoding: .utf8) ?? ""
        #expect(encoded.contains("\"type\""))
        #expect(encoded.contains("\"url\""))
    }

    @Test("Mixed terminal + browser config file decodes")
    func mixedConfigFileDecodes() throws {
        let json = #"""
        {
          "controls": [
            {"id": "git", "title": "Git", "command": "lazygit"},
            {"id": "docs", "title": "Docs", "type": "browser", "url": "https://example.com"}
          ]
        }
        """#
        let file = try JSONDecoder().decode(DockConfigFile.self, from: Data(json.utf8))
        #expect(file.controls.count == 2)
        #expect(file.controls[0].kind == .terminal)
        #expect(file.controls[1].kind == .browser)
        #expect(file.controls[1].url == "https://example.com")
    }
}
