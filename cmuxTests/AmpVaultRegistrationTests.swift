import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AmpVaultRegistrationTests {
    @Test
    func builtInAmpRegistrationUsesCmuxOwnedHookStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-amp-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = CmuxVaultAgentRegistry.load(homeDirectory: root.path)
        let registration = try #require(registry.registration(id: "amp"))

        #expect(registration == .builtInAmp)
        #expect(registration.name == "Amp")
        #expect(registration.iconAssetName == "AgentIcons/Amp")
        #expect(registration.detect.processName == "amp")
        #expect(registration.sessionIdSource == .cmuxHookStore(.amp))
        #expect(registration.resumeCommand == "amp threads continue {{sessionId}}")
        let taskManagerDefinition = try #require(
            CmuxTaskManagerCodingAgentDefinition.builtIns.first { $0.id == "amp" }
        )
        #expect(taskManagerDefinition.assetName == registration.iconAssetName)
    }

    @Test
    func cmuxHookStoreCapabilityCannotBeClaimedByConfig() {
        let data = Data(#"""
        {
          "id": "custom-amp-store",
          "name": "Untrusted Amp Store",
          "detect": { "processName": "amp" },
          "sessionIdSource": { "type": "cmuxHookStore", "store": "amp" },
          "resumeCommand": "amp threads continue {{sessionId}}"
        }
        """#.utf8)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CmuxVaultAgentRegistration.self, from: data)
        }
    }

    @Test
    func ampHookStoreIsSortedSearchableAndResumesCapturedThread() throws {
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

        let errors = SessionIndexStore.ErrorBag()
        let all = SessionIndexStore.loadCmuxHookStoreEntries(
            registration: .builtInAmp,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            errorBag: errors,
            storeURL: storeURL
        )

        #expect(errors.snapshot() == [])
        #expect(all.map(\.sessionId) == ["T-newer", "T-older"])
        #expect(all.allSatisfy {
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
        let entry = try #require(searched.first)
        #expect(searched.count == 1)
        #expect(entry.title == "Ship first-class Amp")
        #expect(entry.cwd == "/tmp/amp repo")
        #expect(entry.fileURL == nil)

        let resume = try #require(entry.resumeCommand)
        #expect(resume.contains("CMUX_AMP_WRAPPER_SHIM"))
        #expect(resume.contains("T-newer"))
        #expect(resume.contains("--mode"))
        #expect(resume.contains("smart"))
        #expect(resume.contains("--effort"))
        #expect(resume.contains("high"))
        #expect(resume.contains("AMP_SETTINGS_FILE=/tmp/amp-settings.json"))
        #expect(!resume.contains("T-stale"))
        #expect(!resume.contains("OPENAI_API_KEY"))
    }

    @Test
    func ampHookStoreFallsBackTitlesAndReportsMalformedStoreSafely() throws {
        let validStoreURL = try writeStore([
            "T-cwd": ["sessionId": "T-cwd", "cwd": "/tmp/amp project", "startedAt": 20.0],
            "T-generic": ["sessionId": "T-generic", "startedAt": 10.0],
        ])
        defer { try? FileManager.default.removeItem(at: validStoreURL.deletingLastPathComponent()) }

        let validErrors = SessionIndexStore.ErrorBag()
        let entries = SessionIndexStore.loadCmuxHookStoreEntries(
            registration: .builtInAmp,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            errorBag: validErrors,
            storeURL: validStoreURL
        )
        #expect(entries.map(\.title) == ["Amp session in amp project", "Amp session"])
        #expect(entries.last?.resumeCommand?.contains("T-generic") == true)

        let malformedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-amp-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: malformedDirectory) }
        let malformedURL = malformedDirectory.appendingPathComponent("amp-hook-sessions.json")
        try Data("{".utf8).write(to: malformedURL)
        let malformedErrors = SessionIndexStore.ErrorBag()

        let malformedEntries = SessionIndexStore.loadCmuxHookStoreEntries(
            registration: .builtInAmp,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            errorBag: malformedErrors,
            storeURL: malformedURL
        )

        #expect(malformedEntries == [])
        #expect(malformedErrors.snapshot() == ["Amp: cannot read amp-hook-sessions.json"])
        #expect(!malformedErrors.snapshot().joined().contains(malformedURL.path))
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
