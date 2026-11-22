use std::collections::BTreeSet;
use std::path::PathBuf;

use super::*;

fn table_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/updater-gate/table.json")
}

fn rendered() -> String {
    let mut text = serde_json::to_string_pretty(&table()).expect("table renders");
    text.push('\n');
    text
}

/// The committed table is the one `step` answers. `CMUX_UPDATE_UPDATER_GATE_TABLE=1` rewrites it.
#[test]
fn committed_table_is_current() {
    let path = table_path();
    let now = rendered();
    if std::env::var("CMUX_UPDATE_UPDATER_GATE_TABLE").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().expect("parent")).expect("schemas dir");
        std::fs::write(&path, &now).expect("write table");
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("{}: {e}; run with CMUX_UPDATE_UPDATER_GATE_TABLE=1", path.display())
    });
    assert!(
        committed == now,
        "{} is stale: rerun `CMUX_UPDATE_UPDATER_GATE_TABLE=1 cargo test -p cmux-host updater::gate::machine` and commit it",
        path.display()
    );
}

/// The sample states are the 24 abstract states, each once, and the table holds every pair.
#[test]
fn every_abstract_state_against_every_event_is_in_the_table() {
    let names: BTreeSet<String> =
        sample_states().iter().map(|s| View::at(s, SAMPLE_NOW).name()).collect();
    assert_eq!(names.len(), 24);
    assert_eq!(sample_states().len(), 24);
    let table = table();
    let rows = table["transitions"].as_array().expect("transitions");
    assert_eq!(rows.len(), 24 * sample_events().len());
    for row in rows {
        assert!(names.contains(row["to"].as_str().expect("to")), "{row}");
    }
}

/// What is left of the connect holds alone.
fn connect_left(view: &View) -> Option<Duration> {
    match view.hold {
        Hold::Connect { left, .. } => Some(left),
        Hold::None | Hold::Resume { .. } => None,
    }
}

/// The invariants one step keeps, whatever the state.
fn check(before: &GateState, now_ms: u64, event: Event, step: &Step) {
    let view = View::at(before, now_ms);
    let after = View::at(&step.state, now_ms);
    let name = || format!("{} {event:?} -> {step:?}", view.name());
    if !step.write {
        assert_eq!(step.state, *before, "an unwritten step changed the state: {}", name());
    }
    if let Event::Run { honor } = event {
        let passed = matches!(step.verdict, Verdict::Run { .. });
        // (a) An update's flip never passes a hold.
        if honor == Honor::All && passed {
            assert_eq!(view.hold, Hold::None, "{}", name());
        }
        // (b) --skip-resume-hold passes a resume hold, reported, and never a connect hold.
        if honor == Honor::AllButResume {
            match view.hold {
                Hold::Connect { left, .. } => {
                    assert_eq!(step.verdict, Verdict::Refused(Refusal::Held(left)), "{}", name());
                }
                Hold::Resume { .. } if passed => assert_eq!(
                    step.verdict,
                    Verdict::Run { skipped: Some(HoldKind::Resume) },
                    "{}",
                    name()
                ),
                Hold::Resume { .. } | Hold::None => {}
            }
        }
        // (c) No flip of any honor runs under a bind in flight.
        if let Bind::InFlight { .. } = view.bind {
            assert!(!passed, "{}", name());
            assert!(matches!(step.verdict, Verdict::Refused(_)), "{}", name());
        }
        // (e) A flip that runs leaves its restart pending.
        if passed {
            assert!(matches!(after.restart, Restart::Pending { .. }), "{}", name());
        }
    }
    // (d) A bind waits for a pending restart, and marks nothing.
    if event == Event::BeginBind && matches!(view.restart, Restart::Pending { .. }) {
        assert_eq!(step.verdict, Verdict::Refused(Refusal::RestartPending), "{}", name());
        assert_eq!(step.state, *before, "{}", name());
        assert!(!step.write, "{}", name());
    }
    // (f) A refusal changes nothing, but a rollback meeting a bind marks its restart.
    if let Verdict::Refused(refusal) = step.verdict {
        let rollback_meets_bind = event == (Event::Run { honor: Honor::Nothing })
            && matches!(refusal, Refusal::BindInFlight(_));
        if rollback_meets_bind {
            assert!(step.write, "{}", name());
            assert!(matches!(after.restart, Restart::Pending { .. }), "{}", name());
            let mut unmarked = step.state.clone();
            unmarked.restart_pending_until_ms = before.restart_pending_until_ms;
            assert_eq!(unmarked, *before, "{}", name());
        } else {
            assert_eq!(step.state, *before, "{}", name());
            assert!(!step.write, "{}", name());
        }
    }
    // (g) A started service has no restart pending.
    if event == Event::ServiceStarted {
        assert_eq!(after.restart, Restart::Idle, "{}", name());
        assert_eq!(step.state.restart_pending_until_ms, None, "{}", name());
    }
    // (h) The own-flip mark is taken once.
    if event == Event::TakeOwnFlip {
        assert_eq!(step.state.own_flip, None, "{}", name());
        assert_eq!(step.write, before.own_flip.is_some(), "{}", name());
    }
    // Holds lapse by time alone: no event shortens one (an unreadable file's holds are lost).
    if event != Event::UnreadableFile {
        assert!(after.held_left() >= view.held_left(), "a hold shrank: {}", name());
        assert!(connect_left(&after) >= connect_left(&view), "a connect hold shrank: {}", name());
    }
}

#[test]
fn every_abstract_state_against_every_event_keeps_the_invariants() {
    let mut refusals = 0;
    for state in sample_states() {
        for (_, event) in sample_events() {
            let step = step(state.clone(), SAMPLE_NOW, event);
            check(&state, SAMPLE_NOW, event, &step);
            if let Verdict::Refused(_) = step.verdict {
                refusals += 1;
            }
        }
    }
    assert!(refusals > 0);
}

/// xorshift64: deterministic, no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn random_event(rng: &mut Rng) -> Event {
    let kind = if rng.below(2) == 0 { HoldKind::Resume } else { HoldKind::Connect };
    let honor = [Honor::All, Honor::AllButResume, Honor::Nothing][rng.below(3) as usize];
    match rng.below(15) {
        0 => Event::Hold { kind, hold: Duration::from_millis(rng.below(600_000)) },
        1 => Event::Hold { kind, hold: CONNECT_HOLD },
        2 => Event::InsideHold { kind },
        3 => Event::BeginBind,
        4 => Event::EndBind,
        5 => Event::HeldLeft,
        6 | 7 => Event::Run { honor },
        8 => Event::RestartQueued,
        9 => Event::FlipRestartQueued {
            // Now and then one that does not fit the file: no mark.
            offset_ns: if rng.below(8) == 0 { i128::MAX } else { i128::from(rng.below(1 << 40)) },
        },
        10 => Event::RunFinished { queued: rng.below(2) == 0 },
        11 => Event::ServiceStarted,
        12 => Event::TakeOwnFlip,
        13 => Event::UnreadableFile,
        _ => Event::Run { honor: Honor::AllButResume },
    }
}

/// Time moves by nothing, a little, or past each bound.
fn random_advance(rng: &mut Rng) -> u64 {
    match rng.below(6) {
        0 => 0,
        1 => rng.below(2_000),
        2 => rng.below(ms(BIND_IN_FLIGHT_FOR) + 5_000),
        3 => rng.below(ms(RESTART_PENDING_FOR) + 5_000),
        4 => rng.below(ms(CONNECT_HOLD) + 5_000),
        _ => ms(CONNECT_HOLD) + rng.below(60_000),
    }
}

#[test]
fn random_walks_keep_the_invariants() {
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    let mut seen = BTreeSet::new();
    let old_file: GateState = serde_json::from_str(r#"{"held_until_ms":2000000}"#).expect("old");
    for walk in 0..200 {
        let mut now_ms = 1_000_000;
        let mut state = match walk % 3 {
            0 => GateState::default(),
            1 => old_file.clone(),
            _ => GateState::repaired(now_ms),
        };
        for _ in 0..40 {
            now_ms += random_advance(&mut rng);
            let event = random_event(&mut rng);
            let step = step(state.clone(), now_ms, event);
            check(&state, now_ms, event, &step);
            let view = View::at(&state, now_ms);
            // A bind's mark (60 s) never outlives the connect hold its start took (5 min).
            if let Bind::InFlight { .. } = view.bind {
                assert!(connect_left(&view).is_some(), "a bind in flight with no connect hold");
            }
            seen.insert(view.name());
            if step.write {
                state = step.state;
            }
        }
    }
    // Every abstract state but the 8 with a bind in flight and no connect hold, which no
    // event reaches (the table still decides them: a hand-made or foreign file can say so).
    let reachable: BTreeSet<String> = sample_states()
        .iter()
        .map(|s| View::at(s, SAMPLE_NOW))
        .filter(|v| matches!(v.bind, Bind::Idle) || connect_left(v).is_some())
        .map(|v| v.name())
        .collect();
    assert_eq!(reachable.len(), 16);
    assert_eq!(seen, reachable, "the walks reach every reachable abstract state");
}

/// A file from before the hold kinds holds only `held_until_ms`: every hold in it is a connect
/// hold, and a resume hold taken over it keeps it one.
#[test]
fn an_old_file_reads_as_a_connect_hold() {
    let old: GateState = serde_json::from_str(r#"{"held_until_ms":5000}"#).expect("old file");
    let left = Duration::from_millis(4000);
    assert_eq!(View::at(&old, 1000).hold, Hold::Connect { left, all: Some(left) });
    let run = step(old.clone(), 1000, Event::Run { honor: Honor::AllButResume });
    assert_eq!(run.verdict, Verdict::Refused(Refusal::Held(left)));
    let held = step(old, 1000, Event::Hold { kind: HoldKind::Resume, hold: CONNECT_HOLD });
    assert_eq!(held.state.connect_until_ms, Some(5000));
    let view = View::at(&held.state, 1000);
    assert_eq!(
        view.hold,
        Hold::Connect { left, all: Some(Duration::from_millis(ms(CONNECT_HOLD))) }
    );
    assert_eq!(
        View::at(&held.state, 5000).hold,
        Hold::Resume { left: Duration::from_millis(ms(CONNECT_HOLD) - 4000) }
    );
}

/// The file keeps its field names and order, so older builds read what this one writes.
#[test]
fn the_file_round_trips_with_its_field_names() {
    assert_eq!(
        serde_json::to_string(&GateState::default()).expect("serializes"),
        r#"{"held_until_ms":null,"connect_until_ms":null,"restart_pending_until_ms":null,"own_flip":null,"bind_in_flight_until_ms":null}"#
    );
    let full = r#"{"held_until_ms":1,"connect_until_ms":2,"restart_pending_until_ms":3,"own_flip":{"at_ms":4,"offset_ns":-5},"bind_in_flight_until_ms":6}"#;
    let state: GateState = serde_json::from_str(full).expect("reads");
    assert_eq!(serde_json::to_string(&state).expect("writes"), full);
    let empty: GateState = serde_json::from_str("{}").expect("an empty object reads");
    assert_eq!(empty, GateState::default());
}

/// A rollback that meets a bind in flight marks its restart pending, writes, and is refused;
/// an update's flip in the same state writes nothing.
#[test]
fn a_rollback_meeting_a_bind_marks_its_restart() {
    let begun = step(GateState::default(), 1000, Event::BeginBind);
    assert_eq!(begun.verdict, Verdict::BindBegun);
    let left = Duration::from_millis(ms(BIND_IN_FLIGHT_FOR) - 500);
    let rollback = step(begun.state.clone(), 1500, Event::Run { honor: Honor::Nothing });
    assert_eq!(rollback.verdict, Verdict::Refused(Refusal::BindInFlight(left)));
    assert!(rollback.write);
    assert!(matches!(View::at(&rollback.state, 1500).restart, Restart::Pending { .. }));
    let update = step(begun.state.clone(), 1500, Event::Run { honor: Honor::All });
    assert!(matches!(update.verdict, Verdict::Refused(Refusal::Held(_))));
    assert!(!update.write);
    assert_eq!(update.state, begun.state);
}

#[test]
fn the_own_flip_is_fresh_only_within_its_bound() {
    let mut flipped = step(GateState::default(), 1000, Event::FlipRestartQueued { offset_ns: 7 });
    assert_eq!(flipped.state.own_flip, Some(OwnFlip { at_ms: 1000, offset_ns: 7 }));
    flipped.state.restart_pending_until_ms = None;
    for (now_ms, fresh) in [(1000, true), (1000 + ms(RESTART_PENDING_FOR), true), (999, false)] {
        let taken = step(flipped.state.clone(), now_ms, Event::TakeOwnFlip);
        assert_eq!(
            taken.verdict,
            Verdict::OwnFlip { mark: Some(OwnFlip { at_ms: 1000, offset_ns: 7 }), fresh }
        );
    }
    let late = step(flipped.state, 1001 + ms(RESTART_PENDING_FOR), Event::TakeOwnFlip);
    assert_eq!(late.verdict.name(), "own_flip_stale");
}
