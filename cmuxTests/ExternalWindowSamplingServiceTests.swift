import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("External window sampling lifetime")
struct ExternalWindowSamplingServiceTests {
    private final class SampleSource: Sendable {
        let released: AsyncStream<Void>.Continuation

        init(released: AsyncStream<Void>.Continuation) {
            self.released = released
        }

        func read() -> ExternalApplicationWindowSnapshot? {
            withExtendedLifetime(self) { nil }
        }

        deinit { released.yield() }
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func releasingSamplerCancelsItsWorkAndReleasesDependencies() async {
        let (releases, releaseContinuation) = AsyncStream<Void>.makeStream()
        let (deliveries, deliveryContinuation) = AsyncStream<Void>.makeStream()
        defer {
            releaseContinuation.finish()
            deliveryContinuation.finish()
        }
        var source: SampleSource? = SampleSource(released: releaseContinuation)
        var sampler: ExternalWindowSamplingService? = ExternalWindowSamplingService()
        sampler?.start(
            interval: .seconds(60),
            sample: { [source] in source?.read() },
            deliver: { _ in deliveryContinuation.yield() }
        )
        source = nil
        var deliveryIterator = deliveries.makeAsyncIterator()
        _ = await deliveryIterator.next()

        sampler = nil

        var releaseIterator = releases.makeAsyncIterator()
        let released: Void? = await releaseIterator.next()
        #expect(released != nil)
    }
}
