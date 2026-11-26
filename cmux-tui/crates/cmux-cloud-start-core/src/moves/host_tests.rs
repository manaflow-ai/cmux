//! Every branch of the place host's rules, in parity with the app's `AppServices: CloudPlaceHost`
//! (`CloudHandlers+Move.swift`) and `CloudPlaceFlows.Cargo.read`.

use super::*;
use serde_json::{Value, json};

fn moved(machine: &str, host: &str, session: &str, brought_back: Option<&str>) -> (String, Value) {
    let mut entry = json!({
        "machineID": machine, "host": host, "session": session,
        "localRoot": "/r", "localChat": "c", "remoteFolder": "/f", "remoteChat": "rc",
    });
    if let Some(back) = brought_back {
        entry["broughtBack"] = json!({ "session": back, "key": "k" });
    }
    (format!("{host}\n{session}"), entry)
}

fn ledgers(entries: &[(String, Value)]) -> MovedChats {
    let object: serde_json::Map<_, _> = entries.iter().cloned().collect();
    MovedChats { moved: Some(Value::Object(object).to_string()), starting: None }
}

fn tab(id: &str, host: &str, session: Option<&str>, local: bool) -> Tab {
    Tab {
        id: id.into(),
        host: host.into(),
        session: session.map(Into::into),
        local,
        title: format!("t-{id}"),
        ..Tab::default()
    }
}

#[test]
fn eligible_local_chat_on_this_mac() {
    assert!(eligible("local", "s", true, &MovedChats::default()));
}

#[test]
fn eligible_refuses_another_machines_daemon() {
    assert!(!eligible("ssh:devbox", "s", false, &MovedChats::default()));
}

#[test]
fn eligible_refuses_the_chief() {
    assert!(!eligible("chief:home", "s", true, &MovedChats::default()));
}

#[test]
fn eligible_cloud_chat_needs_its_ledger_entry() {
    let ledger = ledgers(&[moved("m1", "registry:a", "s", None)]);
    assert!(eligible("registry:a", "s", false, &ledger));
    assert!(!eligible("registry:a", "other", false, &ledger));
    assert!(!eligible("registry:b", "s", true, &MovedChats::default()));
}

#[test]
fn chats_skip_tabs_without_a_session() {
    assert!(chats(&[tab("1", "local", None, true)], &MovedChats::default()).is_empty());
}

#[test]
fn chats_once_per_session_after_eligibility() {
    // The Chief's tab of session `s` comes first but may not move: it never hides the local one.
    let tabs = [
        tab("1", "chief:x", Some("s"), true),
        tab("2", "local", Some("s"), true),
        tab("3", "local", Some("s"), true),
    ];
    let found = chats(&tabs, &MovedChats::default());
    assert_eq!(found.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), ["2"]);
}

#[test]
fn chats_carry_the_tab_facts_and_on_cloud() {
    let ledger = ledgers(&[moved("m1", "registry:a", "c", None)]);
    let mut cloud = tab("9", "registry:a", Some("c"), false);
    cloud.turn_running = true;
    cloud.turn_started_at_ms = Some(12.0);
    cloud.moving = true;
    cloud.queued = 3;
    let found = chats(&[tab("1", "local", Some("l"), true), cloud], &ledger);
    assert_eq!(found.len(), 2);
    assert!(!found[0].on_cloud);
    assert_eq!(
        serde_json::to_value(&found[1]).unwrap(),
        json!({ "id": "9", "session": "c", "title": "t-9", "onCloud": true, "turnRunning": true,
                "turnStartedAtMs": 12.0, "moving": true, "queued": 3 })
    );
    assert!(serde_json::to_value(&found[0]).unwrap().get("turnStartedAtMs").is_none());
}

#[test]
fn cloud_sessions_leave_out_brought_back_chats() {
    let ledger = ledgers(&[
        moved("m1", "registry:a", "s1", None),
        moved("m1", "registry:a", "s2", Some("home")),
    ]);
    assert_eq!(cloud_sessions(&ledger), ["s1"]);
    assert!(cloud_sessions(&MovedChats::default()).is_empty());
}

#[test]
fn own_facts_before_is_the_ledger_machine() {
    let ledger = ledgers(&[moved("m1", "registry:a", "s", None)]);
    assert_eq!(own_facts("s", &ledger, Some("old"), &[]).before.as_deref(), Some("m1"));
}

#[test]
fn own_facts_before_matches_a_chat_coming_back() {
    let ledger = ledgers(&[moved("m2", "registry:a", "remote", Some("home"))]);
    assert_eq!(own_facts("home", &ledger, None, &[]).before.as_deref(), Some("m2"));
}

#[test]
fn own_facts_before_falls_back_to_the_last_machine() {
    assert_eq!(
        own_facts("s", &MovedChats::default(), Some("old"), &[]).before.as_deref(),
        Some("old")
    );
    assert_eq!(own_facts("s", &MovedChats::default(), None, &[]).before, None);
}

#[test]
fn own_facts_machines_hold_live_sessions_and_gone() {
    let ledger = ledgers(&[
        moved("m1", "registry:a", "s1", None),
        moved("m1", "registry:a", "s2", Some("home")),
        moved("m2", "registry:b", "s3", None),
    ]);
    let statuses = [
        MachineStatus { id: "m1".into(), status: "running".into() },
        MachineStatus { id: "m2".into(), status: "deleting".into() },
        MachineStatus { id: "m3".into(), status: "destroyed".into() },
        MachineStatus { id: "m4".into(), status: "paused".into() },
    ];
    let facts = own_facts("x", &ledger, None, &statuses);
    assert_eq!(
        facts.machines,
        vec![
            Machine { id: "m1".into(), sessions: vec!["s1".into()], gone: false },
            Machine { id: "m2".into(), sessions: vec!["s3".into()], gone: true },
            Machine { id: "m3".into(), sessions: vec![], gone: true },
            Machine { id: "m4".into(), sessions: vec![], gone: false },
        ]
    );
}

#[test]
fn cargo_running_turn_continues() {
    let cargo = cargo(&CargoFacts {
        turn_running: true,
        branch: Some("main".into()),
        has_draft: true,
        ..CargoFacts::default()
    });
    assert!(cargo.turn_running && cargo.continues_turn && cargo.has_draft);
    assert_eq!(cargo.branch.as_deref(), Some("main"));
    assert_eq!(cargo.queued, 0);
}

#[test]
fn cargo_idle_turn_does_not_continue() {
    let cargo = cargo(&CargoFacts::default());
    assert!(!cargo.turn_running && !cargo.continues_turn);
}

#[test]
fn cargo_queued_only_when_positive() {
    assert_eq!(cargo(&CargoFacts { queued: Some(2), ..CargoFacts::default() }).queued, 2);
    assert_eq!(cargo(&CargoFacts { queued: Some(0), ..CargoFacts::default() }).queued, 0);
    assert_eq!(cargo(&CargoFacts { queued: Some(-1), ..CargoFacts::default() }).queued, 0);
}

#[test]
fn cargo_claims_win_over_the_read() {
    let facts = CargoFacts {
        has_draft: false,
        queued: Some(5),
        claims: Some(Claims { queued: Some(1), has_draft: Some(true) }),
        ..CargoFacts::default()
    };
    let cargo = cargo(&facts);
    assert_eq!((cargo.queued, cargo.has_draft), (1, true));
}

#[test]
fn cargo_empty_claims_keep_the_read() {
    let facts = CargoFacts {
        has_draft: true,
        queued: Some(4),
        claims: Some(Claims::default()),
        ..CargoFacts::default()
    };
    let cargo = cargo(&facts);
    assert_eq!((cargo.queued, cargo.has_draft), (4, true));
}

#[test]
fn run_refusal_none_when_work_started() {
    let facts = RunFacts { started: true, refusal: Some("no".into()), ..RunFacts::default() };
    assert_eq!(run_refusal(&facts), None);
}

#[test]
fn run_refusal_is_the_moves_own_trimmed() {
    let facts =
        RunFacts { refusal: Some("  No folder \t".into()), ran: true, ..RunFacts::default() };
    assert_eq!(run_refusal(&facts).as_deref(), Some("No folder"));
}

#[test]
fn run_refusal_keeps_line_breaks() {
    let facts = RunFacts { refusal: Some(" a\n".into()), ..RunFacts::default() };
    assert_eq!(run_refusal(&facts).as_deref(), Some("a\n"));
}

#[test]
fn run_refusal_none_when_ran_without_refusal() {
    assert_eq!(
        run_refusal(&RunFacts { ran: true, failed: "f".into(), ..RunFacts::default() }),
        None
    );
}

#[test]
fn run_refusal_unavailable_then_failed() {
    let unavailable = RunFacts {
        unavailable: Some("Sign in ".into()),
        failed: "f".into(),
        ..RunFacts::default()
    };
    assert_eq!(run_refusal(&unavailable).as_deref(), Some("Sign in"));
    assert_eq!(
        run_refusal(&RunFacts { failed: "Move failed".into(), ..RunFacts::default() }).as_deref(),
        Some("Move failed")
    );
}
