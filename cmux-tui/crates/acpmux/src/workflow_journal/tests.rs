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

#[test]
fn native_workflow_journal_canonical_options_but_distinct_prompt_kind_and_options() {
    for (kind, prompt, options) in [
        ("machine", "review", json!({"a": 1, "z": {"x": 2, "y": 3}})),
        ("agent", "changed", json!({"a": 1, "z": {"x": 2, "y": 3}})),
        ("agent", "review", json!({"a": 2, "z": {"x": 2, "y": 3}})),
    ] {
        let directory = tempfile::tempdir().unwrap();
        {
            let mut journal = Journal::open(directory.path(), "script", 1).unwrap();
            let (id, _) = work(
                journal.begin("agent", "review", &json!({"z": {"y": 3, "x": 2}, "a": 1})).unwrap(),
            );
            journal.complete(&id, Ok(json!("saved"))).unwrap();
        }
        {
            let mut journal = Journal::open(directory.path(), "script", 1).unwrap();
            assert_eq!(
                journal.begin("agent", "review", &json!({"a": 1, "z": {"x": 2, "y": 3}})).unwrap(),
                Activity::Replay(Ok(json!("saved")))
            );
            journal.finish().unwrap();
        }
        let mut journal = Journal::open(directory.path(), "script", 1).unwrap();
        assert!(journal.begin(kind, prompt, &options).is_err());
    }
}

#[test]
fn native_workflow_journal_completion_order_cannot_swap_parallel_calls() {
    let directory = tempfile::tempdir().unwrap();
    {
        let mut journal = Journal::open(directory.path(), "script", 2).unwrap();
        let (first, _) = work(journal.begin("agent", "first", &json!({})).unwrap());
        let (second, _) = work(journal.begin("agent", "second", &json!({})).unwrap());
        assert!(journal.finish().is_err());
        journal.complete(&second, Ok(json!(2))).unwrap();
        journal.complete(&first, Ok(json!(1))).unwrap();
        journal.finish().unwrap();
    }
    let mut journal = Journal::open(directory.path(), "script", 0).unwrap();
    assert!(journal.finish().is_err());
    assert_eq!(
        journal.begin("agent", "first", &json!({})).unwrap(),
        Activity::Replay(Ok(json!(1)))
    );
    assert_eq!(
        journal.begin("agent", "second", &json!({})).unwrap(),
        Activity::Replay(Ok(json!(2)))
    );
    journal.finish().unwrap();
}

#[test]
fn native_workflow_journal_recovers_a_cut_tail_but_refuses_corrupt_records() {
    use std::io::Write;
    let directory = tempfile::tempdir().unwrap();
    let id = {
        let mut journal = Journal::open(directory.path(), "script", 1).unwrap();
        work(journal.begin("machine", "build", &json!({})).unwrap()).0
    };
    let path = directory.path().join("activities.jsonl");
    let complete_len = std::fs::metadata(&path).unwrap().len();
    std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap()
        .write_all(b"{\"event\":\"completed\"")
        .unwrap();
    {
        let mut journal = Journal::open(directory.path(), "script", 1).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().len(), complete_len);
        assert_eq!(
            journal.begin("machine", "build", &json!({})).unwrap(),
            Activity::Work { id: id.clone(), recovered: true }
        );
        journal.complete(&id, Ok(json!("built"))).unwrap();
    }
    std::fs::OpenOptions::new().append(true).open(&path).unwrap().write_all(b"not json\n").unwrap();
    assert!(Journal::open(directory.path(), "script", 1).is_err());
}

#[test]
fn native_workflow_journal_binds_completion_and_never_replaces_an_outcome() {
    let directory = tempfile::tempdir().unwrap();
    let mut journal = Journal::open(directory.path(), "script", 1).unwrap();
    let (id, _) = work(journal.begin("call", "tool_name", &json!({"value": 1})).unwrap());
    assert!(journal.complete("unknown activity", Ok(json!(1))).is_err());
    journal.complete(&id, Ok(json!(1))).unwrap();
    journal.complete(&id, Ok(json!(1))).unwrap();
    assert!(journal.complete(&id, Ok(json!(2))).is_err());
}
