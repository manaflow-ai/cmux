use std::collections::BTreeSet;
use std::path::PathBuf;

use super::*;

fn table_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/updater-role/table.json")
}

fn rendered() -> String {
    let mut text = serde_json::to_string_pretty(&table()).expect("table renders");
    text.push('\n');
    text
}

/// The committed table is the one `step` answers. `CMUX_UPDATE_UPDATER_ROLE_TABLE=1` rewrites it.
#[test]
fn committed_table_is_current() {
    let path = table_path();
    let now = rendered();
    if std::env::var("CMUX_UPDATE_UPDATER_ROLE_TABLE").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().expect("parent")).expect("schemas dir");
        std::fs::write(&path, &now).expect("write table");
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("{}: {e}; run with CMUX_UPDATE_UPDATER_ROLE_TABLE=1", path.display())
    });
    assert!(
        committed == now,
        "{} is stale: rerun `CMUX_UPDATE_UPDATER_ROLE_TABLE=1 cargo test -p cmux-host updater::role::machine` and commit it",
        path.display()
    );
}

/// The sample states are the 6 abstract states, each once, and the table holds every pair.
#[test]
fn every_abstract_state_against_every_event_is_in_the_table() {
    let names: BTreeSet<String> = sample_states().iter().map(|s| s.name(SAMPLE_NOW)).collect();
    assert_eq!(names.len(), 6);
    assert_eq!(sample_states().len(), 6);
    let table = table();
    let rows = table["transitions"].as_array().expect("transitions");
    assert_eq!(rows.len(), 6 * sample_events().len());
    for row in rows {
        assert!(names.contains(row["to"].as_str().expect("to")), "{row}");
    }
}

fn left(state: &State, honor: Honor, now_ms: u64) -> Option<Duration> {
    match step(state.clone(), Event::HeldLeft { honor, now_ms }).verdict {
        Verdict::HeldLeft(left) => left,
        other => panic!("held_left answered {other:?}"),
    }
}

/// The invariants one step keeps, whatever the state.
fn check(before: &State, event: Event, step: &Step, now_ms: u64) {
    let after = &step.state;
    let name = || format!("{} {event:?} -> {step:?}", before.name(now_ms));
    // A refusal changes nothing.
    if let Verdict::Refused(_) = step.verdict {
        assert_eq!(after, before, "a refusal changed the state: {}", name());
    }
    // The count moves only by a stop, by one, and only with no commit running.
    if after.generation != before.generation {
        assert_eq!(event, Event::Stop, "{}", name());
        assert_eq!(before.commit, Commit::Free, "{}", name());
        assert_eq!(after.generation, before.generation.wrapping_add(1), "{}", name());
        assert_eq!(step.verdict, Verdict::Stopped { generation: after.generation }, "{}", name());
    }
    match event {
        // A stop or a commit waits for the commit running.
        Event::Stop | Event::Enter if before.commit == Commit::Held => {
            assert_eq!(step.verdict, Verdict::Refused(Refusal::CommitHeld), "{}", name());
        }
        Event::Stop => assert!(matches!(step.verdict, Verdict::Stopped { .. }), "{}", name()),
        Event::Enter => {
            assert_eq!(step.verdict, Verdict::Entered, "{}", name());
            assert_eq!(after.commit, Commit::Held, "{}", name());
        }
        Event::Leave => assert_eq!(after.commit, Commit::Free, "{}", name()),
        // A verb never stops; a worker goes on only at the current count.
        Event::Live { by: Caller::Verb } => assert_eq!(step.verdict, Verdict::Live, "{}", name()),
        Event::Live { by: Caller::Worker { generation } } => {
            let live = generation == before.generation;
            assert_eq!(step.verdict == Verdict::Live, live, "{}", name());
        }
        Event::Start => {
            let generation = before.generation;
            assert_eq!(step.verdict, Verdict::Started { generation }, "{}", name());
        }
        // A rollback honors no hold, an unrecorded one either.
        Event::HeldLeft { honor: Honor::Nothing, .. } => {
            assert_eq!(step.verdict, Verdict::HeldLeft(None), "{}", name());
        }
        Event::HoldNotRecorded { .. } | Event::HeldLeft { .. } => {}
    }
    // Only a hold not recorded changes the holds, and it never shortens one.
    if !matches!(event, Event::HoldNotRecorded { .. }) {
        assert_eq!(after.unrecorded, before.unrecorded, "{}", name());
    }
    for honor in [Honor::All, Honor::AllButResume] {
        assert!(left(after, honor, now_ms) >= left(before, honor, now_ms), "{}", name());
    }
    // Every hold the flag honors, a plain check honors too.
    assert!(left(after, Honor::All, now_ms) >= left(after, Honor::AllButResume, now_ms));
    // A hold not recorded holds a plain check for its whole bound; a connect hold holds the
    // flag's check too.
    if let Event::HoldNotRecorded { kind, now_ms: taken } = event
        && taken == now_ms
    {
        assert_eq!(left(after, Honor::All, now_ms), Some(CONNECT_HOLD), "{}", name());
        if kind == HoldKind::Connect {
            assert_eq!(left(after, Honor::AllButResume, now_ms), Some(CONNECT_HOLD), "{}", name());
        }
    }
}

#[test]
fn every_abstract_state_against_every_event_keeps_the_invariants() {
    let mut refusals = 0;
    for state in sample_states() {
        for (_, event) in sample_events() {
            let step = step(state.clone(), event);
            check(&state, event, &step, SAMPLE_NOW);
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

/// An event a shell could send: a worker asks at the count it started at (`started`), which
/// may since be stale.
fn random_event(rng: &mut Rng, started: Option<u64>, now_ms: u64) -> Event {
    let kind = if rng.below(2) == 0 { HoldKind::Resume } else { HoldKind::Connect };
    let honor = [Honor::All, Honor::AllButResume, Honor::Nothing][rng.below(3) as usize];
    match rng.below(9) {
        0 => Event::Start,
        1 => Event::Stop,
        2 => Event::Enter,
        3 => Event::Leave,
        4 => Event::Live { by: Caller::Verb },
        5 => match started {
            Some(generation) => Event::Live { by: Caller::Worker { generation } },
            None => Event::Live { by: Caller::Verb },
        },
        6 => Event::HoldNotRecorded { kind, now_ms },
        _ => Event::HeldLeft { honor, now_ms },
    }
}

#[test]
fn random_walks_keep_the_invariants() {
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    let mut seen = BTreeSet::new();
    let mut verdicts = BTreeSet::new();
    for _ in 0..200 {
        let mut now_ms = 1_000_000;
        let mut state = State::default();
        let mut started = None;
        let mut stops = 0;
        for _ in 0..40 {
            now_ms += match rng.below(4) {
                0 => 0,
                1 => rng.below(2_000),
                2 => rng.below(CONNECT_HOLD.as_millis() as u64 + 5_000),
                _ => CONNECT_HOLD.as_millis() as u64 + rng.below(60_000),
            };
            let event = random_event(&mut rng, started, now_ms);
            let step = step(state.clone(), event);
            check(&state, event, &step, now_ms);
            seen.insert(state.name(now_ms));
            verdicts.insert(step.verdict.name());
            match step.verdict {
                Verdict::Started { generation } => started = Some(generation),
                Verdict::Stopped { .. } => stops += 1,
                _ => {}
            }
            // A worker is stale exactly when a stop came after its start.
            if let (Some(mine), Event::Live { by: Caller::Worker { .. } }) = (started, event) {
                assert_eq!(step.verdict == Verdict::Live, mine == state.generation);
            }
            state = step.state;
            assert_eq!(state.generation, stops, "the count is the number of stops");
        }
    }
    // Every abstract state is reachable.
    let all: BTreeSet<String> = sample_states().iter().map(|s| s.name(SAMPLE_NOW)).collect();
    assert_eq!(seen, all, "the walks reach every abstract state");
    // And every verdict the shell can meet (a worker is never ahead of the count).
    for name in ["started", "stopped", "entered", "left", "live", "kept", "held", "not_held"] {
        assert!(verdicts.contains(name), "{name} never came");
    }
    for name in ["refused_commit_held", "refused_not_entered", "refused_stale"] {
        assert!(verdicts.contains(name), "{name} never came");
    }
}

/// A stop that meets a commit waits; once the commit leaves, the stop goes in and the worker
/// started before it is stale; a verb still goes on.
#[test]
fn a_stop_waits_for_the_commit_then_stales_the_worker() {
    let started = step(State::default(), Event::Start);
    let Verdict::Started { generation } = started.verdict else { panic!("{started:?}") };
    let worker = Event::Live { by: Caller::Worker { generation } };
    let entered = step(started.state, Event::Enter);
    assert_eq!(entered.verdict, Verdict::Entered);
    let waits = step(entered.state.clone(), Event::Stop);
    assert_eq!(waits.verdict, Verdict::Refused(Refusal::CommitHeld));
    assert_eq!(step(entered.state.clone(), worker).verdict, Verdict::Live, "its own flip goes on");
    let left = step(entered.state, Event::Leave);
    let stopped = step(left.state, Event::Stop);
    assert_eq!(stopped.verdict, Verdict::Stopped { generation: generation + 1 });
    assert_eq!(
        step(stopped.state.clone(), worker).verdict,
        Verdict::Refused(Refusal::Stale { mine: generation, now: generation + 1 })
    );
    assert_eq!(step(stopped.state, Event::Live { by: Caller::Verb }).verdict, Verdict::Live);
}

/// The unrecorded holds answer as `UNRECORDED` did: every kind until its end for a plain
/// check, the connect holds alone for the flag's, nothing for a rollback, each for
/// [`CONNECT_HOLD`] from when it was taken and extended, never shortened.
#[test]
fn unrecorded_holds_keep_the_old_answers() {
    let hold = CONNECT_HOLD.as_millis() as u64;
    let resume =
        step(State::default(), Event::HoldNotRecorded { kind: HoldKind::Resume, now_ms: 1_000 })
            .state;
    assert_eq!(left(&resume, Honor::All, 1_000), Some(CONNECT_HOLD));
    assert_eq!(left(&resume, Honor::AllButResume, 1_000), None);
    assert_eq!(left(&resume, Honor::Nothing, 1_000), None);
    assert_eq!(left(&resume, Honor::All, 1_000 + hold), None, "it lapses at its end");
    let both =
        step(resume, Event::HoldNotRecorded { kind: HoldKind::Connect, now_ms: 3_000 }).state;
    assert_eq!(left(&both, Honor::All, 3_000), Some(CONNECT_HOLD));
    assert_eq!(left(&both, Honor::AllButResume, 4_000), Some(Duration::from_millis(hold - 1_000)));
    // A later resume hold extends every kind but the connect one.
    let later = step(both, Event::HoldNotRecorded { kind: HoldKind::Resume, now_ms: 10_000 }).state;
    assert_eq!(left(&later, Honor::All, 10_000), Some(CONNECT_HOLD));
    assert_eq!(
        left(&later, Honor::AllButResume, 10_000),
        Some(Duration::from_millis(hold - 7_000))
    );
    // An earlier hold taken late (a clock that stepped back) shortens nothing.
    let back =
        step(later.clone(), Event::HoldNotRecorded { kind: HoldKind::Connect, now_ms: 500 }).state;
    assert_eq!(left(&back, Honor::All, 10_000), left(&later, Honor::All, 10_000));
}
