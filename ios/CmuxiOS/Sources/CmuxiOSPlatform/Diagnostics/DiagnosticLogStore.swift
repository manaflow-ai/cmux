import CmuxSentryScrubbing
import Foundation

/// The drain side of `DiagnosticLogSink`: scrubbing, the ring and the files.
actor DiagnosticLogStore {
    static let fileName = "diagnostics.log"
    static let archiveName = "diagnostics.1.log"

    private let fileURL: URL?
    private let archiveURL: URL?
    private let scrubber: SentryScrubber
    private let capacity: Int
    private let maxFileBytes: Int
    private var handle: FileHandle?
    private var fileBytes = 0
    private var tap: (@Sendable (DiagnosticLine) -> Void)?
    private(set) var ring: [DiagnosticLine] = []

    init(directory: URL?, scrubber: SentryScrubber, capacity: Int, maxFileBytes: Int) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        fileURL = directory?.appendingPathComponent(Self.fileName)
        archiveURL = directory?.appendingPathComponent(Self.archiveName)
        self.scrubber = scrubber
        self.capacity = max(1, capacity)
        self.maxFileBytes = max(1_024, maxFileBytes)
    }

    func setTap(_ tap: (@Sendable (DiagnosticLine) -> Void)?) { self.tap = tap }

    func append(_ raw: DiagnosticLine) {
        var line = raw
        line.message = scrubber.scrub(raw.message)
        line.category = scrubber.scrub(raw.category)
        ring.append(line)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        write(line.rendered + "\n")
        tap?(line)
    }

    func exportBody() -> String {
        guard let fileURL, let archiveURL else {
            return ring.map(\.rendered).joined(separator: "\n")
        }
        try? handle?.synchronize()
        let archived = (try? String(contentsOf: archiveURL, encoding: .utf8)) ?? ""
        let active = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return archived + active
    }

    func clear() {
        ring.removeAll()
        try? handle?.close()
        handle = nil
        fileBytes = 0
        for url in [fileURL, archiveURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func write(_ text: String) {
        guard let fileURL else { return }
        let data = Data(text.utf8)
        if handle == nil { open(fileURL) }
        if fileBytes + data.count > maxFileBytes { rotate(fileURL) }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            fileBytes += data.count
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func open(_ url: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            #if os(iOS)
            // Readable after first unlock so a background launch can log.
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            #else
            let attributes: [FileAttributeKey: Any] = [:]
            #endif
            manager.createFile(atPath: url.path, contents: nil, attributes: attributes)
        }
        handle = try? FileHandle(forWritingTo: url)
        fileBytes = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate(_ url: URL) {
        try? handle?.close()
        handle = nil
        if let archiveURL {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.moveItem(at: url, to: archiveURL)
        }
        open(url)
    }
}
