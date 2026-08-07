import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AmpVaultRegistrationTests: XCTestCase {
    func testBuiltInAmpRegistrationUsesCmuxOwnedHookStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-amp-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = CmuxVaultAgentRegistry.load(homeDirectory: root.path)
        let registration = try XCTUnwrap(registry.registration(id: "amp"))

        XCTAssertEqual(registration, .builtInAmp)
        XCTAssertEqual(registration.name, "Amp")
        XCTAssertEqual(registration.iconAssetName, "AgentIcons/Amp")
        XCTAssertEqual(registration.detect.processName, "amp")
        XCTAssertEqual(registration.sessionIdSource, .cmuxHookStore(.amp))
        XCTAssertEqual(registration.resumeCommand, "amp threads continue {{sessionId}}")
    }

    func testCmuxHookStoreCapabilityCannotBeClaimedByConfig() {
        let data = Data(#"""
        {
          "id": "custom-amp-store",
          "name": "Untrusted Amp Store",
          "detect": { "processName": "amp" },
          "sessionIdSource": { "type": "cmuxHookStore", "store": "amp" },
          "resumeCommand": "amp threads continue {{sessionId}}"
        }
        """#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(CmuxVaultAgentRegistration.self, from: data))
    }

    func testAmpHookStoreIsSortedSearchableAndResumesCapturedThread() throws {
        let storeURL = try writeStore([
            "T-older": [
                "sessionId": "T-older",
                "cwd": "/tmp/other repo",
                "title": "Older Amp work",
                "updatedAt": 100.0,
            ],
            "T-newer": [
                "sessionId": "T-newer",
                "cwd": "/tmp/amp repo/../amp repo",
                "title": "Ship first-class Amp",
                "updatedAt": 200.0,
                "launchCommand": [
                    "launcher": "amp",
                    "executablePath": "/opt/amp/bin/amp",
                    "arguments": [
                        "/opt/amp/bin/amp",
                        "threads", "continue", "T-stale",
                        "--mode", "smart",
                        "--effort", "high",
                    ],
                    "workingDirectory": "/tmp/amp repo",
                    "environment": [
                        "AMP_SETTINGS_FILE": "/tmp/amp-settings.json",
                        "OPENAI_API_KEY": "must-not-replay",
                    ],
                    "capturedAt": 123.0,
                    "source": "process",
                ],
            ],
            "T-type-drift": [
                "sessionId": "T-type-drift",
                "cwd": 12345,
                "updatedAt": 300.0,
            ],
        ])
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let errors = ErrorBag()
        let all = SessionIndexStore.loadCmuxHookStoreEntries(
            registration: .builtInAmp,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            errorBag: errors,
            storeURL: storeURL
        )

        XCTAssertEqual(errors.snapshot(), [])
        XCTAssertEqual(all.map(\.sessionId), ["T-newer", "T-older"])
        XCTAssertTrue(all.allSatisfy {
            $0.agent == .registered(RegisteredSessionAgent(registration: .builtInAmp))
        })

        let searched = SessionIndexStore.loadCmuxHookStoreEntries(
            registration: .builtInAmp,
            needle: "first-class",
            cwdFilter: "/tmp/amp repo",
            offset: 0,
            limit: 10,
            errorBag: errors,
            storeURL: storeURL
        )
        let entry = try XCTUnwrap(searched.first)
        XCTAssertEqual(searched.count, 1)
        XCTAssertEqual(entry.title, "Ship first-class Amp")
        XCTAssertEqual(entry.cwd, "/tmp/amp repo")
        XCTAssertNil(entry.fileURL)

        let resume = try XCTUnwrap(entry.resumeCommand)
        XCTAssertTrue(resume.contains("CMUX_AMP_WRAPPER_SHIM"), resume)
        XCTAssertTrue(resume.contains("T-newer"), resume)
        XCTAssertTrue(resume.contains("--mode"), resume)
        XCTAssertTrue(resume.contains("smart"), resume)
        XCTAssertTrue(resume.contains("--effort"), resume)
        XCTAssertTrue(resume.contains("high"), resume)
        XCTAssertTrue(resume.contains("AMP_SETTINGS_FILE=/tmp/amp-settings.json"), resume)
        XCTAssertFalse(resume.contains("T-stale"), resume)
        XCTAssertFalse(resume.contains("OPENAI_API_KEY"), resume)
    }

    func testAmpHookStoreFallsBackTitlesAndReportsMalformedStoreSafely() throws {
        let validStoreURL = try writeStore([
            "T-cwd": ["sessionId": "T-cwd", "cwd": "/tmp/amp project", "startedAt": 20.0],
            "T-generic": ["sessionId": "T-generic", "startedAt": 10.0],
        ])
        defer { try? FileManager.default.removeItem(at: validStoreURL.deletingLastPathComponent()) }

        let validErrors = ErrorBag()
        let entries = SessionIndexStore.loadCmuxHookStoreEntries(
            registration: .builtInAmp,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            errorBag: validErrors,
            storeURL: validStoreURL
        )
        XCTAssertEqual(entries.map(\.title), ["Amp session in amp project", "Amp session"])
        XCTAssertEqual(entries.last?.resumeCommand?.contains("T-generic"), true)

        let malformedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-amp-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: malformedDirectory) }
        let malformedURL = malformedDirectory.appendingPathComponent("amp-hook-sessions.json")
        try Data("{".utf8).write(to: malformedURL)
        let malformedErrors = ErrorBag()

        let malformedEntries = SessionIndexStore.loadCmuxHookStoreEntries(
            registration: .builtInAmp,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            errorBag: malformedErrors,
            storeURL: malformedURL
        )

        XCTAssertEqual(malformedEntries, [])
        XCTAssertEqual(malformedErrors.snapshot(), ["Amp: cannot read amp-hook-sessions.json"])
        XCTAssertFalse(malformedErrors.snapshot().joined().contains(malformedURL.path))
    }

    private func writeStore(_ sessions: [String: [String: Any]]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-amp-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("amp-hook-sessions.json")
        let payload: [String: Any] = ["version": 1, "sessions": sessions]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: storeURL)
        return storeURL
    }
}
