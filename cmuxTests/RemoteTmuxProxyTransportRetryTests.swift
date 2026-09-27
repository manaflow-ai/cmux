import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for the proxy-transport stderr classifier used by remote-tmux
/// interactive retry routing.
@Suite struct RemoteTmuxProxyTransportRetryTests {
    @Test(arguments: [
        "Connection closed by UNKNOWN port 65535",
        "ssh_dispatch_run_fatal: Connection to UNKNOWN port 65535: Broken pipe",
        "Connection closed by UnKnOwN port 65535",
    ])
    func classifiesSilentProxyCommandClosures(_ stderr: String) {
        #expect(RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(stderr))
    }

    @Test(arguments: [
        "channel 0: open failed: connect failed: Connection refused\nstdio forwarding failed\nConnection closed by UNKNOWN port 65535",
        "connect failed: Connection refused\nConnection closed by UNKNOWN port 65535",
        "stdio forwarding failed\nssh_exchange_identification: Connection closed by remote host\nConnection closed by UNKNOWN port 65535",
        "kex_exchange_identification: Connection closed by remote host\nConnection closed by UNKNOWN port 65535",
        "ssh: Could not resolve hostname inner.invalid: nodename nor servname provided\nConnection closed by UNKNOWN port 65535",
        "nc: getaddrinfo: name or service not known\nConnection closed by UNKNOWN port 65535",
        "nc: getaddrinfo: nodename nor servname provided, or not known\nConnection closed by UNKNOWN port 65535",
        "channel 1: open failed: administratively prohibited: open failed\nConnection closed by UNKNOWN port 65535",
        "nc: connect to inner.invalid port 22 (tcp) failed: Connection timed out\nConnection closed by UNKNOWN port 65535",
        "ssh_exchange_identification: Connection closed by remote host\nConnection closed by UNKNOWN port 65535",
        "zsh:1: command not found: corp-proxy\nConnection closed by UNKNOWN port 65535",
        "bash: line 1: corp-proxy: command not found\nConnection closed by UNKNOWN port 65535",
        "sh: 1: corp-proxy: not found\nConnection closed by UNKNOWN port 65535",
        "zsh:1: no such file or directory: /opt/corp/proxy\nConnection closed by UNKNOWN port 65535",
        "bash: line 1: /opt/corp/proxy: No such file or directory\nConnection closed by UNKNOWN port 65535",
        "bash: line 1: /opt/corp/proxy: cannot execute binary file: Exec format error\nConnection closed by UNKNOWN port 65535",
    ])
    func doesNotClassifyExplainedProxyClosures(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(stderr))
    }

    @Test(arguments: [
        "MOTD: lab name is UNKNOWN port 65535 status board",
        "remote warning: process listening on port 65535 with unknown owner",
        "user note: 'unknown port 65535' is reserved",
    ])
    func anchorsProxyClosedMatchToOpenSSHPhrasing(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(stderr))
    }

    @Test(arguments: [
        "ssh: connect to host bad.example.com port 22: Connection refused",
        "ssh: connect to host bad.example.com port 2222: Operation timed out",
        "Connection closed by 10.0.0.5 port 22",
    ])
    func doesNotClassifyRealPortClosuresAsProxyTransport(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(stderr))
    }

    @Test func proxyClosedAndAuthRequiredAreDisjoint() {
        let proxyOnly = "ssh_dispatch_run_fatal: Connection to UNKNOWN port 65535: Broken pipe"
        #expect(RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(proxyOnly))
        #expect(!RemoteTmuxSSHTransport.indicatesAuthRequired(proxyOnly))

        let authOnly = "user@host: Permission denied (publickey,password)."
        #expect(RemoteTmuxSSHTransport.indicatesAuthRequired(authOnly))
        #expect(!RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(authOnly))
    }

    @Test(arguments: [
        "user@host: Permission denied (publickey,password).",
        "Host key verification failed.",
        "Too many authentication failures",
        "Connection closed by UNKNOWN port 65535",
        "ssh_dispatch_run_fatal: Connection to UNKNOWN port 65535: Broken pipe",
    ])
    func composedPredicateFiresForEitherRecoverableSignal(_ stderr: String) {
        #expect(RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr))
    }

    @Test(arguments: [
        "no server running on /tmp/tmux-501/default",
        "no matching host key type found. their offer: ssh-rsa",
        "ssh: connect to host bad.example.com port 22: Connection refused",
        "",
        "channel 0: open failed: connect failed: Connection refused\nstdio forwarding failed\nConnection closed by UNKNOWN port 65535",
        "zsh:1: command not found: corp-proxy\nConnection closed by UNKNOWN port 65535",
    ])
    func composedPredicateRejectsNonRecoverableFailures(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr))
    }
}
