import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for `CmdClickTerminalEditorRouteSettings`, the route that
/// opens Cmd-clicked files of selected extensions in a terminal editor (nvim,
/// vim, helix, …). Verifies command resolution, extension parsing, the routing
/// gate, and the shell invocation builder.
@Suite struct TerminalEditorRouteSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "cmux-terminal-editor-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: resolvedCommand

    @Test func resolvedCommandDefaultsToNvimWhenUnset() {
        let defaults = makeDefaults()
        #expect(CmdClickTerminalEditorRouteSettings.resolvedCommand(defaults: defaults) == "nvim")
    }

    @Test func resolvedCommandIsNilForBlankCommand() {
        for raw in ["", "   ", "\n\t "] {
            let defaults = makeDefaults()
            defaults.set(raw, forKey: CmdClickTerminalEditorRouteSettings.commandKey)
            #expect(
                CmdClickTerminalEditorRouteSettings.resolvedCommand(defaults: defaults) == nil,
                "blank command \(raw.debugDescription) should disable the route"
            )
        }
    }

    @Test func resolvedCommandTrimsWhitespace() {
        let defaults = makeDefaults()
        defaults.set("  vim -R  \n", forKey: CmdClickTerminalEditorRouteSettings.commandKey)
        #expect(CmdClickTerminalEditorRouteSettings.resolvedCommand(defaults: defaults) == "vim -R")
    }

    // MARK: extensions parsing

    @Test func extensionsAreEmptyWhenUnset() {
        let defaults = makeDefaults()
        #expect(CmdClickTerminalEditorRouteSettings.extensions(defaults: defaults).isEmpty)
    }

    @Test func extensionsParseMixedSeparators() {
        let defaults = makeDefaults()
        defaults.set("rs, ts;py\nlua go", forKey: CmdClickTerminalEditorRouteSettings.extensionsKey)
        #expect(
            CmdClickTerminalEditorRouteSettings.extensions(defaults: defaults)
                == Set(["rs", "ts", "py", "lua", "go"])
        )
    }

    @Test func extensionsStripLeadingDotsAndLowercase() {
        let defaults = makeDefaults()
        defaults.set(".RS, .Ts, .PY", forKey: CmdClickTerminalEditorRouteSettings.extensionsKey)
        #expect(
            CmdClickTerminalEditorRouteSettings.extensions(defaults: defaults)
                == Set(["rs", "ts", "py"])
        )
    }

    // MARK: matchesExtension

    @Test func matchesExtensionRespectsTheList() {
        let defaults = makeDefaults()
        defaults.set("rs, ts", forKey: CmdClickTerminalEditorRouteSettings.extensionsKey)
        #expect(CmdClickTerminalEditorRouteSettings.matchesExtension("/proj/main.rs", defaults: defaults))
        #expect(CmdClickTerminalEditorRouteSettings.matchesExtension("/proj/App.TS", defaults: defaults))
        #expect(!CmdClickTerminalEditorRouteSettings.matchesExtension("/proj/README.md", defaults: defaults))
        #expect(!CmdClickTerminalEditorRouteSettings.matchesExtension("/proj/Makefile", defaults: defaults))
    }

    // MARK: wildcard ("*")

    @Test func wildcardMatchesCodeTextAndExtensionlessFiles() {
        let defaults = makeDefaults()
        defaults.set("*", forKey: CmdClickTerminalEditorRouteSettings.extensionsKey)
        for path in ["/p/main.rs", "/p/app.ts", "/p/data.json", "/p/server.log", "/p/Makefile", "/p/Dockerfile"] {
            #expect(
                CmdClickTerminalEditorRouteSettings.matchesExtension(path, defaults: defaults),
                "\(path) should match the * wildcard"
            )
        }
    }

    @Test func wildcardExcludesCmuxNativePreviewTypes() {
        let defaults = makeDefaults()
        defaults.set("*", forKey: CmdClickTerminalEditorRouteSettings.extensionsKey)
        for path in ["/p/README.md", "/p/doc.pdf", "/p/pic.png", "/p/img.JPEG", "/p/clip.mp4", "/p/song.mp3"] {
            #expect(
                !CmdClickTerminalEditorRouteSettings.matchesExtension(path, defaults: defaults),
                "\(path) should be excluded from the * wildcard"
            )
        }
    }

    @Test func wildcardCanBeOverriddenByExplicitExtension() {
        let defaults = makeDefaults()
        // Listing md explicitly alongside * forces Markdown into the terminal editor.
        defaults.set("*, md", forKey: CmdClickTerminalEditorRouteSettings.extensionsKey)
        #expect(CmdClickTerminalEditorRouteSettings.matchesExtension("/p/README.md", defaults: defaults))
    }

    @Test func wildcardShouldRouteRespectsExclusions() {
        let defaults = makeDefaults()
        defaults.set("*", forKey: CmdClickTerminalEditorRouteSettings.extensionsKey)
        let code = makeTempFile(extension: "ts")
        let md = makeTempFile(extension: "md")
        defer {
            try? FileManager.default.removeItem(at: code)
            try? FileManager.default.removeItem(at: md)
        }
        #expect(CmdClickTerminalEditorRouteSettings.shouldRoute(path: code.path, defaults: defaults))
        #expect(!CmdClickTerminalEditorRouteSettings.shouldRoute(path: md.path, defaults: defaults))
    }

    // MARK: editorInvocation

    @Test func editorInvocationQuotesPath() {
        let defaults = makeDefaults()
        defaults.set("nvim", forKey: CmdClickTerminalEditorRouteSettings.commandKey)
        #expect(
            CmdClickTerminalEditorRouteSettings.editorInvocation(forFile: "/a b/c.rs", defaults: defaults)
                == "nvim '/a b/c.rs'"
        )
    }

    @Test func editorInvocationEscapesSingleQuotes() {
        let defaults = makeDefaults()
        defaults.set("nvim", forKey: CmdClickTerminalEditorRouteSettings.commandKey)
        let result = CmdClickTerminalEditorRouteSettings.editorInvocation(
            forFile: "/weird/it's.rs",
            defaults: defaults
        )
        #expect(result == "nvim '/weird/it'\\''s.rs'")
    }

    @Test func editorInvocationIsNilWhenCommandBlank() {
        let defaults = makeDefaults()
        defaults.set("", forKey: CmdClickTerminalEditorRouteSettings.commandKey)
        #expect(CmdClickTerminalEditorRouteSettings.editorInvocation(forFile: "/a/b.rs", defaults: defaults) == nil)
    }

    // MARK: shouldRoute (the routing gate)

    @Test func shouldNotRouteWhenExtensionNotListed() {
        let defaults = makeDefaults()
        defaults.set("rs", forKey: CmdClickTerminalEditorRouteSettings.extensionsKey)
        // No filesystem probe needed: a non-matching extension is rejected early.
        #expect(!CmdClickTerminalEditorRouteSettings.shouldRoute(path: "/proj/notes.md", defaults: defaults))
    }

    @Test func shouldNotRouteWhenExtensionsEmpty() {
        let defaults = makeDefaults()
        let tmp = makeTempFile(extension: "rs")
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(!CmdClickTerminalEditorRouteSettings.shouldRoute(path: tmp.path, defaults: defaults))
    }

    @Test func shouldNotRouteWhenCommandBlank() {
        let defaults = makeDefaults()
        defaults.set("", forKey: CmdClickTerminalEditorRouteSettings.commandKey)
        defaults.set("rs", forKey: CmdClickTerminalEditorRouteSettings.extensionsKey)
        let tmp = makeTempFile(extension: "rs")
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(!CmdClickTerminalEditorRouteSettings.shouldRoute(path: tmp.path, defaults: defaults))
    }

    @Test func shouldRouteForListedReadableFile() {
        let defaults = makeDefaults()
        defaults.set("rs, ts", forKey: CmdClickTerminalEditorRouteSettings.extensionsKey)
        let tmp = makeTempFile(extension: "rs")
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(CmdClickTerminalEditorRouteSettings.shouldRoute(path: tmp.path, defaults: defaults))
    }

    @Test func shouldNotRouteForMissingFile() {
        let defaults = makeDefaults()
        defaults.set("rs", forKey: CmdClickTerminalEditorRouteSettings.extensionsKey)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-te-missing-\(UUID().uuidString).rs")
        #expect(!CmdClickTerminalEditorRouteSettings.shouldRoute(path: missing.path, defaults: defaults))
    }

    private func makeTempFile(extension ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-te-\(UUID().uuidString).\(ext)")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }
}
