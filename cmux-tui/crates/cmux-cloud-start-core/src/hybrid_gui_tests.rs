use super::*;
use serde_json::json;

fn pro() -> Account {
    Account { plan: Some("next_pro".into()), signed_in: true, ..Account::default() }
}

fn catalog() -> Value {
    json!({"defaultHarness": "claude", "harnesses": {"claude": {}}})
}

fn plain() -> Send {
    Send { account: pro(), folder: true, catalog: Some(catalog()), ..Send::default() }
}

#[test]
fn a_plain_folder_send_runs_here_first() {
    let decided = decide(&plain());
    assert!(decided.here);
    assert_eq!(decided.probe, "cloud hybrid gui start: here");
}

#[test]
fn every_shape_the_move_cannot_carry_skips() {
    type Case = (fn(&mut Send), Skip);
    let cases: [Case; 8] = [
        (|send| send.killed = true, Skip::KillSwitch),
        (|send| send.replaces_chat = true, Skip::Repick),
        (|send| send.team = true, Skip::Team),
        (|send| send.repository = true, Skip::Repository),
        (|send| send.environment = true, Skip::Environment),
        (|send| send.folder = false, Skip::NoFolder),
        (|send| send.catalog = None, Skip::NoLocalHarness),
        (|send| send.account.plan = Some("next_intro".into()), Skip::Plan),
    ];
    for (change, skip) in cases {
        let mut send = plain();
        change(&mut send);
        let decided = decide(&send);
        assert_eq!((decided.here, decided.off), (false, Some(skip)));
        assert!(decided.probe.starts_with("cloud hybrid gui start: off "));
    }
    let mut send = plain();
    send.killed = true;
    assert_eq!(decide(&send).probe, "cloud hybrid gui start: off kill-switch");
}

#[test]
fn kill_switch_values() {
    for off in ["0", "false", "OFF", " no "] {
        assert!(says_off(Some(off)));
    }
    for on in [None, Some("1"), Some("on"), Some("")] {
        assert!(!says_off(on));
    }
}

#[test]
fn call_key_is_stable_and_separates_fields() {
    let key = call_key("chat", "turn", 0);
    assert_eq!(key.len(), 64);
    assert_eq!(key, call_key("chat", "turn", 0));
    assert_ne!(key, call_key("chat", "turn", 1));
    assert_ne!(call_key("ab", "c", 0), call_key("a", "bc", 0));
}
