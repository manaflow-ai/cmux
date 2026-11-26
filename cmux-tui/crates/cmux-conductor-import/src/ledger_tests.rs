use super::*;

#[test]
fn round_trip_and_newer() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("conductor-import.json");
    assert_eq!(Ledger::load(&path), Load::None);
    let mut ledger = Ledger::new();
    ledger.mark_pending("w1");
    ledger.mark_done("w2", "ws-9");
    ledger.save(&path).unwrap();
    assert_eq!(Ledger::load(&path), Load::Ledger(ledger));
    assert_eq!(Ledger::decode(br#"{"version":99,"runs":0}"#), Load::Newer(99));
    assert!(matches!(Ledger::decode(b"{"), Load::Unreadable(_)));
}

/// A ledger that parses but breaks what every record keeps is damaged,
/// not usable: a done entry always names its cmux workspace.
#[test]
fn a_done_entry_without_its_cmux_workspace_is_unreadable() {
    let done = br#"{"version":1,"runs":0,"workspaces":{"w":{"stage":"done"}}}"#;
    assert_eq!(
        Ledger::decode(done),
        Load::Unreadable("done workspace w names no cmux workspace".into())
    );
    let empty =
        br#"{"version":1,"runs":0,"workspaces":{"w":{"stage":"pending","cmux_workspace":""}}}"#;
    assert!(matches!(Ledger::decode(empty), Load::Unreadable(_)));
    let pending = br#"{"version":1,"runs":0,"workspaces":{"w":{"stage":"pending"}}}"#;
    assert!(matches!(Ledger::decode(pending), Load::Ledger(_)));
}
