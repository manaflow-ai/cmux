use super::*;
use crate::close_why::{CloseActor, CloseRecord};
use crate::exit_record::Owned;

fn rec(class: ExitClass, prs: &[&str]) -> ExitRecord {
    ExitRecord {
        session: "s1".into(),
        name: "lane-a".into(),
        class,
        close: CloseRecord {
            closed_at: 10,
            actor: CloseActor { kind: "ttl".into(), ..Default::default() },
            reason: "idle".into(),
            outcome: class.as_str().into(),
        },
        owned: Owned {
            prs: prs.iter().map(|s| (*s).to_owned()).collect(),
            folder: "/w/lane-a".into(),
            ..Default::default()
        },
        transcript: Some("t-1".into()),
        harness: "claude".into(),
    }
}

const H: u64 = 3600 * 1000;

#[test]
fn the_restart_type_follows_owned_work() {
    assert_eq!(restart_type(&rec(ExitClass::Killed, &["cmux#1"])), RestartType::Permanent);
    assert_eq!(restart_type(&rec(ExitClass::Dropped, &["cmux#1"])), RestartType::Permanent);
    assert_eq!(restart_type(&rec(ExitClass::Crashed, &[])), RestartType::Transient);
    assert_eq!(restart_type(&rec(ExitClass::Dropped, &[])), RestartType::Transient);
    assert_eq!(restart_type(&rec(ExitClass::Done, &["cmux#1"])), RestartType::Temporary);
    let mut goal = rec(ExitClass::Killed, &[]);
    goal.owned.goal = Some("land it".into());
    assert_eq!(restart_type(&goal), RestartType::Permanent);
}

#[test]
fn a_crash_resumes_its_transcript_and_a_normal_exit_stays_down() {
    let d = |r: &ExitRecord| decide(r, 10 * H, 0, &[], Intensity::default(), Some("coord"));
    let resume = Decision::Restart { transcript: Some("t-1".into()) };
    assert_eq!(d(&rec(ExitClass::Crashed, &[])), resume);
    assert_eq!(d(&rec(ExitClass::Killed, &["cmux#1"])), resume);
    assert_eq!(d(&rec(ExitClass::Dropped, &["cmux#1"])), resume);
    assert_eq!(d(&rec(ExitClass::Dropped, &[])), Decision::Leave { why: "normal exit" });
    assert_eq!(d(&rec(ExitClass::Done, &["cmux#1"])), Decision::Leave { why: "done" });
}

#[test]
fn past_max_restarts_in_the_window_it_escalates_to_the_parent() {
    let r = rec(ExitClass::Crashed, &["cmux#1"]);
    let lim = Intensity::default();
    let two = [Restart { at_ms: 9 * H, tokens: 0 }, Restart { at_ms: 9 * H + 1, tokens: 0 }];
    assert!(matches!(decide(&r, 10 * H, 0, &two, lim, Some("coord")), Decision::Restart { .. }));
    let three = [two[0], two[1], Restart { at_ms: 9 * H + 2, tokens: 0 }];
    let Decision::Escalate { to, why } = decide(&r, 10 * H, 0, &three, lim, Some("coord")) else {
        panic!("expected escalate")
    };
    assert_eq!(to.as_deref(), Some("coord"));
    assert!(why.starts_with("3 restarts in 360 min"), "{why}");
    // Restarts older than the window no longer count.
    let old = [Restart { at_ms: H, tokens: 0 }; 3];
    assert!(matches!(decide(&r, 10 * H, 0, &old, lim, None), Decision::Restart { .. }));
}

#[test]
fn tokens_burned_in_the_window_escalate_like_a_crash_loop() {
    let r = rec(ExitClass::Killed, &[]);
    let lim = Intensity { max_tokens: 1000, ..Intensity::default() };
    let one = [Restart { at_ms: 9 * H, tokens: 600 }];
    assert!(matches!(decide(&r, 10 * H, 300, &one, lim, None), Decision::Restart { .. }));
    let d = decide(&r, 10 * H, 500, &one, lim, None);
    let Decision::Escalate { to: None, why } = d else { panic!("expected escalate: {d:?}") };
    assert!(why.starts_with("1100 tokens"), "{why}");
}

#[test]
fn only_a_harness_exit_is_acted_on() {
    let mut r = rec(ExitClass::Crashed, &[]);
    r.close.actor.kind = "harness_exit".into();
    assert!(acts_on(&r));
    for kind in ["cli", "mcp", "ttl", "daemon", "peer", "agent_self", "app"] {
        r.close.actor.kind = kind.into();
        assert!(!acts_on(&r), "{kind}");
    }
}

#[test]
fn the_parent_note_says_what_acpmux_did() {
    let restart = Decision::Restart { transcript: None };
    assert_eq!(restart.parent_note().as_deref(), Some("acpmux restarted it from its transcript."));
    let up = Decision::Escalate { to: None, why: "3 restarts in 360 min (max 3)".into() };
    assert!(up.parent_note().unwrap().starts_with("acpmux stopped restarting it: 3 restarts"));
    assert_eq!(Decision::Leave { why: "done" }.parent_note(), None);
    assert!(
        restart_text(&rec(ExitClass::Crashed, &[]))
            .starts_with("[restart] This session ended crashed (idle)")
    );
}

#[test]
fn the_decision_serializes_with_its_action() {
    let v =
        serde_json::to_value(Decision::Escalate { to: Some("c".into()), why: "x".into() }).unwrap();
    assert_eq!(v, serde_json::json!({"action": "escalate", "to": "c", "why": "x"}));
}
