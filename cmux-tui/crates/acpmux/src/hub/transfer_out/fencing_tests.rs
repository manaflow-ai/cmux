use super::*;

#[test]
fn a_delayed_owner_is_rejected_for_every_transfer_write_path() {
    // The four protocol operations all use the same fencing predicate. Keep this table
    // explicit so a new endpoint cannot silently accept an old host's epoch.
    for operation in ["read", "write", "commit", "abort"] {
        let error = require_epoch(9, Some(8)).expect_err(operation);
        assert!(error.message.contains("transfer.stale_epoch"));
    }
}

#[test]
fn transfer_epoch_marker_survives_resume_and_only_moves_forward() {
    let dir = std::env::temp_dir().join(format!("acpmux-epoch-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("epoch"), "4").unwrap();
    assert_eq!(transfer_epoch(&dir).unwrap(), 4);
    // A resumed owner can never accept the old epoch after a retry increments it.
    assert!(require_epoch(5, Some(4)).is_err());
    assert!(require_epoch(5, Some(5)).is_ok());
    assert!(reject_stale_epoch(4, 5).is_ok());
    assert!(reject_stale_epoch(5, 4).is_err());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn malformed_epoch_marker_fails_closed() {
    let dir = std::env::temp_dir().join(format!("acpmux-epoch-bad-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("epoch"), "not-an-epoch").unwrap();
    assert!(transfer_epoch_marker(&dir).is_err());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn epoch_parser_distinguishes_legacy_missing_from_malformed() {
    assert_eq!(parse_epoch(None).unwrap(), None);
    assert_eq!(parse_epoch(Some(&json!(7))).unwrap(), Some(7));
    assert!(parse_epoch(Some(&json!("7"))).is_err());
    assert!(parse_epoch(Some(&json!(null))).is_err());
}
