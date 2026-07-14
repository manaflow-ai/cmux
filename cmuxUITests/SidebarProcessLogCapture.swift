import Foundation

/// Captures the app-under-test's unified log without buffering it in the test process.
final class SidebarProcessLogCapture {
    private let process = Process()
    private let outputURL: URL
    private var outputHandle: FileHandle?

    init(processIdentifier: pid_t, outputURL: URL) {
        self.outputURL = outputURL
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        outputHandle = FileHandle(forWritingAtPath: outputURL.path)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style", "compact",
            "--level", "debug",
            "--predicate", "processIdentifier == \(processIdentifier)",
        ]
        process.standardOutput = outputHandle
        process.standardError = outputHandle
    }

    func start() throws {
        try process.run()
    }

    func finish() -> String {
        if process.isRunning {
            process.interrupt()
            process.waitUntilExit()
        }
        try? outputHandle?.synchronize()
        try? outputHandle?.close()
        outputHandle = nil
        return (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
    }
}
