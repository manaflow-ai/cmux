use super::*;

fn begin(cargo: Cargo) -> Flow {
    let (flow, next) = reduce(
        None,
        Event::Begin {
            session: "s1".into(),
            direction: Direction::ToCloud,
            trigger: Trigger::Person,
            from: "This Mac".into(),
            to: String::new(),
            cargo,
            at_ms: 1_000,
        },
    );
    assert_eq!(next, Next::Go);
    flow.expect("a begin makes a flow")
}

fn step(flow: Flow, step: Step, at_ms: u64) -> (Flow, Next) {
    let (flow, next) = reduce(Some(flow), Event::Step { step, at_ms });
    (flow.expect("flow"), next)
}

#[test]
fn steps_run_forward_and_time_each() {
    let flow = begin(Cargo::default());
    let (flow, _) = step(flow, Step::Machine, 1_200);
    let (flow, _) = step(flow, Step::Sync, 2_000);
    // A step back or a repeat is ignored.
    let (flow, next) = step(flow, Step::Machine, 2_100);
    assert_eq!(next, Next::Ignore);
    assert_eq!(flow.step, Step::Sync);
    let (flow, _) = step(flow, Step::Commit, 3_000);
    let (flow, _) = reduce(Some(flow), Event::Live { at_ms: 4_500 });
    let flow = flow.expect("flow");
    let shown = view(&flow, 99_999);
    assert_eq!(shown.state, "live");
    assert_eq!(shown.elapsed_ms, 3_500);
    assert!(!shown.over_budget);
    assert_eq!(shown.runs_at, At::Cloud);
    let times: Vec<_> = shown.steps.iter().map(|s| (s.step, s.ms)).collect();
    assert_eq!(
        times,
        vec![(Step::Preflight, 200), (Step::Machine, 800), (Step::Sync, 1_000), (Step::Commit, 1_500)]
    );
}

#[test]
fn cancel_before_freeze_stops_and_leaves_the_chat() {
    let flow = begin(Cargo::default());
    let (flow, _) = step(flow, Step::Sync, 1_500);
    assert!(view(&flow, 1_600).can_cancel);
    let (flow, next) = reduce(Some(flow), Event::Cancel { at_ms: 1_700 });
    assert_eq!(next, Next::Stop);
    let flow = flow.expect("flow");
    let shown = view(&flow, 5_000);
    assert_eq!(shown.state, "cancelled");
    assert_eq!(shown.runs_at, At::Local);
    assert_eq!(shown.elapsed_ms, 700);
}

#[test]
fn cancel_after_freeze_runs_out_and_says_finishing() {
    let flow = begin(Cargo::default());
    let (flow, _) = step(flow, Step::Freeze, 1_500);
    assert!(!view(&flow, 1_600).can_cancel);
    let (flow, next) = reduce(Some(flow), Event::Cancel { at_ms: 1_700 });
    assert_eq!(next, Next::Go);
    let flow = flow.expect("flow");
    let shown = view(&flow, 1_800);
    assert!(shown.finishing);
    assert!(!shown.can_cancel);
    let (flow, next) = step(flow, Step::Commit, 2_000);
    assert_eq!(next, Next::Go);
    assert!(flow.outcome.is_none());
}

#[test]
fn failure_before_landing_keeps_the_old_place_and_offers_retry() {
    let flow = begin(Cargo::default());
    let (flow, _) = step(flow, Step::Carry, 2_000);
    let (flow, _) = reduce(Some(flow), Event::Failed { reason: "link dropped".into(), at_ms: 2_500 });
    let flow = flow.expect("flow");
    let shown = view(&flow, 9_000);
    assert_eq!(shown.state, "failed");
    assert_eq!(shown.step, Step::Carry);
    assert_eq!(shown.runs_at, At::Local);
    assert!(shown.can_retry);
    assert_eq!(shown.reason.as_deref(), Some("link dropped"));
    // An ended move takes no more events but a new begin.
    let (flow, next) = reduce(Some(flow), Event::Step { step: Step::Commit, at_ms: 3_000 });
    assert_eq!(next, Next::Ignore);
    assert!(matches!(flow.expect("flow").outcome, Some(Outcome::Failed { .. })));
}

#[test]
fn failure_after_commit_is_at_the_new_place() {
    let flow = begin(Cargo::default());
    let (flow, _) = step(flow, Step::Attach, 2_000);
    let (flow, _) = reduce(Some(flow), Event::Failed { reason: "tab".into(), at_ms: 2_100 });
    assert_eq!(runs_at(&flow.expect("flow")), At::Cloud);
}

#[test]
fn over_budget_is_flagged_while_moving() {
    let flow = begin(Cargo::default());
    assert!(!view(&flow, 1_000 + BUDGET_MS).over_budget);
    assert!(view(&flow, 1_001 + BUDGET_MS).over_budget);
}

#[test]
fn carries_say_what_moves_truthfully() {
    let cargo = Cargo {
        turn_running: true,
        continues_turn: true,
        queued: 2,
        has_draft: true,
        branch: Some("lane/x".into()),
        dirty_files: 3,
    };
    let kinds: Vec<_> = carries(&cargo).iter().map(|c| (c.kind, c.how)).collect();
    assert_eq!(
        kinds,
        vec![
            ("history", How::Carried),
            ("turn", How::Continues),
            ("queue", How::Carried),
            ("draft", How::Carried),
            ("branch", How::Carried),
            ("changes", How::Carried),
        ]
    );
    let old = Cargo { turn_running: true, continues_turn: false, ..Cargo::default() };
    let flow = begin(old);
    assert!(view(&flow, 1_000).interrupts_turn);
    // Nothing to say beyond history for an idle clean chat.
    assert_eq!(carries(&Cargo::default()).len(), 1);
}

#[test]
fn step_names_are_the_wire_names() {
    for step in Step::ALL {
        let wire = serde_json::to_value(step).expect("serialize");
        assert_eq!(wire, serde_json::Value::String(step.name().into()));
    }
    assert!(Step::Sync.cancellable() && !Step::Freeze.cancellable());
}

fn busy() -> ChatState {
    ChatState { turn_running: true, turn_ms: 1_000, ..ChatState::default() }
}

#[test]
fn auto_moves_busy_chats_under_pressure_only() {
    let sleep = Signals { sleeping: true, ..Signals::default() };
    assert_eq!(auto(Mode::Auto, &busy(), &sleep), AutoDecision::ToCloud { reason: AutoReason::Sleep });
    // An idle chat never moves, and Local or Cloud mode never asks.
    assert_eq!(auto(Mode::Auto, &ChatState::default(), &sleep), AutoDecision::Stay);
    assert_eq!(auto(Mode::Local, &busy(), &sleep), AutoDecision::Stay);
    let low = Signals { on_battery: true, battery_percent: Some(10), ..Signals::default() };
    assert_eq!(auto(Mode::Auto, &busy(), &low), AutoDecision::ToCloud { reason: AutoReason::LowBattery });
    let charging = Signals { on_battery: false, battery_percent: Some(5), ..Signals::default() };
    assert_eq!(auto(Mode::Auto, &busy(), &charging), AutoDecision::Stay);
    let mem = Signals { memory: Pressure::Critical, ..Signals::default() };
    assert_eq!(auto(Mode::Auto, &busy(), &mem), AutoDecision::ToCloud { reason: AutoReason::Memory });
    let disk = Signals { disk_free_bytes: Some(1 << 30), ..Signals::default() };
    assert_eq!(auto(Mode::Auto, &busy(), &disk), AutoDecision::ToCloud { reason: AutoReason::Disk });
    let away = Signals { idle_ms: Some(rule::AWAY_MS), ..Signals::default() };
    assert_eq!(auto(Mode::Auto, &busy(), &away), AutoDecision::ToCloud { reason: AutoReason::Away });
    let long = ChatState { turn_ms: rule::LONG_TURN_MS, ..busy() };
    assert_eq!(auto(Mode::Auto, &long, &Signals::default()), AutoDecision::ToCloud { reason: AutoReason::LongTurn });
    let queued = ChatState { queued: 1, ..ChatState::default() };
    assert_eq!(auto(Mode::Auto, &queued, &sleep), AutoDecision::ToCloud { reason: AutoReason::Sleep });
    let moving = ChatState { moving: true, ..busy() };
    assert_eq!(auto(Mode::Auto, &moving, &sleep), AutoDecision::Stay);
}

#[test]
fn auto_brings_back_only_its_own_moves_when_all_is_well() {
    let here = Signals { idle_ms: Some(5_000), ..Signals::default() };
    let parked = ChatState { at: At::Cloud, moved_by_auto: true, idle_ms: rule::BACK_IDLE_MS, ..ChatState::default() };
    assert_eq!(auto(Mode::Auto, &parked, &here), AutoDecision::Back);
    // The person put it there: it stays.
    let theirs = ChatState { moved_by_auto: false, ..parked };
    assert_eq!(auto(Mode::Auto, &theirs, &here), AutoDecision::Stay);
    // Busy, away, low or just idle a moment: it stays.
    assert_eq!(auto(Mode::Auto, &ChatState { turn_running: true, ..parked }, &here), AutoDecision::Stay);
    assert_eq!(auto(Mode::Auto, &parked, &Signals { idle_ms: Some(rule::PRESENT_MS), ..here }), AutoDecision::Stay);
    assert_eq!(auto(Mode::Auto, &parked, &Signals { idle_ms: None, ..here }), AutoDecision::Stay);
    let low = Signals { on_battery: true, battery_percent: Some(rule::BACK_BATTERY_PERCENT), ..here };
    assert_eq!(auto(Mode::Auto, &parked, &low), AutoDecision::Stay);
    assert_eq!(auto(Mode::Auto, &ChatState { idle_ms: 1_000, ..parked }, &here), AutoDecision::Stay);
    assert_eq!(auto(Mode::Auto, &parked, &Signals { memory: Pressure::Warn, ..here }), AutoDecision::Stay);
}

#[test]
fn evacuate_moves_local_started_chats_running_first() {
    let chat = |session: &str, at: At, started: bool, turn_running: bool| EvacuateChat {
        session: session.into(),
        at,
        started,
        turn_running,
        moving: false,
    };
    let chats = vec![
        chat("a", At::Local, true, false),
        chat("b", At::Cloud, true, false),
        chat("c", At::Local, false, false),
        chat("d", At::Local, true, true),
        EvacuateChat { moving: true, ..chat("e", At::Local, true, false) },
    ];
    let plan = evacuate(&chats, None);
    assert_eq!(plan.moves, vec!["d".to_string(), "a".to_string()]);
    let skipped: Vec<_> = plan.skipped.iter().map(|s| (s.session.as_str(), s.reason)).collect();
    assert_eq!(skipped, vec![("b", "alreadyCloud"), ("c", "notStarted"), ("e", "moving")]);
    assert_eq!(plan.parallel, 2);
    let picked = vec!["a".to_string()];
    let plan = evacuate(&chats, Some(&picked));
    assert_eq!(plan.moves, vec!["a".to_string()]);
    assert!(plan.skipped.is_empty());
}

#[test]
fn own_machine_is_never_shared() {
    let machine = |id: &str, sessions: &[&str], gone: bool| Machine {
        id: id.into(),
        sessions: sessions.iter().map(|s| s.to_string()).collect(),
        gone,
    };
    let machines =
        vec![machine("m1", &["s1"], false), machine("m2", &["s1", "s2"], false), machine("m3", &[], true)];
    assert_eq!(own_machine("s1", Some("m1"), &machines), OwnMachine::Reuse { machine: "m1".into() });
    assert_eq!(own_machine("s1", Some("m2"), &machines), OwnMachine::Create);
    assert_eq!(own_machine("s1", Some("m3"), &machines), OwnMachine::Create);
    assert_eq!(own_machine("s1", Some("m9"), &machines), OwnMachine::Create);
    assert_eq!(own_machine("s1", None, &machines), OwnMachine::Create);
    let empty = vec![machine("m4", &[], false)];
    assert_eq!(own_machine("s1", Some("m4"), &empty), OwnMachine::Reuse { machine: "m4".into() });
}
