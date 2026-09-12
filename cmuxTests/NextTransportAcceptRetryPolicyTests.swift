#if DEBUG
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Next transport accept retries")
struct NextTransportAcceptRetryPolicyTests {
    @Test func cancellationPropagatesFromTheDeadlineClock() async {
        var retry = NextTransportAcceptRetryPolicy()
        await #expect(throws: CancellationError.self) {
            try await retry.waitAfterFailure { _ in throw CancellationError() }
        }
    }

    @Test func backoffIsBoundedAndResetsAfterSuccessfulAccept() async throws {
        var retry = NextTransportAcceptRetryPolicy()
        for milliseconds in [100, 200, 400, 800, 1600, 3200, 5000, 5000] {
            try await retry.waitAfterFailure { delay in #expect(delay == .milliseconds(milliseconds)) }
        }
        retry.reset()
        try await retry.waitAfterFailure { delay in #expect(delay == .milliseconds(100)) }
    }
}
#endif
