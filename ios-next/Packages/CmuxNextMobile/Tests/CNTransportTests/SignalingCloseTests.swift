@testable import CNTransportWebRTC
import Foundation
import Testing

@Suite struct SignalingCloseTests {
    @Test func recorderReturnsCodeRecordedBeforeOrAfterTheWait() async {
        let early = WebSocketCloseRecorder()
        early.record(4002)
        #expect(await early.code(waitingUpTo: .seconds(5), clock: ContinuousClock()) == 4002)

        let late = WebSocketCloseRecorder()
        let waiter = Task { await late.code(waitingUpTo: .seconds(5), clock: ContinuousClock()) }
        await Task.yield()
        late.record(4005)
        #expect(await waiter.value == 4005)
    }

    @Test func recorderGivesUpAfterTimeout() async {
        let recorder = WebSocketCloseRecorder()
        #expect(await recorder.code(waitingUpTo: .milliseconds(20), clock: ContinuousClock()) == nil)
    }

    @Test func waitAfterTimeoutResumesImmediately() async {
        let recorder = WebSocketCloseRecorder()
        #expect(await recorder.code(waitingUpTo: .milliseconds(10), clock: ContinuousClock()) == nil)
        // The wait already expired: a later caller must not hang for the full timeout.
        let start = ContinuousClock.now
        #expect(await recorder.code(waitingUpTo: .seconds(5), clock: ContinuousClock()) == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func closeCodes() {
        #expect(SignalingClient.tokenExpiredCloseCode == 4002)
        #expect(SignalingClient.sessionRevokedCloseCode == 4005)
    }
}
