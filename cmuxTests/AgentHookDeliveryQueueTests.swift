import CmuxControlSocket
import CryptoKit
import Darwin
import Foundation
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class AgentHookOneShotErrno: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?

    init(_ value: Int32) {
        self.value = value
    }

    func take() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        defer { value = nil }
        return value
    }
}

@Suite("Agent hook durable delivery", .serialized)
struct AgentHookDeliveryQueueTests {
    private struct OutboxTestRecord {
        let markerURL: URL
        let sharedMemoryName: String
    }

    @Test func authenticatedOutboxRecoverySurvivesAuthorityRecreationAndScrubsSecrets() async throws {
        let root = try temporaryDirectory(named: "outbox-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let outboxURL = root.appendingPathComponent("outbox", isDirectory: true)
        let audience = "com.cmuxterm.test.outbox-recovery"
        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let publisherOutbox = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: audience,
            deliveryQueue: queue,
            reconciliationInterval: 60
        ))
        let capability = publisherOutbox.issueCapability()
        let message = try outboxMessage(
            deliveryID: "outbox-recovery",
            payload: Data([0x00, 0xff, 0x0a]),
            environment: testEnvironment(root: root).merging([
                "OPENAI_API_KEY": "outbox-memory-only-secret",
            ], uniquingKeysWith: { _, new in new })
        )
        let record = try publishOutboxRecord(
            message: message,
            capability: capability,
            directoryURL: outboxURL,
            order: 1
        )
        defer { shm_unlink(record.sharedMemoryName) }

        let markerBytes = try Data(contentsOf: record.markerURL)
        let persistedMasterSecret = try Data(contentsOf: publisherOutbox.capabilitySecretURL)
        #expect(persistedMasterSecret.count == SocketClientCapabilityAuthority.secureByteCount)
        #expect(markerBytes.range(of: Data(capability.utf8)) == nil)
        #expect(markerBytes.range(of: persistedMasterSecret) == nil)
        #expect(markerBytes.range(of: Data("outbox-memory-only-secret".utf8)) == nil)
        let secretAttributes = try FileManager.default.attributesOfItem(
            atPath: publisherOutbox.capabilitySecretURL.path
        )
        #expect((secretAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((secretAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())

        // Recreate the authority from disk before importing, matching an app
        // restart after the helper has already published the record.
        await publisherOutbox.stop()
        let recoveringOutbox = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: audience,
            deliveryQueue: queue,
            reconciliationInterval: 60
        ))
        #expect(try Data(contentsOf: recoveringOutbox.capabilitySecretURL) == persistedMasterSecret)

        await recoveringOutbox.start()
        #expect(try await queue.diagnosticStatus(for: "outbox-recovery")?["state"] == "pending")
        #expect(!FileManager.default.fileExists(atPath: record.markerURL.path))
        #expect(sharedMemoryIsMissing(record.sharedMemoryName))
        let storedEnvironment = try storedEnvironmentJSON(
            databaseURL: databaseURL,
            deliveryID: "outbox-recovery"
        )
        #expect(!storedEnvironment.contains("outbox-memory-only-secret"))
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("deliveries.sqlite3") {
            let bytes = (try? Data(contentsOf: file)) ?? Data()
            #expect(bytes.range(of: Data("outbox-memory-only-secret".utf8)) == nil)
        }
        await recoveringOutbox.stop()
    }

    @Test func outboxRejectsWrongAudienceAndTamperedMessage() async throws {
        let root = try temporaryDirectory(named: "outbox-auth-rejection")
        defer { try? FileManager.default.removeItem(at: root) }
        let outboxURL = root.appendingPathComponent("outbox", isDirectory: true)
        let otherAuthority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0x41, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test.outbox-other"
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let outbox = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: "com.cmuxterm.test.outbox-expected",
            deliveryQueue: queue,
            reconciliationInterval: 60
        ))
        let original = try outboxMessage(
            deliveryID: "outbox-tampered",
            payload: Data("original".utf8),
            environment: testEnvironment(root: root)
        )
        let wrongAudienceRecord = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-wrong-audience",
                payload: Data("wrong-audience".utf8),
                environment: testEnvironment(root: root)
            ),
            capability: otherAuthority.issueCapability(),
            directoryURL: outboxURL,
            order: 1
        )
        let tamperedRecord = try publishOutboxRecord(
            message: Data(original.dropLast()) + Data(" \n".utf8),
            authenticating: original,
            capability: outbox.issueCapability(),
            directoryURL: outboxURL,
            order: 2
        )
        let wrongMethodRecord = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-wrong-method",
                payload: Data("wrong-method".utf8),
                environment: testEnvironment(root: root),
                method: "system.exec"
            ),
            capability: outbox.issueCapability(),
            directoryURL: outboxURL,
            order: 3
        )
        defer {
            shm_unlink(wrongAudienceRecord.sharedMemoryName)
            shm_unlink(tamperedRecord.sharedMemoryName)
            shm_unlink(wrongMethodRecord.sharedMemoryName)
        }

        await outbox.reconcileForTesting()

        #expect(try await queue.diagnosticStatus(for: "outbox-wrong-audience") == nil)
        #expect(try await queue.diagnosticStatus(for: "outbox-tampered") == nil)
        #expect(try await queue.diagnosticStatus(for: "outbox-wrong-method") == nil)
        for record in [wrongAudienceRecord, tamperedRecord, wrongMethodRecord] {
            #expect(!FileManager.default.fileExists(atPath: record.markerURL.path))
            #expect(sharedMemoryIsMissing(record.sharedMemoryName))
        }
    }

    @Test func outboxReplayAfterCommittedQueueInsertDeduplicatesAndCleansUp() async throws {
        let root = try temporaryDirectory(named: "outbox-crash-replay")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let outboxURL = root.appendingPathComponent("outbox", isDirectory: true)
        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let outbox = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: "com.cmuxterm.test.outbox-replay",
            deliveryQueue: queue,
            reconciliationInterval: 60
        ))
        let message = try outboxMessage(
            deliveryID: "outbox-crash-replay",
            payload: Data("same-event".utf8),
            environment: testEnvironment(root: root)
        )
        let event = try #require(outboxEvent(from: message))
        try queue.enqueue(event)
        let record = try publishOutboxRecord(
            message: message,
            capability: outbox.issueCapability(),
            directoryURL: outboxURL,
            order: 1
        )
        defer { shm_unlink(record.sharedMemoryName) }

        await outbox.reconcileForTesting()

        #expect(try storedDeliveryIDs(databaseURL: databaseURL) == ["outbox-crash-replay"])
        #expect(!FileManager.default.fileExists(atPath: record.markerURL.path))
        #expect(sharedMemoryIsMissing(record.sharedMemoryName))
    }

    @Test func outboxImportsReadyMarkersInPublicationOrder() async throws {
        let root = try temporaryDirectory(named: "outbox-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let outboxURL = root.appendingPathComponent("outbox", isDirectory: true)
        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let outbox = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: "com.cmuxterm.test.outbox-order",
            deliveryQueue: queue,
            reconciliationInterval: 60
        ))
        let capability = outbox.issueCapability()
        let second = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-second",
                payload: Data("second".utf8),
                environment: testEnvironment(root: root)
            ),
            capability: capability,
            directoryURL: outboxURL,
            order: 2
        )
        let first = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-first",
                payload: Data("first".utf8),
                environment: testEnvironment(root: root)
            ),
            capability: capability,
            directoryURL: outboxURL,
            order: 1
        )
        defer {
            shm_unlink(first.sharedMemoryName)
            shm_unlink(second.sharedMemoryName)
        }

        await outbox.reconcileForTesting()

        #expect(try storedDeliveryIDs(databaseURL: databaseURL) == [
            "outbox-first", "outbox-second",
        ])
    }

    @Test func outboxRescansAfterAnEmptyDirectoryIteration() async throws {
        let root = try temporaryDirectory(named: "outbox-rescan")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let outboxURL = root.appendingPathComponent("outbox", isDirectory: true)
        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let outbox = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: "com.cmuxterm.test.outbox-rescan",
            deliveryQueue: queue,
            reconciliationInterval: 60
        ))

        await outbox.reconcileForTesting()
        await outbox.reconcileForTesting()
        let record = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-after-empty-scans",
                payload: Data("after-empty".utf8),
                environment: testEnvironment(root: root)
            ),
            capability: outbox.issueCapability(),
            directoryURL: outboxURL,
            order: 1
        )
        defer { shm_unlink(record.sharedMemoryName) }

        await outbox.reconcileForTesting()

        #expect(try storedDeliveryIDs(databaseURL: databaseURL) == ["outbox-after-empty-scans"])
        #expect(!FileManager.default.fileExists(atPath: record.markerURL.path))
        #expect(sharedMemoryIsMissing(record.sharedMemoryName))
    }

    @Test func outboxRecoversStalePendingInOrderAndCleansPartialRecords() async throws {
        let root = try temporaryDirectory(named: "outbox-pending-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let outboxURL = root.appendingPathComponent("outbox", isDirectory: true)
        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let outbox = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: "com.cmuxterm.test.outbox-pending",
            deliveryQueue: queue,
            reconciliationInterval: 60,
            pendingRecoveryGrace: 60
        ))
        let capability = outbox.issueCapability()
        let olderPending = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-older-pending",
                payload: Data("older".utf8),
                environment: testEnvironment(root: root)
            ),
            capability: capability,
            directoryURL: outboxURL,
            order: 1,
            markerPrefix: "pending"
        )
        let newerReady = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-newer-ready",
                payload: Data("newer".utf8),
                environment: testEnvironment(root: root)
            ),
            capability: capability,
            directoryURL: outboxURL,
            order: 2
        )
        let partialPending = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-partial-pending",
                payload: Data("partial".utf8),
                environment: testEnvironment(root: root)
            ),
            capability: capability,
            directoryURL: outboxURL,
            order: 3,
            markerPrefix: "pending"
        )
        let missingSharedMemoryPending = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-missing-shm-pending",
                payload: Data("missing".utf8),
                environment: testEnvironment(root: root)
            ),
            capability: capability,
            directoryURL: outboxURL,
            order: 4,
            markerPrefix: "pending"
        )
        shm_unlink(missingSharedMemoryPending.sharedMemoryName)
        defer {
            shm_unlink(olderPending.sharedMemoryName)
            shm_unlink(newerReady.sharedMemoryName)
            shm_unlink(partialPending.sharedMemoryName)
            shm_unlink(missingSharedMemoryPending.sharedMemoryName)
        }
        try Data("\(partialPending.sharedMemoryName)\npartial".utf8).write(
            to: partialPending.markerURL
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: partialPending.markerURL.path
        )

        await outbox.reconcileForTesting()
        #expect(try storedDeliveryIDs(databaseURL: databaseURL).isEmpty)
        #expect(FileManager.default.fileExists(atPath: olderPending.markerURL.path))
        #expect(FileManager.default.fileExists(atPath: newerReady.markerURL.path))
        #expect(FileManager.default.fileExists(atPath: partialPending.markerURL.path))
        #expect(FileManager.default.fileExists(atPath: missingSharedMemoryPending.markerURL.path))

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)],
            ofItemAtPath: olderPending.markerURL.path
        )
        await outbox.reconcileForTesting()
        #expect(try storedDeliveryIDs(databaseURL: databaseURL) == [
            "outbox-older-pending", "outbox-newer-ready",
        ])
        #expect(FileManager.default.fileExists(atPath: partialPending.markerURL.path))

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)],
            ofItemAtPath: partialPending.markerURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)],
            ofItemAtPath: missingSharedMemoryPending.markerURL.path
        )
        await outbox.reconcileForTesting()
        #expect(!FileManager.default.fileExists(atPath: partialPending.markerURL.path))
        #expect(sharedMemoryIsMissing(partialPending.sharedMemoryName))
        #expect(!FileManager.default.fileExists(atPath: missingSharedMemoryPending.markerURL.path))
    }

    @Test func outboxPendingGraceTimerRecoversWithoutPeriodicDelay() async throws {
        let root = try temporaryDirectory(named: "outbox-pending-timer")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let outboxURL = root.appendingPathComponent("outbox", isDirectory: true)
        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let outbox = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: "com.cmuxterm.test.outbox-pending-timer",
            deliveryQueue: queue,
            reconciliationInterval: 60,
            pendingRecoveryGrace: 0.05
        ))
        let record = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-pending-timer",
                payload: Data("timer".utf8),
                environment: testEnvironment(root: root)
            ),
            capability: outbox.issueCapability(),
            directoryURL: outboxURL,
            order: 1,
            markerPrefix: "pending"
        )
        defer { shm_unlink(record.sharedMemoryName) }

        await outbox.start()
        let recovered = await waitUntil(timeout: .seconds(1)) {
            (try? await queue.diagnosticStatus(for: "outbox-pending-timer")) != nil
        }
        #expect(recovered)
        #expect(!FileManager.default.fileExists(atPath: record.markerURL.path))
        #expect(sharedMemoryIsMissing(record.sharedMemoryName))
        await outbox.stop()
    }

    @Test func transientSharedMemoryFailurePreservesRecordForRetry() async throws {
        let root = try temporaryDirectory(named: "outbox-transient-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let outboxURL = root.appendingPathComponent("outbox", isDirectory: true)
        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let injectedError = AgentHookOneShotErrno(EIO)
        let outbox = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: "com.cmuxterm.test.outbox-transient",
            deliveryQueue: queue,
            reconciliationInterval: 60,
            sharedMemoryReadErrorForTesting: { injectedError.take() }
        ))
        let record = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-transient-retry",
                payload: Data("retry".utf8),
                environment: testEnvironment(root: root)
            ),
            capability: outbox.issueCapability(),
            directoryURL: outboxURL,
            order: 1
        )
        let laterRecord = try publishOutboxRecord(
            message: try outboxMessage(
                deliveryID: "outbox-transient-later",
                payload: Data("later".utf8),
                environment: testEnvironment(root: root)
            ),
            capability: outbox.issueCapability(),
            directoryURL: outboxURL,
            order: 2
        )
        defer {
            shm_unlink(record.sharedMemoryName)
            shm_unlink(laterRecord.sharedMemoryName)
        }

        await outbox.reconcileForTesting()
        #expect(try await queue.diagnosticStatus(for: "outbox-transient-retry") == nil)
        #expect(try await queue.diagnosticStatus(for: "outbox-transient-later") == nil)
        #expect(FileManager.default.fileExists(atPath: record.markerURL.path))
        #expect(!sharedMemoryIsMissing(record.sharedMemoryName))
        #expect(FileManager.default.fileExists(atPath: laterRecord.markerURL.path))

        await outbox.reconcileForTesting()
        #expect(try storedDeliveryIDs(databaseURL: databaseURL) == [
            "outbox-transient-retry", "outbox-transient-later",
        ])
        #expect(!FileManager.default.fileExists(atPath: record.markerURL.path))
        #expect(sharedMemoryIsMissing(record.sharedMemoryName))
    }

    @Test func invalidPersistentOutboxSecretDisablesPreparation() async throws {
        let root = try temporaryDirectory(named: "outbox-invalid-secret")
        defer { try? FileManager.default.removeItem(at: root) }
        let outboxURL = root.appendingPathComponent("outbox", isDirectory: true)
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let prepared = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: "com.cmuxterm.test.outbox-invalid-secret",
            deliveryQueue: queue
        ))
        await prepared.stop()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: prepared.capabilitySecretURL.path
        )

        #expect(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: "com.cmuxterm.test.outbox-invalid-secret",
            deliveryQueue: queue
        ) == nil)
    }

    @Test func encodedEventPreservesExactPayloadAndValidatedEnvironment() throws {
        let payload = Data([0x00, 0x7b, 0x22, 0xff, 0x0a])
        let event = try #require(makeEvent(
            deliveryID: "encoded-event",
            payload: payload,
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-test.sock",
                "CMUX_AGENT_LAUNCH_CWD": "/tmp/project with spaces",
                "CMUX_CUSTOM_CLAUDE_PATH": "/tmp/Claude Code/bin/claude",
                "CMUX_TAG": "test-tag",
                "ANTHROPIC_SMALL_FAST_MODEL": "vertex-haiku-id",
                "HTTPS_PROXY": "http://127.0.0.1:8080",
                "OPENAI_API_KEY": "openai-test-key",
                "OPENCODE_CONFIG_DIR": "/tmp/opencode config",
                "PI_CONFIG_DIR": "/tmp/pi config",
            ]
        ))

        #expect(event.payload == payload)
        #expect(event.socketPath == "/tmp/cmux-test.sock")
        #expect(event.environment["CMUX_AGENT_LAUNCH_CWD"] == "/tmp/project with spaces")
        #expect(event.environment["CMUX_CUSTOM_CLAUDE_PATH"] == "/tmp/Claude Code/bin/claude")
        #expect(event.environment["ANTHROPIC_SMALL_FAST_MODEL"] == "vertex-haiku-id")
        #expect(event.environment["HTTPS_PROXY"] == "http://127.0.0.1:8080")
        #expect(event.environment["OPENAI_API_KEY"] == "openai-test-key")
        #expect(event.environment["OPENCODE_CONFIG_DIR"] == "/tmp/opencode config")
        #expect(event.environment["PI_CONFIG_DIR"] == "/tmp/pi config")
        #expect(event.durableEnvironment["OPENAI_API_KEY"] == nil)
        #expect(event.ephemeralEnvironment["OPENAI_API_KEY"] == "openai-test-key")

        for subcommand in [
            "session-start", "prompt-submit", "stop",
            "pre-tool-use", "post-tool-use", "notification",
            "feed:PreToolUse", "feed:PermissionRequest", "feed:PostToolUse",
            "feed:PreCompact", "feed:PostCompact", "feed:SubagentStart", "feed:SubagentStop",
        ] {
            #expect(makeEvent(
                deliveryID: "accepted:\(subcommand)",
                payload: payload,
                environment: ["CMUX_SOCKET_PATH": "/tmp/cmux-test.sock"],
                subcommand: subcommand
            ) != nil)
        }
        #expect(makeEvent(
            deliveryID: "invalid/id",
            payload: payload,
            environment: ["CMUX_SOCKET_PATH": "/tmp/cmux-test.sock"]
        ) == nil)
        #expect(makeEvent(
            deliveryID: "invalid event",
            payload: payload,
            environment: ["CMUX_SOCKET_PATH": "/tmp/cmux-test.sock"]
        ) == nil)

        let sanitizedUnknownEnvironment = makeEvent(
            deliveryID: "unknown-environment",
            payload: payload,
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-test.sock",
                "UNTRUSTED_KEY": "value",
            ]
        )
        #expect(sanitizedUnknownEnvironment != nil)
        #expect(sanitizedUnknownEnvironment?.environment["UNTRUSTED_KEY"] == nil)
        #expect(makeEvent(
            deliveryID: "missing-socket",
            payload: payload,
            environment: ["CMUX_TAG": "test-tag"]
        ) == nil)
    }

    @Test func transientSecretReadFailurePreservesActiveAuthorityForRecovery() async throws {
        let root = try temporaryDirectory(named: "outbox-transient-secret-read")
        defer { try? FileManager.default.removeItem(at: root) }
        let outboxURL = root.appendingPathComponent("outbox", isDirectory: true)
        let budgetURL = outboxURL.appendingPathComponent(".quota-v1")
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let audience = "com.cmuxterm.test.outbox-transient-secret-read"
        let original = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: audience,
            deliveryQueue: queue
        ))
        await original.stop()
        let originalBudget = try Data(contentsOf: budgetURL)
        let originalGeneration = originalBudget.subdata(in: 40..<56)

        let injectionKey = "CMUX_TEST_AGENT_HOOK_OUTBOX_SECRET_READ_FAILURE_PATH"
        #expect(setenv(injectionKey, outboxURL.path, 1) == 0)
        var injectionInstalled = true
        defer {
            if injectionInstalled { unsetenv(injectionKey) }
        }
        #expect(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: audience,
            deliveryQueue: queue
        ) == nil)
        let budgetAfterFailure = try Data(contentsOf: budgetURL)
        #expect(budgetAfterFailure.subdata(in: 40..<56) == originalGeneration)
        #expect(budgetAfterFailure[56] == 1)

        unsetenv(injectionKey)
        injectionInstalled = false
        let recovered = try #require(AgentHookOutbox.prepare(
            directoryURL: outboxURL,
            audience: audience,
            deliveryQueue: queue
        ))
        let recoveredBudget = try Data(contentsOf: budgetURL)
        #expect(recoveredBudget.subdata(in: 40..<56) == originalGeneration)
        #expect(recoveredBudget[56] == 1)
        await recovered.stop()
    }

    @Test func pendingQueueHasFixedRowAndByteAdmissionBounds() async throws {
        let rowRoot = try temporaryDirectory(named: "pending-row-budget")
        defer { try? FileManager.default.removeItem(at: rowRoot) }
        let rowDatabaseURL = rowRoot.appendingPathComponent("deliveries.sqlite3")
        let rowQueue = AgentHookDeliveryQueue(
            databaseURL: rowDatabaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        var acceptedRows = 0
        var rowRejection: Error?
        for index in 0...4_096 {
            let event = try #require(makeEvent(
                deliveryID: "row-budget-\(index)",
                payload: Data([UInt8(truncatingIfNeeded: index)]),
                environment: testEnvironment(root: rowRoot, surfaceID: "row-\(index)")
            ))
            do {
                try rowQueue.enqueue(event)
                acceptedRows += 1
            } catch {
                rowRejection = error
                break
            }
        }
        #expect(acceptedRows == 4_096)
        #expect(rowRejection != nil)
        #expect(try storedDeliveryIDs(databaseURL: rowDatabaseURL).count == 4_096)

        let byteRoot = try temporaryDirectory(named: "pending-byte-budget")
        defer { try? FileManager.default.removeItem(at: byteRoot) }
        let byteDatabaseURL = byteRoot.appendingPathComponent("deliveries.sqlite3")
        let byteQueue = AgentHookDeliveryQueue(
            databaseURL: byteDatabaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let payload = Data(repeating: 0x5a, count: 4 * 1024 * 1024)
        var acceptedBytes = 0
        var byteRejection: Error?
        for index in 0..<17 {
            let event = try #require(makeEvent(
                deliveryID: "byte-budget-\(index)",
                payload: payload,
                environment: testEnvironment(root: byteRoot, surfaceID: "byte-\(index)")
            ))
            do {
                try byteQueue.enqueue(event)
                acceptedBytes += 1
            } catch {
                byteRejection = error
                break
            }
        }
        #expect((15...16).contains(acceptedBytes))
        #expect(byteRejection != nil)
        #expect(try storedDeliveryIDs(databaseURL: byteDatabaseURL).count == acceptedBytes)
    }

    @Test func pendingCredentialOverlayHasFixedMemoryBound() async throws {
        let root = try temporaryDirectory(named: "ephemeral-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let secret = String(repeating: "s", count: 128 * 1024)
        var accepted = 0
        var rejection: Error?
        for index in 0..<129 {
            let event = try #require(makeEvent(
                deliveryID: "ephemeral-budget-\(index)",
                payload: Data("credential-\(index)".utf8),
                environment: testEnvironment(root: root, surfaceID: "credential-\(index)")
                    .merging(["OPENAI_API_KEY": secret], uniquingKeysWith: { _, new in new })
            ))
            do {
                try queue.enqueue(event)
                accepted += 1
            } catch {
                rejection = error
                break
            }
        }
        #expect((127...128).contains(accepted))
        #expect(rejection != nil)
        #expect(try storedDeliveryIDs(databaseURL: databaseURL).count == accepted)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("deliveries.sqlite3") {
            let bytes = (try? Data(contentsOf: file)) ?? Data()
            #expect(bytes.range(of: Data(secret.prefix(128).utf8)) == nil)
        }
    }

    @Test func startupPrunesOldestDeliveredReceiptsToFixedDedupeWindow() throws {
        let root = try temporaryDirectory(named: "receipt-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        try createDeliveredReceiptDatabase(at: databaseURL, count: 4_097)

        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        _ = queue

        let retained = try storedDeliveryIDs(databaseURL: databaseURL)
        #expect(retained.count == 4_096)
        #expect(retained.first == "receipt-0001")
        #expect(retained.last == "receipt-4096")
        #expect(!retained.contains("receipt-0000"))
    }

    @Test func deliveryIdentityIgnoresTransportOnlyDeliveryIDEnvironment() async throws {
        let root = try temporaryDirectory(named: "delivery-id-parity")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let unavailableQueue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let native = try #require(makeEvent(
            deliveryID: "native-fallback-parity",
            payload: Data("same-payload".utf8),
            environment: testEnvironment(root: root)
        ))
        var fallbackEnvironment = testEnvironment(root: root)
        fallbackEnvironment["CMUX_AGENT_HOOK_DELIVERY_ID"] = "native-fallback-parity"
        let fallback = try #require(makeEvent(
            deliveryID: "native-fallback-parity",
            payload: Data("same-payload".utf8),
            environment: fallbackEnvironment
        ))

        #expect(native.contentDigest == fallback.contentDigest)
        #expect(fallback.environment["CMUX_AGENT_HOOK_DELIVERY_ID"] == nil)
        try unavailableQueue.enqueue(native)
        try unavailableQueue.enqueue(fallback)
        await unavailableQueue.waitUntilCurrentDrainFinishes()
        #expect(try await unavailableQueue.diagnosticStatus(for: native.deliveryID)?["state"] == "pending")
    }

    @Test func secretsStayMemoryOnlyButReachLiveDelivery() async throws {
        let root = try temporaryDirectory(named: "ephemeral-secrets")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let scriptURL = root.appendingPathComponent("deliver.sh")
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            printf '%s\n' "$ANTHROPIC_API_KEY" "$AWS_SECRET_ACCESS_KEY" "$OPENAI_API_KEY" \
              "$XAI_API_KEY" "$GEMINI_API_KEY" "$OPENROUTER_API_KEY" > "$TMPDIR/captured-secrets"
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { scriptURL },
            processTimeout: 2,
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        var environment = testEnvironment(root: root)
        let secrets = [
            "ANTHROPIC_API_KEY": "anthropic-memory-only",
            "AWS_SECRET_ACCESS_KEY": "aws-memory-only",
            "OPENAI_API_KEY": "openai-memory-only",
            "XAI_API_KEY": "xai-memory-only",
            "GEMINI_API_KEY": "gemini-memory-only",
            "OPENROUTER_API_KEY": "openrouter-memory-only",
        ]
        environment.merge(secrets, uniquingKeysWith: { _, new in new })
        let event = try #require(makeEvent(
            deliveryID: "ephemeral-secrets",
            payload: Data("payload".utf8),
            environment: environment
        ))

        try queue.enqueue(event)
        await queue.waitUntilCurrentDrainFinishes()
        #expect(try lines(at: root.appendingPathComponent("captured-secrets")) == [
            "anthropic-memory-only", "aws-memory-only", "openai-memory-only",
            "xai-memory-only", "gemini-memory-only", "openrouter-memory-only",
        ])
        let storedEnvironment = try storedEnvironmentJSON(databaseURL: databaseURL, deliveryID: event.deliveryID)
        for secret in secrets.values {
            #expect(!storedEnvironment.contains(secret))
            for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasPrefix("deliveries.sqlite3") {
                let bytes = (try? Data(contentsOf: file)) ?? Data()
                #expect(bytes.range(of: Data(secret.utf8)) == nil)
            }
        }
    }

    @Test func activeDrainCannotObserveDurableRowBeforeCredentialOverlay() async throws {
        let root = try temporaryDirectory(named: "credential-publication-race")
        let releaseFirstURL = root.appendingPathComponent("release-first")
        let releaseEnqueueURL = root.appendingPathComponent("release-enqueue")
        defer {
            try? Data().write(to: releaseFirstURL)
            try? Data().write(to: releaseEnqueueURL)
            try? FileManager.default.removeItem(at: root)
        }
        let scriptURL = root.appendingPathComponent("deliver.sh")
        let durableCommitURL = root.appendingPathComponent("durable-commit")
        let capturedSecretURL = root.appendingPathComponent("captured-secret")
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            if [ "$CMUX_AGENT_HOOK_DELIVERY_ID" = "credential-race-blocker" ]; then
              : > "$TMPDIR/first-started"
              while [ ! -e "$TMPDIR/release-first" ]; do /bin/sleep 0.005; done
            else
              printf '%s' "${OPENAI_API_KEY-unset}" > "$TMPDIR/captured-secret"
            fi
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 2,
            retryBaseDelay: 60,
            retryMaximumDelay: 60,
            maximumConcurrentDeliveries: 1,
            afterDurableCommitForTesting: { deliveryID in
                guard deliveryID == "credential-race-secret" else { return }
                try? Data().write(to: durableCommitURL)
                while !FileManager.default.fileExists(atPath: releaseEnqueueURL.path) {
                    Darwin.usleep(1_000)
                }
            }
        )
        let blocker = try #require(makeEvent(
            deliveryID: "credential-race-blocker",
            payload: Data("blocker".utf8),
            environment: testEnvironment(root: root)
        ))
        var credentialEnvironment = testEnvironment(root: root)
        credentialEnvironment["OPENAI_API_KEY"] = "publication-race-secret"
        let credentialDelivery = try #require(makeEvent(
            deliveryID: "credential-race-secret",
            payload: Data("credential".utf8),
            environment: credentialEnvironment
        ))

        try queue.enqueue(blocker)
        let blockerStarted = await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("first-started").path)
        }
        #expect(blockerStarted)

        let enqueueTask = Task.detached {
            try queue.enqueue(credentialDelivery)
        }
        let rowCommitted = await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: durableCommitURL.path)
        }
        #expect(rowCommitted)
        try Data().write(to: releaseFirstURL)

        let credentialDelivered = await waitUntil(timeout: .seconds(2)) {
            guard let captured = try? Data(contentsOf: capturedSecretURL) else { return false }
            return !captured.isEmpty
        }
        #expect(credentialDelivered)
        if credentialDelivered {
            #expect(try String(contentsOf: capturedSecretURL, encoding: .utf8) == "publication-race-secret")
        }

        try Data().write(to: releaseEnqueueURL)
        try await enqueueTask.value
        await queue.waitUntilCurrentDrainFinishes()
    }

    @Test func openingLegacyQueueScrubsCredentialValuesFromPendingRows() throws {
        let root = try temporaryDirectory(named: "credential-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let rawLaunchArguments = [
            "/usr/local/bin/codex",
            "--remote", "wss://relay.example.test/session?token=legacy-argv-secret",
            "--model", "gpt-5.4",
            "legacy prompt secret",
        ]
        let rawLaunchArgumentsBase64 = nulSeparatedBase64(rawLaunchArguments)
        let secretEnvironment: [String: String] = [
            "OPENAI_API_KEY": "legacy-openai-api-secret",
            "AWS_CONTAINER_AUTHORIZATION_TOKEN": "legacy-container-auth-secret",
            "AWS_SECURITY_TOKEN": "legacy-security-token-secret",
            "AWS_BEARER_TOKEN_BEDROCK": "legacy-bedrock-bearer-secret",
            "OPENAI_ADMIN_KEY": "legacy-openai-admin-secret",
            "OPENAI_BEARER_TOKEN": "legacy-openai-bearer-secret",
            "HTTPS_PROXY": "https://legacy-user:legacy-password@proxy.example.test:8443",
            "HERMES_CODEX_BASE_URL": "https://legacy-user:legacy-password@api.example.test/v1",
            "OPENAI_BASE_URL": "https://api.example.test/v1?access_token=legacy-query-secret",
        ]
        let newlyUnsafeEnvironment: [String: String] = [
            "CMUX_AGENT_LAUNCH_ARGV_B64": rawLaunchArgumentsBase64,
            "CMUX_AGENT_LAUNCH_KIND": "codex",
            "AWS_CONTAINER_CREDENTIALS_FULL_URI":
                "http://169.254.170.2/v2/credentials/legacy-path-capability",
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI":
                "/v2/credentials/legacy-path-capability",
            "GOOGLE_CREDENTIALS_JSON":
                #"{"type":"service_account","private_key":"legacy-provider-blob-secret"}"#,
            "AWS_CREDENTIAL_PROVIDER_BLOB":
                "[default]\naws_access_key_id=legacy-provider-blob-secret",
            "OPENROUTER_BASE_URL":
                "https://api.example.test/v1?sig=legacy-signed-url-secret",
            "XAI_BASE_URL":
                "api.example.test/not-an-absolute-url",
            "OPENAI_EXPERIMENTAL_PROVIDER_STATE":
                "legacy-unknown-provider-value",
        ]
        let durableLocators: [String: String] = [
            "AWS_CONFIG_FILE": "/tmp/aws-config",
            "AWS_SHARED_CREDENTIALS_FILE": "/tmp/aws-credentials",
            "AWS_WEB_IDENTITY_TOKEN_FILE": "/tmp/aws-web-identity-token",
            "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE": "/tmp/aws-container-authorization-token",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/google-credentials.json",
            "ANTHROPIC_BASE_URL": "https://api.anthropic.com/v1",
            "HTTP_PROXY": "http://127.0.0.1:8080",
        ]
        var environment = testEnvironment(root: root)
        environment.merge(secretEnvironment, uniquingKeysWith: { _, new in new })
        environment.merge(newlyUnsafeEnvironment, uniquingKeysWith: { _, new in new })
        environment.merge(durableLocators, uniquingKeysWith: { _, new in new })
        let legacy = try #require(makeEvent(
            deliveryID: "legacy-credential-row",
            payload: Data("legacy".utf8),
            environment: environment
        ))
        let legacyDigest = contentDigest(
            agent: legacy.agent,
            subcommand: legacy.subcommand,
            payload: legacy.payload,
            environment: legacy.environment
        )
        try createLegacyDeliveryDatabase(
            at: databaseURL,
            event: legacy,
            contentDigest: legacyDigest,
            nextAttemptAt: Date().addingTimeInterval(3_600).timeIntervalSince1970
        )

        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        withExtendedLifetime(queue) {}

        let storedData = Data(try storedEnvironmentJSON(
            databaseURL: databaseURL,
            deliveryID: legacy.deliveryID
        ).utf8)
        let stored = try #require(
            JSONSerialization.jsonObject(with: storedData) as? [String: String]
        )
        for key in secretEnvironment.keys {
            #expect(stored[key] == nil)
        }
        for key in newlyUnsafeEnvironment.keys where key != "CMUX_AGENT_LAUNCH_KIND" {
            if key == "CMUX_AGENT_LAUNCH_ARGV_B64" {
                let sanitized = try #require(stored[key])
                #expect(decodedNulSeparatedBase64(sanitized) == [
                    "/usr/local/bin/codex", "--model", "gpt-5.4",
                ])
                #expect(sanitized != rawLaunchArgumentsBase64)
            } else {
                #expect(stored[key] == nil)
            }
        }
        #expect(stored["CMUX_AGENT_LAUNCH_KIND"] == "codex")
        for (key, value) in durableLocators {
            #expect(stored[key] == value)
        }

        let storedDigest = try storedContentDigest(
            databaseURL: databaseURL,
            deliveryID: legacy.deliveryID
        )
        #expect(storedDigest == contentDigest(
            agent: legacy.agent,
            subcommand: legacy.subcommand,
            payload: legacy.payload,
            environment: stored
        ))
        #expect(storedDigest != legacyDigest)
        try queue.enqueue(legacy)

        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("deliveries.sqlite3") {
            let bytes = try Data(contentsOf: file)
            for secret in Array(secretEnvironment.values) + [
                rawLaunchArgumentsBase64,
                newlyUnsafeEnvironment["AWS_CONTAINER_CREDENTIALS_FULL_URI"] ?? "",
                newlyUnsafeEnvironment["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"] ?? "",
                newlyUnsafeEnvironment["GOOGLE_CREDENTIALS_JSON"] ?? "",
                newlyUnsafeEnvironment["AWS_CREDENTIAL_PROVIDER_BLOB"] ?? "",
                newlyUnsafeEnvironment["OPENROUTER_BASE_URL"] ?? "",
                newlyUnsafeEnvironment["XAI_BASE_URL"] ?? "",
                newlyUnsafeEnvironment["OPENAI_EXPERIMENTAL_PROVIDER_STATE"] ?? "",
            ] where !secret.isEmpty {
                #expect(bytes.range(of: Data(secret.utf8)) == nil)
            }
        }
    }

    @Test func migratedCredentialRowAcceptsRetryAndRepublishesOverlay() async throws {
        let root = try temporaryDirectory(named: "credential-migration-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let scriptURL = root.appendingPathComponent("deliver.sh")
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            printf '%s' "$OPENAI_API_KEY" > "$TMPDIR/captured-migrated-secret"
            """
        )
        var environment = testEnvironment(root: root)
        environment["OPENAI_API_KEY"] = "migrated-retry-secret"
        let event = try #require(makeEvent(
            deliveryID: "legacy-credential-retry",
            payload: Data("legacy-retry".utf8),
            environment: environment
        ))
        let legacyDigest = contentDigest(
            agent: event.agent,
            subcommand: event.subcommand,
            payload: event.payload,
            environment: event.environment
        )
        #expect(legacyDigest != event.contentDigest)
        try createLegacyDeliveryDatabase(
            at: databaseURL,
            event: event,
            contentDigest: legacyDigest,
            nextAttemptAt: Date().addingTimeInterval(3_600).timeIntervalSince1970
        )

        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { scriptURL },
            processTimeout: 2,
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        try queue.enqueue(event)
        try await queue.retryPendingDeliveries()
        await queue.waitUntilCurrentDrainFinishes()

        #expect(
            try String(
                contentsOf: root.appendingPathComponent("captured-migrated-secret"),
                encoding: .utf8
            ) == "migrated-retry-secret"
        )
        #expect(try await queue.diagnosticStatus(for: event.deliveryID)?["state"] == "delivered")
    }

    @Test func feedTelemetryTargetsUseTheBoundedDeliveryQueue() async throws {
        let root = try temporaryDirectory(named: "feed-targets")
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("deliver.sh")
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            printf '%s\n' "$*" >> "$TMPDIR/arguments"
            /bin/cat >/dev/null
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 2,
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let targets = [
            "feed:PreToolUse", "feed:PermissionRequest", "feed:PostToolUse",
            "feed:PreCompact", "feed:PostCompact", "feed:SubagentStart", "feed:SubagentStop",
        ]
        for (index, target) in targets.enumerated() {
            let event = try #require(makeEvent(
                deliveryID: "feed-target-\(index)",
                payload: Data("payload-\(index)".utf8),
                environment: testEnvironment(root: root),
                subcommand: target
            ))
            try queue.enqueue(event)
        }
        await queue.waitUntilCurrentDrainFinishes()

        #expect(try lines(at: root.appendingPathComponent("arguments")) == targets.map {
            "--socket /tmp/cmux-agent-hook-delivery-test.sock hooks feed --source codex --event \($0.dropFirst("feed:".count))"
        })
    }

    @Test func diskBacklogSurvivesQueueReplacementAndDeduplicatesBurst() async throws {
        let root = try temporaryDirectory(named: "burst")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let scriptURL = root.appendingPathComponent("deliver.sh")
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            if ! /bin/mkdir "$TMPDIR/active-child" 2>/dev/null; then
              printf 'overlap\n' >> "$TMPDIR/overlap"
            fi
            trap '/bin/rmdir "$TMPDIR/active-child" 2>/dev/null || true' EXIT
            /bin/cat > "$TMPDIR/payload-$CMUX_AGENT_HOOK_DELIVERY_ID"
            printf '%s\n' "$CMUX_AGENT_HOOK_DELIVERY_ID" >> "$TMPDIR/delivered"
            /bin/sleep 0.005
            """
        )

        let unavailableQueue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { nil },
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        var events: [AgentHookDeliveryEvent] = []
        for index in 0..<64 {
            let payload = Data("payload-\(index)".utf8)
            let event = try #require(makeEvent(
                deliveryID: "burst-\(index)",
                payload: payload,
                environment: testEnvironment(root: root)
            ))
            events.append(event)
            try unavailableQueue.enqueue(event)
        }
        let emptyPayloadEvent = try #require(makeEvent(
            deliveryID: "burst-empty",
            payload: Data(),
            environment: testEnvironment(root: root)
        ))
        events.append(emptyPayloadEvent)
        try unavailableQueue.enqueue(emptyPayloadEvent)
        await unavailableQueue.waitUntilCurrentDrainFinishes()

        let recoveredQueue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { scriptURL },
            processTimeout: 2,
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        try await recoveredQueue.retryPendingDeliveries()
        await recoveredQueue.waitUntilCurrentDrainFinishes()

        let delivered = try lines(at: root.appendingPathComponent("delivered"))
        #expect(delivered.count == 65)
        #expect(Set(delivered) == Set((0..<64).map { "burst-\($0)" } + ["burst-empty"]))
        #expect(Array(delivered.prefix(64)) == (0..<64).map { "burst-\($0)" })
        #expect(delivered.last == "burst-empty")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("overlap").path))
        for index in 0..<64 {
            let actual = try Data(contentsOf: root.appendingPathComponent("payload-burst-\(index)"))
            #expect(actual == Data("payload-\(index)".utf8))
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("payload-burst-empty")).isEmpty)

        try recoveredQueue.enqueue(events[0])
        await recoveredQueue.waitUntilCurrentDrainFinishes()
        #expect(try lines(at: root.appendingPathComponent("delivered")).count == 65)

        let conflicting = try #require(makeEvent(
            deliveryID: "burst-0",
            payload: Data("different".utf8),
            environment: testEnvironment(root: root)
        ))
        var collisionWasRejected = false
        do {
            try recoveredQueue.enqueue(conflicting)
        } catch {
            collisionWasRejected = true
        }
        #expect(collisionWasRejected)
    }

    @Test func independentOrderingKeysUseBoundedParallelDelivery() async throws {
        let root = try temporaryDirectory(named: "parallel-keys")
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("deliver.sh")
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            active="$TMPDIR/active-$CMUX_AGENT_HOOK_DELIVERY_ID"
            /bin/mkdir "$active"
            set -- "$TMPDIR"/active-*
            printf '%s\n' "$#" >> "$TMPDIR/concurrency-counts"
            /bin/sleep 0.15
            /bin/rmdir "$active"
            printf '%s\n' "$CMUX_AGENT_HOOK_DELIVERY_ID" >> "$TMPDIR/delivered"
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 2,
            retryBaseDelay: 60,
            retryMaximumDelay: 60,
            maximumConcurrentDeliveries: 100
        )
        let started = ContinuousClock().now
        for index in 0..<36 {
            let event = try #require(makeEvent(
                deliveryID: "parallel-\(index)",
                payload: Data("payload-\(index)".utf8),
                environment: testEnvironment(root: root, surfaceID: "surface-\(index)")
            ))
            try queue.enqueue(event)
        }
        await queue.waitUntilCurrentDrainFinishes()
        let elapsed = started.duration(to: ContinuousClock().now)

        let activeCounts = try lines(at: root.appendingPathComponent("concurrency-counts")).compactMap(Int.init)
        let maximumActive = try #require(activeCounts.max())
        #expect(maximumActive > 1)
        #expect(activeCounts.allSatisfy { $0 <= 32 })
        #expect(elapsed < .seconds(2.5))
        #expect(Set(try lines(at: root.appendingPathComponent("delivered"))).count == 36)
    }

    @Test func detachedDoubleForksRetainTheConfiguredProcessGroupBudget() async throws {
        let root = try temporaryDirectory(named: "detached-process-group-budget")
        let scriptURL = root.appendingPathComponent("deliver.sh")
        let firstForkURL = root.appendingPathComponent("first-fork.sh")
        let lingerURL = root.appendingPathComponent("linger.sh")
        defer {
            if let descendantPIDs = try? lines(at: root.appendingPathComponent("descendant-pids")) {
                for rawPID in descendantPIDs {
                    if let pid = Int32(rawPID) {
                        Darwin.kill(pid, SIGKILL)
                    }
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            /bin/sh "$TMPDIR/first-fork.sh" "$CMUX_AGENT_HOOK_DELIVERY_ID" &
            exit 0
            """
        )
        try writeExecutable(
            at: firstForkURL,
            contents: """
            #!/bin/sh
            /bin/sh "$TMPDIR/linger.sh" "$1" &
            exit 0
            """
        )
        try writeExecutable(
            at: lingerURL,
            contents: """
            #!/bin/sh
            delivery_id="$1"
            printf '%s\n' "$$" >> "$TMPDIR/descendant-pids"
            active="$TMPDIR/active-$delivery_id"
            /bin/mkdir "$active"
            set -- "$TMPDIR"/active-*
            printf '%s\n' "$#" >> "$TMPDIR/process-group-counts"
            /bin/sleep 0.4
            /bin/rmdir "$active"
            printf '%s\n' "$delivery_id" >> "$TMPDIR/descendants-finished"
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 2,
            lingeringProcessGroupTimeout: 2,
            terminationGrace: 0.05,
            retryBaseDelay: 60,
            retryMaximumDelay: 60,
            maximumConcurrentDeliveries: 8
        )

        for index in 0..<64 {
            let event = try #require(makeEvent(
                deliveryID: "detached-budget-\(index)",
                payload: Data(),
                environment: testEnvironment(root: root, surfaceID: "surface:detached-budget-\(index)")
            ))
            try queue.enqueue(event)
        }
        await queue.waitUntilCurrentDrainFinishes()

        let observedProcessGroups = try lines(
            at: root.appendingPathComponent("process-group-counts")
        ).compactMap(Int.init)
        #expect(observedProcessGroups.count == 64)
        #expect(observedProcessGroups.max() == 8)
        #expect(observedProcessGroups.allSatisfy { $0 <= 8 })
        #expect(Set(try lines(at: root.appendingPathComponent("descendants-finished"))).count == 64)
        #expect(
            (try FileManager.default.contentsOfDirectory(atPath: root.path))
                .allSatisfy { !$0.hasPrefix("active-") }
        )
        for rawPID in try lines(at: root.appendingPathComponent("descendant-pids")) {
            let pid = try #require(Int32(rawPID))
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test func closedSupervisorInputCannotTerminateTheAppDuringPayloadUpload() async throws {
        let root = try temporaryDirectory(named: "supervisor-closed-input")
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisorURL = root.appendingPathComponent("close-input.sh")
        try writeExecutable(
            at: supervisorURL,
            contents: """
            #!/bin/sh
            exec 0<&-
            /bin/sleep 0.05
            exit 74
            """
        )

        let launch = try await AgentHookDeliverySupervisorClient.launch(
            supervisorURL: supervisorURL,
            childURL: URL(fileURLWithPath: "/usr/bin/true"),
            childArguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            payload: Data(repeating: 0xa5, count: 8 * 1024 * 1024),
            errorOutput: .nullDevice,
            directTimeout: 2,
            groupTimeout: 3,
            terminationGrace: 0.05
        )

        guard case .transportError(let detail) = launch.directResult else {
            Issue.record("Expected a closed supervisor input to report a transport error")
            return
        }
        #expect(detail.contains("Writing the supervisor payload failed"))
        _ = await launch.handle.waitForTermination()
    }

    @Test func rawSpawnCannotInheritTheSupervisorControlLease() async throws {
        let root = try temporaryDirectory(named: "supervisor-control-cloexec")
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisorURL = root.appendingPathComponent("lease-supervisor.sh")
        try writeExecutable(
            at: supervisorURL,
            contents: """
            #!/bin/sh
            printf 'CMUX-HOOK-SUPERVISOR 1 READY %s %s\n' "$$" "$$"
            printf 'CMUX-HOOK-SUPERVISOR 1 RESULT EXIT 0\n'
            exec 1>&-
            /bin/cat >/dev/null
            """
        )

        let launch = try await AgentHookDeliverySupervisorClient.launch(
            supervisorURL: supervisorURL,
            childURL: URL(fileURLWithPath: "/usr/bin/true"),
            childArguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            payload: Data(),
            errorOutput: .nullDevice,
            directTimeout: 2,
            groupTimeout: 3,
            terminationGrace: 0.05
        )
        #expect(launch.directResult == .exited(0))

        let sleeperPID = try spawnRawSleep(seconds: "3")
        defer {
            Darwin.kill(sleeperPID, SIGKILL)
            waitForChild(sleeperPID)
        }
        #expect(Darwin.kill(sleeperPID, 0) == 0)

        let started = ContinuousClock.now
        launch.handle.requestCancellation()
        let supervisorStatus = await launch.handle.waitForTermination()
        let elapsed = started.duration(to: .now)

        #expect(supervisorStatus == 0)
        #expect(elapsed < .seconds(1))
        #expect(Darwin.kill(sleeperPID, 0) == 0)
    }

    @Test func liveSupervisorOwnsDetachedDeliveryGroupUntilItDrains() async throws {
        let root = try temporaryDirectory(named: "owned-supervisor")
        let scriptURL = root.appendingPathComponent("deliver.sh")
        let firstForkURL = root.appendingPathComponent("first-fork.sh")
        let lingerURL = root.appendingPathComponent("linger.sh")
        let supervisorPIDFile = root.appendingPathComponent("supervisor.pid")
        let descendantPIDFile = root.appendingPathComponent("descendant.pid")
        defer {
            for pidFile in [supervisorPIDFile, descendantPIDFile] {
                if let rawPID = try? String(contentsOf: pidFile, encoding: .utf8),
                   let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            : "${CMUX_AGENT_HOOK_DELIVERY_SUPERVISOR_PID:?}"
            printf '%s' "$CMUX_AGENT_HOOK_DELIVERY_SUPERVISOR_PID" > "$TMPDIR/supervisor.pid"
            /bin/sh "$TMPDIR/first-fork.sh" &
            exit 0
            """
        )
        try writeExecutable(
            at: firstForkURL,
            contents: """
            #!/bin/sh
            /bin/sh "$TMPDIR/linger.sh" &
            exit 0
            """
        )
        try writeExecutable(
            at: lingerURL,
            contents: """
            #!/bin/sh
            printf '%s' "$$" > "$TMPDIR/descendant.pid"
            : > "$TMPDIR/descendant-active"
            while [ ! -e "$TMPDIR/release-descendant" ]; do
              /bin/sleep 0.01
            done
            /bin/rm -f "$TMPDIR/descendant-active"
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 2,
            lingeringProcessGroupTimeout: 3,
            terminationGrace: 0.05,
            retryBaseDelay: 60,
            retryMaximumDelay: 60,
            maximumConcurrentDeliveries: 1
        )
        let event = try #require(makeEvent(
            deliveryID: "owned-supervisor",
            payload: Data([0x00, 0xff, 0x0a]),
            environment: testEnvironment(root: root)
        ))

        try queue.enqueue(event)
        let directDeliveryFinished = await waitUntil(timeout: .seconds(2)) {
            let state = try? await queue.diagnosticStatus(for: event.deliveryID)?["state"]
            return state == "delivered"
                && FileManager.default.fileExists(atPath: supervisorPIDFile.path)
                && FileManager.default.fileExists(atPath: descendantPIDFile.path)
                && FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("descendant-active").path
                )
        }
        #expect(directDeliveryFinished)

        let supervisorPID = try #require(Int32(
            String(contentsOf: supervisorPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let descendantPID = try #require(Int32(
            String(contentsOf: descendantPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        #expect(supervisorPID != descendantPID)
        #expect(Darwin.kill(supervisorPID, 0) == 0)
        #expect(Darwin.getpgid(supervisorPID) == supervisorPID)
        #expect(Darwin.getpgid(descendantPID) == supervisorPID)

        try Data().write(to: root.appendingPathComponent("release-descendant"))
        await queue.waitUntilCurrentDrainFinishes()

        for pid in [supervisorPID, descendantPID] {
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test func completedLeaderFreesItsSurfaceLaneWhileDescendantRetainsPermit() async throws {
        let root = try temporaryDirectory(named: "detached-lane-release")
        let scriptURL = root.appendingPathComponent("deliver.sh")
        let firstForkURL = root.appendingPathComponent("first-fork.sh")
        let lingerURL = root.appendingPathComponent("linger.sh")
        let supervisorPIDFile = root.appendingPathComponent("first-supervisor.pid")
        let descendantPIDFile = root.appendingPathComponent("descendant.pid")
        defer {
            for pidFile in [supervisorPIDFile, descendantPIDFile] {
                if let rawPID = try? String(contentsOf: pidFile, encoding: .utf8),
                   let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            if [ "$CMUX_AGENT_HOOK_DELIVERY_ID" = "lane-first" ]; then
              printf '%s' "$CMUX_AGENT_HOOK_DELIVERY_SUPERVISOR_PID" > "$TMPDIR/first-supervisor.pid"
              /bin/sh "$TMPDIR/first-fork.sh" &
              exit 0
            fi
            if [ "$CMUX_AGENT_HOOK_DELIVERY_ID" = "lane-later" ]; then
              if [ -e "$TMPDIR/first-descendant-active" ]; then
                : > "$TMPDIR/later-started-before-descendant-exit"
              fi
              : > "$TMPDIR/later-direct-active"
              attempts=0
              while [ ! -e "$TMPDIR/release-later-direct" ] && [ "$attempts" -lt 400 ]; do
                /bin/sleep 0.01
                attempts=$((attempts + 1))
              done
              if [ ! -e "$TMPDIR/release-later-direct" ]; then
                : > "$TMPDIR/later-release-failsafe"
              fi
              /bin/rm -f "$TMPDIR/later-direct-active"
            elif [ -e "$TMPDIR/first-descendant-active" ]; then
              : > "$TMPDIR/independent-started-before-descendant-exit"
            fi
            : > "$TMPDIR/$CMUX_AGENT_HOOK_DELIVERY_ID-started"
            printf '%s\n' "$CMUX_AGENT_HOOK_DELIVERY_ID" >> "$TMPDIR/leaders-finished"
            """
        )
        try writeExecutable(
            at: firstForkURL,
            contents: """
            #!/bin/sh
            /bin/sh "$TMPDIR/linger.sh" &
            exit 0
            """
        )
        try writeExecutable(
            at: lingerURL,
            contents: """
            #!/bin/sh
            printf '%s' "$$" > "$TMPDIR/descendant.pid"
            : > "$TMPDIR/first-descendant-active"
            attempts=0
            while [ ! -e "$TMPDIR/release-first-descendant" ] && [ "$attempts" -lt 500 ]; do
              /bin/sleep 0.01
              attempts=$((attempts + 1))
            done
            if [ ! -e "$TMPDIR/release-first-descendant" ]; then
              : > "$TMPDIR/descendant-release-failsafe"
            fi
            /bin/rm -f "$TMPDIR/first-descendant-active"
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 5,
            lingeringProcessGroupTimeout: 6,
            terminationGrace: 0.05,
            retryBaseDelay: 60,
            retryMaximumDelay: 60,
            maximumConcurrentDeliveries: 2
        )
        let first = try #require(makeEvent(
            deliveryID: "lane-first",
            payload: Data(),
            environment: testEnvironment(root: root)
        ))
        let later = try #require(makeEvent(
            deliveryID: "lane-later",
            payload: Data(),
            environment: testEnvironment(root: root)
        ))
        let independent = try #require(makeEvent(
            deliveryID: "lane-independent",
            payload: Data(),
            environment: testEnvironment(root: root, surfaceID: "surface:independent")
        ))

        try queue.enqueue(first)
        let firstLeaderCompleted = await waitUntil(timeout: .seconds(2)) {
            let state = try? await queue.diagnosticStatus(for: first.deliveryID)?["state"]
            return FileManager.default.fileExists(
                atPath: root.appendingPathComponent("first-descendant-active").path
            ) && state == "delivered"
        }
        #expect(firstLeaderCompleted)
        let supervisorPID = try #require(Int32(
            String(contentsOf: supervisorPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        #expect(Darwin.kill(supervisorPID, 0) == 0)

        try queue.enqueue(later)
        let sameSurfaceLaneReleased = await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("later-direct-active").path
            )
        }
        #expect(sameSurfaceLaneReleased)

        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("later-started-before-descendant-exit").path
        ))
        #expect(Darwin.kill(supervisorPID, 0) == 0)

        try queue.enqueue(independent)
        let independentStartedWhileBothPermitsOwned = await waitUntil(timeout: .milliseconds(500)) {
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("lane-independent-started").path
            )
        }
        #expect(!independentStartedWhileBothPermitsOwned)

        try Data().write(to: root.appendingPathComponent("release-later-direct"))
        let independentStartedAfterPermitRelease = await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("lane-independent-started").path
            )
        }
        #expect(independentStartedAfterPermitRelease)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("independent-started-before-descendant-exit").path
        ))
        #expect(Darwin.kill(supervisorPID, 0) == 0)

        try Data().write(to: root.appendingPathComponent("release-first-descendant"))
        await queue.waitUntilCurrentDrainFinishes()

        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("descendant-release-failsafe").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("later-release-failsafe").path
        ))
        #expect(try lines(at: root.appendingPathComponent("leaders-finished")) == [
            "lane-later", "lane-independent",
        ])
        let descendantPID = try #require(Int32(
            String(contentsOf: descendantPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        for pid in [supervisorPID, descendantPID] {
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test func leaderExitDoesNotLetHungDescendantOutliveDeliveryDeadline() async throws {
        let root = try temporaryDirectory(named: "detached-process-group-timeout")
        let scriptURL = root.appendingPathComponent("deliver.sh")
        let firstForkURL = root.appendingPathComponent("first-fork.sh")
        let lingerURL = root.appendingPathComponent("linger.sh")
        let descendantPIDFile = root.appendingPathComponent("descendant.pid")
        defer {
            if let rawPID = try? String(contentsOf: descendantPIDFile, encoding: .utf8),
               let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: root)
        }
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            /bin/sh "$TMPDIR/first-fork.sh" &
            exit 0
            """
        )
        try writeExecutable(
            at: firstForkURL,
            contents: """
            #!/bin/sh
            /bin/sh "$TMPDIR/linger.sh" &
            exit 0
            """
        )
        try writeExecutable(
            at: lingerURL,
            contents: """
            #!/bin/sh
            printf '%s' "$$" > "$TMPDIR/descendant.pid"
            trap '' TERM
            while :; do /bin/sleep 1; done
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 2,
            lingeringProcessGroupTimeout: 0.3,
            terminationGrace: 0.05,
            retryBaseDelay: 60,
            retryMaximumDelay: 60,
            maximumConcurrentDeliveries: 1
        )
        let event = try #require(makeEvent(
            deliveryID: "detached-timeout",
            payload: Data(),
            environment: testEnvironment(root: root)
        ))

        try queue.enqueue(event)
        await queue.waitUntilCurrentDrainFinishes()

        let status = try await queue.diagnosticStatus(for: event.deliveryID)
        #expect(status?["state"] == "delivered")
        let descendantPID = try #require(Int32(
            String(contentsOf: descendantPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        errno = 0
        #expect(Darwin.kill(descendantPID, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func cancellingDrainClosesSupervisorLeaseWithoutTouchingUnrelatedSession() async throws {
        let root = try temporaryDirectory(named: "detached-process-group-cancel")
        let scriptURL = root.appendingPathComponent("deliver.sh")
        let firstForkURL = root.appendingPathComponent("first-fork.sh")
        let lingerURL = root.appendingPathComponent("linger.sh")
        let supervisorPIDFile = root.appendingPathComponent("supervisor.pid")
        let descendantPIDFile = root.appendingPathComponent("descendant.pid")
        let unrelatedPIDFile = root.appendingPathComponent("unrelated.pid")
        let unrelatedProcess = Process()
        defer {
            if unrelatedProcess.isRunning {
                unrelatedProcess.terminate()
                unrelatedProcess.waitUntilExit()
            }
            for pidFile in [supervisorPIDFile, descendantPIDFile] {
                if let rawPID = try? String(contentsOf: pidFile, encoding: .utf8),
                   let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        unrelatedProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        unrelatedProcess.arguments = [
            "-c",
            "import os, pathlib, signal; os.setsid(); "
                + "pathlib.Path(os.environ['CMUX_TEST_UNRELATED_PID_FILE']).write_text(str(os.getpid())); "
                + "signal.pause()",
        ]
        var unrelatedEnvironment = ProcessInfo.processInfo.environment
        unrelatedEnvironment["CMUX_TEST_UNRELATED_PID_FILE"] = unrelatedPIDFile.path
        unrelatedProcess.environment = unrelatedEnvironment
        unrelatedProcess.standardOutput = FileHandle.nullDevice
        unrelatedProcess.standardError = FileHandle.nullDevice
        try unrelatedProcess.run()
        let unrelatedSessionReady = await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: unrelatedPIDFile.path)
        }
        #expect(unrelatedSessionReady)
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            printf '%s' "$CMUX_AGENT_HOOK_DELIVERY_SUPERVISOR_PID" > "$TMPDIR/supervisor.pid"
            /bin/sh "$TMPDIR/first-fork.sh" &
            exit 0
            """
        )
        try writeExecutable(
            at: firstForkURL,
            contents: """
            #!/bin/sh
            /bin/sh "$TMPDIR/linger.sh" &
            exit 0
            """
        )
        try writeExecutable(
            at: lingerURL,
            contents: """
            #!/bin/sh
            printf '%s' "$$" > "$TMPDIR/descendant.pid"
            trap '' TERM
            while :; do /bin/sleep 1; done
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 30,
            lingeringProcessGroupTimeout: 30,
            terminationGrace: 0.05,
            retryBaseDelay: 60,
            retryMaximumDelay: 60,
            maximumConcurrentDeliveries: 1
        )
        let event = try #require(makeEvent(
            deliveryID: "detached-cancel",
            payload: Data(),
            environment: testEnvironment(root: root)
        ))

        try queue.enqueue(event)
        let permitTransferred = await waitUntil(timeout: .seconds(2)) {
            let state = try? await queue.diagnosticStatus(for: event.deliveryID)?["state"]
            return FileManager.default.fileExists(atPath: descendantPIDFile.path)
                && state == "delivered"
        }
        #expect(permitTransferred)

        let supervisorPID = try #require(Int32(
            String(contentsOf: supervisorPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let descendantPID = try #require(Int32(
            String(contentsOf: descendantPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let unrelatedPID = try #require(Int32(
            String(contentsOf: unrelatedPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        #expect(Darwin.getpgid(supervisorPID) == supervisorPID)
        #expect(Darwin.getpgid(descendantPID) == supervisorPID)
        #expect(Darwin.getpgid(unrelatedPID) == unrelatedPID)

        await queue.cancelCurrentDrainForTesting()

        let supervisedSessionExited = await waitUntil(timeout: .seconds(1)) {
            Darwin.kill(supervisorPID, 0) == -1 && Darwin.kill(descendantPID, 0) == -1
        }
        #expect(supervisedSessionExited)
        for pid in [supervisorPID, descendantPID] {
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
        #expect(unrelatedProcess.isRunning)
        #expect(Darwin.kill(unrelatedPID, 0) == 0)
        #expect(Darwin.getpgid(unrelatedPID) == unrelatedPID)
    }

    @Test func legacyPendingRowsAreBackfilledBeforeNewEventsDrain() async throws {
        let root = try temporaryDirectory(named: "ordering-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("deliveries.sqlite3")
        let scriptURL = root.appendingPathComponent("deliver.sh")
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            if ! /bin/mkdir "$TMPDIR/active-ordering-key" 2>/dev/null; then
              printf 'overlap\n' >> "$TMPDIR/overlap"
            fi
            printf '%s\n' "$CMUX_AGENT_HOOK_DELIVERY_ID" >> "$TMPDIR/started"
            /bin/sleep 0.15
            printf '%s\n' "$CMUX_AGENT_HOOK_DELIVERY_ID" >> "$TMPDIR/delivered"
            /bin/rmdir "$TMPDIR/active-ordering-key" 2>/dev/null || true
            """
        )
        let legacy = try #require(makeEvent(
            deliveryID: "legacy-session-start",
            payload: Data("legacy".utf8),
            environment: testEnvironment(root: root),
            subcommand: "session-start"
        ))
        try createLegacyDeliveryDatabase(at: databaseURL, event: legacy)

        let queue = AgentHookDeliveryQueue(
            databaseURL: databaseURL,
            executableURLProvider: { scriptURL },
            processTimeout: 2,
            retryBaseDelay: 60,
            retryMaximumDelay: 60,
            maximumConcurrentDeliveries: 4
        )
        let later = try #require(makeEvent(
            deliveryID: "new-prompt-submit",
            payload: Data("new".utf8),
            environment: testEnvironment(root: root),
            subcommand: "prompt-submit"
        ))
        try queue.enqueue(later)
        await queue.waitUntilCurrentDrainFinishes()

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("overlap").path))
        #expect(try lines(at: root.appendingPathComponent("started")) == [
            "legacy-session-start", "new-prompt-submit",
        ])
        #expect(try lines(at: root.appendingPathComponent("delivered")) == [
            "legacy-session-start", "new-prompt-submit",
        ])
    }

    @Test func failedChildBlocksItsOrderingKeyButNotIndependentKeys() async throws {
        let root = try temporaryDirectory(named: "retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("deliver.sh")
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            /bin/cat > "$TMPDIR/payload-$CMUX_AGENT_HOOK_DELIVERY_ID"
            if [ "$CMUX_AGENT_HOOK_DELIVERY_ID" = "retry-first" ] && [ ! -e "$TMPDIR/failed-once" ]; then
              : > "$TMPDIR/failed-once"
              printf 'intentional first failure\n' >&2
              exit 9
            fi
            printf '%s\n' "$CMUX_AGENT_HOOK_DELIVERY_ID" >> "$TMPDIR/delivered"
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 2,
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let first = try #require(makeEvent(
            deliveryID: "retry-first",
            payload: Data("first".utf8),
            environment: testEnvironment(root: root)
        ))
        let later = try #require(makeEvent(
            deliveryID: "retry-later",
            payload: Data("later".utf8),
            environment: testEnvironment(root: root)
        ))
        let independent = try #require(makeEvent(
            deliveryID: "retry-independent",
            payload: Data("independent".utf8),
            environment: testEnvironment(root: root, surfaceID: "surface:independent")
        ))
        try queue.enqueue(first)
        try queue.enqueue(later)
        try queue.enqueue(independent)
        await queue.waitUntilCurrentDrainFinishes()

        let firstFailure = try await queue.diagnosticStatus(for: first.deliveryID)
        let blockedLater = try await queue.diagnosticStatus(for: later.deliveryID)
        let independentSuccess = try await queue.diagnosticStatus(for: independent.deliveryID)
        #expect(firstFailure?["state"] == "pending")
        #expect(firstFailure?["attempts"] == "1")
        #expect(firstFailure?["last_error"]?.contains("status 9") == true)
        #expect(firstFailure?["last_error"]?.contains("intentional first failure") == true)
        #expect(blockedLater?["state"] == "pending")
        #expect(blockedLater?["attempts"] == "0")
        #expect(independentSuccess?["state"] == "delivered")

        try await queue.retryPendingDeliveries()
        await queue.waitUntilCurrentDrainFinishes()
        let retried = try await queue.diagnosticStatus(for: first.deliveryID)
        let unblockedLater = try await queue.diagnosticStatus(for: later.deliveryID)
        #expect(retried?["state"] == "delivered")
        #expect(retried?["attempts"] == "2")
        #expect(unblockedLater?["state"] == "delivered")
        let delivered = try lines(at: root.appendingPathComponent("delivered"))
        #expect(Set(delivered) == ["retry-first", "retry-later", "retry-independent"])
        let firstIndex = try #require(delivered.firstIndex(of: "retry-first"))
        let laterIndex = try #require(delivered.firstIndex(of: "retry-later"))
        #expect(firstIndex < laterIndex)
    }

    @Test func hungChildIsKilledWithinDeadlineAndIndependentKeyRuns() async throws {
        let root = try temporaryDirectory(named: "timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("deliver.sh")
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            /bin/cat > "$TMPDIR/payload-$CMUX_AGENT_HOOK_DELIVERY_ID"
            if [ "$CMUX_AGENT_HOOK_DELIVERY_ID" = "timeout-first" ]; then
              trap 'exit 143' TERM
              while :; do :; done
            fi
            printf '%s\n' "$CMUX_AGENT_HOOK_DELIVERY_ID" >> "$TMPDIR/delivered"
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 0.2,
            terminationGrace: 0.05,
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        let hung = try #require(makeEvent(
            deliveryID: "timeout-first",
            payload: Data("hang".utf8),
            environment: testEnvironment(root: root)
        ))
        let later = try #require(makeEvent(
            deliveryID: "timeout-later",
            payload: Data("later".utf8),
            environment: testEnvironment(root: root, surfaceID: "surface:timeout-later")
        ))

        let started = ContinuousClock().now
        try queue.enqueue(hung)
        try queue.enqueue(later)
        await queue.waitUntilCurrentDrainFinishes()
        let elapsed = started.duration(to: ContinuousClock().now)

        let hungStatus = try await queue.diagnosticStatus(for: hung.deliveryID)
        let laterStatus = try await queue.diagnosticStatus(for: later.deliveryID)
        #expect(hungStatus?["state"] == "pending")
        #expect(hungStatus?["last_error"]?.contains("exceeded") == true)
        #expect(laterStatus?["state"] == "delivered")
        #expect(elapsed < .seconds(2))
        #expect(try lines(at: root.appendingPathComponent("delivered")) == ["timeout-later"])
    }

    @Test func timedOutDeliveryKillsTermIgnoringProcessGroup() async throws {
        let root = try temporaryDirectory(named: "process-group-timeout")
        let scriptURL = root.appendingPathComponent("deliver.sh")
        let leaderPIDFile = root.appendingPathComponent("leader.pid")
        let descendantPIDFile = root.appendingPathComponent("descendant.pid")
        defer {
            for pidFile in [leaderPIDFile, descendantPIDFile] {
                if let rawPID = try? String(contentsOf: pidFile, encoding: .utf8),
                   let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            printf '%s' "$$" > "$CMUX_AGENT_LAUNCH_CWD"
            /bin/sh -c 'trap "" TERM; printf "%s" "$$" > "$CMUX_AGENT_LAUNCH_EXECUTABLE"; while :; do :; done' &
            trap '' TERM
            while :; do :; done
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 0.5,
            terminationGrace: 0.05,
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )
        var environment = testEnvironment(root: root)
        environment["CMUX_AGENT_LAUNCH_CWD"] = leaderPIDFile.path
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = descendantPIDFile.path
        let event = try #require(makeEvent(
            deliveryID: "timeout-process-group",
            payload: Data("hang".utf8),
            environment: environment
        ))

        try queue.enqueue(event)
        await queue.waitUntilCurrentDrainFinishes()

        for pidFile in [leaderPIDFile, descendantPIDFile] {
            let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
            let pid = try #require(Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)))
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test func cancelledDrainReapsChildAndRecoversPendingRow() async throws {
        let root = try temporaryDirectory(named: "cancel-recovery")
        let scriptURL = root.appendingPathComponent("deliver.sh")
        let leaderPIDFile = root.appendingPathComponent("leader.pid")
        defer {
            if let rawPID = try? String(contentsOf: leaderPIDFile, encoding: .utf8),
               let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: root)
        }
        try writeExecutable(
            at: scriptURL,
            contents: """
            #!/bin/sh
            if [ ! -e "$TMPDIR/started-once" ]; then
              : > "$TMPDIR/started-once"
              printf '%s' "$$" > "$CMUX_AGENT_LAUNCH_CWD"
              trap 'exit 143' TERM
              while :; do :; done
            fi
            printf '%s\n' "$CMUX_AGENT_HOOK_DELIVERY_ID" >> "$TMPDIR/delivered"
            """
        )
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { scriptURL },
            processTimeout: 30,
            terminationGrace: 0.05,
            retryBaseDelay: 0.02,
            retryMaximumDelay: 0.02
        )
        var environment = testEnvironment(root: root)
        environment["CMUX_AGENT_LAUNCH_CWD"] = leaderPIDFile.path
        let event = try #require(makeEvent(
            deliveryID: "cancel-recovery",
            payload: Data("cancel".utf8),
            environment: environment
        ))
        try queue.enqueue(event)
        let childStarted = await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: leaderPIDFile.path)
        }
        #expect(childStarted)

        await queue.cancelCurrentDrainForTesting()

        let rawPID = try String(contentsOf: leaderPIDFile, encoding: .utf8)
        let leaderPID = try #require(Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)))
        let leaderGone = await waitUntil(timeout: .seconds(1)) {
            Darwin.kill(leaderPID, 0) == -1
        }
        #expect(leaderGone)
        errno = 0
        #expect(Darwin.kill(leaderPID, 0) == -1)
        #expect(errno == ESRCH)
        let recovered = await waitUntil(timeout: .seconds(2)) {
            (try? await queue.diagnosticStatus(for: event.deliveryID)?["state"]) == "delivered"
        }
        #expect(recovered)
        let status = try await queue.diagnosticStatus(for: event.deliveryID)
        #expect(status?["attempts"] == "2")
        #expect(try lines(at: root.appendingPathComponent("delivered")) == ["cancel-recovery"])
    }

    private func makeEvent(
        deliveryID: String,
        payload: Data,
        environment: [String: String],
        subcommand: String = "session-start"
    ) -> AgentHookDeliveryEvent? {
        var environmentData = Data()
        for key in environment.keys.sorted() {
            environmentData.append(contentsOf: key.utf8)
            environmentData.append(0)
            environmentData.append(contentsOf: (environment[key] ?? "").utf8)
            environmentData.append(0)
        }
        return AgentHookDeliveryEvent(params: [
            "delivery_id": deliveryID,
            "agent": "codex",
            "subcommand": subcommand,
            "payload_b64": payload.base64EncodedString(),
            "environment_b64": environmentData.base64EncodedString(),
        ])
    }

    private func outboxMessage(
        deliveryID: String,
        payload: Data,
        environment: [String: String],
        subcommand: String = "session-start",
        method: String = "agent.hook.enqueue"
    ) throws -> Data {
        var environmentData = Data()
        for key in environment.keys.sorted() {
            environmentData.append(contentsOf: key.utf8)
            environmentData.append(0)
            environmentData.append(contentsOf: (environment[key] ?? "").utf8)
            environmentData.append(0)
        }
        let request: [String: Any] = [
            "id": "hook-\(deliveryID)",
            "method": method,
            "params": [
                "delivery_id": deliveryID,
                "agent": "codex",
                "subcommand": subcommand,
                "payload_b64": payload.base64EncodedString(),
                "environment_b64": environmentData.base64EncodedString(),
            ],
        ]
        var data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        data.append(0x0a)
        return data
    }

    private func outboxEvent(from message: Data) -> AgentHookDeliveryEvent? {
        guard let request = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              request["method"] as? String == "agent.hook.enqueue",
              let params = request["params"] as? [String: Any] else {
            return nil
        }
        return AgentHookDeliveryEvent(params: params)
    }

    private func publishOutboxRecord(
        message: Data,
        authenticating authenticatedMessage: Data? = nil,
        capability: String,
        directoryURL: URL,
        order: UInt64,
        markerPrefix: String = "ready"
    ) throws -> OutboxTestRecord {
        let authenticatedMessage = authenticatedMessage ?? message
        let authentication = try #require(
            SocketClientCapabilityOutboxAuthentication.make(
                capability: capability,
                message: authenticatedMessage
            )
        )
        let random = UInt64.random(in: .min ... .max)
        let sharedMemoryName = String(format: "/ch%016llx", random)
        let descriptor = sharedMemoryName.withCString {
            cmux_agent_hook_shm_create_for_testing($0)
        }
        guard descriptor >= 0 else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(errno))
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var keepSharedMemory = false
        defer {
            Darwin.close(descriptor)
            if !keepSharedMemory {
                shm_unlink(sharedMemoryName)
            }
        }
        guard ftruncate(descriptor, off_t(message.count)) == 0 else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(errno))
        }
        let mapping = mmap(
            nil,
            message.count,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            descriptor,
            0
        )
        guard mapping != MAP_FAILED else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(errno))
        }
        message.copyBytes(to: mapping!.assumingMemoryBound(to: UInt8.self), count: message.count)
        munmap(mapping, message.count)

        let marker = """
        \(sharedMemoryName)
        \(authentication.nonce)
        \(authentication.code.base64EncodedString())
        \(message.count)

        """
        let markerURL = directoryURL.appendingPathComponent(
            String(format: "\(markerPrefix)-%016llx-%016llx", order, random),
            isDirectory: false
        )
        try Data(marker.utf8).write(to: markerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerURL.path
        )
        keepSharedMemory = true
        return OutboxTestRecord(
            markerURL: markerURL,
            sharedMemoryName: sharedMemoryName
        )
    }

    private func sharedMemoryIsMissing(_ name: String) -> Bool {
        let descriptor = name.withCString {
            cmux_agent_hook_shm_open_readonly($0)
        }
        guard descriptor < 0 else {
            Darwin.close(descriptor)
            return false
        }
        return errno == ENOENT
    }

    private func storedDeliveryIDs(databaseURL: URL) throws -> [String] {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let database else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(openStatus))
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(
            database,
            "SELECT delivery_id FROM agent_hook_deliveries ORDER BY sequence ASC;",
            -1,
            &statement,
            nil
        )
        guard prepareStatus == SQLITE_OK, let statement else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(prepareStatus))
        }
        defer { sqlite3_finalize(statement) }
        var deliveryIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) {
            deliveryIDs.append(String(cString: text))
        }
        return deliveryIDs
    }

    private func testEnvironment(root: URL, surfaceID: String = "surface:test") -> [String: String] {
        [
            "CMUX_SOCKET_PATH": "/tmp/cmux-agent-hook-delivery-test.sock",
            "CMUX_SURFACE_ID": surfaceID,
            "TMPDIR": root.path,
        ]
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func spawnRawSleep(seconds: String) throws -> pid_t {
        var arguments: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sleep"),
            strdup(seconds),
            nil,
        ]
        defer {
            for argument in arguments where argument != nil {
                free(argument)
            }
        }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var processIdentifier: pid_t = 0
        let status = "/bin/sleep".withCString { executablePath in
            arguments.withUnsafeMutableBufferPointer { argumentBuffer in
                environment.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &processIdentifier,
                        executablePath,
                        nil,
                        nil,
                        argumentBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        return processIdentifier
    }

    private func waitForChild(_ processIdentifier: pid_t) {
        var childStatus: Int32 = 0
        while waitpid(processIdentifier, &childStatus, 0) < 0, errno == EINTR {}
    }

    private func storedEnvironmentJSON(databaseURL: URL, deliveryID: String) throws -> String {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let database else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(openStatus))
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(
            database,
            "SELECT environment_json FROM agent_hook_deliveries WHERE delivery_id = ? LIMIT 1;",
            -1,
            &statement,
            nil
        )
        guard prepareStatus == SQLITE_OK, let statement else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(prepareStatus))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, deliveryID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: 999)
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return String(decoding: Data(bytes: bytes, count: count), as: UTF8.self)
    }

    private func storedContentDigest(databaseURL: URL, deliveryID: String) throws -> Data {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let database else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(openStatus))
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(
            database,
            "SELECT content_digest FROM agent_hook_deliveries WHERE delivery_id = ? LIMIT 1;",
            -1,
            &statement,
            nil
        )
        guard prepareStatus == SQLITE_OK, let statement else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(prepareStatus))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, deliveryID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: 998)
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private func nulSeparatedBase64(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private func decodedNulSeparatedBase64(_ value: String) -> [String]? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
    }

    private func createLegacyDeliveryDatabase(
        at url: URL,
        event: AgentHookDeliveryEvent,
        contentDigest: Data? = nil,
        nextAttemptAt: TimeInterval = 0
    ) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open(url.path, &database)
        guard openStatus == SQLITE_OK, let database else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(openStatus))
        }
        defer { sqlite3_close(database) }
        let environmentData = try JSONSerialization.data(withJSONObject: event.environment, options: [.sortedKeys])
        let storedContentDigest = contentDigest ?? event.contentDigest
        let quote: (String) -> String = { value in
            "'\(value.replacingOccurrences(of: "'", with: "''"))'"
        }
        let hex: (Data) -> String = { data in
            data.map { String(format: "%02x", $0) }.joined()
        }
        let schema = """
        CREATE TABLE agent_hook_deliveries (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            delivery_id TEXT NOT NULL UNIQUE,
            content_digest BLOB NOT NULL,
            agent TEXT NOT NULL,
            subcommand TEXT NOT NULL,
            payload BLOB NOT NULL,
            socket_path TEXT NOT NULL,
            environment_json BLOB NOT NULL,
            accepted_at REAL NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_attempt_at REAL,
            next_attempt_at REAL NOT NULL,
            delivered_at REAL,
            last_error TEXT
        );
        INSERT INTO agent_hook_deliveries (
            delivery_id, content_digest, agent, subcommand, payload,
            socket_path, environment_json, accepted_at, next_attempt_at
        ) VALUES (
            \(quote(event.deliveryID)), X'\(hex(storedContentDigest))', \(quote(event.agent)),
            \(quote(event.subcommand)), X'\(hex(event.payload))', \(quote(event.socketPath)),
            X'\(hex(environmentData))', 0, \(nextAttemptAt)
        );
        """
        let status = sqlite3_exec(database, schema, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw NSError(
                domain: "AgentHookDeliveryQueueTests",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
            )
        }
    }

    private func createDeliveredReceiptDatabase(at url: URL, count: Int) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open(url.path, &database)
        guard openStatus == SQLITE_OK, let database else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(openStatus))
        }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE agent_hook_deliveries (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            delivery_id TEXT NOT NULL UNIQUE,
            ordering_key TEXT NOT NULL,
            content_digest BLOB NOT NULL,
            agent TEXT NOT NULL,
            subcommand TEXT NOT NULL,
            payload BLOB NOT NULL,
            socket_path TEXT NOT NULL,
            environment_json BLOB NOT NULL,
            accepted_at REAL NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_attempt_at REAL,
            next_attempt_at REAL NOT NULL,
            delivered_at REAL,
            last_error TEXT
        );
        """
        var status = sqlite3_exec(database, schema, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(status))
        }

        var statement: OpaquePointer?
        status = sqlite3_prepare_v2(
            database,
            """
            INSERT INTO agent_hook_deliveries (
                delivery_id, ordering_key, content_digest, agent, subcommand,
                payload, socket_path, environment_json, accepted_at,
                next_attempt_at, delivered_at
            ) VALUES (?, ?, zeroblob(32), 'codex', 'session-start', X'', '', X'7B7D', ?, 0, ?);
            """,
            -1,
            &statement,
            nil
        )
        guard status == SQLITE_OK, let statement else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(status))
        }
        defer { sqlite3_finalize(statement) }
        for index in 0..<count {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let deliveryID = String(format: "receipt-%04d", index)
            status = sqlite3_bind_text(
                statement,
                1,
                deliveryID,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
            guard status == SQLITE_OK else {
                throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(status))
            }
            status = sqlite3_bind_text(
                statement,
                2,
                "receipt-order",
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
            guard status == SQLITE_OK else {
                throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(status))
            }
            sqlite3_bind_double(statement, 3, TimeInterval(index))
            sqlite3_bind_double(statement, 4, TimeInterval(index))
            status = sqlite3_step(statement)
            guard status == SQLITE_DONE else {
                throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(status))
            }
        }
    }

    private func contentDigest(
        agent: String,
        subcommand: String,
        payload: Data,
        environment: [String: String]
    ) -> Data {
        var hasher = SHA256()
        hash(Data(agent.utf8), into: &hasher)
        hash(Data(subcommand.utf8), into: &hasher)
        hash(payload, into: &hasher)
        for key in environment.keys.sorted() {
            hash(Data(key.utf8), into: &hasher)
            hash(Data((environment[key] ?? "").utf8), into: &hasher)
        }
        return Data(hasher.finalize())
    }

    private func hash(_ data: Data, into hasher: inout SHA256) {
        var count = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &count) { bytes in
            hasher.update(data: Data(bytes))
        }
        hasher.update(data: data)
    }

    private func waitUntil(
        timeout: Duration,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    private func lines(at url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }
}
