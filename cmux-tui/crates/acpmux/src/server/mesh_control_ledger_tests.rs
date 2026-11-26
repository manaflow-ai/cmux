use super::*;
use crate::mesh::{Kind, Mode, Sender, Target};

fn message() -> InMessage {
    InMessage {
        message_id: "message-1".into(),
        kind: Kind::Control,
        op: Some("start".into()),
        mode: Mode::Now,
        to: Target::default(),
        from: Sender::default(),
        body: r#"{"version":1,"params":{}}"#.into(),
        attempt: 1,
        start_work: None,
        state: None,
        subject: None,
    }
}

#[test]
fn pending_claims_survive_restart_and_finished_results_replay() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ledger.json");
    let ledger = ControlLedger::open(Some(path.clone()));
    let message = message();
    let Claim::New { key, .. } = ledger.claim("sender", &message, true) else {
        panic!("new claim")
    };
    assert!(matches!(ledger.claim("sender", &message, true), Claim::Waiting(_)));
    let restarted = ControlLedger::open(Some(path.clone()));
    assert!(matches!(restarted.claim("sender", &message, true), Claim::Unknown));
    let ack = Ack::delivered("message-1", Some("stable-session-id".into()));
    ledger.finish(&key, ack.clone());
    let restarted = ControlLedger::open(Some(path));
    assert!(
        matches!(restarted.claim("sender", &message, true), Claim::Done(replayed) if replayed == ack)
    );
}

#[test]
fn replay_is_bound_to_sender_and_payload() {
    let ledger = ControlLedger::open(None);
    let mut message = message();
    let Claim::New { key, .. } = ledger.claim("sender", &message, true) else {
        panic!("new claim")
    };
    ledger.finish(&key, Ack::delivered("message-1", None));
    assert!(matches!(ledger.claim("other", &message, true), Claim::New { .. }));
    message.op = Some("stop".into());
    assert!(matches!(ledger.claim("sender", &message, true), Claim::Conflict));
}

#[test]
fn corrupt_or_unwritable_ledger_never_admits_execution() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ledger.json");
    std::fs::write(&path, b"not json").unwrap();
    assert!(matches!(
        ControlLedger::open(Some(path.clone())).claim("sender", &message(), true),
        Claim::Unknown
    ));
    let unwritable = ControlLedger::open(Some(path.join("inside-a-file.json")));
    assert!(matches!(unwritable.claim("sender", &message(), true), Claim::Unknown));
    assert!(matches!(unwritable.claim("sender", &message(), true), Claim::Unknown));
}

#[test]
fn indeterminate_execution_ends_waiters_but_retains_its_fence() {
    let ledger = ControlLedger::open(None);
    let Claim::New { key, receiver } = ledger.claim("sender", &message(), true) else {
        panic!("new claim")
    };
    let execution = ledger.execution(key);
    drop(execution);
    assert!(receiver.has_changed().is_err(), "no operation remains to answer these waiters");
    assert!(matches!(ledger.claim("sender", &message(), true), Claim::Unknown));
}

#[test]
fn capacity_does_not_fence_new_messages_or_block_replay() {
    let ledger = ControlLedger::open(None);
    assert!(matches!(ledger.claim("sender", &message(), false), Claim::Unknown));
    let Claim::New { key, .. } = ledger.claim("sender", &message(), true) else {
        panic!("no pending fence should be written when execution had no capacity")
    };
    ledger.finish(&key, Ack::delivered("message-1", None));
    assert!(matches!(ledger.claim("sender", &message(), false), Claim::Done(_)));
}

#[test]
fn failed_result_persistence_leaves_the_durable_pending_fence() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ledger.json");
    let mut ledger = ControlLedger::open(Some(path.clone()));
    let Claim::New { key, receiver } = ledger.claim("sender", &message(), true) else {
        panic!("new claim")
    };
    ledger.path = Some(path.join("inside-a-file.json"));
    ledger.finish(&key, Ack::delivered("message-1", None));
    assert!(receiver.borrow().is_none());
    assert!(matches!(
        ControlLedger::open(Some(path)).claim("sender", &message(), true),
        Claim::Unknown
    ));
}
