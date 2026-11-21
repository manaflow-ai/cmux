use super::*;

fn receipt(id: &str) -> Receipt {
    Receipt {
        attempt: Attempt {
            id: id.into(),
            instance: "run1".into(),
            decision_nonce: "nonce1".into(),
            request_digest: "request".into(),
            answers_digest: "answers".into(),
            annotations_digest: String::new(),
        },
        session: "session1".into(),
        permission: "permission1".into(),
        option: Some("allow_once".into()),
        state: "unknown".into(),
        reason: None,
        sequence: 0,
    }
}

#[test]
fn claimed_and_delivered_survive_reconstruction_without_authority() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE);
    let mut ledger = Ledger::default();
    ledger.claim(&receipt("a1"), Some(&path)).unwrap();
    assert_eq!(Ledger::default().status("a1", Some(&path)).unwrap()["state"], "unknown");
    ledger.finish("a1", true, Some(&path)).unwrap();
    let restored = Ledger::default().status("a1", Some(&path)).unwrap();
    assert_eq!(restored["state"], "delivered");
    assert_eq!(restored["permission"], "permission1");
    assert_eq!(restored["answersDigest"], "answers");
    assert!(restored.get("personDecision").is_none());
    assert!(restored.get("proof").is_none());
}

#[test]
fn duplicate_claim_and_changed_answer_never_send_again() {
    let mut ledger = Ledger::default();
    let original = receipt("a1");
    ledger.claim(&original, None).unwrap();
    assert_eq!(
        ledger.claim(&original, None).unwrap_err().data.unwrap()["reason"],
        "question.delivery_claimed"
    );
    let mut changed = original;
    changed.attempt.answers_digest = "different".into();
    assert_eq!(
        ledger.claim(&changed, None).unwrap_err().data.unwrap()["reason"],
        "question.delivery_conflict"
    );
    ledger.finish("a1", true, None).unwrap();
    assert!(ledger.claim(&receipt("a1"), None).is_err());
}

#[test]
fn failed_result_persistence_remains_unknown_after_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE);
    let unavailable = dir.path().join("missing").join(FILE);
    let mut ledger = Ledger::default();
    ledger.claim(&receipt("a1"), Some(&path)).unwrap();
    assert!(ledger.finish("a1", true, Some(&unavailable)).is_err());
    assert_eq!(ledger.status("a1", Some(&path)).unwrap()["state"], "unknown");
    assert_eq!(Ledger::default().status("a1", Some(&path)).unwrap()["state"], "unknown");
}

#[test]
fn failed_claim_cannot_be_retried_in_memory() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missing").join(FILE);
    let mut ledger = Ledger::default();
    assert!(ledger.claim(&receipt("a1"), Some(&path)).is_err());
    assert_eq!(
        ledger.claim(&receipt("a1"), Some(&path)).unwrap_err().data.unwrap()["reason"],
        "question.delivery_claimed"
    );
}

#[test]
fn bounded_retention_never_evicts_unknown_and_missing_never_means_delivered() {
    let mut ledger = Ledger::default();
    for n in 0..MAX {
        ledger.claim(&receipt(&format!("a{n}")), None).unwrap();
    }
    assert_eq!(
        ledger.claim(&receipt("overflow"), None).unwrap_err().data.unwrap()["reason"],
        "question.delivery_capacity"
    );
    ledger.finish("a0", false, None).unwrap();
    assert_eq!(ledger.status("a0", None).unwrap()["reason"], "agent_gone");
    ledger.claim(&receipt("overflow"), None).unwrap();
    assert_eq!(ledger.rows.len(), MAX);
    assert_eq!(ledger.status("a0", None).unwrap(), json!({"id":"a0","state":"unknown"}));
    assert_eq!(ledger.status("a1", None).unwrap()["state"], "unknown");
}

#[cfg(unix)]
#[test]
fn receipt_claim_stays_in_held_home_after_path_replacement() {
    use crate::lost_home_race_tests::{forced, isolated, nothing};
    isolated(
        module_path!(),
        "receipt_claim_stays_in_held_home_after_path_replacement",
        |home| {
            let path = home.join(FILE);
            forced(home, path.clone(), nothing, Some(FILE), move || {
                let _ = Ledger::default().claim(&receipt("a1"), Some(&path));
            });
        },
        |_, _| {},
    );
}

#[cfg(unix)]
#[test]
fn receipt_read_uses_held_home_not_replacement_success() {
    use crate::lost_home_race_tests::{isolated, replace};
    isolated(
        module_path!(),
        "receipt_read_uses_held_home_not_replacement_success",
        |home| {
            let path = home.join(FILE);
            Ledger::default().claim(&receipt("a1"), Some(&path)).unwrap();
            crate::config::hold_home();
            replace(home);
            let mut replacement = receipt("a1");
            replacement.state = "delivered".into();
            // Test setup deliberately writes the replacement, not the held home.
            std::fs::write(
                &path,
                serde_json::to_vec(&BTreeMap::from([("a1", replacement)])).unwrap(),
            )
            .unwrap();
            assert_eq!(Ledger::default().status("a1", Some(&path)).unwrap()["state"], "unknown");
        },
        |_, _| {},
    );
}
