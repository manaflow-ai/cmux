import Foundation

/// File-backed process I/O for tests that wait for termination before reading output.
/// Regular pipes can deadlock when either stdin or a child output exceeds pipe capacity.
final class ProcessTestFileCapture {
    private let rootURL: URL
    private let standardInputURL: URL
    private let standardOutputURL: URL
    private let standardErrorURL: URL
    private let standardInputHandle: FileHandle
    private let standardOutputHandle: FileHandle
    private let standardErrorHandle: FileHandle
    private var handlesAreClosed = false

    init(standardInput: String?) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-process-capture-\(UUID().uuidString)", isDirectory: true)
        standardInputURL = rootURL.appendingPathComponent("stdin", isDirectory: false)
        standardOutputURL = rootURL.appendingPathComponent("stdout", isDirectory: false)
        standardErrorURL = rootURL.appendingPathComponent("stderr", isDirectory: false)

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        do {
            try Data((standardInput ?? "").utf8).write(to: standardInputURL)
            guard FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil),
                  FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            standardInputHandle = try FileHandle(forReadingFrom: standardInputURL)
            standardOutputHandle = try FileHandle(forWritingTo: standardOutputURL)
            standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    func attach(to process: Process) {
        process.standardInput = standardInputHandle
        process.standardOutput = standardOutputHandle
        process.standardError = standardErrorHandle
    }

    func closeParentHandles() {
        guard !handlesAreClosed else { return }
        handlesAreClosed = true
        try? standardInputHandle.close()
        try? standardOutputHandle.close()
        try? standardErrorHandle.close()
    }

    func standardOutput() -> String {
        string(contentsOf: standardOutputURL)
    }

    func standardError() -> String {
        string(contentsOf: standardErrorURL)
    }

    func cleanup() {
        closeParentHandles()
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func string(contentsOf url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
