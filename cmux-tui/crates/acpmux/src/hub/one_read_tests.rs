//! One read of MDM's off per operation (#23322, reviews 73, 75 and 77): an off that comes and
//! goes right after an operation first reads it still holds for that operation. Each test runs
//! the off and the unset at that point (`AFTER_OFF_COUNT`).

use super::*;
use std::sync::atomic::AtomicBool;

/// MDM's off comes and goes.
fn came_and_went(hub: &Hub) {
    hub.update_start_mode_state(None, |s| s.full_access_managed = Some(false));
    hub.update_start_mode_state(None, |s| s.full_access_managed = None);
}

/// MDM's off comes and goes right after the next operation's first read of it.
fn blip_at_the_next_read() {
    AFTER_OFF_COUNT.set(Some(came_and_went));
}

/// MDM's off comes and goes right after every read of it on this thread, until `stop_blips`: a
/// chat's creation reads it for the pool claim before its start does.
fn blip_at_every_read() {
    fn again(hub: &Hub) {
        came_and_went(hub);
        AFTER_OFF_COUNT.set(Some(again));
    }
    AFTER_OFF_COUNT.set(Some(again));
}

fn stop_blips() {
    AFTER_OFF_COUNT.set(None);
}

/// A hub on the stand-in agent, run with `env` and the extra arguments `args`.
fn hub_on(env: &[&str], args: &[&str]) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut argv = vec!["/usr/bin/env"];
    argv.extend(env);
    argv.extend(["python3", fake]);
    argv.extend(args);
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": argv}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn here() -> NewRequest {
    NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() }
}

/// A start: a profile pinning full access does not start.
#[tokio::test]
async fn a_start_holds_an_off_that_came_and_went_after_its_first_read() {
    let hub = hub_on(&[], &["--yolo"]);
    blip_at_every_read();
    let started = hub.new_session(here()).await;
    stop_blips();
    assert!(
        started.is_err(),
        "a profile pinning full access started though MDM's off came and went as the start read it"
    );
}

/// A mode switch: a switch into full access is refused.
#[tokio::test]
async fn a_switch_holds_an_off_that_came_and_went_after_its_first_read() {
    let hub = hub_on(&["FAKE_FULL_ACCESS=1"], &[]);
    let session = hub.new_session(here()).await.unwrap();
    blip_at_the_next_read();
    let switched = hub
        .forward_as(&session, method::SESSION_SET_MODE, json!({"modeId": "full-access"}), false)
        .await;
    assert!(
        switched.is_err(),
        "a switch into full access ran though MDM's off came and went as it read it: {switched:?}"
    );
}

/// An ask: full access does not answer it.
#[tokio::test]
async fn an_ask_holds_an_off_that_came_and_went_after_its_first_read() {
    let hub = hub_on(&["FAKE_FULL_ACCESS=1"], &[]);
    let session = hub.new_session(here()).await.unwrap();
    hub.forward_as(&session, method::SESSION_SET_MODE, json!({"modeId": "full-access"}), false)
        .await
        .expect("full access is allowed before the off");
    blip_at_the_next_read();
    let request = json!({
        "sessionId": "fake-1",
        "toolCall": {"toolCallId": "t1", "title": "Edit a file", "kind": "edit"},
        "options": [
            {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
            {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
        ],
    });
    let epoch = session.permission_epoch.load(Ordering::SeqCst);
    let answered = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        hub.handle_permission_for(&session, request, epoch, None, None, None, None),
    )
    .await;
    assert!(
        !matches!(&answered, Ok(v) if v["outcome"]["optionId"] == "allow"),
        "full access answered an ask though MDM's off came and went as it read it: {answered:?}"
    );
}

/// A pooled agent's report of full access: its entry keeps it.
#[tokio::test]
async fn a_pooled_report_holds_an_off_that_came_and_went_after_its_first_read() {
    let hub = hub_on(&[], &[]);
    let reported_off = AtomicBool::new(false);
    blip_at_the_next_read();
    hub.pool_reported("no-such-entry", &reported_off);
    assert!(
        reported_off.load(Ordering::SeqCst),
        "a report of full access was not kept though MDM's off came and went as it was read"
    );
}

/// Review 122: two reads merged hold an off either one saw, whichever was taken first.
#[tokio::test]
async fn merged_reads_hold_an_off_either_one_saw() {
    let hub = hub_on(&[], &[]);
    let first = hub.off_latch();
    came_and_went(&hub);
    let second = hub.off_latch();
    assert!(!second.off(), "a read after the unset sees no off");
    assert!(second.merge(&first).off(), "the merge lost the off the earlier read saw");
    assert!(first.merge(&second).off(), "the merge lost the off the earlier read saw");
    let quiet = (hub.off_latch(), hub.off_latch());
    assert!(!quiet.0.merge(&quiet.1).off(), "two reads with no off between them merged to an off");
}

/// A start holds an off that comes and goes as it is entered, before it waits on the spawn lock
/// (review 123).
#[tokio::test]
async fn a_start_holds_an_off_that_came_and_went_as_it_was_entered() {
    let hub = hub_on(&[], &["--yolo"]);
    AT_OPERATION_ENTRY.set(Some(came_and_went));
    let started = hub.new_session(here()).await;
    AT_OPERATION_ENTRY.set(None);
    assert!(started.is_err(), "a profile pinning full access started after an off at its entry");
}

/// An ask holds an off that comes and goes as it is entered, before its preprocessing (review
/// 123).
#[tokio::test]
async fn an_ask_holds_an_off_that_came_and_went_as_it_was_entered() {
    let hub = hub_on(&["FAKE_FULL_ACCESS=1"], &[]);
    let session = hub.new_session(here()).await.unwrap();
    hub.forward_as(&session, method::SESSION_SET_MODE, json!({"modeId": "full-access"}), false)
        .await
        .expect("full access is allowed before the off");
    AT_OPERATION_ENTRY.set(Some(came_and_went));
    let answered = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        hub.handle_permission_for(
            &session,
            edit_ask(),
            current_epoch(&session),
            None,
            None,
            None,
            None,
        ),
    )
    .await;
    AT_OPERATION_ENTRY.set(None);
    assert!(
        !matches!(&answered, Ok(v) if v["outcome"]["optionId"] == "allow"),
        "full access answered an ask after an off at its entry: {answered:?}"
    );
}

fn edit_ask() -> Value {
    json!({
        "sessionId": "fake-1",
        "toolCall": {"toolCallId": "t2", "title": "Edit a file", "kind": "edit"},
        "options": [
            {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
            {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
        ],
    })
}

fn current_epoch(session: &Session) -> u64 {
    session.permission_epoch.load(Ordering::SeqCst)
}
