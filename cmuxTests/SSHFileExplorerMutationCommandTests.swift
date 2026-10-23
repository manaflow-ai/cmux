import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Runs the generated SSH mutation commands through real local shells, the
/// way the remote login shell would receive them.
@Suite(.serialized)
struct SSHFileExplorerMutationCommandTests {
    /// A name with a quote, `$`, a leading `-` and a precomposed (NFC) letter.
    private static let hostileName = "-it's $HOME \u{E9}.txt"

    @Test
    func testCommandsWrapAQuotedShScriptWithoutRawUserText() {
        let path = "/home/dev/\(Self.hostileName)"
        let destination = "/home/dev/\(Self.hostileName) copy"
        let commands: [SSHFileExplorerMutationCommand] = [
            .createFile(path: path),
            .createDirectory(path: path),
            .rename(path: path, to: destination),
            .delete(path: path),
            .copy(path: path, to: destination),
        ]
        for mutation in commands {
            let command = mutation.command
            #expect(command.hasPrefix("sh -c '"))
            #expect(command.hasSuffix("'"))
            let script = command.dropFirst("sh -c '".count).dropLast()
            #expect(!script.contains("'"))
            #expect(!script.contains("\\"))
            #expect(!script.contains("!"))
            #expect(!script.contains("$HOME"))
            #expect(command.unicodeScalars.allSatisfy { $0.isASCII })
            #expect(script.contains(Data(path.utf8).base64EncodedString()))
        }

        let create = SSHFileExplorerMutationCommand.createFile(path: path).command
        #expect(create.contains("then exit 73; fi"))
        #expect(create.contains("set -C; : > \"$t\""))
        #expect(create.contains("[ -w \"$dir\" ] || exit 77"))
        #expect(SSHFileExplorerMutationCommand.createDirectory(path: path).command.contains("mkdir -- \"$t\""))
        #expect(SSHFileExplorerMutationCommand.rename(path: path, to: destination).command
            .contains("mv -n -- \"$s\" \"$t\""))
        #expect(SSHFileExplorerMutationCommand.delete(path: path).command.contains("rm -rf -- \"$t\""))
        #expect(SSHFileExplorerMutationCommand.copy(path: path, to: destination).command
            .contains("cp -R -p -- \"$s\" \"$t\""))
    }

    @Test
    func testCreateCommandsKeepExactNamesAndNeverTruncate() throws {
        for shell in Self.availableShells {
            let directory = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent(Self.hostileName).path

            #expect(try Self.run(.createFile(path: path), shell: shell) == 0)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(names.map(\.precomposedStringWithCanonicalMapping) == [Self.hostileName])

            try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
            #expect(try Self.run(.createFile(path: path), shell: shell) == 73)
            #expect(try Self.run(.createDirectory(path: path), shell: shell) == 73)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
        }
    }

    @Test
    func testRenameAndCopyCommandsRefuseExistingDestinations() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("a.txt").path
        let destination = directory.appendingPathComponent("b.txt").path
        try Data("a".utf8).write(to: URL(fileURLWithPath: source))
        try Data("b".utf8).write(to: URL(fileURLWithPath: destination))

        #expect(try Self.run(.rename(path: source, to: destination)) == 73)
        #expect(try Self.run(.copy(path: source, to: destination)) == 73)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "a")
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "b")

        let copyPath = directory.appendingPathComponent("a copy.txt").path
        #expect(try Self.run(.copy(path: source, to: copyPath)) == 0)
        #expect(try String(contentsOfFile: copyPath, encoding: .utf8) == "a")

        #expect(try Self.run(.delete(path: copyPath)) == 0)
        #expect(!FileManager.default.fileExists(atPath: copyPath))
    }

    @Test
    func testCaseOnlyRenameCommandRenames() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Readme.md").path
        let destination = directory.appendingPathComponent("README.md").path
        try Data("content".utf8).write(to: URL(fileURLWithPath: source))

        // The temp folder is usually on a case-insensitive volume, where
        // `[ -e README.md ]` also matches the source.
        #expect(try Self.run(.rename(path: source, to: destination)) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["README.md"])
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "content")
    }

    /// `/bin/sh` always, plus csh to show a non-POSIX login shell works.
    private static var availableShells: [String] {
        ["/bin/sh", "/bin/csh"].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ mutation: SSHFileExplorerMutationCommand, shell: String = "/bin/sh") throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -f keeps csh from reading the runner's ~/.cshrc.
        process.arguments = shell.hasSuffix("csh") ? ["-f", "-c", mutation.command] : ["-c", mutation.command]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
