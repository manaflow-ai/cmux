import CmuxFoundation
import CmuxSwiftRender
import CmuxSwiftRenderUI
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// What a resolved sidebar file gets mounted as, and specifically that a rejected `.url` gets
/// mounted as nothing.
///
/// Both hosting surfaces asked "web?" and treated the answer "no" as "interpreted". A `.url` file
/// naming an unloadable target answers "no" while being a web sidebar, so it fell into the
/// interpreted lane — which does not check extensions, decodes any unrecognised file as declarative
/// JSON, and runs its actions through the live dispatch. That is a privilege the web path had just
/// refused to grant the same file.
@Suite("Custom sidebar mount decision")
@MainActor
struct CustomSidebarMountDecisionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to directory: URL, as name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("a loopback .url mounts as a page")
    func loadableURLFileMountsAsWeb() async throws {
        let dir = try directory()
        let url = try write("http://127.0.0.1:8787/\n", to: dir, as: "board.url")

        #expect(
            await CustomSidebarMountDecision.deciding(fileURL: url)
                == .web(.remote(URL(string: "http://127.0.0.1:8787/")!))
        )
    }

    @Test("an .html document mounts as a page")
    func htmlMountsAsWeb() async throws {
        let dir = try directory()
        let url = try write("<!doctype html>", to: dir, as: "board.html")

        #expect(await CustomSidebarMountDecision.deciding(fileURL: url) == .web(.document(url)))
    }

    @Test("a .swift file mounts as interpreted")
    func swiftMountsAsInterpreted() async throws {
        let dir = try directory()
        let url = try write("Text(\"hi\")", to: dir, as: "board.swift")

        #expect(await CustomSidebarMountDecision.deciding(fileURL: url) == .interpreted(url))
    }

    // The finding, stated as behaviour: each of these is a `.url` the web path rejects, and none of
    // them may arrive at the interpreter — least of all the one whose bytes are valid sidebar DSL.
    @Test(
        "a rejected .url mounts as nothing rather than falling through to the interpreter",
        arguments: [
            "",
            "   \n\n",
            "ftp://example.com/board",
            "file:///etc/passwd",
            "http:",
            "https:///board",
            "javascript:alert(1)",
            "{\"version\":1,\"root\":{\"type\":\"text\",\"text\":\"pwn\"}}",
        ]
    )
    func rejectedURLFileMountsAsUnavailable(contents: String) async throws {
        let dir = try directory()
        let url = try write(contents, to: dir, as: "board.url")

        #expect(await CustomSidebarMountDecision.deciding(fileURL: url) == .unavailable)
    }

    @Test("an unrecognised extension mounts as nothing")
    func unknownExtensionMountsAsUnavailable() async throws {
        let dir = try directory()
        let url = try write("Text(\"hi\")", to: dir, as: "board.txt")

        #expect(await CustomSidebarMountDecision.deciding(fileURL: url) == .unavailable)
    }

    @Test("an uppercase extension mounts as nothing, matching the classifier")
    func uppercaseExtensionMountsAsUnavailable() async throws {
        let dir = try directory()
        let url = try write("<!doctype html>", to: dir, as: "board.HTML")

        #expect(await CustomSidebarMountDecision.deciding(fileURL: url) == .unavailable)
    }

    @Test("a name resolving to nothing mounts as nothing")
    func missingFileMountsAsUnavailable() async {
        #expect(await CustomSidebarMountDecision.deciding(fileURL: nil) == .unavailable)
    }

    /// The end-to-end claim: a rejected `.url` whose bytes are valid sidebar DSL never reaches a
    /// state the interpreter would render, so no action of its can ever be dispatched.
    @Test("a rejected .url carrying sidebar DSL never produces an interpreted render state")
    func rejectedURLFileNeverReachesInterpreter() async throws {
        let dir = try directory()
        let dsl = """
        {"version":1,"root":{"type":"text","text":"pwn"}}
        """
        let url = try write(dsl, to: dir, as: "board.url")

        #expect(await CustomSidebarMountDecision.deciding(fileURL: url) == .unavailable)

        // And even if something did hand the file straight to the model, the model refuses it
        // rather than decoding it as a sidebar document.
        let model = CustomSidebarModel(fileURL: url)
        model.reload()
        if case .json = model.state {
            Issue.record("a .url file was decoded as a declarative sidebar document")
        }
    }

    // MARK: - Deciding without reading

    /// The half a caller may run inline. Every extension whose kind follows from its name answers
    /// immediately; a `.url` answers `nil`, so a caller has no way to accidentally decide one from
    /// its name alone.
    @Test(
        "an extension-decided kind needs no filesystem access, and agrees with the full decision",
        arguments: [
            "board.swift",
            "board.json",
            "board.html",
            "board.txt",
            "board.HTML",
        ]
    )
    func decidedWithoutReadingAgrees(name: String) async throws {
        let dir = try directory()
        let url = try write("<!doctype html>", to: dir, as: name)
        let inline = CustomSidebarMountDecision.decidedWithoutReading(fileURL: url)

        #expect(inline != nil)
        #expect(inline == (await CustomSidebarMountDecision.deciding(fileURL: url)))

        // And the same answer without the file existing at all, which is what proves no read.
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/\(name)")
        #expect(CustomSidebarMountDecision.decidedWithoutReading(fileURL: missing) != nil)
    }

    @Test("a .url file cannot be decided without reading it")
    func urlFileCannotBeDecidedInline() throws {
        let dir = try directory()
        let url = try write("http://127.0.0.1:8787/\n", to: dir, as: "board.url")

        #expect(CustomSidebarMountDecision.decidedWithoutReading(fileURL: url) == nil)
    }
}
