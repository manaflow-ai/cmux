import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Deterministic seeded RNG (SplitMix64) so a property-test failure is
/// reproducible from the printed seed.
private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
private final class MutableDateBox {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

/// Covers the session-persistence read path introduced for the single
/// agent-index owner: `SharedLiveAgentIndex.indexForSessionPersistence()`
/// must produce the same index a from-scratch
/// `RestorableAgentSessionIndex.load` would, and must fold in hook-store
/// changes observed since the owner's last reload.
@MainActor
@Suite(.serialized)
struct SharedLiveAgentIndexOwnerPathTests {
    private struct RecordModel {
        let sessionId: String
        let workspaceId: UUID
        let panelId: UUID
        var cwd: String
        var updatedAt: TimeInterval
    }

    private struct Fixture {
        let root: URL
        let configDir: URL
        let projectsDir: URL
        let cwds: [URL]
    }

    @Test
    func ownerPathIndexMatchesFromScratchLoadAcrossRandomizedMutations() async throws {
        let seed = ProcessInfo.processInfo.environment["CMUX_OWNER_PATH_TEST_SEED"]
            .flatMap(UInt64.init) ?? 0x5EED_2026_08_26
        print("SharedLiveAgentIndexOwnerPathTests randomized-mutation seed: \(seed)")
        var rng = SeededRandomNumberGenerator(seed: seed)

        let fm = FileManager.default
        let fixture = try makeFixture(prefix: "cmux-owner-path-equivalence")
        defer { try? fm.removeItem(at: fixture.root) }

        let dateBox = MutableDateBox(Date(timeIntervalSince1970: 1_000_000))
        let sharedIndex = makeSharedIndex(fixture: fixture, dateBox: dateBox)

        var records: [RecordModel] = []
        // sessionId -> transcript file paths currently on disk for it.
        var transcriptPathsBySession: [String: [String]] = [:]

        try writeClaudeHookStore(root: fixture.root, records: records)

        for step in 0..<40 {
            try applyRandomMutation(
                step: step,
                fixture: fixture,
                records: &records,
                transcriptPathsBySession: &transcriptPathsBySession,
                rng: &rng
            )

            // Force the owner past its TTL fast path so every step performs a
            // coalesced refresh that reads the mutated stores, independent of
            // filesystem-watcher delivery timing.
            dateBox.value = dateBox.value.addingTimeInterval(120)
            let ownerIndex = try #require(
                await sharedIndex.indexForSessionPersistence(),
                "step \(step) seed \(seed): owner path returned no index"
            )
            let scratchIndex = RestorableAgentSessionIndex.load(
                homeDirectory: fixture.root.path,
                fileManager: fm,
                registry: CmuxVaultAgentRegistry(registrations: []),
                detectedSnapshots: [:],
                processArgumentsProvider: { _ in nil },
                processPresenceProvider: { _ in .absent },
                processIdentityProvider: { _ in nil }
            )

            #expect(
                ownerIndex.isComplete == scratchIndex.isComplete,
                "step \(step) seed \(seed): isComplete diverged"
            )
            let ownerCanonical = try canonicalEntries(ownerIndex)
            let scratchCanonical = try canonicalEntries(scratchIndex)
            #expect(
                ownerCanonical == scratchCanonical,
                "step \(step) seed \(seed): owner-path index diverged from from-scratch load"
            )

            // Model check: a claude record is restorable exactly when some
            // transcript file for its session exists on disk.
            let expectedPanels = Set(records.compactMap { record -> String? in
                let hasTranscript = !(transcriptPathsBySession[record.sessionId] ?? [])
                    .isEmpty
                return hasTranscript
                    ? "\(record.workspaceId.uuidString)|\(record.panelId.uuidString)"
                    : nil
            })
            #expect(
                Set(ownerCanonical.keys) == expectedPanels,
                "step \(step) seed \(seed): restorable panel set diverged from on-disk transcript state"
            )
        }
    }

    @Test
    func autosaveReadPathObservesHookStoreChangeAfterOwnerCachePopulated() async throws {
        let fm = FileManager.default
        let fixture = try makeFixture(prefix: "cmux-owner-path-autosave")
        defer { try? fm.removeItem(at: fixture.root) }

        let dateBox = MutableDateBox(Date())
        let sharedIndex = makeSharedIndex(fixture: fixture, dateBox: dateBox)

        try writeClaudeHookStore(root: fixture.root, records: [])
        let initialIndex = await sharedIndex.indexForSessionPersistence()
        #expect(initialIndex != nil)
        #expect(initialIndex?.forkValidationEntries().isEmpty == true)

        // Hook-store change after the owner cached an index: a new session
        // starts and its hook record plus transcript land on disk.
        let sessionId = "aaaaaaaa-1111-2222-3333-444444444444"
        let workspaceId = UUID()
        let panelId = UUID()
        let record = RecordModel(
            sessionId: sessionId,
            workspaceId: workspaceId,
            panelId: panelId,
            cwd: fixture.cwds[0].path,
            updatedAt: 20
        )
        try writeClaudeTranscript(
            sessionId: sessionId,
            cwd: fixture.cwds[0],
            projectsDir: fixture.projectsDir
        )
        try writeClaudeHookStore(root: fixture.root, records: [record])

        // The autosave read path must observe the change within one autosave
        // cycle: the directory watcher marks the change pending and
        // indexForSessionPersistence folds it into a coalesced refresh. Poll
        // only for watcher-event delivery; a fast-path read before the event
        // lands legitimately returns the older cached index.
        var ownerIndex: RestorableAgentSessionIndex?
        for _ in 0..<200 {
            let index = await sharedIndex.indexForSessionPersistence()
            if index?.snapshot(workspaceId: workspaceId, panelId: panelId) != nil {
                ownerIndex = index
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let observedIndex = try #require(
            ownerIndex,
            "autosave read path never observed the hook-store change"
        )
        #expect(
            observedIndex.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == sessionId
        )

        // Second leg of the autosave composition: the resume-index load
        // revalidates the owner's index instead of re-reading hook stores and
        // must keep the new session.
        let resumeIndexes = await ProcessDetectedResumeIndexes.load(
            homeDirectory: fixture.root.path,
            fileManager: fm,
            cachedRestorableAgentIndex: observedIndex,
            ttyDeviceBindings: [:]
        )
        #expect(
            resumeIndexes.restorableAgentIndex.snapshot(
                workspaceId: workspaceId,
                panelId: panelId
            )?.sessionId == sessionId
        )
    }

    // MARK: - Mutations

    private func applyRandomMutation(
        step: Int,
        fixture: Fixture,
        records: inout [RecordModel],
        transcriptPathsBySession: inout [String: [String]],
        rng: inout SeededRandomNumberGenerator
    ) throws {
        enum Mutation: CaseIterable {
            case addRecord
            case updateRecordUpdatedAt
            case updateRecordCwd
            case removeRecord
            case createTranscript
            case deleteTranscript
        }

        let mutation = Mutation.allCases.randomElement(using: &rng) ?? .addRecord
        switch mutation {
        case .addRecord:
            let sessionId = randomUUID(using: &rng).uuidString.lowercased()
            let cwd = fixture.cwds.randomElement(using: &rng) ?? fixture.cwds[0]
            let record = RecordModel(
                sessionId: sessionId,
                workspaceId: randomUUID(using: &rng),
                panelId: randomUUID(using: &rng),
                cwd: cwd.path,
                updatedAt: TimeInterval(Int.random(in: 1...100_000, using: &rng))
            )
            records.append(record)
            if Bool.random(using: &rng) {
                let path = try writeClaudeTranscript(
                    sessionId: sessionId,
                    cwd: cwd,
                    projectsDir: fixture.projectsDir
                )
                transcriptPathsBySession[sessionId, default: []].append(path)
            }
        case .updateRecordUpdatedAt:
            guard let index = records.indices.randomElement(using: &rng) else { return }
            records[index].updatedAt += TimeInterval(Int.random(in: 1...100, using: &rng))
        case .updateRecordCwd:
            guard let index = records.indices.randomElement(using: &rng),
                  let cwd = fixture.cwds.randomElement(using: &rng) else { return }
            records[index].cwd = cwd.path
        case .removeRecord:
            guard let index = records.indices.randomElement(using: &rng) else { return }
            records.remove(at: index)
        case .createTranscript:
            let candidates = records.filter {
                (transcriptPathsBySession[$0.sessionId] ?? []).isEmpty
            }
            guard let record = candidates.randomElement(using: &rng) else { return }
            let path = try writeClaudeTranscript(
                sessionId: record.sessionId,
                cwd: URL(fileURLWithPath: record.cwd, isDirectory: true),
                projectsDir: fixture.projectsDir
            )
            transcriptPathsBySession[record.sessionId, default: []].append(path)
        case .deleteTranscript:
            let candidates = transcriptPathsBySession.filter { !$0.value.isEmpty }
            guard let sessionId = candidates.keys.sorted().randomElement(using: &rng),
                  let path = transcriptPathsBySession[sessionId]?.first else {
                return
            }
            try FileManager.default.removeItem(atPath: path)
            transcriptPathsBySession[sessionId]?.removeFirst()
        }
        try writeClaudeHookStore(root: fixture.root, records: records)
    }

    // MARK: - Fixture helpers

    private func makeFixture(prefix: String) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let cwds = [
            root.appendingPathComponent("repo-a", isDirectory: true),
            root.appendingPathComponent("repo-b", isDirectory: true),
        ]
        for cwd in cwds {
            try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
            try fm.createDirectory(
                at: projectsDir.appendingPathComponent(
                    RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
        }
        return Fixture(root: root, configDir: configDir, projectsDir: projectsDir, cwds: cwds)
    }

    private func makeSharedIndex(
        fixture: Fixture,
        dateBox: MutableDateBox
    ) -> SharedLiveAgentIndex {
        let fm = FileManager.default
        let root = fixture.root
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [],
            sampledAt: Date(timeIntervalSince1970: 42),
            includesProcessDetails: true
        )
        return SharedLiveAgentIndex(
            indexLoader: {
                SharedLiveAgentIndexLoader(
                    homeDirectory: root.path,
                    fileManager: fm,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    processSnapshotProvider: { processSnapshot },
                    capturedAtProvider: { 42 },
                    processArgumentsProvider: { _ in nil },
                    processIdentityProvider: { _ in nil }
                )
                .loadResultSynchronously()
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent(".cmuxterm", isDirectory: true).path
            },
            dateProvider: { dateBox.value }
        )
    }

    /// Canonicalizes an index for equality comparison across load paths.
    private func canonicalEntries(
        _ index: RestorableAgentSessionIndex
    ) throws -> [String: String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var canonical: [String: String] = [:]
        for (key, entry) in index.forkValidationEntries() {
            let snapshotJSON = String(
                data: try encoder.encode(entry.snapshot),
                encoding: .utf8
            ) ?? ""
            canonical["\(key.workspaceId.uuidString)|\(key.panelId.uuidString)"] = [
                snapshotJSON,
                String(describing: entry.lifecycle),
                String(entry.updatedAt),
                String(describing: entry.processLiveness),
                String(entry.hasRecordedProcessID),
                entry.processIDs.sorted().map(String.init).joined(separator: ","),
                entry.agentProcessIDs.sorted().map(String.init).joined(separator: ","),
                String(entry.containsUnrelatedProcess),
            ].joined(separator: "\u{1f}")
        }
        return canonical
    }

    @discardableResult
    private func writeClaudeTranscript(
        sessionId: String,
        cwd: URL,
        projectsDir: URL
    ) throws -> String {
        let transcriptURL = projectsDir
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
                isDirectory: true
            )
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try """
        {"type":"last-prompt","sessionId":"\(sessionId)"}
        {"type":"user","sessionId":"\(sessionId)","cwd":"\(cwd.path)","message":{"role":"user","content":"hello"}}

        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        return transcriptURL.path
    }

    private func writeClaudeHookStore(root: URL, records: [RecordModel]) throws {
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        var sessions: [String: [String: Any]] = [:]
        for record in records {
            sessions[record.sessionId] = [
                "sessionId": record.sessionId,
                "workspaceId": record.workspaceId.uuidString,
                "surfaceId": record.panelId.uuidString,
                "cwd": record.cwd,
                "pid": NSNull(),
                "updatedAt": record.updatedAt,
                "launchCommand": [
                    "launcher": "claude",
                    "executablePath": "/usr/local/bin/claude",
                    "arguments": ["/usr/local/bin/claude"],
                    "workingDirectory": record.cwd,
                    "environment": ["CLAUDE_CONFIG_DIR": configDir.path],
                    "capturedAt": record.updatedAt,
                    "source": "test",
                ],
            ]
        }
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": sessions,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: stateDir.appendingPathComponent("claude-hook-sessions.json", isDirectory: false),
            options: .atomic
        )
    }

    private func randomUUID(using rng: inout SeededRandomNumberGenerator) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8(truncatingIfNeeded: rng.next())
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
