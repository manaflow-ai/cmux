import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct PortScannerProcessCaptureTests {
    private func openFDCount() -> Int? {
        try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    @Test
    func captureStandardOutputDoesNotLeakPipeFDs() throws {
        let baseline = try #require(openFDCount(), "Unable to inspect /dev/fd on this runner")

        var maxCount = baseline
        for _ in 0..<200 {
            let output = PortScanner.captureStandardOutput(
                executablePath: "/usr/bin/printf",
                arguments: ["cmux"]
            )
            #expect(output == "cmux")
            if let current = openFDCount() {
                maxCount = max(maxCount, current)
            }
        }

        let finalCount = try #require(openFDCount(), "Unable to inspect final /dev/fd count on this runner")

        #expect(maxCount - baseline <= 8)
        #expect(finalCount - baseline <= 8)
    }

    @Test
    func unchangedAgentPortResultsAreSuppressed() async {
        let scanner = PortScanner()
        let workspaceId = UUID()
        let revisions = [workspaceId: UInt64(0)]

        let initialEmpty = await scanner.validatedAgentResults(
            workspaceIds: [workspaceId],
            agentPortsByWorkspace: [:],
            agentRevisions: revisions
        )
        #expect(initialEmpty.isEmpty)

        let firstPorts = await scanner.validatedAgentResults(
            workspaceIds: [workspaceId],
            agentPortsByWorkspace: [workspaceId: [3000, 8787]],
            agentRevisions: revisions
        )
        #expect(firstPorts.count == 1)
        #expect(firstPorts.first?.0 == workspaceId)
        #expect(firstPorts.first?.1 == [3000, 8787])

        let unchangedPorts = await scanner.validatedAgentResults(
            workspaceIds: [workspaceId],
            agentPortsByWorkspace: [workspaceId: [8787, 3000]],
            agentRevisions: revisions
        )
        #expect(unchangedPorts.isEmpty)

        let clearedPorts = await scanner.validatedAgentResults(
            workspaceIds: [workspaceId],
            agentPortsByWorkspace: [:],
            agentRevisions: revisions
        )
        #expect(clearedPorts.count == 1)
        #expect(clearedPorts.first?.0 == workspaceId)
        #expect(clearedPorts.first?.1 == [])

        let unchangedEmpty = await scanner.validatedAgentResults(
            workspaceIds: [workspaceId],
            agentPortsByWorkspace: [:],
            agentRevisions: revisions
        )
        #expect(unchangedEmpty.isEmpty)
    }
}

@Suite
struct ProcessTerminationGateTests {
    @Test
    func prelaunchTerminationRequestIsDeferredUntilLaunch() {
        let gate = ProcessTerminationGate()

        #expect(
            !gate.requestTermination(),
            "A cancellation that arrives before Process.run() succeeds must not touch the Process."
        )
        #expect(
            gate.markLaunched(),
            "Once launch succeeds, the deferred termination request should be applied to the running Process."
        )
        gate.markFinished()
        #expect(
            !gate.requestTermination(),
            "Late cancellation after completion must not touch Process termination state."
        )
    }

    @Test
    func finishedPrelaunchProcessIgnoresDeferredTermination() {
        let gate = ProcessTerminationGate()

        #expect(!gate.requestTermination())
        gate.markFinished()
        #expect(
            !gate.markLaunched(),
            "If launch fails and the run is already finished, no deferred termination should be applied."
        )
    }
}
