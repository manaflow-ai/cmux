import CmuxMobileSSH
@testable import CmuxiOSSSHCore
import Foundation
import Testing

/// Answers every question with a fixed decision and records them.
actor ScriptedPrompter: SSHTrustPrompter {
    let answer: SSHTrustDecision
    private(set) var questions: [SSHTrustQuestion] = []
    init(_ answer: SSHTrustDecision) { self.answer = answer }
    func decide(_ question: SSHTrustQuestion) async -> SSHTrustDecision {
        questions.append(question)
        return answer
    }
}

actor MemoryKnownHosts: SSHKnownHostsStore {
    var pins: [String: SSHHostKey] = [:]
    func pinnedKey(for identity: String) -> SSHHostKey? { pins[identity] }
    func pin(_ key: SSHHostKey, for identity: String) { pins[identity] = key }
}

@Suite struct TOFUHostKeyVerifierTests {
    let endpoint = SSHEndpoint(host: "Box.lan", port: 2222, username: "me")
    var keyA: SSHHostKey { SSHKnownHostsTests.keyA }
    var keyB: SSHHostKey { SSHKnownHostsTests.keyB }

    @Test func unknownKeyIsAskedAndPinnedOnTrust() async {
        let store = MemoryKnownHosts()
        let prompter = ScriptedPrompter(.trust)
        let verifier = TOFUHostKeyVerifier(knownHosts: store, prompter: prompter, names: ["[box.lan]:2222": "Box"])
        #expect(await verifier.verify(keyA, for: endpoint))
        #expect(await store.pins["[box.lan]:2222"] == keyA)
        #expect(await prompter.questions == [.unknown(hostName: "Box", identity: "[box.lan]:2222", presented: keyA)])
        // Pinned now: no second question.
        #expect(await verifier.verify(keyA, for: endpoint))
        #expect(await prompter.questions.count == 1)
    }

    @Test func rejectPinsNothing() async {
        let store = MemoryKnownHosts()
        let verifier = TOFUHostKeyVerifier(knownHosts: store, prompter: ScriptedPrompter(.reject))
        #expect(await verifier.verify(keyA, for: endpoint) == false)
        #expect(await store.pins.isEmpty)
    }

    @Test func changedKeyWarnsAndReplacesOnlyOnTrust() async {
        let store = MemoryKnownHosts()
        await store.pin(keyA, for: endpoint.hostKeyIdentity)
        let declining = ScriptedPrompter(.reject)
        #expect(await TOFUHostKeyVerifier(knownHosts: store, prompter: declining).verify(keyB, for: endpoint) == false)
        #expect(await declining.questions == [.changed(hostName: "Box.lan", identity: "[box.lan]:2222", pinned: keyA, presented: keyB)])
        #expect(await store.pins[endpoint.hostKeyIdentity] == keyA)
        #expect(await TOFUHostKeyVerifier(knownHosts: store, prompter: ScriptedPrompter(.trust)).verify(keyB, for: endpoint))
        #expect(await store.pins[endpoint.hostKeyIdentity] == keyB)
    }
}
