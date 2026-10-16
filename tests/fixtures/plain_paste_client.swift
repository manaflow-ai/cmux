import AppKit
import Darwin
import Foundation

/// Exercises the production Swift pipe owner without launching the cmux app.
@main
struct PlainPasteClientProbe {
    @MainActor
    static func main() async throws {
        let helper = URL(fileURLWithPath: CommandLine.arguments[2])
        switch CommandLine.arguments[1] {
        case "restore":
            try await restoration(helper: helper)
        case "cancel":
            try await cancellation(helper: helper, provider: URL(fileURLWithPath: CommandLine.arguments[3]))
        case "malformed":
            try await malformedResponse()
        default:
            throw failure("Unknown probe")
        }
        print("PASS: \(CommandLine.arguments[1])")
    }

    @MainActor
    private static func restoration(helper: URL) async throws {
        let board = NSPasteboard(name: .init("cmux-client-restore-\(UUID())"))
        defer { board.releaseGlobally() }
        let reader = TerminalPlainTextPasteWorkerPool(executableURL: helper)
        _ = try await reader.request(request(name: board.name.rawValue, generation: -1))
        for trial in 0..<30 {
            let text = "dictation-\(trial) 日本語 🦀\nsecond line\n"
            board.clearContents()
            try check(board.setString(text, forType: .string), "Failed to seed test clipboard")
            let restoration = Task { @MainActor in
                try await Task.sleep(for: .milliseconds(100))
                board.clearContents()
                try check(board.setString("saved clipboard", forType: .string), "Failed to restore")
            }
            defer { restoration.cancel() }
            let response = try await reader.request(request(name: board.name.rawValue, generation: board.changeCount))
            try await restoration.value
            try check(response.status == 0 && response.payload == Data(text.utf8), "Lost transcription")
            try check(board.string(forType: .string) == "saved clipboard", "Changed saved clipboard")
        }
    }

    @MainActor
    private static func cancellation(helper: URL, provider: URL) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "cmux-client-cancel-\(UUID())"
        let ready = root.appendingPathComponent("ready.json")
        let requested = root.appendingPathComponent("requested")
        let config = root.appendingPathComponent("provider.json")
        try JSONSerialization.data(withJSONObject: [
            "name": name, "text": "never returned", "behavior": "stall",
            "representations": [:], "ready": ready.path, "requested": requested.path
        ]).write(to: config)
        let producer = Process()
        producer.executableURL = provider
        producer.arguments = [config.path]
        try producer.run()
        defer {
            producer.terminate()
            producer.waitUntilExit()
            NSPasteboard(name: .init(name)).releaseGlobally()
        }
        try await waitForFile(ready)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as! [String: Int]
        let wrapper = try countingWrapper(executable: helper, root: root)
        let reader = TerminalPlainTextPasteWorkerPool(executableURL: wrapper)
        let data = try request(name: name, generation: metadata["generation"]!)
        let task = Task { try await reader.request(data) }
        try await waitForFile(requested)
        let firstPID = try workerPIDs(root).first!
        task.cancel()
        do {
            _ = try await task.value
            throw failure("Cancelled read succeeded")
        } catch is CancellationError {}
        try check(kill(firstPID, 0) == -1 && errno == ESRCH, "Returned before reaping worker")

        let board = NSPasteboard(name: .init("cmux-client-recovery-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("after cancellation", forType: .string)
        let response = try await reader.request(request(name: board.name.rawValue, generation: board.changeCount))
        try check(response.status == 0 && response.payload == Data("after cancellation".utf8), "Reader did not recover")
        try check(workerPIDs(root).count == 2, "Unexpected reader process count")
    }

    private static func malformedResponse() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("fake.py")
        try """
        #!/usr/bin/python3
        import os, signal, sys
        os.write(1, b'R')
        sys.stdin.buffer.readline()
        os.write(1, b'\\x00\\x01\\x00\\x00\\x01')
        signal.pause()
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let wrapper = try countingWrapper(executable: fake, root: root)
        let connection = TerminalPlainTextPasteWorkerConnection(executableURL: wrapper)
        try await connection.start()
        do {
            _ = try await connection.request(Data("{}".utf8))
            throw failure("Accepted oversized payload header")
        } catch TerminalPastePreparationWorkerError.invalidWorkerResponse {}
        let pid = try workerPIDs(root).first!
        try check(kill(pid, 0) == -1 && errno == ESRCH, "Invalid worker was not reaped")
    }

    private static func request(name: String, generation: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "pasteboard": ["pasteboardName": name, "changeCount": generation],
            "mode": ["paste": [:]], "destination": ["terminal": [:]]
        ])
    }

    private static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-client-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private static func countingWrapper(executable: URL, root: URL) throws -> URL {
        let wrapper = root.appendingPathComponent("reader")
        let pids = root.appendingPathComponent("pids")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$$\" >> \(quoted(pids.path))\nexec \(quoted(executable.path)) \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        return wrapper
    }

    private static func workerPIDs(_ root: URL) throws -> [Int32] {
        try String(contentsOf: root.appendingPathComponent("pids"), encoding: .utf8)
            .split(separator: "\n").compactMap { Int32($0) }
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func waitForFile(_ url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(FileManager.default.fileExists(atPath: url.path), "Fixture did not signal readiness")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PlainPasteClientProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
