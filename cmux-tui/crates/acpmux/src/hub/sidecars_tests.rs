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
fn sleeps_of_any_shape_add_up() {
    let mut r = Rules::default();
    r.observe("t", &bash("1", "sleep 30 && gh run view 9"));
    r.observe("t", &bash("2", "sleep 60; curl -s localhost:8080/health"));
    let text = r.observe("t", &bash("3", "sleep 10")).unwrap();
    assert!(text.contains("3 `sleep` waits"));
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
