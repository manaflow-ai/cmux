use super::*;
use serde_json::json;

fn bash(id: &str, cmd: &str) -> Value {
    json!({"sessionUpdate": "tool_call", "toolCallId": id, "kind": "execute",
           "rawInput": {"command": cmd}})
}

fn edit(id: &str) -> Value {
    json!({"sessionUpdate": "tool_call", "toolCallId": id, "kind": "edit",
           "rawInput": {"file_path": "/x/a.rs", "old_string": "a", "new_string": "b"},
           "locations": [{"path": "/x/a.rs"}]})
}

#[test]
fn normalize_blanks_numbers_and_spaces() {
    assert_eq!(normalize("gh  pr checks 58319"), normalize("gh pr checks 58320"));
    assert_eq!(normalize("sleep 30"), "sleep #");
    assert!(normalize(&"x".repeat(900)).len() <= MAX_KEY);
}

#[test]
fn three_same_status_checks_fire_once() {
    let mut r = Rules::default();
    assert!(r.observe("t", &bash("1", "gh pr checks 1")).is_none());
    assert!(r.observe("t", &bash("2", "gh pr checks 1")).is_none());
    let text = r.observe("t", &bash("3", "gh  pr checks 1")).unwrap();
    assert!(text.starts_with("[sidecar] polling: `gh pr checks 1` ran 3 times"));
    assert!(r.observe("t", &bash("4", "gh pr checks 1")).is_none(), "once per turn");
}

#[test]
fn an_update_of_a_seen_call_is_not_a_new_run() {
    let mut r = Rules::default();
    for _ in 0..5 {
        assert!(r.observe("t", &bash("1", "git fetch origin")).is_none());
    }
}

#[test]
fn an_edit_between_resets_the_count() {
    let mut r = Rules::default();
    r.observe("t", &bash("1", "cargo check; git status"));
    r.observe("t", &bash("2", "cargo check; git status"));
    assert!(r.observe("t", &edit("e")).is_none());
    assert!(r.observe("t", &bash("3", "cargo check; git status")).is_none());
}

#[test]
fn the_same_sleep_poll_fires_but_different_sleeps_do_not() {
    let mut r = Rules::default();
    r.observe("t", &bash("1", "sleep 30; gh run view 9"));
    r.observe("t", &bash("2", "sleep 60; curl -s localhost:8080/health"));
    assert!(r.observe("t", &bash("3", "sleep 10; git push origin HEAD")).is_none());
    r.observe("t", &bash("4", "sleep 30; gh run view 9"));
    assert!(r.observe("t", &bash("5", "sleep 45; gh run view 10")).is_some());
}

#[test]
fn a_shared_waiter_is_the_fix_not_a_poll() {
    let mut r = Rules::default();
    for i in 0..5 {
        let cmd = "glaeda-gh wait run o/r/1 --timeout 900";
        assert!(r.observe("t", &bash(&i.to_string(), cmd)).is_none());
    }
}

#[test]
fn a_background_task_command_counts_too() {
    let mut r = Rules::default();
    let bg = |id: &str| {
        json!({"sessionUpdate": "tool_call", "toolCallId": id,
        "title": "mcp__acpmux__bg_start", "rawInput": {"command": "sleep 480; gh api repos/o/r/actions/runs"}})
    };
    r.observe("t", &bg("1"));
    r.observe("t", &bg("2"));
    assert!(r.observe("t", &bg("3")).is_some());
}

#[test]
fn work_commands_never_fire() {
    let mut r = Rules::default();
    for i in 0..10 {
        assert!(r.observe("t", &bash(&i.to_string(), "cargo test -p acpmux")).is_none());
    }
}

#[test]
fn a_new_turn_starts_clean() {
    let mut r = Rules::default();
    r.observe("t1", &bash("1", "gh pr checks 1"));
    r.observe("t1", &bash("2", "gh pr checks 1"));
    assert!(r.observe("t2", &bash("3", "gh pr checks 1")).is_none());
}

#[test]
fn stamp_puts_counters_only_after_a_fire() {
    let id = "sidecar-test-session";
    let mut msg = json!({});
    stamp(id, &mut msg);
    assert!(msg.get("harnessMagic").is_none());
    with(id, |r| {
        for i in 0..3 {
            r.observe("t", &bash(&i.to_string(), "gh pr checks 7"));
        }
        r.polling += 1;
    });
    stamp(id, &mut msg);
    assert_eq!(msg["harnessMagic"]["sidecars"], json!({"polling": 1, "steered": 0}));
    forget(id);
}

#[test]
fn off_by_default() {
    let none = |_: &str| None;
    assert!(!super::super::harness_magic::enabled_in(FEATURE, None, &none));
    let on = json!({"agents": {"harnessMagic": {"sidecars": {"enabled": true}}}});
    assert!(super::super::harness_magic::enabled_in(FEATURE, Some(&on), &none));
    let kill = |k: &str| (k == "ACPMUX_HM_SIDECARS").then(|| "0".to_owned());
    assert!(!super::super::harness_magic::enabled_in(FEATURE, Some(&on), &kill));
}

#[test]
fn the_wait_pattern_compiles() {
    assert!(super::WAIT_SHAPED.is_some());
}

fn stall_hub() -> Arc<Hub> {
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg, Box::new(crate::store::MemoryStore::default()))
}

fn stall_session(hub: &Hub, id: &str) -> Arc<Session> {
    hub.insert_test_session(
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
            "family": "claude", "cwd": "/tmp", "status": "waiting", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap(),
    )
}

fn hold(session: &Session, id: &str, request: Value) -> tokio::sync::oneshot::Receiver<Value> {
    let (reply, rx) = tokio::sync::oneshot::channel();
    session.permissions.lock().unwrap().pending.insert(
        id.to_owned(),
        PendingPermission {
            request,
            reply,
            decision_nonce: super::super::person::new_nonce(),
            ancestor_may_answer: false,
            prev_status: SessionStatus::Ready,
            agent_request: None,
            agent_host_incarnation: None,
        },
    );
    rx
}

#[tokio::test]
async fn a_stall_is_raised_only_for_an_ask_still_waiting() {
    let hub = stall_hub();
    let s = stall_session(&hub, "stall-1");
    let request = json!({"toolCall": {"title": "Run tests", "kind": "execute"}});
    let _rx = hold(&s, "p1", request.clone());
    let rec = stall_record(&s, "p1", STALL).unwrap();
    assert_eq!(rec, json!({"permissionId": "p1", "request": request, "waitedS": 600}));
    assert!(stall_record(&s, "p2", STALL).is_none(), "another ask");
    s.permissions.lock().unwrap().pending.remove("p1");
    assert!(stall_record(&s, "p1", STALL).is_none(), "answered before the bound");
}

#[test]
fn stamp_counts_stalls_without_polling() {
    let id = "sidecar-stall-stamp";
    with(id, |r| r.stalls += 1);
    // A new turn's first tool call keeps the stall counted for the turn that waited.
    with(id, |r| r.observe("t2", &bash("1", "ls")));
    let mut msg = json!({});
    stamp(id, &mut msg);
    assert_eq!(msg["harnessMagic"]["sidecars"], json!({"permissionStalls": 1}));
    forget(id);
}
