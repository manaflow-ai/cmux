//! The holder move: which route a start takes, and every row of the refusal table.

use super::super::{
    AutoStore, Event, HOLDER_MOVE_VERSION, Home, Refusal, State, Turn, route, step,
};
use super::*;

fn run(state: State, events: &[Event]) -> (State, Vec<Effect>) {
    events.iter().enumerate().fold((state, Vec::new()), |(state, mut all), (at, event)| {
        let answer = step(state, event.clone(), 1000 + at as u64 * 100);
        all.extend(answer.effects);
        (answer.state, all)
    })
}

fn holder_start() -> State {
    State { route: MoveRoute::Holder, ..State::default() }
}

fn asks(effects: &[Effect]) -> usize {
    effects.iter().filter(|effect| **effect == Effect::AskHolderMove).count()
}

fn transfers(effects: &[Effect]) -> usize {
    effects.iter().filter(|effect| **effect == Effect::Move).count()
}

fn refused(code: Refusal) -> Event {
    Event::HolderRefused { code }
}

/// Begun, its first turn over, the machine up: the first ask is made.
const ASKED: [Event; 4] = [Event::Begin, Event::TurnStarted, Event::TurnEnded, Event::MachineReady];

#[test]
fn the_holder_route_needs_a_registered_chat_and_this_builds_move_version() {
    let store = |registered, move_version| AutoStore { registered, move_version };
    assert_eq!(route(&store(true, Some(HOLDER_MOVE_VERSION))), MoveRoute::Holder);
    assert_eq!(route(&store(true, Some(HOLDER_MOVE_VERSION + 1))), MoveRoute::Holder);
    // An older daemon, one that names no version, or a chat not in the store: today's transfer.
    assert_eq!(route(&store(true, Some(1))), MoveRoute::Transfer);
    assert_eq!(route(&store(true, None)), MoveRoute::Transfer);
    assert_eq!(route(&store(false, Some(HOLDER_MOVE_VERSION))), MoveRoute::Transfer);
    assert_eq!(route(&AutoStore::default()), MoveRoute::Transfer);
}

#[test]
fn an_older_callers_state_and_store_read_as_the_transfer() {
    // The state as a caller before this change sends it, and its default: the transfer.
    let old: State =
        serde_json::from_value(serde_json::json!({"home": "here", "cloud": "ready"})).unwrap();
    assert_eq!((old.route, old.copy_owed, old.epoch), (MoveRoute::Transfer, false, None));
    let store: AutoStore = serde_json::from_value(serde_json::json!({})).unwrap();
    assert_eq!(route(&store), MoveRoute::Transfer);
    // The transfer start asks nothing of the store.
    let (state, effects) = run(State::default(), &ASKED);
    assert_eq!((transfers(&effects), asks(&effects)), (1, 0));
    assert_eq!(state.cloud, Cloud::Moving);
}

#[test]
fn the_holder_start_asks_the_store_once_at_the_boundary() {
    let (state, effects) = run(holder_start(), &ASKED);
    assert_eq!((asks(&effects), transfers(&effects)), (1, 0));
    assert_eq!(state.cloud, Cloud::Moving);
    // A machine ready mid-answer waits for a boundary, as the transfer does.
    let (state, effects) =
        run(holder_start(), &[Event::Begin, Event::TurnStarted, Event::MachineReady]);
    assert_eq!(asks(&effects), 0);
    let (_, effects) = run(state, &[Event::ToolStarted, Event::ToolEnded]);
    assert_eq!(asks(&effects), 1);
}

#[test]
fn given_makes_the_machine_the_holder_and_delivers_what_was_held() {
    let (state, _) = run(holder_start(), &ASKED);
    let (state, effects) =
        run(state, &[Event::Prompt { id: "p1".into() }, Event::HolderGiven { epoch: 7 }]);
    assert_eq!((state.home, state.cloud, state.epoch), (Home::Cloud, Cloud::Live, Some(7)));
    assert!(effects.contains(&Effect::Hold { id: "p1".into() }));
    assert_eq!(effects.last(), Some(&Effect::Deliver { id: "p1".into(), to: Home::Cloud }));
}

#[test]
fn not_copied_waits_for_the_turns_end_then_asks_again() {
    let (state, _) = run(holder_start(), &ASKED);
    let (state, effects) = run(state, &[refused(Refusal::NotCopied)]);
    assert_eq!((state.cloud, state.copy_owed, state.home), (Cloud::Ready, true, Home::Here));
    assert_eq!(asks(&effects), 0);
    // A tool boundary is not a turn's end: no ask yet.
    let (state, effects) = run(state, &[Event::TurnStarted, Event::ToolStarted, Event::ToolEnded]);
    assert_eq!((asks(&effects), state.turn), (0, Turn::Running));
    let (state, effects) = run(state, &[Event::TurnEnded]);
    assert_eq!((asks(&effects), state.copy_owed, state.cloud), (1, false, Cloud::Moving));
    assert_eq!(state.route, MoveRoute::Holder);
}

#[test]
fn not_copied_past_the_tries_falls_back_to_the_transfer() {
    let mut state = run(holder_start(), &ASKED).0;
    for _ in 1..MOVE_TRIES {
        state = run(state, &[refused(Refusal::NotCopied), Event::TurnEnded]).0;
    }
    assert_eq!(state.tries, MOVE_TRIES);
    let (state, effects) = run(state, &[refused(Refusal::NotCopied)]);
    assert_eq!((state.route, transfers(&effects)), (MoveRoute::Transfer, 1));
    assert_eq!(state.cloud, Cloud::Moving);
}

#[test]
fn no_machine_off_and_an_unknown_code_fall_back_to_the_transfer_at_once() {
    for code in [Refusal::NoMachine, Refusal::Off, Refusal::Unknown] {
        let (state, _) = run(holder_start(), &ASKED);
        let (state, effects) = run(state, &[refused(code.clone())]);
        assert_eq!(state.route, MoveRoute::Transfer, "{code:?}");
        assert_eq!((transfers(&effects), asks(&effects)), (1, 0), "{code:?}");
        assert_eq!(state.cloud, Cloud::Moving, "{code:?}");
        let (state, _) = run(state, &[Event::MoveCommitted]);
        assert_eq!((state.home, state.cloud), (Home::Cloud, Cloud::Live), "{code:?}");
    }
}

#[test]
fn a_fallback_with_a_held_prompt_runs_it_here_and_moves_at_its_boundary() {
    let (state, _) = run(holder_start(), &ASKED);
    let (state, effects) =
        run(state, &[Event::Prompt { id: "p1".into() }, refused(Refusal::NoMachine)]);
    assert_eq!(transfers(&effects), 0);
    assert_eq!(effects.last(), Some(&Effect::Deliver { id: "p1".into(), to: Home::Here }));
    let (_, effects) = run(state, &[Event::TurnStarted, Event::TurnEnded]);
    assert_eq!(transfers(&effects), 1);
}

#[test]
fn stale_epoch_leaves_the_chat_here_and_pauses_the_machine() {
    let (state, _) = run(holder_start(), &ASKED);
    let (state, effects) = run(state, &[refused(Refusal::StaleEpoch)]);
    assert_eq!((state.home, state.cloud), (Home::Here, Cloud::Failed));
    assert_eq!(state.reason.as_deref(), Some(STALE));
    assert!(effects.contains(&Effect::PauseMachine));
    assert_eq!(transfers(&effects), 0);
}

#[test]
fn a_chat_lost_to_another_holder_ends_the_drive_and_pauses_the_machine() {
    let (state, _) = run(holder_start(), &ASKED);
    let (state, effects) = run(state, &[Event::HolderLost]);
    assert_eq!((state.cloud, state.reason.as_deref()), (Cloud::Failed, Some(LOST)));
    assert!(effects.contains(&Effect::PauseMachine));
}

#[test]
fn a_stop_during_the_ask_is_kept_by_a_refusal_that_would_retry() {
    let (state, _) = run(holder_start(), &ASKED);
    let (state, effects) = run(state, &[Event::Stop, refused(Refusal::NotCopied)]);
    assert_eq!(
        (state.cloud, state.reason.as_deref()),
        (Cloud::Failed, Some(super::super::STOPPED))
    );
    assert_eq!((asks(&effects), transfers(&effects)), (0, 0));
}

#[test]
fn a_late_answer_or_one_to_a_transfer_changes_nothing() {
    // Before any ask, after the chat went live, and to a transfer start.
    let mut given = ASKED.to_vec();
    given.push(Event::HolderGiven { epoch: 2 });
    for (start, before) in [
        (holder_start(), vec![Event::Begin]),
        (holder_start(), given),
        (State::default(), ASKED.to_vec()),
    ] {
        let (state, _) = run(start, &before);
        for answer in
            [Event::HolderGiven { epoch: 9 }, refused(Refusal::StaleEpoch), Event::HolderLost]
        {
            let after = step(state.clone(), answer, 9000);
            assert_eq!(after.state, state);
            assert!(after.effects.is_empty());
        }
    }
}

#[test]
fn the_wire_codes_are_the_stores() {
    for (code, wire) in [
        (Refusal::NotCopied, "auto.not_copied"),
        (Refusal::NoMachine, "auto.no_machine"),
        (Refusal::Off, "auto.off"),
        (Refusal::StaleEpoch, "auto.stale_epoch"),
    ] {
        assert_eq!(serde_json::to_value(&code).unwrap(), wire);
        assert_eq!(serde_json::from_value::<Refusal>(wire.into()).unwrap(), code);
    }
    assert_eq!(
        serde_json::from_value::<Refusal>("auto.new_code".into()).unwrap(),
        Refusal::Unknown
    );
    let event: Event =
        serde_json::from_value(serde_json::json!({"on": "holderRefused", "code": "auto.off"}))
            .unwrap();
    assert_eq!(event, refused(Refusal::Off));
    assert_eq!(
        serde_json::to_value(Effect::AskHolderMove).unwrap(),
        serde_json::json!({"do": "askHolderMove"})
    );
}
