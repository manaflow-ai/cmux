use std::net::SocketAddr;

use super::*;

const CLOUD: Facts = Facts { linux: true, bound_instance: true };

fn addr(s: &str) -> SocketAddr {
    s.parse().unwrap()
}

fn enrolled(text: &str) -> SocketAddr {
    match parse(Some(text), CLOUD) {
        Ok(RemoteEntry::Enrolled { bind }) => bind,
        other => panic!("{text}: {other:?}"),
    }
}

fn refused(text: &str, facts: Facts) -> String {
    match parse(Some(text), facts) {
        Err(reason) => reason,
        Ok(entry) => panic!("{text} was accepted as {entry:?}"),
    }
}

/// No host config: the session host listens on loopback and every
/// connection must present an enrolled device (no insecure bind, no
/// trusted carrier).
#[test]
fn the_default_is_loopback_with_enrolled_auth() {
    for text in [None, Some("{}"), Some(r#"{"remoteWs": {}}"#)] {
        let entry = parse(text, CLOUD).unwrap();
        assert_eq!(entry, RemoteEntry::Enrolled { bind: addr("127.0.0.1:1337") }, "{text:?}");
        assert_eq!(entry.args(), ["--remote-ws", "127.0.0.1:1337"]);
        assert_eq!(entry.warning(), None);
    }
    assert_eq!(DEFAULT_BIND, addr("127.0.0.1:1337"));
}

#[test]
fn loopback_and_tailnet_binds_keep_enrolled_auth() {
    assert_eq!(enrolled(r#"{"remoteWs": {"bind": "127.0.0.1:2000"}}"#), addr("127.0.0.1:2000"));
    assert_eq!(enrolled(r#"{"remoteWs": {"bind": "[::1]:1337"}}"#), addr("[::1]:1337"));
    // Tailnet (100.64.0.0/10 and fd7a:115c:a1e0::/48): plaintext rides the
    // WireGuard tunnel, so the insecure-bind flag is needed, never the
    // trusted carrier.
    for bind in ["100.101.102.103:1337", "[fd7a:115c:a1e0::5]:1337"] {
        let text = format!(r#"{{"remoteWs": {{"bind": "{bind}"}}}}"#);
        assert_eq!(enrolled(&text), addr(bind));
        let entry = parse(Some(&text), CLOUD).unwrap();
        assert_eq!(entry.args(), ["--remote-ws", bind, "--remote-ws-insecure-bind"]);
    }
}

#[test]
fn other_binds_without_the_edge_carrier_are_refused() {
    for bind in
        ["0.0.0.0:1337", "[::]:1337", "192.168.1.5:1337", "100.128.0.1:1337", "8.8.8.8:1337"]
    {
        let text = format!(r#"{{"remoteWs": {{"bind": "{bind}"}}}}"#);
        let reason = refused(&text, CLOUD);
        assert!(reason.contains(bind), "{reason}");
    }
}

/// The Cloud mode: the 0.0.0.0 bind with the trusted carrier, only with
/// an explicit `carrier: "freestyle-edge"` on a Linux Cloud machine with a
/// bound metadata instance id. Its argv equals cmuxTuiDaemon.ts.
#[test]
fn the_cloud_edge_carrier_keeps_the_exact_cloud_command_line() {
    for bind in ["0.0.0.0:1337", "[::]:1337"] {
        let text = format!(r#"{{"remoteWs": {{"bind": "{bind}", "carrier": "freestyle-edge"}}}}"#);
        let entry = parse(Some(&text), CLOUD).unwrap();
        assert_eq!(
            entry,
            RemoteEntry::TrustedCarrier { bind: addr(bind), carrier: Carrier::FreestyleEdge }
        );
        assert_eq!(
            entry.args(),
            ["--remote-ws", bind, "--remote-ws-insecure-bind", "--remote-ws-trusted-carrier"]
        );
        let warning = entry.warning().unwrap();
        assert!(warning.contains("trusted-carrier") && warning.contains("cx-wx2"), "{warning}");
        assert!(warning.contains("freestyle-edge"), "{warning}");
    }
}

#[test]
fn the_edge_carrier_is_refused_outside_its_conditions() {
    let edge = |bind: &str| {
        format!(r#"{{"remoteWs": {{"bind": "{bind}", "carrier": "freestyle-edge"}}}}"#)
    };
    // Only with the wildcard bind.
    assert!(refused(&edge("127.0.0.1:1337"), CLOUD).contains("0.0.0.0"));
    assert!(refused(&edge("100.101.102.103:1337"), CLOUD).contains("0.0.0.0"));
    // Only on Linux, and only on a machine bound to a metadata instance id.
    let not_linux = Facts { linux: false, bound_instance: true };
    assert!(refused(&edge("0.0.0.0:1337"), not_linux).contains("Linux"));
    let unbound = Facts { linux: true, bound_instance: false };
    assert!(refused(&edge("0.0.0.0:1337"), unbound).contains("instance id"));
    // A missing bind with the carrier is not the wildcard.
    assert!(refused(r#"{"remoteWs": {"carrier": "freestyle-edge"}}"#, CLOUD).contains("0.0.0.0"));
}

#[test]
fn malformed_config_is_refused() {
    for text in [
        "not json",
        "[]",
        r#"{"remoteWs": "0.0.0.0:1337"}"#,
        r#"{"remoteWs": {"bind": 1337}}"#,
        r#"{"remoteWs": {"bind": "localhost:1337"}}"#,
        r#"{"remoteWs": {"bind": "0.0.0.0:1337", "carrier": "any-network"}}"#,
        r#"{"remoteWs": {"bind": "127.0.0.1:1337", "trusted": true}}"#,
    ] {
        refused(text, CLOUD);
    }
}

/// /etc/cmux/host.json is trusted only when the agent's user owns it and
/// neither group nor others can write it.
#[test]
fn the_host_config_file_must_be_owned_by_the_agent_and_not_shared_writable() {
    assert_eq!(file_is_trusted(0, 0o100644, 0), Ok(()));
    assert_eq!(file_is_trusted(0, 0o100600, 0), Ok(()));
    assert!(file_is_trusted(1000, 0o100644, 0).unwrap_err().contains("uid 1000"));
    assert!(file_is_trusted(0, 0o100664, 0).unwrap_err().contains("writable"));
    assert!(file_is_trusted(0, 0o100646, 0).unwrap_err().contains("writable"));
    assert!(file_is_trusted(0, 0o100666, 0).is_err());
}
