import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminalDefaultFileOpenRequestCJKTests {
    @Test
    func buildsAsciiSafeStartupInputForNonAsciiCommandPath() throws {
        let contentType = DefaultTerminalRegistration.contentType(forIdentifier: "com.apple.terminal.shell-script")
        let url = URL(fileURLWithPath: "/Users/kuaiyun/测试目录/run.command")

        let request = try #require(TerminalDefaultFileOpenRequest(fileURL: url, contentType: contentType))

        #expect(request.initialInput.utf8.allSatisfy { $0 < 0x80 })
        #expect(!request.initialInput.contains("测试目录"))
        #expect(Self.ghosttyInitialInputTransport(request.initialInput) == request.initialInput)
    }

    @Test(arguments: ["/bin/zsh", "/bin/csh", "/bin/tcsh"])
    func nonAsciiCommandPathStartupInputReconstructsRealPathThroughTransport(shellPath: String) throws {
        guard FileManager.default.isExecutableFile(atPath: shellPath) else {
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-default-cjk-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("测试目录", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = directory.appendingPathComponent("run.command", isDirectory: false)
        try "#!/bin/sh\nprintf '%s' \"$0\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let request = try #require(TerminalDefaultFileOpenRequest(fileURL: executable))
        let expectedPath = request.fileURL.path(percentEncoded: false)
        let delivered = Self.ghosttyInitialInputTransport(request.initialInput)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-f", "-c", delivered]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let stdout = try #require(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus != 0 {
            Issue.record("\(shellPath) failed: \(stderr ?? "")")
        }
        #expect(process.terminationStatus == 0)
        #expect(stdout == expectedPath)
    }

    private static func ghosttyInitialInputTransport(_ input: String) -> String {
        var bytes: [UInt8] = []
        for byte in input.utf8 {
            if byte < 0x80 {
                bytes.append(byte)
            } else {
                bytes.append(contentsOf: String(UnicodeScalar(byte)).utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
