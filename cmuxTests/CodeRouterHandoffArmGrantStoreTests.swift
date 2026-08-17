import CmuxControlSocket
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("CodeRouter handoff arm grants")
struct CodeRouterHandoffArmGrantStoreTests {
    private let start = SocketPeerProcessStartTime(
        absoluteTime: 1_700_000_000_123_456
    )
    private let binding = CodeRouterHandoffSessionBinding(
        authSessionGeneration: 7,
        resolvedTeamID: "team-a"
    )

    @Test func missingGrantFails() {
        let store = CodeRouterHandoffArmGrantStore()
        #expect(store.consume(
            token: token(processID: 41, version: 2),
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == nil)
    }

    @Test func validExecTransitionConsumesExactlyOnce() {
        let store = CodeRouterHandoffArmGrantStore()
        let old = token(processID: 42, version: 10)
        let current = token(processID: 42, version: 11)
        #expect(store.arm(
            token: old,
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: challenge(999),
            clientChallenge: challenge(42)
        ))
        #expect(store.consume(
            token: current,
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == binding)
        #expect(store.consume(
            token: current,
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == nil)
    }

    @Test func beginValidationDoesNotConsumeGrant() {
        let store = CodeRouterHandoffArmGrantStore()
        let old = token(processID: 420, version: 10)
        let current = token(processID: 420, version: 11)
        #expect(store.arm(
            token: old,
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: challenge(998),
            clientChallenge: challenge(420)
        ))
        #expect(store.sessionBindingForBegin(
            token: current,
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == binding)
        #expect(store.pendingGrantCount == 1)
        #expect(store.sessionBindingForBegin(
            token: current,
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == binding)
        #expect(store.consume(
            token: current,
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == binding)
        #expect(store.pendingGrantCount == 0)
    }

    @Test func unchangedAuditTokenFailsAndConsumesGrant() {
        let store = CodeRouterHandoffArmGrantStore()
        let old = token(processID: 43, version: 20)
        #expect(store.arm(
            token: old,
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: challenge(999),
            clientChallenge: challenge(43)
        ))
        #expect(store.consume(
            token: old,
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == nil)
        #expect(store.consume(
            token: token(processID: 43, version: 21),
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == nil)
    }

    @Test func identicalProofTupleCannotCreateASecondReservation() {
        let store = CodeRouterHandoffArmGrantStore()
        let nonce = challenge(900)
        let clientChallenge = challenge(901)
        let old = token(processID: 430, version: 20)
        #expect(store.armWithResult(
            token: old,
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: nonce,
            clientChallenge: clientChallenge
        ) == .armed)
        #expect(store.consume(
            token: token(processID: 430, version: 21),
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == binding)
        #expect(store.armWithResult(
            token: old,
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: nonce,
            clientChallenge: clientChallenge
        ) == .replay)
        #expect(store.pendingGrantCount == 0)
    }

    @Test func wrongPIDCannotConsumeAnotherProcessGrant() {
        let store = CodeRouterHandoffArmGrantStore()
        #expect(store.arm(
            token: token(processID: 44, version: 30),
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: challenge(999),
            clientChallenge: challenge(44)
        ))
        #expect(store.consume(
            token: token(processID: 45, version: 31),
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == nil)
        #expect(store.consume(
            token: token(processID: 44, version: 31),
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == binding)
    }

    @Test func changedStartTimeGenerationOrSessionFails() {
        let changedStart = SocketPeerProcessStartTime(
            absoluteTime: start.absoluteTime + 1
        )
        let changedBinding = CodeRouterHandoffSessionBinding(
            authSessionGeneration: binding.authSessionGeneration + 1,
            resolvedTeamID: binding.resolvedTeamID
        )

        let startStore = CodeRouterHandoffArmGrantStore()
        #expect(startStore.arm(
            token: token(processID: 46, version: 40),
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: challenge(999),
            clientChallenge: challenge(46)
        ))
        #expect(startStore.consume(
            token: token(processID: 46, version: 41),
            processStartTime: changedStart,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == nil)

        let generationStore = CodeRouterHandoffArmGrantStore()
        #expect(generationStore.arm(
            token: token(processID: 47, version: 50),
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: challenge(999),
            clientChallenge: challenge(47)
        ))
        #expect(generationStore.consume(
            token: token(processID: 47, version: 51),
            processStartTime: start,
            authorizationGeneration: 10,
            currentSessionBinding: binding
        ) == nil)

        let sessionStore = CodeRouterHandoffArmGrantStore()
        #expect(sessionStore.arm(
            token: token(processID: 48, version: 60),
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: challenge(999),
            clientChallenge: challenge(48)
        ))
        #expect(sessionStore.consume(
            token: token(processID: 48, version: 61),
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: changedBinding
        ) == nil)
    }

    @Test func expiredGrantsArePrunedAndCannotBeConsumed() {
        let now = LockedNanosecondClock(100)
        let store = CodeRouterHandoffArmGrantStore {
            now.value
        }
        #expect(store.arm(
            token: token(processID: 49, version: 70),
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: challenge(999),
            clientChallenge: challenge(49)
        ))
        now.value = 100 + CodeRouterHandoffArmGrantStore.lifetimeNanoseconds
        #expect(store.consume(
            token: token(processID: 49, version: 71),
            processStartTime: start,
            authorizationGeneration: 9,
            currentSessionBinding: binding
        ) == nil)
        #expect(store.pendingGrantCount == 0)
    }

    @Test func activeGrantCountIsBoundedAndFullStoreRejectsNewPID() {
        let now = LockedNanosecondClock(1_000)
        let store = CodeRouterHandoffArmGrantStore { now.value }
        for offset in 0..<CodeRouterHandoffArmGrantStore.maximumGrantCount {
            #expect(store.arm(
                token: token(
                    processID: pid_t(1_000 + offset),
                    version: UInt32(80 + offset)
                ),
                processStartTime: start,
                authorizationGeneration: 9,
                sessionBinding: binding,
                capabilityNonce: challenge(999),
                clientChallenge: challenge(1_000 + offset)
            ))
        }
        #expect(!store.arm(
            token: token(processID: 2_000, version: 200),
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: challenge(999),
            clientChallenge: challenge(2_000)
        ))
        #expect(store.pendingGrantCount
            == CodeRouterHandoffArmGrantStore.maximumGrantCount)

        now.value += CodeRouterHandoffArmGrantStore.lifetimeNanoseconds
        #expect(store.arm(
            token: token(processID: 2_000, version: 201),
            processStartTime: start,
            authorizationGeneration: 9,
            sessionBinding: binding,
            capabilityNonce: challenge(999),
            clientChallenge: challenge(2_001)
        ))
        #expect(store.pendingGrantCount == 1)
    }

    @Test func peerVerifierHasAnInjectableExactTokenSeam() {
        let expected = token(processID: 50, version: 90)
        let observed = OSAllocatedUnfairLock<SocketPeerAuditToken?>(
            initialState: nil
        )
        let verifier = CodeRouterSocketPeerVerifier { token in
            observed.withLock { $0 = token }
            return token == expected
        }
        #expect(verifier.isTrusted(expected))
        #expect(observed.withLock { $0 } == expected)
        #expect(!verifier.isTrusted(token(processID: 50, version: 91)))
    }

    @Test func handoffBeginWireRequestIsExactAndVersioned() {
        let exact = #"{"id":"coderouter-handoff-begin","method":"coderouter.handoff.begin","params":{"protocolVersion":2}}"#
        #expect(TerminalController.isValidCodeRouterProtocolRequest(
            exact,
            method: "coderouter.handoff.begin",
            expectedID: "coderouter-handoff-begin"
        ))
        #expect(!TerminalController.isValidCodeRouterProtocolRequest(
            " \(exact)",
            method: "coderouter.handoff.begin",
            expectedID: "coderouter-handoff-begin"
        ))
        #expect(!TerminalController.isValidCodeRouterProtocolRequest(
            #"{"id":"coderouter-handoff-begin","method":"coderouter.handoff.begin","params":{"protocolVersion":2},"extra":true}"#,
            method: "coderouter.handoff.begin",
            expectedID: "coderouter-handoff-begin"
        ))
        #expect(!TerminalController.isValidCodeRouterProtocolRequest(
            #"{"id":"coderouter-handoff-begin","method":"coderouter.handoff.begin","params":{"protocolVersion":true}}"#,
            method: "coderouter.handoff.begin",
            expectedID: "coderouter-handoff-begin"
        ))
        #expect(!TerminalController.isValidCodeRouterProtocolRequest(
            #"{"id":"coderouter-handoff-begin","method":"coderouter.handoff.begin","params":{"protocolVersion":2,"teamId":"team-a"}}"#,
            method: "coderouter.handoff.begin",
            expectedID: "coderouter-handoff-begin"
        ))
        #expect(!TerminalController.isValidCodeRouterProtocolRequest(
            #"{"id":"coderouter-handoff-begin","method":" coderouter.handoff.begin ","params":{"protocolVersion":2}}"#,
            method: "coderouter.handoff.begin",
            expectedID: "coderouter-handoff-begin"
        ))
        #expect(!TerminalController.isValidCodeRouterProtocolRequest(
            #"{"id":"coderouter-handoff-begin","method":"feed.push","method":"coderouter.handoff.begin","params":{"protocolVersion":2}}"#,
            method: "coderouter.handoff.begin",
            expectedID: "coderouter-handoff-begin"
        ))
        #expect(!TerminalController.isValidCodeRouterProtocolRequest(
            #"{"meth\u006fd":"feed.push","id":"coderouter-handoff-begin","method":"coderouter.handoff.begin","params":{"protocolVersion":2}}"#,
            method: "coderouter.handoff.begin",
            expectedID: "coderouter-handoff-begin"
        ))
        for invalidIDRequest in [
            #"{"method":"coderouter.handoff.begin","params":{"protocolVersion":2}}"#,
            #"{"id":1,"method":"coderouter.handoff.begin","params":{"protocolVersion":2}}"#,
            #"{"id":"wrong","method":"coderouter.handoff.begin","params":{"protocolVersion":2}}"#,
        ] {
            #expect(!TerminalController.isValidCodeRouterProtocolRequest(
                invalidIDRequest,
                method: "coderouter.handoff.begin",
                expectedID: "coderouter-handoff-begin"
            ))
        }
    }

    @Test func handoffCompleteWireRequestIsExactAndChallengeBound() {
        let challenge = "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI"
        let exact = #"{"id":"coderouter-handoff-complete","method":"coderouter.handoff.complete","params":{"protocolVersion":2,"challenge":"\#(challenge)"}}"#
        #expect(TerminalController.codeRouterHandoffCompleteChallenge(exact)
            == challenge)
        #expect(TerminalController.codeRouterHandoffCompleteChallenge(
            "\(exact)\u{00A0}"
        ) == nil)
        #expect(TerminalController.codeRouterHandoffCompleteChallenge(
            exact.replacingOccurrences(
                of: #""protocolVersion":2"#,
                with: #""protocolVersion":2.0"#
            )
        ) == nil)
        #expect(TerminalController.codeRouterHandoffCompleteChallenge(
            exact.replacingOccurrences(
                of: "coderouter-handoff-complete",
                with: "wrong",
                maxReplacements: 1
            )
        ) == nil)
        #expect(TerminalController.codeRouterHandoffCompleteChallenge(
            exact.replacingOccurrences(of: challenge, with: challenge + "=")
        ) == nil)
        #expect(TerminalController.codeRouterHandoffCompleteChallenge(
            #"{"meth\u006fd":"feed.push","id":"coderouter-handoff-complete","method":"coderouter.handoff.complete","params":{"protocolVersion":2,"challenge":"\#(challenge)"}}"#
        ) == nil)
        #expect(TerminalController.isCodeRouterHandoffCommand(exact))
        #expect(!TerminalController.isCodeRouterHandoffCommand(
            #"{"id":"coderouter-handoff","method":"coderouter.handoff","params":{"protocolVersion":2}}"#
        ))
    }

    @Test func handoffChallengeGenerationHasAnInjectableRandomSeam() {
        let bytes = Data(repeating: 0x22, count: 32)
        #expect(TerminalController.makeCodeRouterHandoffChallenge {
            bytes
        } == "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI")
        #expect(TerminalController.makeCodeRouterHandoffChallenge {
            Data(repeating: 0x22, count: 31)
        } == nil)
    }

    @Test func armProofWireRequestIsExactAndCanonical() throws {
        let nonce = challenge(700)
        let clientChallenge = challenge(701)
        let nonceText = try #require(
            SocketClientCapabilityProof.encodeBase64URL32(nonce)
        )
        let challengeText = try #require(
            SocketClientCapabilityProof.encodeBase64URL32(clientChallenge)
        )
        let exact = #"{"id":"coderouter-handoff-arm","method":"coderouter.handoff.arm","params":{"protocolVersion":2,"capabilityNonce":"\#(nonceText)","clientChallenge":"\#(challengeText)","clientProcessID":42,"clientProcessStartAbsoluteTime":"0123456789abcdef","clientProof":"\#(String(repeating: "a", count: 64))"}}"#
        let parsed = try #require(
            TerminalController.codeRouterHandoffArmProofRequest(exact)
        )
        #expect(parsed.nonce == nonce)
        #expect(parsed.challenge == clientChallenge)
        #expect(parsed.processID == 42)
        #expect(parsed.processStartAbsoluteTime == 0x0123_4567_89ab_cdef)

        #expect(TerminalController.codeRouterHandoffArmProofRequest(
            exact.replacingOccurrences(
                of: #""protocolVersion":2"#,
                with: #""protocolVersion":2.0"#
            )
        ) == nil)
        #expect(TerminalController.codeRouterHandoffArmProofRequest(
            exact.replacingOccurrences(
                of: #""clientProcessID":42"#,
                with: #""clientProcessID":42.0"#
            )
        ) == nil)
        #expect(TerminalController.codeRouterHandoffArmProofRequest(
            exact.replacingOccurrences(
                of: "coderouter-handoff-arm",
                with: "wrong",
                maxReplacements: 1
            )
        ) == nil)
        #expect(TerminalController.codeRouterHandoffArmProofRequest(
            exact.replacingOccurrences(
                of: String(repeating: "a", count: 64),
                with: String(repeating: "A", count: 64)
            )
        ) == nil)
        #expect(TerminalController.codeRouterHandoffArmProofRequest(
            exact.replacingOccurrences(
                of: String(repeating: "a", count: 64),
                with: String(repeating: "a", count: 63)
            )
        ) == nil)
        #expect(TerminalController.codeRouterHandoffArmProofRequest(
            #"{"id":"coderouter-handoff-arm","method":"coderouter.handoff.arm","params":{"protocolVersion":2}}"#
        ) == nil)
        #expect(TerminalController.codeRouterHandoffArmProofRequest(
            exact.replacingOccurrences(
                of: #"{"id"#,
                with: #"{"meth\u006fd":"feed.push","id"#
            )
        ) == nil)
        // The exact arm frame must not rely on the caller-side line trim.
        // Foundation accepts ASCII JSON framing whitespace, so exercise the
        // parser seam directly as well as the socket handler's raw-line gate.
        #expect(TerminalController.codeRouterHandoffArmProofRequest(
            " \(exact)"
        ) == nil)
        #expect(TerminalController.codeRouterHandoffArmProofRequest(
            "\(exact) "
        ) == nil)
        #expect(TerminalController.codeRouterHandoffArmProofRequest(
            "\u{00A0}\(exact)"
        ) == nil)
        #expect(TerminalController.codeRouterHandoffArmProofRequest(
            "\(exact)\u{2003}"
        ) == nil)
    }

    @Test func teamBindingUsesExactBytesAndDomainPrefix() {
        #expect(TerminalController.codeRouterTeamBinding(teamID: "team-a")
            == "f8cf6117b5f506cc3e5da5a09d35bed388105ef4d6aec59c1952b159e0f3e5c5")
        #expect(TerminalController.codeRouterTeamBinding(teamID: " team-a ") == nil)
        #expect(TerminalController.codeRouterTeamBinding(
            teamID: "team\u{200B}a"
        ) == nil)
        #expect(TerminalController.codeRouterTeamBinding(
            teamID: "team\u{0007}a"
        ) == nil)
        #expect(TerminalController.codeRouterTeamBinding(
            teamID: "team\u{E0101}a"
        ) != nil)
        #expect(TerminalController.codeRouterTeamBinding(
            teamID: String(repeating: "t", count: 201)
        ) == nil)
        #expect(TerminalController.codeRouterTeamBinding(teamID: nil) == nil)
        #expect(TerminalController.codeRouterTeamBinding(teamID: "") == nil)
    }

    private func token(
        processID: pid_t,
        version: UInt32
    ) -> SocketPeerAuditToken {
        var words = [UInt32](repeating: 0, count: 8)
        words[5] = UInt32(bitPattern: processID)
        words[7] = version
        let bytes = words.withUnsafeBytes { Array($0) }
        return SocketPeerAuditToken(bytes: bytes)!
    }

    private func challenge(_ marker: Int) -> Data {
        var data = Data(repeating: 0, count: SocketClientCapabilityProof.byteCount)
        var bigEndian = UInt64(truncatingIfNeeded: marker).bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            data.replaceSubrange(0..<bytes.count, with: bytes)
        }
        return data
    }
}

private final class LockedNanosecondClock: Sendable {
    private let state: OSAllocatedUnfairLock<UInt64>

    init(_ initialValue: UInt64) {
        state = OSAllocatedUnfairLock(initialState: initialValue)
    }

    var value: UInt64 {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
