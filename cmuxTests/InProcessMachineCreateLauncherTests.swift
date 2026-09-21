import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The in-process New Machine create: the argv the coordinator already builds, the
/// idempotency key lifecycle, the create → link → terminal order, cancellation after
/// the receipt, and failure redaction, all through injected dependencies.
@MainActor
@Suite(.serialized)
struct InProcessMachineCreateLauncherTests {
    private static let workspaceID = UUID()
    private static let route = "ws://10.16.0.7:1337/v1/link"
    private static let attach = VMCreateAttach(
        route: route, session: "cloud", trustedCarrier: true,
        daemonBuild: VMCmuxRemoteEndpoint.DaemonBuild(commit: "abc123", remoteProtocol: nil, version: nil),
        guestToolsBaked: false, readiness: "dial", receivedAt: Date(timeIntervalSince1970: 1_787_400_000)
    )
    private static var createArguments: [String] {
        ["vm", "new", "--desktop", "--size", "24576", "--focus", "false", "--workspace", workspaceID.uuidString]
    }
    private static var openArguments: [String] {
        ["vm", "open", "vm-fresh", "--workspace", workspaceID.uuidString, "--focus", "false"]
    }

    // MARK: - argv

    @Test func parsesTheSheetsCreateInvocation() {
        let windowID = UUID()
        let invocation = InProcessMachineCreateLauncher.parse(arguments: Self.createArguments + ["--window", windowID.uuidString])
        #expect(invocation == InProcessMachineCreateLauncher.Invocation(
            verb: .create(kind: .desktop, memoryMb: 24576, displayName: nil),
            workspaceID: Self.workspaceID, focus: false, windowID: windowID
        ))
        let named = InProcessMachineCreateLauncher.parse(arguments: [
            "vm", "new", "--base", "--name", "my box", "--focus", "true", "--workspace", Self.workspaceID.uuidString
        ])
        #expect(named == InProcessMachineCreateLauncher.Invocation(
            verb: .create(kind: .base, memoryMb: nil, displayName: "my box"),
            workspaceID: Self.workspaceID, focus: true, windowID: nil
        ))
    }

    @Test func parsesTheCoordinatorsRetryOpenInvocation() {
        let invocation = InProcessMachineCreateLauncher.parse(arguments: Self.openArguments)
        #expect(invocation == InProcessMachineCreateLauncher.Invocation(
            verb: .open(machineID: "vm-fresh"), workspaceID: Self.workspaceID, focus: false, windowID: nil
        ))
    }

    @Test(arguments: [
        ["vm", "base", "open", "--workspace", UUID().uuidString, "--desktop", "--focus", "false"],
        ["vm", "new", "--desktop", "--focus", "false"],
        ["vm", "new", "--workspace", "not-a-uuid"],
        ["vm", "new", "--workspace", UUID().uuidString, "--image", "sh-custom"],
        ["vm", "open", "--workspace", UUID().uuidString],
        ["vm", "rm", "vm-fresh"],
        ["vm", "new", "--workspace", UUID().uuidString, "extra"]
    ])
    func leavesEveryOtherInvocationToTheCLI(arguments: [String]) {
        #expect(InProcessMachineCreateLauncher.parse(arguments: arguments) == nil)
    }

    @Test func idempotencyKeyIsTheOperationIDSoRetriesReplayTheSameCreate() {
        let operationID = UUID()
        let key = InProcessMachineCreateLauncher.idempotencyKey(operationID: operationID)
        #expect(key == "app-" + operationID.uuidString.lowercased())
        #expect(InProcessMachineCreateLauncher.idempotencyKey(operationID: operationID) == key)
        #expect(InProcessMachineCreateLauncher.idempotencyKey(operationID: UUID()) != key)
    }

    // MARK: - create response

    @Test func decodesTheCreateResponseAddressAndAttachBlock() throws {
        let now = Date(timeIntervalSince1970: 1_787_400_000)
        // Parsed the way `createMachine` parses the HTTP body: the decoder reads the
        // NSNumber that JSONSerialization produces, not a Swift integer literal.
        let body = """
        {"id": "vm-fresh", "provider": "freestyle", "image": "md-1", "status": "running",
         "createdAt": 1787399000000, "slug": "calm-petrel",
         "address": {"ipv4": "10.16.0.7", "ipv6": "fd00:4::7"},
         "attach": {"transport": "cmux-remote", "route": "\(Self.route)", "session": "cloud", "trustedCarrier": true,
                    "daemonBuild": {"commit": "abc123", "remoteProtocol": null, "version": null},
                    "guestToolsBaked": false, "readiness": "dial"}}
        """
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let result = try VMClient.decodeCreateResult(object, now: now)
        #expect(result.summary.id == "vm-fresh")
        #expect(result.summary.slug == "calm-petrel")
        #expect(result.summary.addressIPv4 == "10.16.0.7")
        #expect(result.summary.addressIPv6 == "fd00:4::7")
        #expect(result.summary.createdAt == 1_787_399_000_000)
        let attach = try #require(result.attach)
        #expect(attach.route == Self.route)
        #expect(attach.session == "cloud")
        #expect(attach.trustedCarrier)
        #expect(attach.daemonBuild?.commit == "abc123")
        #expect(attach.daemonBuild?.remoteProtocol == nil)
        #expect(!attach.guestToolsBaked)
        #expect(attach.readiness == "dial")
        #expect(attach.receivedAt == now)
    }

    @Test func olderBackendsWithoutAttachStillDecodeAndForeignTransportsAreIgnored() throws {
        let legacy: [String: Any] = ["id": "vm-old", "provider": "freestyle", "image": "md-1"]
        let result = try VMClient.decodeCreateResult(legacy, now: Date())
        #expect(result.attach == nil)
        #expect(result.summary.addressIPv4 == nil)
        #expect(result.summary.status == "running")
        let foreign: [String: Any] = [
            "id": "vm-old", "provider": "freestyle", "image": "md-1",
            "attach": ["transport": "ssh", "route": "ssh://10.16.0.7"]
        ]
        #expect(try VMClient.decodeCreateResult(foreign, now: Date()).attach == nil)
        let incomplete: [String: Any] = [
            "id": "vm-old", "provider": "freestyle", "image": "md-1",
            "attach": ["transport": "cmux-remote", "session": "cloud"]
        ]
        #expect(try VMClient.decodeCreateResult(incomplete, now: Date()).attach == nil, "a block without a route cannot be dialed")
        #expect(throws: VMClientError.self) {
            try VMClient.decodeCreateResult(["id": "vm-old"], now: Date())
        }
    }

    @Test func remoteInfoPayloadFromTheCreateReceiptNeedsNoControlPlaneCall() {
        let payload = TerminalController.cmuxRemoteInfoPayload(cachedAttach: Self.attach)
        #expect(payload["transport"] as? String == "cmux-remote")
        #expect(payload["route"] as? String == Self.route)
        #expect(payload["session"] as? String == "cloud")
        #expect(payload["trusted_carrier"] as? Bool == true)
        #expect(payload["token"] as? String == "")
        #expect((payload["daemon_build"] as? [String: Any])?["commit"] as? String == "abc123")
        #expect(payload["network_addresses"] == nil)
    }

    // MARK: - flow

    /// Stands in for VMClient, the registry, the link manager, the catalog and the
    /// workspace: records the order every step runs in and can block or fail any of them.
    @MainActor
    final class Recorder {
        var steps: [String] = []
        var attach: VMCreateAttach?
        var createError: Error?
        var connectError: Error?
        var connectGate: CloudLinkFirstValue<Bool>?
        var remoteWorkspaceID: String? = "ws_main"
        var selectedWorkspaces: Set<UUID> = []

        private func summary(_ id: String, address: String?) -> VMSummary {
            var summary = VMSummary(id: id, provider: "freestyle", status: "running", image: "md-1", createdAt: 1, base: nil)
            summary.addressIPv4 = address
            return summary
        }

        func dependencies() -> InProcessMachineCreateLauncher.Dependencies {
            InProcessMachineCreateLauncher.Dependencies(
                create: { [self] _, key in
                    steps.append("create key=\(key)")
                    if let createError { throw createError }
                    return VMCreateResult(summary: summary("vm-fresh", address: attach == nil ? nil : "10.16.0.7"), attach: attach)
                },
                status: { [self] id in
                    steps.append("status \(id)")
                    return summary(id, address: "10.16.0.9")
                },
                cachedAttach: { [self] _ in attach },
                recordCreatedMachine: { [self] summary, attach in
                    steps.append("record \(summary.id) address=\(summary.addressIPv4 ?? "-") attach=\(attach != nil)")
                },
                prepareLoadingPane: { [self] _, focus in
                    steps.append("pane focus=\(focus)")
                    return UUID()
                },
                bind: { [self] _, machineID, remoteWorkspaceID in
                    steps.append("bind \(machineID) remote=\(remoteWorkspaceID ?? "-")")
                },
                connect: { [self] machineID, attach in
                    steps.append("connect \(machineID) attach=\(attach != nil)")
                    if let connectError { throw connectError }
                    if let connectGate {
                        _ = await connectGate.result
                        try Task.checkCancellation()
                    }
                },
                newTerminal: { [self] machineID, _, focus in
                    steps.append("terminal \(machineID) focus=\(focus)")
                    return remoteWorkspaceID
                },
                isWorkspaceSelected: { [self] workspaceID in selectedWorkspaces.contains(workspaceID) }
            )
        }
    }

    private func run(
        _ arguments: [String],
        operationID: UUID = UUID(),
        recorder: Recorder
    ) async throws -> CloudVMActionLauncher.Completion {
        let invocation = try #require(InProcessMachineCreateLauncher.parse(arguments: arguments))
        return await InProcessMachineCreateLauncher.run(
            invocation, operationID: operationID, dependencies: recorder.dependencies(),
            onOutput: { chunk in recorder.steps.append("progress \(chunk)") }
        )
    }

    @Test func createResponseWithAttachDialsWithoutAStatusReadOrTheAttachEndpoint() async throws {
        let recorder = Recorder()
        recorder.attach = Self.attach
        let operationID = UUID()
        let completion = try await run(Self.createArguments, operationID: operationID, recorder: recorder)
        #expect(completion.terminationStatus == 0)
        #expect(completion.succeeded)
        #expect(!completion.wasCancelled)
        #expect(completion.machineId == "vm-fresh")
        #expect(completion.workspaceId == Self.workspaceID)
        #expect(completion.output == "OK machine=vm-fresh\nworkspace=\(Self.workspaceID.uuidString)\n")
        #expect(recorder.steps == [
            "create key=app-\(operationID.uuidString.lowercased())",
            "progress OK machine=vm-fresh\n",
            "record vm-fresh address=10.16.0.7 attach=true",
            "pane focus=false",
            "bind vm-fresh remote=-",
            "connect vm-fresh attach=true",
            "terminal vm-fresh focus=false",
            "bind vm-fresh remote=ws_main"
        ])
        #expect(MachineCreateCoordinator.createdMachineID(fromOutput: completion.output) == "vm-fresh")
    }

    @Test func missingAttachFallsBackToOneStatusReadThenTheExistingLinkPath() async throws {
        let recorder = Recorder()
        let completion = try await run(Self.createArguments, recorder: recorder)
        #expect(completion.terminationStatus == 0)
        #expect(completion.workspaceId == Self.workspaceID)
        #expect(recorder.steps.dropFirst(2).elementsEqual([
            "record vm-fresh address=- attach=false",
            "pane focus=false",
            "bind vm-fresh remote=-",
            "status vm-fresh",
            "record vm-fresh address=10.16.0.9 attach=false",
            "connect vm-fresh attach=false",
            "terminal vm-fresh focus=false",
            "bind vm-fresh remote=ws_main"
        ]))
    }

    @Test func retryOpenSkipsTheCreateAndReusesTheCachedReceipt() async throws {
        let recorder = Recorder()
        recorder.attach = Self.attach
        let completion = try await run(Self.openArguments, recorder: recorder)
        #expect(completion.terminationStatus == 0)
        #expect(completion.machineId == "vm-fresh")
        #expect(completion.workspaceId == Self.workspaceID)
        #expect(completion.output == "workspace=\(Self.workspaceID.uuidString)\n")
        #expect(recorder.steps == [
            "pane focus=false",
            "bind vm-fresh remote=-",
            "connect vm-fresh attach=true",
            "terminal vm-fresh focus=false",
            "bind vm-fresh remote=ws_main"
        ])
    }

    @Test func aTargetWorkspaceTheUserIsLookingAtGetsPaneFocusWithoutASelectionChange() async throws {
        let recorder = Recorder()
        recorder.attach = Self.attach
        recorder.selectedWorkspaces = [Self.workspaceID]
        _ = try await run(Self.createArguments, recorder: recorder)
        #expect(recorder.steps.contains("pane focus=true"))
        #expect(recorder.steps.contains("terminal vm-fresh focus=true"))
    }

    @Test func cancellationAfterTheReceiptReportsTheMachineForCleanupWithoutOpeningIt() async throws {
        let recorder = Recorder()
        recorder.attach = Self.attach
        let gate = CloudLinkFirstValue<Bool>()
        recorder.connectGate = gate
        let invocation = try #require(InProcessMachineCreateLauncher.parse(arguments: Self.createArguments))
        let task = Task {
            await InProcessMachineCreateLauncher.run(
                invocation, operationID: UUID(), dependencies: recorder.dependencies(), onOutput: { _ in }
            )
        }
        await Self.yieldUntil { recorder.steps.contains("connect vm-fresh attach=true") }
        task.cancel()
        let completion = await task.value
        #expect(completion.wasCancelled)
        #expect(!completion.succeeded)
        #expect(completion.machineId == "vm-fresh", "the tombstone needs the id to destroy the machine")
        #expect(completion.workspaceId == nil)
        #expect(!recorder.steps.contains { $0.hasPrefix("terminal") })
    }

    @Test func createFailuresAreRedactedBeforeTheyReachThePendingRow() async throws {
        let recorder = Recorder()
        recorder.createError = VMClientError.httpStatus(
            500, #"{"error":"vm_create_failed","detail":"Authorization: Bearer secret-token-value"}"#
        )
        let completion = try await run(Self.createArguments, recorder: recorder)
        #expect(completion.terminationStatus == 1)
        #expect(completion.machineId == nil)
        #expect(completion.workspaceId == nil)
        let shown = MachineCreateCoordinator.displayableFailureOutput(completion.output)
        #expect(!shown.isEmpty)
        #expect(!shown.contains("secret-token-value"))
        #expect(recorder.steps.count == 1, "nothing runs after a refused create")
    }

    @Test func openFailureAfterTheReceiptKeepsTheMachineIDSoRetryOpensInsteadOfCreating() async throws {
        let recorder = Recorder()
        recorder.attach = Self.attach
        recorder.connectError = CloudMachineLinkManager.ManagerError.retryLater("daemon still starting")
        let completion = try await run(Self.createArguments, recorder: recorder)
        #expect(completion.terminationStatus == 1)
        #expect(completion.machineId == "vm-fresh")
        #expect(completion.output.hasPrefix("OK machine=vm-fresh\n"))
        #expect(completion.output.contains("daemon still starting"))

        let coordinator = MachineCreateCoordinator(notifier: { _ in }, notificationCenter: NotificationCenter())
        let request = MachineCreateCoordinatorTests.newMachineRequest().targetingReservedWorkspace(Self.workspaceID)
        let id = try #require(coordinator.startOperation(request, cancellableLaunch: { _, progress, complete in
            progress("OK machine=vm-fresh\n")
            complete(completion)
            return CloudVMActionLauncher.CancellationHandle { }
        }))
        #expect(coordinator.operation(id: id)?.createdMachineID == "vm-fresh")
        #expect(coordinator.operation(id: id)?.failureOutput == "daemon still starting")
        #expect(coordinator.lastFinished?.outcome == .createdButOpenFailed(machineID: "vm-fresh", output: "daemon still starting"))
    }

    @MainActor
    private static func yieldUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }
}
