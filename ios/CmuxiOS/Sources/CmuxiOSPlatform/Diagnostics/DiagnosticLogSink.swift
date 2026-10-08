public import CmuxSentryScrubbing
public import Foundation

/// The app's structured diagnostic log (plans/cmux-next/ios-next/c16-platform.md
/// section 3). `record` is non-blocking from any thread; one drain task
/// scrubs each line, keeps a bounded ring in memory and appends it to a
/// rotated file, so lines land in admission order.
///
/// Built once by the composition root and injected; no singleton.
public final class DiagnosticLogSink: DiagnosticRecording, Sendable {
    private enum Item: Sendable {
        case line(DiagnosticLine)
        case barrier(CheckedContinuation<Void, Never>)
    }

    private let continuation: AsyncStream<Item>.Continuation
    private let store: DiagnosticLogStore
    private let now: @Sendable () -> Date
    private let maxExportBytes: Int

    /// - Parameters:
    ///   - directory: Where `diagnostics.log` lives; nil keeps the log in
    ///     memory only.
    ///   - capacity: Lines kept in memory.
    ///   - maxFileBytes: The active file rotates to one archive past this size.
    ///   - maxExportBytes: Hard upper bound for a user-requested export,
    ///     including the support header.
    public init(
        directory: URL?,
        scrubber: SentryScrubber = SentryScrubber(),
        capacity: Int = 2_000,
        maxFileBytes: Int = 1_000_000,
        maxExportBytes: Int = 2_000_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let store = DiagnosticLogStore(directory: directory, scrubber: scrubber,
                                       capacity: capacity, maxFileBytes: maxFileBytes,
                                       maxExportBytes: maxExportBytes)
        let (stream, continuation) = AsyncStream.makeStream(of: Item.self, bufferingPolicy: .unbounded)
        self.store = store
        self.continuation = continuation
        self.now = now
        self.maxExportBytes = max(1, maxExportBytes)
        Task.detached(priority: .utility) {
            for await item in stream {
                switch item {
                case .line(let line): await store.append(line)
                case .barrier(let done): done.resume()
                }
            }
        }
    }

    deinit { continuation.finish() }

    public func record(_ level: DiagnosticLevel, category: String, _ message: String) {
        continuation.yield(.line(DiagnosticLine(date: now(), level: level, category: category, message: message)))
    }

    /// Waits until every line recorded before this call is stored.
    public func flush() async {
        await withCheckedContinuation { done in continuation.yield(.barrier(done)) }
    }

    /// Mirrors each stored (scrubbed) line, for example to Sentry breadcrumbs.
    public func setTap(_ tap: (@Sendable (DiagnosticLine) -> Void)?) async {
        await store.setTap(tap)
    }

    /// The in-memory lines, oldest first.
    public func lines() async -> [DiagnosticLine] {
        await flush()
        return await store.ring
    }

    /// Writes one text file (support header, then the archived and active
    /// log) to `directory` (the temporary directory by default) and returns
    /// its URL, ready for a share sheet.
    public func export(header: DiagnosticSupportInfo, to directory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        await flush()
        let prefix = header.rendered + "\n\n"
        let bodyBudget = max(0, maxExportBytes - prefix.utf8.count)
        let body = await store.exportBody(maxBytes: bodyBudget)
        let stamp = now().formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let url = directory.appendingPathComponent("cmux-diagnostics-\(stamp).txt")
        let text = prefix + body
        try Data(Self.bounded(text, maxBytes: maxExportBytes).utf8).write(to: url, options: .atomic)
        return url
    }

    private static func bounded(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let marker = "[diagnostics export truncated]\n"
        let budget = max(0, maxBytes - marker.utf8.count)
        var bytes = Array(text.utf8.suffix(budget))
        while !bytes.isEmpty {
            let suffix = String(decoding: bytes, as: UTF8.self)
            if suffix.utf8.count <= budget { return marker + suffix }
            bytes.removeFirst()
        }
        return marker
    }

    /// Empties the ring and deletes the files.
    public func clear() async {
        await flush()
        await store.clear()
    }
}
