use super::*;

#[test]
fn canonical_terminal_hex_requires_lowercase_uuid_v4() {
    let canonical = "00000000000040008000000000000001";
    assert_eq!(TerminalId::from_hex(canonical).unwrap().to_hex(), canonical);
    assert!(TerminalId::from_hex("00000000000030008000000000000001").is_none());
    assert!(TerminalId::from_hex("00000000000040007000000000000001").is_none());
    assert!(TerminalId::from_hex("0000000000004000800000000000000A").is_none());
    assert!(TerminalId::from_hex("short").is_none());
}

// hq RFD 0224: a host serves `PROTOCOL_MIN_VERSION..=PROTOCOL_VERSION`, keeping N-1 for rollbacks.
#[test]
fn host_serves_previous_protocol_for_rollback_clients() {
    use crate::terminal_host_protocol::{PROTOCOL_MIN_VERSION, PROTOCOL_VERSION};
    assert!(PROTOCOL_MIN_VERSION <= PROTOCOL_VERSION - 1);
    let n = PROTOCOL_VERSION;
    // N-1 client: an older daemon after a rollback adopts this build's host.
    assert_eq!(negotiate_version(n - 1, n - 1, served_versions()).unwrap(), n - 1);
    // N+1 client: a newer daemon that also speaks N picks N.
    assert_eq!(negotiate_version(n, n + 1, served_versions()).unwrap(), n);
    assert_eq!(negotiate_version(1, n + 3, served_versions()).unwrap(), n);
}

#[test]
fn no_common_protocol_is_typed_version_incompatible_with_update_side() {
    use crate::terminal_host_protocol::{PROTOCOL_MIN_VERSION, PROTOCOL_VERSION};
    let newer = negotiate_version(PROTOCOL_VERSION + 1, PROTOCOL_VERSION + 2, served_versions())
        .unwrap_err();
    assert_eq!(newer.error_kind(), Some(VERSION_INCOMPATIBLE));
    assert_eq!(newer.update_side(), Some("host"));
    assert!(newer.to_string().starts_with("version.incompatible:"), "{newer}");
    assert!(newer.to_string().contains("reopen the terminal"), "{newer}");

    let older = negotiate_version(1, PROTOCOL_MIN_VERSION - 1, served_versions()).unwrap_err();
    assert_eq!(older.error_kind(), Some(VERSION_INCOMPATIBLE));
    assert_eq!(older.update_side(), Some("client"));
    assert!(older.to_string().contains("update cmux"), "{older}");

    assert!(negotiate_version(0, 0, served_versions()).is_err());
    assert!(negotiate_version(4, 3, served_versions()).is_err());
}
