import XCTest
import Darwin
import Foundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CMUXSudoTests: XCTestCase {
    private enum SudoTestError: Error {
        case missingPendingRequestID
        case resultTimeout
    }

    private var tempDirectories: [URL] = []

    override func tearDown() {
#if DEBUG
        CMUXSudoTestHooks.reset()
#endif
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    func testSudoRequestParserRejectsMalformedPayloads() {
        let valid = makeParams()

        assertInvalid(valid.merging(["argv": [String]()] as [String: Any]) { _, new in new })
        assertInvalid(
            valid.merging(["argv": ["/usr/bin/id", "bad\0value"]] as [String: Any]) { _, new in new }
        )
        assertInvalid(
            valid.merging(["workspace_id": "not-a-uuid"] as [String: Any]) { _, new in new }
        )
        assertInvalid(valid.merging(["caller_pid": -1] as [String: Any]) { _, new in new })
        assertInvalid(
            valid.merging(["caller_pid": NSNumber(value: Int64(Int32.max) + 1)] as [String: Any]) { _, new in new }
        )
        assertInvalid(valid.merging(["caller_pid": NSNumber(value: 123.9)] as [String: Any]) { _, new in new })
        assertInvalid(valid.merging(["caller_pid": NSNumber(value: true)] as [String: Any]) { _, new in new })
        assertInvalid(
            valid.merging(["caller_uid": NSNumber(value: Int64(UInt32.max) + 1)] as [String: Any]) { _, new in new }
        )
        assertInvalid(valid.merging(["caller_uid": NSNumber(value: 501.2)] as [String: Any]) { _, new in new })
        assertInvalid(valid.merging(["caller_uid": NSNumber(value: false)] as [String: Any]) { _, new in new })
    }

    func testSudoCallerValidatorRejectsRequestsOutsideCmuxPtyScope() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let request = try parsedRequest(workspaceID: workspaceID, surfaceID: surfaceID)
        let matchingProcess = CmuxTopProcessArguments(
            arguments: ["/usr/bin/cmux", "sudo"],
            environment: [
                "CMUX_WORKSPACE_ID": workspaceID.uuidString,
                "CMUX_SURFACE_ID": surfaceID.uuidString,
            ]
        )

        let allowed = CMUXSudoCallerValidator.validate(
            request: request,
            peerIdentity: CMUXSocketPeerIdentity(
                pid: request.callerPID,
                uid: request.callerUID,
                processStartTime: 1
            ),
            isDescendant: { $0 == request.callerPID },
            processArguments: { _ in matchingProcess },
            surfaceExists: { _, _ in true }
        )
        XCTAssertTrue(allowed.allowed, allowed.reason ?? "")

        let mismatchedPeer = CMUXSudoCallerValidator.validate(
            request: request,
            peerIdentity: CMUXSocketPeerIdentity(
                pid: request.callerPID,
                uid: request.callerUID + 1,
                processStartTime: 1
            ),
            isDescendant: { _ in true },
            processArguments: { _ in matchingProcess },
            surfaceExists: { _, _ in true }
        )
        XCTAssertFalse(mismatchedPeer.allowed)
        XCTAssertTrue(mismatchedPeer.reason?.contains("uid") == true)

        let missingProcessIdentity = CMUXSudoCallerValidator.validate(
            request: request,
            peerIdentity: CMUXSocketPeerIdentity(pid: request.callerPID, uid: request.callerUID),
            isDescendant: { _ in true },
            processArguments: { _ in matchingProcess },
            surfaceExists: { _, _ in true }
        )
        XCTAssertFalse(missingProcessIdentity.allowed)
        XCTAssertTrue(missingProcessIdentity.reason?.contains("process identity") == true)

        let missingScope = CMUXSudoCallerValidator.validate(
            request: request,
            peerIdentity: CMUXSocketPeerIdentity(
                pid: request.callerPID,
                uid: request.callerUID,
                processStartTime: 1
            ),
            isDescendant: { _ in true },
            processArguments: { _ in CmuxTopProcessArguments(arguments: ["/bin/zsh"], environment: [:]) },
            surfaceExists: { _, _ in true }
        )
        XCTAssertFalse(missingScope.allowed)
        XCTAssertTrue(missingScope.reason?.contains("scope") == true)

        let missingSurface = CMUXSudoCallerValidator.validate(
            request: request,
            peerIdentity: CMUXSocketPeerIdentity(
                pid: request.callerPID,
                uid: request.callerUID,
                processStartTime: 1
            ),
            isDescendant: { _ in true },
            processArguments: { _ in matchingProcess },
            surfaceExists: { _, _ in false }
        )
        XCTAssertFalse(missingSurface.allowed)
        XCTAssertTrue(missingSurface.reason?.contains("active") == true)
    }

    func testSudoHelperEnvelopeSignsCanonicalPayload() throws {
        let request = try parsedRequest(argv: ["/bin/echo", "hello world"])
        let envelope = try CMUXSudoHelperClient.signedEnvelope(for: request)
        XCTAssertTrue(CMUXSudoHelperSignatureVerifier.verify(envelope))

        var tamperedPayload = envelope.payload
        tamperedPayload["argv"] = ["/usr/bin/whoami"]
        let tampered = CMUXSudoSignedHelperEnvelope(
            payload: tamperedPayload,
            signatureBase64: envelope.signatureBase64,
            publicKeyBase64: envelope.publicKeyBase64
        )
        XCTAssertFalse(CMUXSudoHelperSignatureVerifier.verify(tampered))
    }

    func testSudoAuditLogChainsEntriesAndUsesPrivatePermissions() throws {
        let logURL = temporaryDirectory().appendingPathComponent("sudo-audit.jsonl")
        let first = try CMUXSudoAuditLogger.append(auditRecord(id: "first"), logURL: logURL)
        let second = try CMUXSudoAuditLogger.append(auditRecord(id: "second"), logURL: logURL)

        XCTAssertTrue(first["previous_sha256"] is NSNull)
        XCTAssertEqual(second["previous_sha256"] as? String, first["entry_sha256"] as? String)
        XCTAssertNotNil(second["entry_sha256"] as? String)

        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: logURL.deletingLastPathComponent().path
        )
        let directoryPermissions = try XCTUnwrap(directoryAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)

        let entries = try auditEntries(in: logURL)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["request_id"] as? String, "first")
        XCTAssertEqual(entries[1]["request_id"] as? String, "second")
    }

    func testSudoAuditLogRotationSeedsFreshLogFromRotatedTail() throws {
        let logURL = temporaryDirectory().appendingPathComponent("sudo-audit.jsonl")
        let oversizedMessage = String(repeating: "x", count: Int(CMUXSudoAuditLogger.maxBytes) + 1)
        let first = try CMUXSudoAuditLogger.append(auditRecord(id: "first", message: oversizedMessage), logURL: logURL)
        let second = try CMUXSudoAuditLogger.append(auditRecord(id: "second"), logURL: logURL)
        let third = try CMUXSudoAuditLogger.append(auditRecord(id: "third"), logURL: logURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(logURL.path).1"))
        XCTAssertEqual(second["previous_sha256"] as? String, first["entry_sha256"] as? String)
        XCTAssertEqual(third["previous_sha256"] as? String, second["entry_sha256"] as? String)
    }

    func testSudoAuditLogFailsClosedWhenExistingChainIsCorrupt() throws {
        let logURL = temporaryDirectory().appendingPathComponent("sudo-audit.jsonl")
        try Data("{\"request_id\":\"tampered\"}\n".utf8).write(to: logURL)

        XCTAssertThrowsError(try CMUXSudoAuditLogger.ensureWritable(logURL: logURL))
        XCTAssertThrowsError(try CMUXSudoAuditLogger.append(auditRecord(id: "after-tamper"), logURL: logURL))

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(contents, "{\"request_id\":\"tampered\"}\n")

        let chainedLogURL = temporaryDirectory().appendingPathComponent("sudo-audit.jsonl")
        _ = try CMUXSudoAuditLogger.append(auditRecord(id: "before-tamper"), logURL: chainedLogURL)
        var tamperedEntry = try auditEntries(in: chainedLogURL)[0]
        tamperedEntry["command_display"] = "/usr/bin/whoami"
        var tamperedData = try JSONSerialization.data(withJSONObject: tamperedEntry, options: [.sortedKeys])
        tamperedData.append(0x0a)
        try tamperedData.write(to: chainedLogURL)

        XCTAssertThrowsError(try CMUXSudoAuditLogger.ensureWritable(logURL: chainedLogURL))
        XCTAssertThrowsError(try CMUXSudoAuditLogger.append(auditRecord(id: "after-edited-entry"), logURL: chainedLogURL))
    }

    func testSudoPendingStoreRejectsDuplicateIDsAndPreservesFinishedResultOnCancel() {
        let store = CMUXSudoPendingRequestStore()
        let requestID = UUID().uuidString
        let access = CMUXSudoPendingRequestStore.Access(
            pid: getpid(),
            uid: getuid(),
            processStartTime: 1,
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let peer = CMUXSocketPeerIdentity(pid: getpid(), uid: getuid(), processStartTime: 1)
        let recycledPIDPeer = CMUXSocketPeerIdentity(pid: getpid(), uid: getuid(), processStartTime: 2)
        let completed = CMUXSudoSocketResponse.ok([
            "status": .string("completed"),
            "exit_code": .int(0),
        ])
        let timeout = CMUXSudoSocketResponse.err(code: "cancelled", message: "timed out")

        XCTAssertTrue(store.begin(requestID, access: access))
        XCTAssertFalse(store.begin(requestID, access: access))
        if case .forbidden = store.state(for: requestID, peerIdentity: recycledPIDPeer) {
        } else {
            XCTFail("Expected recycled PID with different start time to be forbidden")
        }
        store.finish(requestID, response: completed)

        switch store.cancel(requestID: requestID, peerIdentity: peer, response: timeout) {
        case .finished(let response):
            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.payload["status"]?.any as? String, "completed")
        case .missing, .forbidden, .cancelled:
            XCTFail("Expected finished response to survive cancellation")
        }
    }

    func testSudoPendingStoreCancelDoesNotMaskLaterHelperResult() {
        let store = CMUXSudoPendingRequestStore()
        let requestID = UUID().uuidString
        let access = CMUXSudoPendingRequestStore.Access(
            pid: getpid(),
            uid: getuid(),
            processStartTime: 1,
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let peer = CMUXSocketPeerIdentity(pid: getpid(), uid: getuid(), processStartTime: 1)
        let timeout = CMUXSudoSocketResponse.err(code: "cancelled", message: "timed out")
        let completed = CMUXSudoSocketResponse.ok([
            "status": .string("completed"),
            "exit_code": .int(0),
        ])

        XCTAssertTrue(store.begin(requestID, access: access))
        switch store.cancel(requestID: requestID, peerIdentity: peer, response: timeout) {
        case .cancelled:
            break
        case .missing, .forbidden, .finished:
            XCTFail("Expected pending request cancellation acknowledgement")
        }

        if case .pending = store.state(for: requestID, peerIdentity: peer) {
        } else {
            XCTFail("Expected cancelled pending request to remain readable until helper completion")
        }

        store.finish(requestID, response: completed)
        switch store.state(for: requestID, peerIdentity: peer) {
        case .finished(let response):
            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.payload["status"]?.any as? String, "completed")
        case .missing, .forbidden, .pending:
            XCTFail("Expected later helper result to replace pending cancellation")
        }
    }

    func testSudoPendingStoreCancelsSupersededAttachedTask() {
        let store = CMUXSudoPendingRequestStore()
        let requestID = UUID().uuidString
        let access = CMUXSudoPendingRequestStore.Access(
            pid: getpid(),
            uid: getuid(),
            processStartTime: 1,
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let firstCancelled = expectation(description: "first task cancelled")
        let firstTask = Task {
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    await Task.yield()
                }
            } onCancel: {
                firstCancelled.fulfill()
            }
        }
        let secondTask = Task {}
        defer {
            firstTask.cancel()
            secondTask.cancel()
        }

        XCTAssertTrue(store.begin(requestID, access: access))
        store.attachTask(requestID, task: firstTask)
        store.attachTask(requestID, task: secondTask)

        wait(for: [firstCancelled], timeout: 1)
    }

    func testSudoRequestDenialAuditsAndSkipsHelper() throws {
#if DEBUG
        let workspaceID = UUID()
        let surfaceID = UUID()
        let logURL = temporaryDirectory().appendingPathComponent("sudo-audit.jsonl")
        installValidSudoHooks(workspaceID: workspaceID, surfaceID: surfaceID, logURL: logURL)
        CMUXSudoTestHooks.approvalOverride = { _ in
            CMUXSudoApprovalResult(approved: false, reason: "test denial")
        }
        CMUXSudoTestHooks.helperOverride = { _ in
            XCTFail("Denied sudo requests must not reach the helper")
            return CMUXSudoHelperExecutionResult(
                status: "completed",
                exitCode: 0,
                stdout: nil,
                stderr: nil,
                errorCode: nil,
                message: nil
            )
        }

        let requestResult = TerminalController.withSocketPeerIdentityForTesting(pid: getpid(), uid: getuid()) {
            TerminalController.shared.v2SudoRequestOnSocketWorker(
                params: makeParams(workspaceID: workspaceID, surfaceID: surfaceID)
            )
        }
        let requestID = try pendingRequestID(from: requestResult)
        let result = try waitForSudoResult(requestID: requestID)

        guard case .err(let code, let message, _) = result else {
            return XCTFail("Expected denial error, got \(result)")
        }
        XCTAssertEqual(code, "authentication_denied")
        XCTAssertEqual(message, "test denial")

        let entries = try auditEntries(in: logURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["result"] as? String, "denied")
        XCTAssertEqual(entries[0]["error_code"] as? String, "authentication_denied")
#else
        throw XCTSkip("Sudo request flow hooks are debug-only.")
#endif
    }

    func testSudoRequestApprovalExecutesSignedHelperAndAudits() throws {
#if DEBUG
        let workspaceID = UUID()
        let surfaceID = UUID()
        let logURL = temporaryDirectory().appendingPathComponent("sudo-audit.jsonl")
        installValidSudoHooks(workspaceID: workspaceID, surfaceID: surfaceID, logURL: logURL)
        CMUXSudoTestHooks.approvalOverride = { _ in
            CMUXSudoApprovalResult(approved: true, reason: nil)
        }
        CMUXSudoTestHooks.helperOverride = { envelope in
            XCTAssertTrue(CMUXSudoHelperSignatureVerifier.verify(envelope))
            XCTAssertEqual(envelope.payload["argv"] as? [String], ["/usr/bin/id"])
            XCTAssertEqual(envelope.payload["cwd"] as? String, "/tmp")
            XCTAssertEqual(envelope.payload["timeout_seconds"] as? Int, 600)
            return CMUXSudoHelperExecutionResult(
                status: "completed",
                exitCode: 0,
                stdout: "uid=0(root)\n",
                stderr: "",
                errorCode: nil,
                message: nil
            )
        }

        let requestResult = TerminalController.withSocketPeerIdentityForTesting(pid: getpid(), uid: getuid()) {
            TerminalController.shared.v2SudoRequestOnSocketWorker(
                params: makeParams(workspaceID: workspaceID, surfaceID: surfaceID)
            )
        }
        let requestID = try pendingRequestID(from: requestResult)
        let result = try waitForSudoResult(requestID: requestID)

        guard case .ok(let payload) = result,
              let object = payload as? [String: Any] else {
            return XCTFail("Expected successful sudo response, got \(result)")
        }
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertEqual(object["exit_code"] as? Int, 0)
        XCTAssertEqual(object["stdout"] as? String, "uid=0(root)\n")
        XCTAssertEqual(object["audit_log"] as? String, logURL.path)

        let entries = try auditEntries(in: logURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["result"] as? String, "completed")
        XCTAssertEqual(entries[0]["exit_code"] as? Int, 0)
        XCTAssertEqual(entries[0]["working_directory"] as? String, "/tmp")
#else
        throw XCTSkip("Sudo request flow hooks are debug-only.")
#endif
    }

    func testSudoRequestIgnoresCallerSuppliedWorkingDirectory() throws {
#if DEBUG
        let workspaceID = UUID()
        let surfaceID = UUID()
        let logURL = temporaryDirectory().appendingPathComponent("sudo-audit.jsonl")
        installValidSudoHooks(workspaceID: workspaceID, surfaceID: surfaceID, logURL: logURL)
        CMUXSudoTestHooks.workingDirectoryOverride = { _ in "/var/tmp" }
        CMUXSudoTestHooks.approvalOverride = { request in
            XCTAssertEqual(request.cwd, "/var/tmp")
            return CMUXSudoApprovalResult(approved: true, reason: nil)
        }
        CMUXSudoTestHooks.helperOverride = { envelope in
            XCTAssertEqual(envelope.payload["cwd"] as? String, "/var/tmp")
            return CMUXSudoHelperExecutionResult(
                status: "completed",
                exitCode: 0,
                stdout: "",
                stderr: "",
                errorCode: nil,
                message: nil
            )
        }

        var params = makeParams(workspaceID: workspaceID, surfaceID: surfaceID)
        params["cwd"] = "/malicious"
        let requestResult = TerminalController.withSocketPeerIdentityForTesting(pid: getpid(), uid: getuid()) {
            TerminalController.shared.v2SudoRequestOnSocketWorker(params: params)
        }
        let requestID = try pendingRequestID(from: requestResult)
        _ = try waitForSudoResult(requestID: requestID)

        let entries = try auditEntries(in: logURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["working_directory"] as? String, "/var/tmp")
#else
        throw XCTSkip("Sudo request flow hooks are debug-only.")
#endif
    }

    func testSudoRequestSigningFailureAuditsAndSkipsHelper() throws {
#if DEBUG
        let workspaceID = UUID()
        let surfaceID = UUID()
        let logURL = temporaryDirectory().appendingPathComponent("sudo-audit.jsonl")
        installValidSudoHooks(workspaceID: workspaceID, surfaceID: surfaceID, logURL: logURL)
        CMUXSudoTestHooks.approvalOverride = { _ in
            CMUXSudoApprovalResult(approved: true, reason: nil)
        }
        CMUXSudoTestHooks.signedEnvelopeOverride = { _ in
            throw NSError(domain: "CMUXSudoTests", code: 1)
        }
        CMUXSudoTestHooks.helperOverride = { _ in
            XCTFail("Signing failures must not reach the helper")
            return CMUXSudoHelperExecutionResult(
                status: "completed",
                exitCode: 0,
                stdout: "",
                stderr: "",
                errorCode: nil,
                message: nil
            )
        }

        let requestResult = TerminalController.withSocketPeerIdentityForTesting(pid: getpid(), uid: getuid()) {
            TerminalController.shared.v2SudoRequestOnSocketWorker(
                params: makeParams(workspaceID: workspaceID, surfaceID: surfaceID)
            )
        }
        let requestID = try pendingRequestID(from: requestResult)
        let result = try waitForSudoResult(requestID: requestID)

        guard case .err(let code, _, _) = result else {
            return XCTFail("Expected signing failure, got \(result)")
        }
        XCTAssertEqual(code, "signing_failed")

        let entries = try auditEntries(in: logURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["result"] as? String, "signing_failed")
        XCTAssertEqual(entries[0]["error_code"] as? String, "signing_failed")
#else
        throw XCTSkip("Sudo request flow hooks are debug-only.")
#endif
    }

    func testSudoRequestUnavailableHelperSkipsApprovalAndAudits() throws {
#if DEBUG
        let workspaceID = UUID()
        let surfaceID = UUID()
        let logURL = temporaryDirectory().appendingPathComponent("sudo-audit.jsonl")
        installValidSudoHooks(workspaceID: workspaceID, surfaceID: surfaceID, logURL: logURL)
        CMUXSudoTestHooks.helperAvailabilityOverride = {
            .unavailable(errorCode: "helper_not_found", message: "missing helper for test")
        }
        CMUXSudoTestHooks.approvalOverride = { _ in
            XCTFail("Unavailable sudo helpers must not trigger approval UI")
            return CMUXSudoApprovalResult(approved: true, reason: nil)
        }
        CMUXSudoTestHooks.helperOverride = { _ in
            XCTFail("Unavailable sudo helpers must not execute commands")
            return CMUXSudoHelperExecutionResult(
                status: "completed",
                exitCode: 0,
                stdout: nil,
                stderr: nil,
                errorCode: nil,
                message: nil
            )
        }

        let requestResult = TerminalController.withSocketPeerIdentityForTesting(pid: getpid(), uid: getuid()) {
            TerminalController.shared.v2SudoRequestOnSocketWorker(
                params: makeParams(workspaceID: workspaceID, surfaceID: surfaceID)
            )
        }
        let requestID = try pendingRequestID(from: requestResult)
        let result = try waitForSudoResult(requestID: requestID)

        guard case .err(let code, let message, let data) = result else {
            return XCTFail("Expected helper availability error, got \(result)")
        }
        XCTAssertEqual(code, "helper_not_found")
        XCTAssertEqual(message, "missing helper for test")
        let object = try XCTUnwrap(data as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "helper_unavailable")
        XCTAssertEqual(object["error_code"] as? String, "helper_not_found")

        let entries = try auditEntries(in: logURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["result"] as? String, "helper_unavailable")
        XCTAssertEqual(entries[0]["error_code"] as? String, "helper_not_found")
        XCTAssertEqual(entries[0]["message"] as? String, "missing helper for test")
#else
        throw XCTSkip("Sudo request flow hooks are debug-only.")
#endif
    }

    func testSudoRequestHelperFailureSurfacesMessageAndAudits() throws {
#if DEBUG
        let workspaceID = UUID()
        let surfaceID = UUID()
        let logURL = temporaryDirectory().appendingPathComponent("sudo-audit.jsonl")
        installValidSudoHooks(workspaceID: workspaceID, surfaceID: surfaceID, logURL: logURL)
        CMUXSudoTestHooks.approvalOverride = { _ in
            CMUXSudoApprovalResult(approved: true, reason: nil)
        }
        CMUXSudoTestHooks.helperOverride = { _ in
            CMUXSudoHelperExecutionResult(
                status: "helper_unavailable",
                exitCode: nil,
                stdout: nil,
                stderr: nil,
                errorCode: "helper_transport_error",
                message: "transport broken for test"
            )
        }

        let requestResult = TerminalController.withSocketPeerIdentityForTesting(pid: getpid(), uid: getuid()) {
            TerminalController.shared.v2SudoRequestOnSocketWorker(
                params: makeParams(workspaceID: workspaceID, surfaceID: surfaceID)
            )
        }
        let requestID = try pendingRequestID(from: requestResult)
        let result = try waitForSudoResult(requestID: requestID)

        guard case .err(let code, let message, let data) = result else {
            return XCTFail("Expected helper transport error, got \(result)")
        }
        XCTAssertEqual(code, "helper_transport_error")
        XCTAssertEqual(message, "transport broken for test")
        let object = try XCTUnwrap(data as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "helper_unavailable")
        XCTAssertEqual(object["error_code"] as? String, "helper_transport_error")
        XCTAssertNotNil(object["exit_code"] as? NSNull)

        let entries = try auditEntries(in: logURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["result"] as? String, "helper_unavailable")
        XCTAssertEqual(entries[0]["error_code"] as? String, "helper_transport_error")
        XCTAssertEqual(entries[0]["message"] as? String, "transport broken for test")
#else
        throw XCTSkip("Sudo request flow hooks are debug-only.")
#endif
    }

    func testSudoResultRejectsMalformedAndUnknownRequests() throws {
#if DEBUG
        switch TerminalController.shared.v2SudoResultOnSocketWorker(params: [:]) {
        case .err(let code, _, _):
            XCTAssertEqual(code, "invalid_params")
        case .ok(let payload):
            XCTFail("Expected invalid params error, got \(payload)")
        }

        switch TerminalController.shared.v2SudoResultOnSocketWorker(params: ["request_id": UUID().uuidString]) {
        case .err(let code, _, _):
            XCTAssertEqual(code, "not_found")
        case .ok(let payload):
            XCTFail("Expected missing result error, got \(payload)")
        }
#else
        throw XCTSkip("Sudo request flow hooks are debug-only.")
#endif
    }

    func testSudoResultRejectsDifferentSocketPeer() throws {
#if DEBUG
        let workspaceID = UUID()
        let surfaceID = UUID()
        let logURL = temporaryDirectory().appendingPathComponent("sudo-audit.jsonl")
        installValidSudoHooks(workspaceID: workspaceID, surfaceID: surfaceID, logURL: logURL)
        CMUXSudoTestHooks.approvalOverride = { _ in
            CMUXSudoApprovalResult(approved: true, reason: nil)
        }
        CMUXSudoTestHooks.helperOverride = { _ in
            CMUXSudoHelperExecutionResult(
                status: "completed",
                exitCode: 0,
                stdout: "ok\n",
                stderr: "",
                errorCode: nil,
                message: nil
            )
        }

        let requestResult = TerminalController.withSocketPeerIdentityForTesting(pid: getpid(), uid: getuid()) {
            TerminalController.shared.v2SudoRequestOnSocketWorker(
                params: makeParams(workspaceID: workspaceID, surfaceID: surfaceID)
            )
        }
        let requestID = try pendingRequestID(from: requestResult)

        let wrongPeerResult = TerminalController.withSocketPeerIdentityForTesting(pid: getpid() + 1, uid: getuid()) {
            TerminalController.shared.v2SudoResultOnSocketWorker(params: ["request_id": requestID])
        }
        guard case .err(let code, _, _) = wrongPeerResult else {
            return XCTFail("Expected access denied for wrong peer, got \(wrongPeerResult)")
        }
        XCTAssertEqual(code, "access_denied")
        _ = try waitForSudoResult(requestID: requestID)
#else
        throw XCTSkip("Sudo request flow hooks are debug-only.")
#endif
    }

    private func installValidSudoHooks(workspaceID: UUID, surfaceID: UUID, logURL: URL) {
#if DEBUG
        CMUXSudoTestHooks.auditLogURLOverride = logURL
        CMUXSudoTestHooks.isDescendantOverride = { $0 == getpid() }
        CMUXSudoTestHooks.processArgumentsOverride = { _ in
            CmuxTopProcessArguments(
                arguments: ["/usr/bin/cmux", "sudo"],
                environment: [
                    "CMUX_WORKSPACE_ID": workspaceID.uuidString,
                    "CMUX_SURFACE_ID": surfaceID.uuidString,
                ]
            )
        }
        CMUXSudoTestHooks.surfaceExistsOverride = { requestedWorkspaceID, requestedSurfaceID in
            requestedWorkspaceID == workspaceID && requestedSurfaceID == surfaceID
        }
        CMUXSudoTestHooks.workingDirectoryOverride = { _ in "/tmp" }
        CMUXSudoTestHooks.helperAvailabilityOverride = { .available }
#endif
    }

    private func assertInvalid(_ params: [String: Any]) {
        switch CMUXSudoCommandRequest.parse(params: params) {
        case .success(let request):
            XCTFail("Expected invalid sudo request, got \(request)")
        case .failure(let error):
            XCTAssertEqual(error.code, "invalid_params")
        }
    }

    private func pendingRequestID(
        from result: TerminalController.V2CallResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        guard case .ok(let payload) = result,
              let object = payload as? [String: Any],
              object["status"] as? String == "pending",
              let requestID = object["request_id"] as? String else {
            XCTFail("Expected pending sudo response, got \(result)", file: file, line: line)
            throw SudoTestError.missingPendingRequestID
        }
        return requestID
    }

    private func waitForSudoResult(
        requestID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> TerminalController.V2CallResult {
        for _ in 0..<200 {
            let result = TerminalController.withSocketPeerIdentityForTesting(pid: getpid(), uid: getuid()) {
                TerminalController.shared.v2SudoResultOnSocketWorker(params: ["request_id": requestID])
            }
            if case .ok(let payload) = result,
               let object = payload as? [String: Any],
               object["status"] as? String == "pending" {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                continue
            }
            return result
        }
        XCTFail("Timed out waiting for sudo result", file: file, line: line)
        throw SudoTestError.resultTimeout
    }

    private func parsedRequest(
        workspaceID: UUID = UUID(),
        surfaceID: UUID = UUID(),
        argv: [String] = ["/usr/bin/id"]
    ) throws -> CMUXSudoCommandRequest {
        switch CMUXSudoCommandRequest.parse(
            params: makeParams(workspaceID: workspaceID, surfaceID: surfaceID, argv: argv)
        ) {
        case .success(let request):
            return request
        case .failure(let error):
            throw error
        }
    }

    private func makeParams(
        workspaceID: UUID = UUID(),
        surfaceID: UUID = UUID(),
        argv: [String] = ["/usr/bin/id"]
    ) -> [String: Any] {
        [
            "request_id": UUID().uuidString,
            "argv": argv,
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
            "caller_pid": Int(getpid()),
            "caller_uid": Int(getuid()),
            "cwd": "/tmp",
        ]
    }

    private func auditRecord(id: String, message: String? = nil) -> CMUXSudoAuditRecord {
        CMUXSudoAuditRecord(
            requestID: id,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            workspaceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            surfaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
            requesterPID: 123,
            requesterUID: 501,
            command: ["/usr/bin/id"],
            commandDisplay: "/usr/bin/id",
            workingDirectory: "/tmp",
            result: "completed",
            exitCode: 0,
            errorCode: nil,
            message: message
        )
    }

    private func auditEntries(in logURL: URL) throws -> [[String: Any]] {
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let data = Data(String(line).utf8)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
    }

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-sudo-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirectories.append(url)
        return url
    }
}
