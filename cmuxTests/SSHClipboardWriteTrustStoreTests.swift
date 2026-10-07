import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SSHClipboardWriteTrustStoreTests {
    // Regression context from #18324 (@simjak): cmux 0.65.0's cmux-tui SSH
    // mirrors received OSC 52 from a remote TUI/tmux selection, but the
    // manual-I/O callback policy kept that remote-origin write off the Mac
    // clipboard until the user explicitly trusted the SSH machine.
    @Test("trust is opt-in, endpoint-scoped, revocable, and write-only")
    @MainActor
    func trustPolicy() throws {
        let suiteName = "cmux.ssh-clipboard-trust-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SSHClipboardWriteTrustStore(defaults: defaults)
        let trusted = SurfaceMachineID.ssh("endpoint-a")
        let differentEndpoint = SurfaceMachineID.ssh("endpoint-b")

        #expect(!store.isTrusted(trusted))
        #expect(!store.allowsRemoteClipboardWrites(for: trusted))
        #expect(!store.allowsRemoteClipboardReads(for: trusted))
        #expect(store.allowsRemoteClipboardWrites(for: .cloud("cloud-machine")))
        #expect(!store.allowsRemoteClipboardWrites(for: .local))

        store.setTrusted(true, for: trusted)
        #expect(store.isTrusted(trusted))
        #expect(store.allowsRemoteClipboardWrites(for: trusted))
        #expect(!store.allowsRemoteClipboardWrites(for: differentEndpoint))
        #expect(!store.allowsRemoteClipboardReads(for: trusted))

        let reloaded = SSHClipboardWriteTrustStore(defaults: defaults)
        #expect(reloaded.isTrusted(trusted))
        reloaded.setTrusted(false, for: trusted)
        #expect(!reloaded.isTrusted(trusted))
        #expect(!reloaded.allowsRemoteClipboardWrites(for: trusted))
    }
}
