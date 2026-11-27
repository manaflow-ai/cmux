//! [`owner_return_plan`]'s rules (module docs).

use super::*;

fn placed(id: &str, running: bool, paused: bool) -> Placed {
    Placed {
        id: id.into(),
        name: format!("chat-{id}"),
        running,
        paused,
        moving: false,
        tried_at_ms: None,
    }
}

fn tick(state: &mut ReturnState, enrolled: bool, idle: Option<f64>, s: Vec<Placed>) -> ReturnPlan {
    owner_return_plan(state, enrolled, idle, || s, &ReturnSetting::default(), 1_000_000)
}

/// The owner returns: the idle session moves, the busy one is paused, nothing is killed.
#[test]
fn owner_return_moves_idle_and_pauses_busy() {
    let mut st = ReturnState::default();
    let plan =
        tick(&mut st, true, Some(1.0), vec![placed("a", false, false), placed("b", true, false)]);
    assert!(plan.returned && st.back());
    assert!(!plan.freed);
    assert_eq!(
        plan.actions,
        vec![
            Action::Move { id: "a".into(), name: "chat-a".into() },
            Action::Pause { id: "b".into() },
        ]
    );
    // Next tick: a moved, b paused: the machine is free, and the return is not new.
    let plan = tick(&mut st, true, Some(2.0), vec![placed("b", true, true)]);
    assert!(!plan.returned && plan.freed && plan.actions.is_empty());
}

/// The owner away: nothing moves or pauses; paused work resumes only once away `resume_secs`.
#[test]
fn owner_return_hysteresis_and_resume() {
    let mut st = ReturnState::default();
    let plan = tick(&mut st, true, Some(900.0), vec![placed("a", false, false)]);
    assert!(plan.actions.is_empty() && !st.back());
    tick(&mut st, true, Some(0.5), vec![placed("b", true, false)]);
    assert!(st.back());
    // Between the marks: still back, the paused one stays paused.
    let plan = tick(&mut st, true, Some(30.0), vec![placed("b", true, true)]);
    assert!(st.back() && plan.actions.is_empty());
    // Away a minute: resumed.
    let plan = tick(&mut st, true, Some(60.0), vec![placed("b", true, true)]);
    assert!(!st.back());
    assert_eq!(plan.actions, vec![Action::Resume { id: "b".into() }]);
}

/// Idle time unread: nothing destructive, and the sessions are not even listed.
#[test]
fn owner_return_unread_idle_does_nothing() {
    let mut st = ReturnState::default();
    let plan = owner_return_plan(
        &mut st,
        true,
        None,
        || panic!("listed sessions on an unread idle time"),
        &ReturnSetting::default(),
        0,
    );
    assert_eq!(plan.why, Why::PresenceUnread);
    assert!(plan.actions.is_empty() && !st.back());
}

/// Not enrolled: no moves or pauses, and anything left paused resumes.
#[test]
fn owner_return_not_enrolled_resumes_and_moves_nothing() {
    let mut st = ReturnState::default();
    let plan =
        tick(&mut st, false, Some(0.0), vec![placed("a", false, false), placed("b", true, true)]);
    assert_eq!(plan.actions, vec![Action::Resume { id: "b".into() }]);
    assert!(!st.back());
}

/// A paused session whose turn ended is resumed so it can move; one tried recently or moving
/// is left; at most `per_tick` move.
#[test]
fn owner_return_resume_to_move_cooldown_and_cap() {
    let mut st = ReturnState::default();
    let mut tried = placed("t", false, false);
    tried.tried_at_ms = Some(1_000_000 - 1000);
    let mut moving = placed("m", false, false);
    moving.moving = true;
    let mut s = vec![placed("p", false, true), tried, moving];
    s.extend((0..6).map(|i| placed(&format!("i{i}"), false, false)));
    let plan = tick(&mut st, true, Some(0.0), s);
    let moves = plan.actions.iter().filter(|a| matches!(a, Action::Move { .. })).count();
    assert_eq!(moves, DEFAULT_PER_TICK);
    assert_eq!(plan.actions[0], Action::Resume { id: "p".into() });
    assert!(
        !plan
            .actions
            .iter()
            .any(|a| matches!(a, Action::Move { id, .. } if id == "t" || id == "m"))
    );
    // Only a session that was tried and stays idle is left: free.
    let mut tried = placed("t", false, false);
    tried.tried_at_ms = Some(1_000_000 - 1000);
    assert!(tick(&mut st, true, Some(0.0), vec![tried]).freed);
}
