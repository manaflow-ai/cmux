import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif


// MARK: - Codex JSON-RPC prompt submission, permission modes, approvals, and startup errors
extension CodexAppServerSessionTests {
    private func expectThrowsErrorAsync<T>(
        _ expression: () async throws -> T,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await expression()
            Issue.record("Expected expression to throw", sourceLocation: sourceLocation)
        } catch {
        }
    }

    @Test
    func testEncodesPromptAsJSONRPCInsteadOfRawStdin() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: "/tmp/cmux-agent-session-test",
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        expectEqual(jsonLine(sentLines[0])["method"] as? String, "initialize")

        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        expectEqual(jsonLine(sentLines[1])["method"] as? String, "initialized")

        let threadStart = jsonLine(sentLines[2])
        expectEqual(threadStart["method"] as? String, "thread/start")
        let threadParams = try #require(threadStart["params"] as? [String: Any])
        expectEqual(threadParams["cwd"] as? String, "/tmp/cmux-agent-session-test")

        let submitTask = Task { try await session.submit("hello codex", permissionMode: .fullAccess) }
        expectEqual(sentLines.count, 3, "Prompt should queue until thread/start returns a thread id.")

        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await submitTask.value
        let turnStart = jsonLine(sentLines[3])
        expectEqual(turnStart["method"] as? String, "turn/start")
        let turnParams = try #require(turnStart["params"] as? [String: Any])
        expectEqual(turnParams["threadId"] as? String, "thread-1")
        expectEqual(turnParams["approvalPolicy"] as? String, "never")
        expectEqual(turnParams["approvalsReviewer"] as? String, "user")
        let sandboxPolicy = try #require(turnParams["sandboxPolicy"] as? [String: Any])
        expectEqual(sandboxPolicy["type"] as? String, "dangerFullAccess")
        let input = try #require(turnParams["input"] as? [[String: Any]])
        expectEqual(input.first?["type"] as? String, "text")
        expectEqual(input.first?["text"] as? String, "hello codex")

        for line in sentLines {
            expectTrue(line.hasPrefix("{"), "Codex app-server stdin must stay JSON-RPC, got \(line)")
        }
    }

    @Test
    func testCodexInputQueueBeforeThreadIsBounded() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        let submitTask = Task { try await session.submit("first prompt") }
        await expectThrowsErrorAsync {
            try await session.submit("second prompt")
        }

        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await submitTask.value

        expectEqual(sentLines.count, 4)
        let turnStart = jsonLine(sentLines[3])
        expectEqual(turnStart["method"] as? String, "turn/start")
        let turnParams = try #require(turnStart["params"] as? [String: Any])
        let input = try #require(turnParams["input"] as? [[String: Any]])
        expectEqual(input.first?["text"] as? String, "first prompt")
    }

    @Test
    func testCodexInputQueueRejectsOversizedPromptBeforeThread() async throws {
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { _ in },
            outputSink: { _, _ in }
        )

        try await session.start()
        await expectThrowsErrorAsync {
            try await session.submit(String(repeating: "x", count: 64 * 1024 + 1))
        }
    }

    @Test
    func testAutoReviewPermissionModeAddsCodexReviewerOverride() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await session.submit("please review", permissionMode: .autoReview)

        let turnStart = jsonLine(sentLines[3])
        expectEqual(turnStart["method"] as? String, "turn/start")
        let turnParams = try #require(turnStart["params"] as? [String: Any])
        expectEqual(turnParams["threadId"] as? String, "thread-1")
        expectEqual(turnParams["approvalPolicy"] as? String, "on-request")
        expectEqual(turnParams["approvalsReviewer"] as? String, "auto_review")
        expectTrue(turnParams["sandboxPolicy"] is NSNull)
    }

    @Test
    func testCustomPermissionModeLeavesCodexConfigInControl() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await session.submit("use config", permissionMode: .custom)

        let turnStart = jsonLine(sentLines[3])
        expectEqual(turnStart["method"] as? String, "turn/start")
        let turnParams = try #require(turnStart["params"] as? [String: Any])
        expectEqual(turnParams["threadId"] as? String, "thread-1")
        expectNil(turnParams["approvalPolicy"])
        expectNil(turnParams["approvalsReviewer"])
        expectNil(turnParams["sandboxPolicy"])
    }

    @Test
    func testDefaultPermissionModeAvoidsInteractiveCodexApprovals() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await session.submit("use full access", permissionMode: .fullAccess)
        session.consumeStdout(#"{"method":"turn/completed","params":{"threadId":"thread-1"}}"# + "\n")
        try await session.submit("back to defaults", permissionMode: .standard)

        let elevatedParams = try #require(jsonLine(sentLines[3])["params"] as? [String: Any])
        expectEqual(elevatedParams["approvalPolicy"] as? String, "never")
        let elevatedSandboxPolicy = try #require(elevatedParams["sandboxPolicy"] as? [String: Any])
        expectEqual(elevatedSandboxPolicy["type"] as? String, "dangerFullAccess")

        let defaultParams = try #require(jsonLine(sentLines[4])["params"] as? [String: Any])
        expectEqual(defaultParams["approvalPolicy"] as? String, "never")
        expectTrue(defaultParams["approvalsReviewer"] is NSNull)
        expectTrue(defaultParams["sandboxPolicy"] is NSNull)
    }

    @Test
    func testCodexSubmitBlocksReentrantTurnWhileWriteIsPending() async throws {
        var sentLines: [String] = []
        var pendingTurnWrite: CheckedContinuation<Void, Never>?
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
                if line.contains(#""method":"turn/start""#) {
                    await withCheckedContinuation { continuation in
                        pendingTurnWrite = continuation
                    }
                }
                sentLines.append(line)
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")

        let firstSubmit = Task { try await session.submit("first prompt") }
        while pendingTurnWrite == nil {
            await Task.yield()
        }

        await expectThrowsErrorAsync {
            try await session.submit("second prompt")
        }

        pendingTurnWrite?.resume()
        try await firstSubmit.value
        expectEqual(sentLines.count, 4)
        let turnParams = try #require(jsonLine(sentLines[3])["params"] as? [String: Any])
        let input = try #require(turnParams["input"] as? [[String: Any]])
        expectEqual(input.first?["text"] as? String, "first prompt")
    }

    @Test
    func testCodexApprovalRequestsOnlyAutoApproveForFullAccessMode() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await session.submit("default prompt", permissionMode: .standard)
        session.consumeStdout(
            #"{"id":"cmd-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1"}}"# + "\n")
        session.consumeStdout(
            #"{"id":"perm-1","method":"item/permissions/requestApproval","params":{"permissions":{"network":{"enabled":true}}}}"# + "\n")
        await expectThrowsErrorAsync {
            try await session.submit("blocked full access prompt", permissionMode: .fullAccess)
        }
        session.consumeStdout(#"{"method":"turn/completed","params":{"threadId":"thread-1"}}"# + "\n")
        try await session.submit("full access prompt", permissionMode: .fullAccess)
        session.consumeStdout(
            #"{"id":"cmd-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1"}}"# + "\n")
        session.consumeStdout(
            #"{"id":"perm-2","method":"item/permissions/requestApproval","params":{"permissions":{"network":{"enabled":true}}}}"# + "\n")

        let defaultCommandResponse = jsonLine(sentLines[4])
        let defaultCommandResult = try #require(defaultCommandResponse["result"] as? [String: Any])
        expectEqual(defaultCommandResult["decision"] as? String, "decline")

        let defaultPermissionResponse = jsonLine(sentLines[5])
        let defaultPermissionResult = try #require(defaultPermissionResponse["result"] as? [String: Any])
        let defaultPermissions = try #require(defaultPermissionResult["permissions"] as? [String: Any])
        expectTrue(defaultPermissions.isEmpty)

        let fullAccessCommandResponse = jsonLine(sentLines[7])
        let fullAccessCommandResult = try #require(fullAccessCommandResponse["result"] as? [String: Any])
        expectEqual(fullAccessCommandResult["decision"] as? String, "acceptForSession")

        let fullAccessPermissionResponse = jsonLine(sentLines[8])
        let fullAccessPermissionResult = try #require(fullAccessPermissionResponse["result"] as? [String: Any])
        let fullAccessPermissions = try #require(fullAccessPermissionResult["permissions"] as? [String: Any])
        let networkPermissions = try #require(fullAccessPermissions["network"] as? [String: Any])
        expectEqual(networkPermissions["enabled"] as? Bool, true)
    }

    @Test
    func testInitializeErrorFailsStartupAndRejectsLaterPrompts() async throws {
        var sentLines: [String] = []
        var output: [(String, String)] = []
        var failures: [String?] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { stream, text in output.append((stream, text)) },
            failureSink: { details in failures.append(details) }
        )

        try await session.start()
        let submitTask = Task { try await session.submit("queued prompt") }
        session.consumeStdout(#"{"id":1,"error":{"message":"unsupported initialize"}}"# + "\n")
        await expectThrowsErrorAsync {
            try await submitTask.value
        }

        expectEqual(sentLines.count, 1)
        expectEqual(failures.count, 1)
        expectEqual(failures.first!, "unsupported initialize")
        expectEqual(output.last?.0, "stderr")
        expectEqual(output.last?.1, "Codex app-server request failed.")
        await expectThrowsErrorAsync {
            try await session.submit("later prompt")
        }
    }

    @Test
    func testThreadStartErrorClearsStartupStateAndRejectsLaterPrompts() async throws {
        var sentLines: [String] = []
        var failures: [String?] = []
        let session = CodexAppServerSession(
            workingDirectory: "/tmp/cmux-missing-cwd",
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in },
            failureSink: { details in failures.append(details) }
        )

        try await session.start()
        session.consumeStdout(#"{"id":1,"result":{}}"# + "\n")
        await Task.yield()
        expectEqual(jsonLine(sentLines[2])["method"] as? String, "thread/start")

        let submitTask = Task { try await session.submit("queued prompt") }
        session.consumeStdout(#"{"id":2,"error":{"message":"bad cwd"}}"# + "\n")
        await expectThrowsErrorAsync {
            try await submitTask.value
        }

        expectEqual(failures.count, 1)
        expectEqual(failures.first!, "bad cwd")
        expectEqual(sentLines.count, 3)
        await expectThrowsErrorAsync {
            try await session.submit("later prompt")
        }
    }

    private func jsonLine(_ rawLine: String) -> [String: Any] {
        guard let data = rawLine.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data),
            let object = decoded as? [String: Any]
        else {
            Issue.record("Expected JSON object")
            return [:]
        }
        return object
    }
}
