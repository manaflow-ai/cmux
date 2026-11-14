use super::*;

fn peer() -> LinkPeer {
    LinkPeer { install: "inst_1".into(), user: "user_42".into(), team: "team_a".into() }
}

/// The golden line both ends agree on.
pub(crate) const GOLDEN: &str =
    r#"{"link_peer":{"install":"inst_1","user":"user_42","team":"team_a"}}"#;

/// The golden line of a stream whose link token the host accepted.
pub(crate) const GOLDEN_CHECKED: &str = r#"{"link_peer":{"install":"inst_1","user":"user_42","team":"team_a"},"check":"link_token","check_issued_at_ms":1700000000000}"#;

#[test]
fn the_stamp_round_trips_through_the_golden_line() {
    assert_eq!(encode(&peer(), None).unwrap(), GOLDEN);
    assert_eq!(parse(&format!("{GOLDEN}\n")).unwrap(), Stamp { peer: peer(), check: None });
}

#[test]
fn token_issue_time_checked_stamp_round_trips_and_unknown_checks_are_refused() {
    assert_eq!(
        encode(&peer(), Some(StampCheck::LinkToken { issued_at_ms: 1_700_000_000_000 })).unwrap(),
        GOLDEN_CHECKED
    );
    assert_eq!(
        parse(GOLDEN_CHECKED).unwrap(),
        Stamp {
            peer: peer(),
            check: Some(StampCheck::LinkToken { issued_at_ms: 1_700_000_000_000 })
        }
    );
    let unknown = r#"{"link_peer":{"install":"i","user":"u","team":"t"},"check":"admin"}"#;
    assert_eq!(parse(unknown), Err(StampError::Malformed));
    let inside = r#"{"link_peer":{"install":"i","user":"u","team":"t","check":"link_token"}}"#;
    assert_eq!(parse(inside), Err(StampError::Malformed));
}

#[test]
fn token_issue_time_is_required_only_for_a_checked_stamp() {
    for fields in [
        r#", "check":"link_token""#,
        r#", "check_issued_at_ms":1700000000000"#,
        r#", "check":"link_token", "check_issued_at_ms":0"#,
        r#", "check":"link_token", "check_issued_at_ms":-1"#,
        r#", "check":"link_token", "check_issued_at_ms":1.5"#,
        r#", "check":"link_token", "check_issued_at_ms":18446744073709551616"#,
    ] {
        let line = format!(r#"{{"link_peer":{{"install":"i","user":"u","team":"t"}}{fields}}}"#);
        assert_eq!(parse(&line), Err(StampError::Malformed), "{line}");
    }
    assert_eq!(encode(&peer(), None).unwrap(), GOLDEN);
    assert_eq!(parse(GOLDEN).unwrap().check, None);
    assert_eq!(
        encode(&peer(), Some(StampCheck::LinkToken { issued_at_ms: 0 })),
        Err(StampError::Malformed)
    );
}

#[test]
fn native_signed_roles_round_trip_without_legacy_owner_fallback() {
    for vm_kind in [None, Some(VmKind::Team), Some(VmKind::Owner)] {
        let check = Some(StampCheck::NativeLinkToken { issued_at_ms: 1_700_000_000_000, vm_kind });
        let encoded = encode(&peer(), check).unwrap();
        assert_eq!(parse(&encoded).unwrap().check, check);
        assert!(encoded.contains("native_link_token"));
    }
    for fields in [
        r#", "native_vm_kind":"owner""#,
        r#", "check":"link_token", "check_issued_at_ms":1, "native_vm_kind":"owner""#,
        r#", "check":"native_link_token", "native_vm_kind":"owner""#,
        r#", "check":"native_link_token", "check_issued_at_ms":0, "native_vm_kind":"owner""#,
        r#", "check":"native_link_token", "check_issued_at_ms":1, "native_vm_kind":null"#,
        r#", "check":"native_link_token", "check_issued_at_ms":1, "native_vm_kind":"admin""#,
    ] {
        let line = format!(r#"{{"link_peer":{{"install":"i","user":"u","team":"t"}}{fields}}}"#);
        assert_eq!(parse(&line), Err(StampError::Malformed), "{line}");
    }
}

#[test]
fn a_stamp_with_extra_fields_or_bad_ids_is_refused() {
    let extra = r#"{"link_peer":{"install":"i","user":"u","team":"t","admin":true}}"#;
    assert_eq!(parse(extra), Err(StampError::Malformed));
    let outer = r#"{"link_peer":{"install":"i","user":"u","team":"t"},"cmd":"identify"}"#;
    assert_eq!(parse(outer), Err(StampError::Malformed));
    let slash = r#"{"link_peer":{"install":"../x","user":"u","team":"t"}}"#;
    assert_eq!(parse(slash), Err(StampError::InvalidId));
    let empty = r#"{"link_peer":{"install":"","user":"u","team":"t"}}"#;
    assert_eq!(parse(empty), Err(StampError::InvalidId));
    assert_eq!(parse(&"x".repeat(MAX_STAMP_BYTES + 1)), Err(StampError::TooLong));
    assert_eq!(parse(r#"{"cmd":"identify"}"#), Err(StampError::Malformed));
}
