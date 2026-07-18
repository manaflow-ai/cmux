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
        let secretEnvironment: [String: String] = [
            "OPENAI_API_KEY": "legacy-openai-api-secret",
            "AWS_CONTAINER_AUTHORIZATION_TOKEN": "legacy-container-auth-secret",
            "AWS_SECURITY_TOKEN": "legacy-security-token-secret",
            "AWS_BEARER_TOKEN_BEDROCK": "legacy-bedrock-bearer-secret",
            "OPENAI_ADMIN_KEY": "legacy-openai-admin-secret",
            "OPENAI_BEARER_TOKEN": "legacy-openai-bearer-secret",
            "HTTPS_PROXY": "https://legacy-user:legacy-password@proxy.example.test:8443",
            "ANTHROPIC_BASE_URL": "https://legacy-user:legacy-password@api.example.test/v1",
            "OPENAI_BASE_URL": "https://api.example.test/v1?access_token=legacy-query-secret",
        ]
        let durableLocators: [String: String] = [
            "AWS_CONFIG_FILE": "/tmp/aws-config",
            "AWS_SHARED_CREDENTIALS_FILE": "/tmp/aws-credentials",
            "AWS_WEB_IDENTITY_TOKEN_FILE": "/tmp/aws-web-identity-token",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/google-credentials.json",
            "XAI_BASE_URL": "https://api.x.ai/v1",
            "HTTP_PROXY": "http://127.0.0.1:8080",
        ]
        var environment = testEnvironment(root: root)
        environment.merge(secretEnvironment, uniquingKeysWith: { _, new in new })
        environment.merge(durableLocators, uniquingKeysWith: { _, new in new })
        let legacy = try #require(makeEvent(
            deliveryID: "legacy-credential-row",
            payload: Data("legacy".utf8),
            environment: environment
        ))
        try createLegacyDeliveryDatabase(
            at: databaseURL,
            event: legacy,
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
        for (key, value) in durableLocators {
            #expect(stored[key] == value)
        }

        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("deliveries.sqlite3") {
            let bytes = try Data(contentsOf: file)
            for secret in secretEnvironment.values {
                #expect(bytes.range(of: Data(secret.utf8)) == nil)
            }
        }
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

    private func createLegacyDeliveryDatabase(
        at url: URL,
        event: AgentHookDeliveryEvent,
        nextAttemptAt: TimeInterval = 0
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
