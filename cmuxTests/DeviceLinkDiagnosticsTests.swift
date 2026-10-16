import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The recorder that lets the next report carry the real reason: every phase
/// change lands in the window's bounded history and, with codes only, in the
/// persisted IRX journal.
@Suite("Devices: link diagnostics")
@MainActor
struct DeviceLinkDiagnosticsTests {
    private let studio = SurfaceDeviceInstanceID(deviceID: "22222222-2222-2222-2222-222222222222", tag: "nightly")

    @Test("A refusal is recorded with its class and code, persisted without the Mac's name")
    func refusalIsRecordedAndPersisted() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-link-diagnostics-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "device-link", journalFileURL: file)
        let diagnostics = DeviceLinkDiagnostics(journal: journal, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        let refusal = DeviceLinkFailure(kind: .hostDenied, code: "invalid-grant", message: "Austin\u{2019}s MacBook Pro has not authorized this Mac.")
        diagnostics.record(phase: .connecting(attempt: 1), failure: nil, instance: studio, deviceName: "Austin\u{2019}s MacBook Pro")
        diagnostics.record(phase: .blocked(refusal), failure: refusal, instance: studio, deviceName: "Austin\u{2019}s MacBook Pro")

        #expect(diagnostics.events.map(\.phaseName) == ["connecting", "blocked"])
        #expect(diagnostics.events.last?.relevantFailure == refusal)
        #expect(diagnostics.journalPath == file.path)
        let report = diagnostics.reportText()
        #expect(report.contains("Austin\u{2019}s MacBook Pro (nightly) blocked class=host-denied code=invalid-grant"))
        #expect(report.contains(refusal.message))
        #expect(report.contains(file.path))

        let persisted = try String(contentsOf: file, encoding: .utf8)
        #expect(persisted.contains("\"component\":\"device-link\""))
        #expect(persisted.contains("\"event\":\"blocked\""))
        #expect(persisted.contains("\"a_class\":\"host-denied\""))
        #expect(persisted.contains("\"a_code\":\"invalid-grant\""))
        #expect(persisted.contains("\"a_device\":\"22222222\""))
        #expect(!persisted.contains("MacBook"), "the journal carries identifiers and codes, never names")
        #expect(!persisted.contains("authorized"), "the journal carries identifiers and codes, never sentences")
    }

    @Test("The history is bounded and a wait keeps the failure that caused it")
    func boundedHistory() {
        let diagnostics = DeviceLinkDiagnostics()
        let blip = DeviceLinkFailure(kind: .transient, code: "connection-failed", message: "Could not connect.")
        for attempt in 1...(DeviceLinkDiagnostics.capacity + 5) {
            diagnostics.record(phase: .waiting(attempt: attempt, delay: .seconds(1)), failure: blip, instance: studio, deviceName: "Studio")
        }
        #expect(diagnostics.events.count == DeviceLinkDiagnostics.capacity)
        #expect(diagnostics.events.first?.attempt == 6)
        #expect(diagnostics.events.last?.relevantFailure == blip)
        diagnostics.record(phase: .connected, failure: blip, instance: studio, deviceName: "Studio")
        #expect(diagnostics.events.last?.relevantFailure == nil, "a connected link carries no failure")
        diagnostics.reset()
        #expect(diagnostics.events.isEmpty)
        #expect(diagnostics.reportText().contains("No device link activity"))
    }
}
