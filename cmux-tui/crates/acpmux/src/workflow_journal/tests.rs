use super::{Activity, Journal};
use serde_json::json;

fn work(activity: Activity) -> (String, bool) {
    match activity {
        Activity::Work { id, recovered } => (id, recovered),
        Activity::Replay(_) => panic!("expected activity work"),
    }
}

#[test]
fn native_workflow_journal_replays_success_and_failure_after_reopen() {
    let directory = tempfile::tempdir().unwrap();
    let options = json!({"harness": "codex", "schema": {"type": "object"}});
    let success = Ok(json!({"commit": "abc"}));
    let failure = Err(json!({"code": "agent.failed", "message": "stopped"}));
    {
        let mut journal = Journal::open(directory.path(), "pinned script", 2).unwrap();
        let (first, recovered) = work(journal.begin("agent", "review", &options).unwrap());
        assert!(!recovered);
        journal.complete(&first, success.clone()).unwrap();
        let (second, _) = work(journal.begin("machine", "build", &json!({"on": "ci"})).unwrap());
        assert_ne!(first, second);
        journal.complete(&second, failure.clone()).unwrap();
    }
    let mut resumed = Journal::open(directory.path(), "pinned script", 1).unwrap();
    assert_eq!(resumed.begin("agent", "review", &options).unwrap(), Activity::Replay(success));
    assert_eq!(
        resumed.begin("machine", "build", &json!({"on": "ci"})).unwrap(),
        Activity::Replay(failure)
    );
}

#[test]
fn native_workflow_journal_reuses_started_identity_after_interruption() {
    let directory = tempfile::tempdir().unwrap();
    let original = {
        let mut journal = Journal::open(directory.path(), "script", 1).unwrap();
        let (id, recovered) = work(journal.begin("machine", "compile", &json!({})).unwrap());
        assert!(!recovered);
        id
    };
    let mut resumed = Journal::open(directory.path(), "script", 1).unwrap();
    assert_eq!(
        resumed.begin("machine", "compile", &json!({})).unwrap(),
        Activity::Work { id: original, recovered: true }
    );
}

#[test]
fn native_workflow_journal_refuses_changed_script_and_call_inputs() {
    let directory = tempfile::tempdir().unwrap();
    {
        let mut journal = Journal::open(directory.path(), "script", 1).unwrap();
        journal.begin("agent", "review", &json!({"schema": {"type": "object"}})).unwrap();
    }
    assert!(Journal::open(directory.path(), "edited script", 1).is_err());
    let mut resumed = Journal::open(directory.path(), "script", 1).unwrap();
    assert!(resumed.begin("agent", "different prompt", &json!({})).is_err());
}

#[test]
fn native_workflow_journal_resets_fresh_budget_but_replays_do_not_spend_it() {
    let directory = tempfile::tempdir().unwrap();
    {
        let mut journal = Journal::open(directory.path(), "script", 1).unwrap();
        let (id, _) = work(journal.begin("agent", "first", &json!({})).unwrap());
        journal.complete(&id, Ok(json!(1))).unwrap();
        assert!(journal.begin("agent", "second", &json!({})).is_err());
    }
    let mut resumed = Journal::open(directory.path(), "script", 1).unwrap();
    assert_eq!(
        resumed.begin("agent", "first", &json!({})).unwrap(),
        Activity::Replay(Ok(json!(1)))
    );
    let (_, recovered) = work(resumed.begin("agent", "second", &json!({})).unwrap());
    assert!(!recovered);
}

#[test]
fn native_workflow_journal_has_only_one_resume_owner() {
    let directory = tempfile::tempdir().unwrap();
    let owner = Journal::open(directory.path(), "script", 1).unwrap();
    assert!(Journal::open(directory.path(), "script", 1).is_err());
    drop(owner);
    assert!(Journal::open(directory.path(), "script", 1).is_ok());
}
