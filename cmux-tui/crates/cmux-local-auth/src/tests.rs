use super::*;

const PORT: u16 = 47811;

fn policy() -> ListenerPolicy {
    ListenerPolicy::loopback(PORT)
}

#[test]
fn rebinding_and_malformed_hosts_are_refused() {
    for host in [
        "evil.example",
        "evil.example:47811",
        "localhost.evil.example",
        "127.0.0.1.nip.io",
        "127.0.0.2",
        "0.0.0.0",
        "user@127.0.0.1",
        "127.0.0.1/x",
        "::1",
        "[::1]x",
        "127.0.0.1:notaport",
        "",
    ] {
        assert_eq!(policy().check(&[host], &[]), Err(Refusal::ForeignHost), "{host}");
    }
}
