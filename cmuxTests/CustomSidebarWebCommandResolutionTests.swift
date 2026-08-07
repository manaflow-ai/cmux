import CmuxFoundation
import CmuxSwiftRenderUI
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Covers the two resolutions every `cmux sidebar` subcommand depends on.
///
/// `select` and `open` take a name and need a file; `validate` and `reload` take a name and need a
/// report. When those two disagreed — the picker resolving four extensions, the validator only two —
/// an HTML sidebar rendered from the rail while the CLI reported it missing, and `open` had no file
/// to mount. Both are asserted against the same directory here so they cannot drift apart again.
@Suite("Custom sidebar web-source command resolution")
@MainActor
struct CustomSidebarWebCommandResolutionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-web-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to directory: URL, as name: String) throws {
        try contents.write(
            to: directory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    /// The file `select` / `open` would mount for a name.
    private func resolvedFile(_ name: String, in directory: URL) -> URL? {
        CmuxExtensionSidebarSelection.customSidebarFileURL(forName: name, sidebarsDirectory: directory)
    }

    @Test("an html sidebar resolves to a file the open path can mount")
    func htmlResolvesForOpen() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html><title>Board</title>", to: dir, as: "board.html")

        #expect(resolvedFile("board", in: dir)?.lastPathComponent == "board.html")
    }

    @Test("a url sidebar resolves to a file the open path can mount")
    func urlResolvesForOpen() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("http://127.0.0.1:8787/\n", to: dir, as: "board.url")

        #expect(resolvedFile("board", in: dir)?.lastPathComponent == "board.url")
    }

    // The bug in one assertion: the same name, the same directory, resolved by the command path and
    // by the validation path, must land on the same file.
    @Test(
        "select/open resolution and validation agree on the same file",
        arguments: ["board.swift", "board.json", "board.html", "board.url"]
    )
    func resolutionAgreesWithValidation(file: String) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        switch (file as NSString).pathExtension {
        case "swift": try write("Text(\"Swift\")", to: dir, as: file)
        case "json": try write(#"{"version":1,"root":{"type":"text","text":"J"}}"#, to: dir, as: file)
        case "html": try write("<!doctype html>", to: dir, as: file)
        default: try write("http://127.0.0.1:8787/\n", to: dir, as: file)
        }

        let commandFile = resolvedFile("board", in: dir)
        let report = CustomSidebarValidator().validate(directory: dir, name: "board")

        #expect(commandFile?.lastPathComponent == file)
        #expect(report.entries.first?.fileURL.lastPathComponent == file)
        #expect(report.validCount == 1)
    }

    @Test("both paths honour interpreted precedence when several files share a name")
    func precedenceAgrees() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Text(\"Swift\")", to: dir, as: "board.swift")
        try write("<!doctype html>", to: dir, as: "board.html")
        try write("http://127.0.0.1:8787/\n", to: dir, as: "board.url")

        #expect(resolvedFile("board", in: dir)?.lastPathComponent == "board.swift")
        #expect(
            CustomSidebarValidator().validate(directory: dir, name: "board")
                .entries.first?.fileURL.lastPathComponent == "board.swift"
        )
    }

    // `select` and `open` refuse a sidebar whose report carries an error, so a `.url` naming an
    // unloadable target has to fail validation rather than mounting a pane that renders nothing.
    @Test("a url sidebar naming an unloadable target fails the check select and open gate on")
    func unloadableURLBlocksSelect() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("file:///etc/passwd\n", to: dir, as: "board.url")

        let report = CustomSidebarValidator().validate(directory: dir, name: "board")

        // Resolvable as a file — so the picker lists it — but not valid, which is the state the
        // command layer turns into a message instead of an empty pane.
        #expect(resolvedFile("board", in: dir)?.lastPathComponent == "board.url")
        #expect(report.entries.first?.isValid == false)
    }

    @Test("a web sidebar classifies as a web source so the pane renders it as a page")
    func webSidebarClassifiesForPaneRendering() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html>", to: dir, as: "board.html")
        let fileURL = try #require(resolvedFile("board", in: dir))

        guard case .web = CustomSidebarSource.classify(fileURL: fileURL) else {
            Issue.record("An .html sidebar must classify as a web source, not fall to the interpreter.")
            return
        }
    }
}
