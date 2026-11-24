//! The writer's choice of a turn and of its passes: no clock and no thread.

use std::time::{Duration, Instant};

use super::{Pass, Turn, WriterState, take_trim, take_turn};

/// The parked snapshots' trim runs once a day however busy the writer is: the first pass after start (whose prune
/// already trimmed) only starts the day.
#[test]
fn the_parked_trim_runs_once_a_day_with_any_pass() {
    let mut state = WriterState::default();
    assert!(!take_trim(&mut state), "the start's prune ran it");
    assert!(!take_trim(&mut state), "a busy writer's next pass does not");
    let a_day_ago = Instant::now().checked_sub(super::super::parked_trim::PASS_EVERY);
    let Some(a_day_ago) = a_day_ago else { return }; // a clock that started under a day ago (Windows)
    state.last_trim = Some(a_day_ago);
    assert!(take_trim(&mut state), "a day later any pass runs it");
    assert!(!take_trim(&mut state));
}

/// A terminal's history grew by a step while a write pass is due: the turn that takes the write pass also
/// measures. The write pass runs the budget at most once per snapshot interval (`OutputStore::enforce_due`), and
/// the terminal does not ask again while its request is open (`LogState::measure_due`). So a request that the
/// write pass takes and does not run is served only by a later request of another terminal that is taken with no
/// write pass due, or by the interval (30 s). In
/// `the_total_memory_budget_holds_while_terminals_print_not_one_interval_later` the interval is one hour and the
/// terminals stop at their own cap, so no later request comes; a loaded host made it red: "four full terminals
/// kept 9074 and 9074 rows over the 16 MiB budget". No clock: the writer's choice is a function of its state
/// and one instant.
#[test]
fn the_total_memory_budget_request_is_not_lost_to_a_write_pass_that_is_due_first() {
    let now = Instant::now();
    let mut state = WriterState { last_trim: Some(now), ..WriterState::default() };

    // Only a request: the turn measures and writes nothing.
    state.memory_due = true;
    assert_eq!(take_turn(&mut state, now), Some(Turn { memory: true, write: false, trim: false }));
    assert_eq!(take_turn(&mut state, now), None, "one request is one measurement");

    // Only a write pass that is due: the turn writes and measures nothing more.
    state.due = Some(now);
    assert_eq!(take_turn(&mut state, now), Some(Turn { memory: false, write: true, trim: false }));
    assert_eq!(take_turn(&mut state, now), None);

    // A write pass that is not due yet does not hold the request back.
    state.due = Some(now + Duration::from_secs(3600));
    state.memory_due = true;
    assert_eq!(take_turn(&mut state, now), Some(Turn { memory: true, write: false, trim: false }));

    // Both at the same instant: the write pass runs, and the request is not lost.
    state.due = Some(now);
    state.memory_due = true;
    let turn = take_turn(&mut state, now).expect("a write pass is due");
    assert!(turn.write, "a due write pass runs in the turn that takes it: {turn:?}");
    assert!(
        turn.memory || state.memory_due,
        "the request for a measurement is gone and no turn measures: the terminal's `measure_due` stays set, \
         so it does not ask again, and the total memory budget waits for another terminal's request or for \
         the snapshot interval: {turn:?}"
    );
}

/// `run` runs exactly the passes of its turn, in this order: the measurement, then the write pass with the
/// turn's trim. So the turn that takes a request with a due write pass does measure.
#[test]
fn a_turn_with_a_request_and_a_due_write_pass_measures_first_then_writes() {
    let passes = |memory, write, trim| Turn { memory, write, trim }.passes().collect::<Vec<_>>();
    assert_eq!(passes(true, true, true), [Pass::Memory, Pass::Write { trim: true }]);
    assert_eq!(passes(true, false, false), [Pass::Memory]);
    assert_eq!(passes(false, true, false), [Pass::Write { trim: false }]);
}
