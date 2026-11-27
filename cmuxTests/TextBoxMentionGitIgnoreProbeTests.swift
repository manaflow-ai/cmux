import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Text box mention Git ignore probe")
struct TextBoxMentionGitIgnoreProbeTests {
    @Test
    func fileSuggestionsSurviveGitIgnoreClosingItsInputPipe() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-git-ignore-broken-pipe-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "struct VisibleNeedle {}".write(
            to: sourceDirectory.appendingPathComponent("VisibleNeedle.swift"),
            atomically: true,
            encoding: .utf8
        )

        // Fill each probe batch beyond a normal pipe buffer. This makes the
        // parent observe the child closing stdin instead of winning the race
        // by buffering its entire write before Git exits.
        for index in 0..<256 {
            let prefix = String(format: "probe-%03d-", index)
            let directoryName = prefix + String(repeating: "x", count: 255 - prefix.utf8.count)
            try fileManager.createDirectory(
                at: root.appendingPathComponent(directoryName, isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        let gitInit = Process()
        gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitInit.arguments = ["-C", root.path, "init", "--quiet"]
        gitInit.standardInput = FileHandle.nullDevice
        gitInit.standardOutput = FileHandle.nullDevice
        gitInit.standardError = FileHandle.nullDevice
        try gitInit.run()
        gitInit.waitUntilExit()
        #expect(gitInit.terminationStatus == 0)

        // rev-parse still recognizes the worktree, but check-ignore exits 128
        // before consuming stdin because it must parse the corrupt index.
        try Data("corrupt index".utf8).write(to: root.appendingPathComponent(".git/index"))

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 14),
                query: "VisibleNeedle",
                trigger: "@"
            ),
            rootDirectory: root.path
        )

        #expect(suggestions.contains { $0.title == "@Sources/VisibleNeedle.swift" })
    }
}
