@testable import CmuxiOSSSHCore
import CmuxMobileSSH
import Testing

@Suite struct SSHReconnectPolicyTests {
    @Test func doublesUpToTheCapThenStops() {
        let policy = SSHReconnectPolicy(initial: .milliseconds(500), maximum: .seconds(3), attempts: 5)
        #expect((1...5).map { policy.delay(beforeAttempt: $0) } == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(3), .seconds(3)])
        #expect(policy.delay(beforeAttempt: 6) == nil)
        #expect(policy.delay(beforeAttempt: 0) == nil)
    }

    @Test func failureClassification() {
        #expect(SSHSessionFailure(SSHConnectionError.authenticationFailed) == .authenticationFailed)
        #expect(SSHSessionFailure(SSHConnectionError.closed) == .network)
        #expect(SSHSessionFailure(SSHConnectionError.channelRequestRejected("pty-req")) == .shellRejected)
        #expect(SSHSessionFailure(CancellationError()) == .network)
        #expect(SSHSessionFailure.network.isRetryable)
        #expect(!SSHSessionFailure.hostKeyRejected.isRetryable)
    }
}
