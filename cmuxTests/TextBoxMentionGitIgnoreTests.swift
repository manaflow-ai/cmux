import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Text box mention Git ignore")
struct TextBoxMentionGitIgnoreTests {
    @Test
    func closedInputPipeReturnsFailureWithoutRaisingSIGPIPE() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()

        let didWrite = TextBoxGitIgnoreResolver().writeInput(
            Data("Sources\nSources/\n".utf8),
            to: pipe.fileHandleForWriting
        )

        #expect(!didWrite)
    }

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

        let gitInit = Process()
        gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitInit.arguments = ["-C", root.path, "init", "--quiet"]
        gitInit.standardOutput = FileHandle.nullDevice
        gitInit.standardError = FileHandle.nullDevice
        try gitInit.run()
        gitInit.waitUntilExit()
        #expect(gitInit.terminationStatus == 0)

        // rev-parse still recognizes this as a worktree, while check-ignore exits
        // before reading stdin because it must parse the corrupt index first.
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
