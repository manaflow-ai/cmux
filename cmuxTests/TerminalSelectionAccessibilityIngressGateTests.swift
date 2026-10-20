import Testing

@Suite struct TerminalSelectionAccessibilityIngressGateTests {
    @Test func burstKeepsOnePendingEventUntilTheConsumerDrainsIt() async {
        let signal = TerminalSelectionAccessibilitySignal()

        let enqueuedCount = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    signal.request()
                }
            }

            var count = 0
            for await enqueued in group where enqueued {
                count += 1
            }
            return count
        }

        #expect(enqueuedCount == 1)
        var iterator = signal.events.makeAsyncIterator()
        _ = await iterator.next()
        #expect(signal.request())
        signal.finish()
    }
}
