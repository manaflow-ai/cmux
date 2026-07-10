import Testing

@Suite struct TerminalSelectionAccessibilityIngressGateTests {
    @Test func burstClaimsOneMainActorHopUntilTheLatestEventIsQuiet() async {
        let gate = TerminalSelectionAccessibilityIngressGate()

        let claimedHopCount = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    gate.registerRequest(at: 10)
                }
            }

            var count = 0
            for await claimed in group where claimed {
                count += 1
            }
            return count
        }

        #expect(claimedHopCount == 1)
        #expect(gate.registerRequest(at: 11) == false)

        switch gate.drainDecision(at: 11.05, debounceInterval: 0.1) {
        case .reschedule(let delay):
            #expect(abs(delay - 0.05) < 0.000_001)
        case .post:
            Issue.record("The newest request has not been quiet for the debounce interval")
        }

        #expect(gate.registerRequest(at: 12) == false)
        #expect(gate.drainDecision(at: 12.1, debounceInterval: 0.1) == .post)
        #expect(gate.registerRequest(at: 13))
    }
}
