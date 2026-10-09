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
    private let maxExportBytes: Int
    private var handle: FileHandle?
    private var fileBytes = 0
    private var tap: (@Sendable (DiagnosticLine) -> Void)?
    private(set) var ring: [DiagnosticLine] = []

    init(directory: URL?, scrubber: SentryScrubber, capacity: Int, maxFileBytes: Int,
         maxExportBytes: Int) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        fileURL = directory?.appendingPathComponent(Self.fileName)
        archiveURL = directory?.appendingPathComponent(Self.archiveName)
        self.scrubber = scrubber
        self.capacity = max(1, capacity)
        self.maxFileBytes = max(1_024, maxFileBytes)
        self.maxExportBytes = max(1, maxExportBytes)
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

    func exportBody(maxBytes: Int? = nil) -> String {
        let limit = max(0, maxBytes ?? maxExportBytes)
        guard let fileURL, let archiveURL else {
            return boundedBody(ring.map(\.rendered).joined(separator: "\n"), maxBytes: limit)
        }
        try? handle?.synchronize()
        let archived = (try? String(contentsOf: archiveURL, encoding: .utf8)) ?? ""
        let active = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return boundedBody(archived + active, maxBytes: limit)
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

    /// Keeps a user-requested diagnostics export bounded even if a caller
    /// supplies a larger-than-default log file budget. Whole lines are kept
    /// where possible so the newest part of an export stays readable.
    private func boundedBody(_ body: String, maxBytes: Int) -> String {
        guard body.utf8.count > maxBytes else { return body }

        let marker = "[older diagnostic lines omitted]\n"
        guard maxBytes > marker.utf8.count else { return suffix(body, maxBytes: maxBytes) }
        let budget = maxBytes - marker.utf8.count
        var selected: [Substring] = []
        var used = 0
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let separator = selected.isEmpty ? 0 : 1
            let size = line.utf8.count + separator
            guard used + size <= budget else { break }
            selected.append(line)
            used += size
        }

        if selected.isEmpty {
            return marker + suffix(body, maxBytes: budget)
        }
        return marker + selected.reversed().joined(separator: "\n")
    }

    /// Returns a valid UTF-8 suffix without exceeding `maxBytes`.
    private func suffix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var bytes = Array(text.utf8.suffix(maxBytes))
        while !bytes.isEmpty {
            let value = String(decoding: bytes, as: UTF8.self)
            if value.utf8.count <= maxBytes { return value }
            bytes.removeFirst()
        }
        return ""
    }
}
