import Foundation
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent hook durable delivery", .serialized)
struct AgentHookDeliveryQueueTests {
    @Test func encodedEventPreservesExactPayloadAndValidatedEnvironment() throws {
        let payload = Data([0x00, 0x7b, 0x22, 0xff, 0x0a])
        let event = try #require(makeEvent(
            deliveryID: "encoded-event",
            payload: payload,
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-test.sock",
                "CMUX_AGENT_LAUNCH_CWD": "/tmp/project with spaces",
                "CMUX_TAG": "test-tag",
            ]
        ))

        #expect(event.payload == payload)
        #expect(event.socketPath == "/tmp/cmux-test.sock")
        #expect(event.environment["CMUX_AGENT_LAUNCH_CWD"] == "/tmp/project with spaces")

        for subcommand in [
            "session-start", "prompt-submit", "stop",
            "pre-tool-use", "post-tool-use", "notification",
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

        #expect(makeEvent(
            deliveryID: "unknown-environment",
            payload: payload,
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-test.sock",
                "UNTRUSTED_KEY": "value",
            ]
        ) == nil)
        #expect(makeEvent(
            deliveryID: "missing-socket",
            payload: payload,
            environment: ["CMUX_TAG": "test-tag"]
        ) == nil)
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
            exec /usr/bin/python3 -c '
            import os
            import signal

            os.setpgid(0, 0)
            with open(os.environ["CMUX_AGENT_LAUNCH_CWD"], "w") as handle:
                handle.write(str(os.getpid()))
            descendant = os.fork()
            if descendant == 0:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                with open(os.environ["CMUX_AGENT_LAUNCH_EXECUTABLE"], "w") as handle:
                    handle.write(str(os.getpid()))
                while True:
                    signal.pause()
            while True:
                signal.pause()
            '
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

    private func createLegacyDeliveryDatabase(
        at url: URL,
        event: AgentHookDeliveryEvent
    ) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open(url.path, &database)
        guard openStatus == SQLITE_OK, let database else {
            throw NSError(domain: "AgentHookDeliveryQueueTests", code: Int(openStatus))
        }
        defer { sqlite3_close(database) }
        let environmentData = try JSONSerialization.data(withJSONObject: event.environment, options: [.sortedKeys])
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
            \(quote(event.deliveryID)), X'\(hex(event.contentDigest))', \(quote(event.agent)),
            \(quote(event.subcommand)), X'\(hex(event.payload))', \(quote(event.socketPath)),
            X'\(hex(environmentData))', 0, 0
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
