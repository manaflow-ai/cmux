import CmuxiOSPlatform
import Foundation
import Testing

@Suite("Diagnostic log sink")
struct DiagnosticLogSinkTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("c16-diag-\(UUID().uuidString)")
    }

    @Test func linesKeepAdmissionOrderAndScrubSecrets() async {
        let sink = DiagnosticLogSink(directory: nil)
        sink.info("auth", "token sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789 for a@b.example")
        sink.warning("router", "second")
        let lines = await sink.lines()
        #expect(lines.map(\.category) == ["auth", "router"])
        #expect(!lines[0].message.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!lines[0].message.contains("a@b.example"))
    }

    @Test func ringIsBounded() async {
        let sink = DiagnosticLogSink(directory: nil, capacity: 3)
        for index in 0..<10 { sink.info("t", "line \(index)") }
        let lines = await sink.lines()
        #expect(lines.map(\.message) == ["line 7", "line 8", "line 9"])
    }

    @Test func exportCarriesHeaderAndFileAndClearEmptiesIt() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = DiagnosticLogSink(directory: directory)
        sink.info("app", "launch")
        let header = DiagnosticSupportInfo(appVersion: "1.2", build: "34", osVersion: "iOS 18", deviceModel: "iPhone17,1",
                                           locale: "en_US", extra: [.init("Flags", "feedTab")])
        let url = try await sink.export(header: header, to: directory)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("cmux 1.2 (34)"))
        #expect(text.contains("Flags: feedTab"))
        #expect(text.contains("app: launch"))
        await sink.clear()
        #expect(await sink.lines().isEmpty)
        let cleared = try String(contentsOf: try await sink.export(header: header, to: directory), encoding: .utf8)
        #expect(!cleared.contains("app: launch"))
    }

    @Test func activeFileRotatesIntoOneArchive() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = DiagnosticLogSink(directory: directory, maxFileBytes: 1_024)
        for index in 0..<100 { sink.info("t", "line \(index) " + String(repeating: "x", count: 40)) }
        await sink.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["diagnostics.1.log", "diagnostics.log"])
        let active = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("diagnostics.log").path)
        #expect((active[.size] as? Int ?? .max) <= 1_024)
    }

    @Test func exportIsBoundedAndRetainsTheNewestDiagnosticLines() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = DiagnosticLogSink(directory: directory, maxFileBytes: 1_024, maxExportBytes: 256)
        for index in 0..<80 {
            sink.info("router", "line \(index) " + String(repeating: "x", count: 24))
        }
        let header = DiagnosticSupportInfo(appVersion: "1", build: "2", osVersion: "iOS", deviceModel: "iPhone",
                                           locale: "en_US")
        let url = try await sink.export(header: header, to: directory)
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        #expect(data.count <= 256)
        #expect(text.contains("[diagnostics export truncated]"))
        #expect(text.contains("line 79"))
    }

    @Test func tinyExportCapsNeverWritePastTheConfiguredLimit() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = DiagnosticLogSink(directory: directory, maxExportBytes: 1)
        sink.info("router", "line")
        let header = DiagnosticSupportInfo(appVersion: "1", build: "2", osVersion: "iOS", deviceModel: "iPhone",
                                           locale: "en_US")
        let url = try await sink.export(header: header, to: directory)
        #expect(try Data(contentsOf: url).count <= 1)
    }

    @Test func tapSeesScrubbedLines() async {
        let sink = DiagnosticLogSink(directory: nil)
        let seen = TapBox()
        await sink.setTap { line in seen.append(line.message) }
        sink.error("x", "boom")
        await sink.flush()
        #expect(seen.values == ["boom"])
    }
}

/// Collects tap callbacks across threads.
final class TapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
}
