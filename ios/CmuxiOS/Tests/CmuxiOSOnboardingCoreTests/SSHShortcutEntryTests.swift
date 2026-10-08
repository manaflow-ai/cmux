import CmuxiOSFeatureKit
import CmuxiOSOnboardingCore
import Testing

@Suite("SSH shortcut entry")
struct SSHShortcutEntryTests {
    @Test("Separate fields make an SSH host draft")
    func fields() {
        let draft = SSHShortcutEntry(host: " devbox.local ", user: "dev", port: "2222").draft
        #expect(draft == HostDraft(name: "devbox.local",
                                   kind: .ssh(endpoint: HostEndpoint(address: "devbox.local", port: 2222, user: "dev"), jumpHost: nil)))
    }

    @Test("user@host:port in the host field fills blank user and port")
    func pasted() {
        let draft = SSHShortcutEntry(host: "root@10.0.0.4:22").draft
        #expect(draft?.kind == .ssh(endpoint: HostEndpoint(address: "10.0.0.4", port: 22, user: "root"), jumpHost: nil))
        let ipv6 = SSHShortcutEntry(host: "fe80::1").draft
        #expect(ipv6?.kind == .ssh(endpoint: HostEndpoint(address: "fe80::1"), jumpHost: nil))
    }

    @Test("Bracketed IPv6 in a pasted endpoint is unwrapped and keeps its port")
    func bracketedIPv6() {
        let withPort = SSHShortcutEntry(host: "root@[fd7a:115c:a1e0::1]:2222").draft
        #expect(withPort?.kind == .ssh(
            endpoint: HostEndpoint(address: "fd7a:115c:a1e0::1", port: 2222, user: "root"),
            jumpHost: nil
        ))

        let separatePort = SSHShortcutEntry(host: "[fd7a:115c:a1e0::1]", port: "2200").draft
        #expect(separatePort?.kind == .ssh(
            endpoint: HostEndpoint(address: "fd7a:115c:a1e0::1", port: 2200),
            jumpHost: nil
        ))
    }

    @Test("Empty hosts, spaces and bad ports are refused")
    func invalid() {
        #expect(SSHShortcutEntry().draft == nil)
        #expect(SSHShortcutEntry(host: "two words").draft == nil)
        #expect(SSHShortcutEntry(host: "box", port: "0").draft == nil)
        #expect(SSHShortcutEntry(host: "box", port: "70000").draft == nil)
        #expect(SSHShortcutEntry(host: "box", port: "ssh").draft == nil)
        #expect(SSHShortcutEntry(host: "[fd7a::1]:").draft == nil)
        #expect(SSHShortcutEntry(host: "[fd7a::1]suffix").draft == nil)
        #expect(SSHShortcutEntry(host: "[fd7a::1]:70000").draft == nil)
        #expect(SSHShortcutEntry(host: "[]").draft == nil)
    }
}
