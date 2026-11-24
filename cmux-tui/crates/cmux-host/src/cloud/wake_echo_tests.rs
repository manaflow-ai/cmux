//! Wake-to-first-echo timing (`wake_echo.rs`) and its report block, old daemon against new.

use serde_json::{Value, json};

use super::sender::Answer;
use super::session::Session;
use super::wake_echo::{WAKE_ECHO_DEADLINE_MS, WakeEcho};
use super::wire::DaemonInfo;

const WALL: u64 = 1_790_000_000_000;

fn ok() -> Answer {
    Answer::Http { status: 200, body: json!({"ok": true, "value": {"applied": true}}) }
}

fn session() -> Session {
    Session::new(
        "vm_m0000000000000000001",
        DaemonInfo { version: "test".into(), capabilities: vec![] },
        3_600_000,
    )
}

/// A new daemon's activity (capability `vm-activity-echo-v1`).
fn new_daemon(attach: Option<u64>, input: Option<u64>, echo: Option<u64>) -> Value {
    json!({
        "attached_clients": 1, "live_agents": 0,
        "last_user_input_at_ms": input, "last_agent_action_at_ms": null,
        "last_person_attach_at_ms": attach, "echo_input_at_ms": input, "echo_at_ms": echo,
    })
}

/// An old daemon's activity: none of the echo marks.
fn old_daemon(input: Option<u64>) -> Value {
    json!({
        "attached_clients": 1, "live_agents": 0,
        "last_user_input_at_ms": input, "last_agent_action_at_ms": null,
    })
}

#[test]
fn a_new_daemons_marks_make_one_echoed_wake_block() {
    let mut w = WakeEcho::default();
    assert!(w.resumed(1_000, WALL).is_none());
    w.report_ok(1_400);
    assert!(w.daemon_activity(&new_daemon(Some(WALL + 900), None, None)).is_none());
    let block = w
        .daemon_activity(&new_daemon(Some(WALL + 900), Some(WALL + 1_000), Some(WALL + 1_030)))
        .expect("the echo finishes the wake");
    assert_eq!(
        block,
        json!({"v": 1, "resumed_at": WALL, "net_up_at": WALL + 400, "pty_attach_at": WALL + 900,
               "input_at": WALL + 1_000, "echo_at": WALL + 1_030, "outcome": "echoed"})
    );
    assert!(w.next_deadline().is_none());
    assert_eq!(w.latest(), Some(block));
    // Only the first ok report after the resume is net up; nothing more is measured.
    w.report_ok(9_000);
    assert!(
        w.daemon_activity(&new_daemon(Some(WALL + 5_000), Some(WALL + 6_000), Some(WALL + 6_010)))
            .is_none()
    );
}

#[test]
fn marks_from_before_the_pause_never_count() {
    let mut w = WakeEcho::default();
    w.resumed(1_000, WALL);
    let stale = new_daemon(Some(WALL - 60_000), Some(WALL - 50_000), Some(WALL - 49_990));
    assert!(w.daemon_activity(&stale).is_none());
    // An echo pair older than this wake's attach is not this wake's either.
    let early_pair = new_daemon(Some(WALL + 500), Some(WALL + 100), Some(WALL + 120));
    assert!(w.daemon_activity(&early_pair).is_none());
    assert_eq!(w.latest().unwrap()["pty_attach_at"], WALL + 500);
}

#[test]
fn an_old_daemon_ends_the_wake_as_a_timeout_with_the_roles_own_marks() {
    let mut s = session();
    let reqs = s.resume(10_000, WALL);
    assert_eq!(reqs.len(), 1);
    assert!(reqs[0].params.get("wake").is_none(), "the resume report carries no wake yet");
    let (_, _) = s.answered(&reqs[0], &ok(), 10_300, 0.5);
    let mut now = 10_500;
    let mut sent = s.daemon_activity(&old_daemon(Some(WALL + 2_000)), now);
    assert!(s.next_deadline().unwrap() <= 10_000 + WAKE_ECHO_DEADLINE_MS);
    let mut reqs: Vec<super::sender::OpRequest> = Vec::new();
    while reqs.iter().all(|r| r.params.get("wake").is_none()) {
        assert!(now <= 10_000 + WAKE_ECHO_DEADLINE_MS + 20_000, "the timeout block never went");
        for r in std::mem::take(&mut sent) {
            let (next, _) = s.answered(&r, &ok(), now, 0.5);
            reqs.push(r);
            sent.extend(next);
        }
        if sent.is_empty() {
            now = s.next_deadline().unwrap().max(now);
            sent.extend(s.fire(now));
        }
    }
    let wake = &reqs.iter().find(|r| r.params.get("wake").is_some()).unwrap().params["wake"];
    assert_eq!(wake["outcome"], "timeout");
    assert_eq!(wake["v"], 1);
    assert_eq!(wake["net_up_at"], WALL + 300);
    assert_eq!(wake["pty_attach_at"], Value::Null);
}

#[test]
fn the_echo_report_carries_the_block_once_and_a_failed_send_keeps_it() {
    let mut s = session();
    let reqs = s.resume(10_000, WALL);
    s.answered(&reqs[0], &ok(), 10_200, 0.5);
    let mut reqs = s
        .daemon_activity(&new_daemon(Some(WALL + 500), Some(WALL + 700), Some(WALL + 720)), 10_800);
    let mut now = 10_800;
    while reqs.is_empty() {
        now = s.next_deadline().unwrap();
        reqs = s.fire(now);
    }
    let req = reqs.pop().unwrap();
    assert!(req.reason.contains("wake"), "{}", req.reason);
    assert_eq!(req.params["wake"]["outcome"], "echoed");
    assert_eq!(req.params["wake"]["echo_at"], WALL + 720);
    // A failed send keeps the block for the retry.
    let (next, _) = s.answered(&req, &Answer::Transport, now + 50, 0.5);
    assert!(next.is_empty());
    let retry = loop {
        now = s.next_deadline().unwrap();
        let mut r = s.fire(now);
        if let Some(r) = r.pop() {
            break r;
        }
    };
    assert_eq!(retry.params["wake"]["echo_at"], WALL + 720);
    s.answered(&retry, &ok(), now + 50, 0.5);
    // Delivered: the next report leaves it out.
    assert!(s.reporter.wake().is_none());
}

#[test]
fn a_second_resume_before_an_echo_reports_the_first_as_a_timeout() {
    let mut s = session();
    s.resume(10_000, WALL);
    let reqs = s.resume(70_000, WALL + 3_600_000);
    // The first resume's report is in flight, so the second is due later; its block waits.
    assert!(reqs.is_empty());
    assert_eq!(s.reporter.wake().unwrap()["outcome"], "timeout");
    assert_eq!(s.reporter.wake().unwrap()["resumed_at"], WALL);
    assert_eq!(s.wake_latest().unwrap()["resumed_at"], WALL + 3_600_000);
}
