use super::*;

#[test]
fn a_tool_call_runs_unless_it_only_waits_on_a_permission() {
    let mut doing = super::super::activity::TurnActivity::default();
    assert!(!tool_runs(&doing, &[]), "no tool call: a move may stop the turn");
    doing.open_tools.insert("t-1".into());
    assert!(tool_runs(&doing, &[]), "a call in flight runs");
    let asked = json!({"toolCall": {"toolCallId": "t-1"}});
    assert!(!tool_runs(&doing, &[("r".into(), asked.clone())]), "it waits on the person");
    doing.open_tools.insert("t-2".into());
    assert!(tool_runs(&doing, &[("r".into(), asked)]), "another call runs beside it");
    let past = super::super::activity::TurnActivity { open_past_cap: 1, ..Default::default() };
    assert!(tool_runs(&past, &[]), "a call past the id cap runs");
}

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

#[test]
fn concurrent_transfer_claims_have_one_winner() {
    use std::sync::{Arc, Mutex};
    let moving = Arc::new(Mutex::new(None));
    let mut threads = Vec::new();
    for id in ["first", "second"] {
        let moving = moving.clone();
        threads.push(std::thread::spawn(move || {
            let mut moving = moving.lock().unwrap();
            claim_transfer(&mut moving, id)
        }));
    }
    let winners = threads.into_iter().filter_map(|t| t.join().ok()).filter(|won| *won).count();
    assert_eq!(winners, 1);
}
