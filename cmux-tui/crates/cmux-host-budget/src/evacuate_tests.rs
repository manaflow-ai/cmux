//! [`evacuate_plan`]'s rules, one test each (module docs).

use super::*;

const S: u64 = 1000;
const MIN: u64 = 60 * S;

fn on() -> Setting {
    Setting { on: true, ..Setting::default() }
}

/// A session idle since `idle_since` (ms), nothing else said of it.
fn idle(id: &str, idle_since: u64) -> Candidate {
    Candidate {
        id: id.into(),
        name: format!("chat-{id}"),
        idle_since_ms: idle_since,
        running: false,
        attended: false,
        kept: false,
        moved_at_ms: None,
    }
}

/// Sessions idle since 0, 10 s, 20 s ... (the first is idle longest).
fn several(n: usize) -> Vec<Candidate> {
    (0..n).map(|i| idle(&format!("s{i}"), i as u64 * 10 * S)).collect()
}

fn ids(plan: &Plan) -> Vec<&str> {
    plan.moves.iter().map(|m| m.id.as_str()).collect()
}

/// Feeds `level` every 15 s from `from` to `to` (ms, inclusive); returns the last plan.
fn run(
    state: &mut Hysteresis,
    level: Level,
    sessions: &[Candidate],
    setting: &Setting,
    from: u64,
    to: u64,
) -> Plan {
    let mut t = from;
    let mut last = None;
    while t <= to {
        last = Some(evacuate_plan(state, Some(level), || sessions.to_vec(), setting, t));
        t += 15 * S;
    }
    last.expect("one tick at least")
}

#[test]
fn under_budget_moves_nothing_and_never_reads_the_sessions() {
    let mut state = Hysteresis::default();
    for t in (0..10).map(|i| 100 * MIN + i * 15 * S) {
        let plan = evacuate_plan(
            &mut state,
            Some(Level::Normal),
            || panic!("a host within budget never lists its sessions"),
            &on(),
            t,
        );
        assert!(plan.moves.is_empty());
        assert_eq!(plan.why, Why::WithinBudget { level: Level::Normal });
    }
    assert!(!state.active());
}

#[test]
fn over_briefly_moves_nothing() {
    let mut state = Hysteresis::default();
    let sessions = several(3);
    let t0 = 100 * MIN;
    // Over for 105 s of the 120 s hold, then back to Normal: the run is broken.
    let plan = run(&mut state, Level::Critical, &sessions, &on(), t0, t0 + 105 * S);
    assert!(plan.moves.is_empty());
    assert!(matches!(plan.why, Why::Holding { .. }), "{:?}", plan.why);
    let plan = evacuate_plan(&mut state, Some(Level::Normal), Vec::new, &on(), t0 + 120 * S);
    assert!(plan.moves.is_empty());
    // Over again: the hold counts from the start again.
    let plan = run(&mut state, Level::Warning, &sessions, &on(), t0 + 135 * S, t0 + 240 * S);
    assert!(plan.moves.is_empty(), "a new run waits its own hold: {plan:?}");
    assert!(!state.active());
}

#[test]
fn sustained_moves_the_longest_idle_first_capped_per_tick() {
    let mut state = Hysteresis::default();
    let sessions = several(5);
    let setting = Setting { per_tick: 2, ..on() };
    let t0 = 100 * MIN;
    let plan = run(&mut state, Level::Warning, &sessions, &setting, t0, t0 + 120 * S);
    assert_eq!(ids(&plan), ["s0", "s1"], "the two idle longest, longest first");
    assert_eq!(plan.moves[0].idle_ms, t0 + 120 * S);
    assert!(matches!(plan.why, Why::Over { level: Level::Warning, over_secs: 120 }));
    assert!(state.active());

    // The input order does not matter.
    let mut reversed = sessions.clone();
    reversed.reverse();
    let mut state2 = Hysteresis::default();
    let plan = run(&mut state2, Level::Warning, &reversed, &setting, t0, t0 + 120 * S);
    assert_eq!(ids(&plan), ["s0", "s1"]);
}

#[test]
fn a_busy_watched_kept_or_freshly_idle_session_stays() {
    let mut state = Hysteresis::default();
    let t0 = 100 * MIN;
    let end = t0 + 120 * S;
    let sessions = vec![
        Candidate { running: true, ..idle("busy", 0) },
        Candidate { attended: true, ..idle("watched", 0) },
        Candidate { kept: true, ..idle("kept", 0) },
        idle("fresh", end - 4 * MIN),
        idle("old", 50 * MIN),
    ];
    let setting = Setting { per_tick: 10, ..on() };
    let plan = run(&mut state, Level::Critical, &sessions, &setting, t0, end);
    assert_eq!(ids(&plan), ["old"]);
}

#[test]
fn recovering_stops_and_calm_ends_the_evacuation() {
    let mut state = Hysteresis::default();
    let sessions = several(3);
    let t0 = 100 * MIN;
    let plan = run(&mut state, Level::Warning, &sessions, &on(), t0, t0 + 120 * S);
    assert_eq!(ids(&plan), ["s0"]);
    // Back at Normal: nothing moves, though it is still evacuating for the calm period.
    let plan = evacuate_plan(&mut state, Some(Level::Normal), Vec::new, &on(), t0 + 135 * S);
    assert!(plan.moves.is_empty());
    assert_eq!(plan.why, Why::Easing { level: Level::Normal });
    assert!(state.active());
    // Over again within the calm period: moves at once, no new hold (no flapping either way).
    let plan =
        evacuate_plan(&mut state, Some(Level::Warning), || sessions.clone(), &on(), t0 + 150 * S);
    assert_eq!(ids(&plan), ["s0"]);
    // Calm for the whole calm period: evacuation ends.
    let plan = run(&mut state, Level::Normal, &sessions, &on(), t0 + 165 * S, t0 + 225 * S);
    assert_eq!(plan.why, Why::WithinBudget { level: Level::Normal });
    assert!(!state.active());
    // Over again after that waits a full hold.
    let plan =
        evacuate_plan(&mut state, Some(Level::Warning), || sessions.clone(), &on(), t0 + 240 * S);
    assert!(plan.moves.is_empty());
    assert!(matches!(plan.why, Why::Holding { .. }));
}

#[test]
fn between_the_marks_keeps_evacuating_without_moving() {
    // Enter at Critical, leave at Normal: Warning in between neither moves nor ends it.
    let setting = Setting { enter: Level::Critical, ..on() };
    let mut state = Hysteresis::default();
    let sessions = several(2);
    let t0 = 100 * MIN;
    let plan = run(&mut state, Level::Warning, &sessions, &setting, t0, t0 + 10 * MIN);
    assert!(plan.moves.is_empty());
    assert!(!state.active(), "Warning never reaches a Critical entry");
    let plan = run(&mut state, Level::Critical, &sessions, &setting, t0, t0 + 120 * S);
    assert_eq!(ids(&plan), ["s0"]);
    let plan = run(&mut state, Level::Warning, &sessions, &setting, t0 + 135 * S, t0 + 20 * MIN);
    assert!(plan.moves.is_empty());
    assert!(state.active(), "Warning is above the leave mark");
}

#[test]
fn a_just_moved_session_is_not_moved_again() {
    let mut state = Hysteresis::default();
    let t0 = 100 * MIN;
    let end = t0 + 120 * S;
    let sessions = vec![
        Candidate { moved_at_ms: Some(end - 29 * MIN), ..idle("back", 0) },
        Candidate { moved_at_ms: Some(end - 31 * MIN), ..idle("long-ago", 10 * S) },
        idle("never", 20 * S),
    ];
    let setting = Setting { per_tick: 10, ..on() };
    let plan = run(&mut state, Level::Warning, &sessions, &setting, t0, end);
    assert_eq!(ids(&plan), ["long-ago", "never"], "inside the 30 min cooldown stays");
}

#[test]
fn setting_off_moves_nothing_and_forgets_the_run() {
    let mut state = Hysteresis::default();
    let sessions = several(3);
    let t0 = 100 * MIN;
    let off = Setting::default();
    assert!(!off.on, "off is the default");
    let plan = run(&mut state, Level::Critical, &sessions, &off, t0, t0 + 30 * MIN);
    assert!(plan.moves.is_empty());
    assert_eq!(plan.why, Why::Off);
    // On, then off mid-evacuation: the state goes, and turning it on again waits a hold.
    run(&mut state, Level::Critical, &sessions, &on(), t0, t0 + 120 * S);
    assert!(state.active());
    evacuate_plan(&mut state, Some(Level::Critical), Vec::new, &off, t0 + 135 * S);
    assert!(!state.active());
    let plan =
        evacuate_plan(&mut state, Some(Level::Critical), || sessions.clone(), &on(), t0 + 150 * S);
    assert!(plan.moves.is_empty());
}

#[test]
fn an_unread_budget_is_never_over() {
    let mut state = Hysteresis::default();
    run(&mut state, Level::Critical, &several(1), &on(), 0, 120 * S);
    assert!(state.active());
    let plan = evacuate_plan(&mut state, None, || panic!("not read"), &on(), 135 * S);
    assert_eq!(plan.why, Why::BudgetUnknown);
    assert!(!state.active());
}

#[test]
fn zero_per_tick_moves_nothing() {
    let mut state = Hysteresis::default();
    let setting = Setting { per_tick: 0, ..on() };
    let plan = run(&mut state, Level::Critical, &several(3), &setting, 0, 120 * S);
    assert!(plan.moves.is_empty());
}
