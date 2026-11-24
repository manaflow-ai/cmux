//! A hybrid start: who gets it, the one writer, the handoff point and what a failure leaves.

use super::*;

fn run(state: State, events: &[(Event, u64)]) -> (State, Vec<Effect>) {
    events.iter().fold((state, Vec::new()), |(state, mut all), (event, now)| {
        let answer = step(state, event.clone(), *now);
        all.extend(answer.effects);
        (answer.state, all)
    })
}

fn prompt(id: &str) -> Event {
    Event::Prompt { id: id.to_owned() }
}

fn deliver(id: &str, to: Home) -> Effect {
    Effect::Deliver { id: id.to_owned(), to }
}

fn moves(effects: &[Effect]) -> usize {
    effects.iter().filter(|effect| **effect == Effect::Move).count()
}

fn account(plan: Option<&str>, flag: Option<bool>) -> Account {
    Account { plan: plan.map(str::to_owned), flag, cloud_disabled: false, signed_in: true }
}

#[test]
fn it_is_on_for_everybody_on_a_pro_plan() {
    assert_eq!(enabled(&account(Some("next_pro"), None)), Ok(()));
    assert_eq!(enabled(&account(Some("next_max"), None)), Ok(()));
    assert_eq!(enabled(&account(Some("next_plus"), None)), Err(Off::Plan));
    // `billing.status`'s spelling, which is what the CLI can read.
    for plan in ["pro", "founders", "team", "next_pro", "max", "next_max"] {
        assert_eq!(enabled(&account(Some(plan), None)), Ok(()), "{plan}");
    }
    for plan in ["go", "next_plus", "next_intro", "next_taste", "free"] {
        assert_eq!(enabled(&account(Some(plan), None)), Err(Off::Plan), "{plan}");
    }
    assert_eq!(enabled(&account(None, None)), Err(Off::Plan));
    assert_eq!(enabled(&account(None, None)), Err(Off::Plan));
}

#[test]
fn the_servers_flag_wins_over_the_plan_and_cloud_off_over_both() {
    assert_eq!(enabled(&account(Some("next_pro"), Some(false))), Err(Off::Flag));
    assert_eq!(enabled(&account(None, Some(true))), Ok(()));
    let signed_out = Account { signed_in: false, ..account(Some("next_pro"), Some(true)) };
    assert_eq!(enabled(&signed_out), Err(Off::NoCloud));
    let disabled = Account { cloud_disabled: true, ..account(Some("next_pro"), Some(true)) };
    assert_eq!(enabled(&disabled), Err(Off::NoCloud));
}

#[test]
fn the_chat_starts_here_at_once_beside_its_machine() {
    let answer = step(State::default(), Event::Begin, 100);
    assert_eq!(
        answer.effects,
        [
            Effect::StartHere,
            Effect::CreateMachine,
            Effect::Show { cloud: Cloud::Booting, reason: None }
        ]
    );
    assert_eq!((answer.state.home, answer.state.cloud), (Home::Here, Cloud::Booting));
    // The first prompt goes here, with no wait for the machine.
    let first = step(answer.state.clone(), prompt("p1"), 101);
    assert_eq!(first.effects, [deliver("p1", Home::Here)]);
    // A second Begin starts nothing again.
    assert!(step(answer.state, Event::Begin, 102).effects.is_empty());
}

#[test]
fn an_idle_chat_moves_as_soon_as_its_machine_is_ready() {
    let (state, effects) = run(
        State::default(),
        &[
            (Event::Begin, 0),
            (prompt("p1"), 1),
            (Event::TurnStarted, 2),
            (Event::TurnEnded, 900),
            (Event::MachineReady, 4_000),
        ],
    );
    assert_eq!(state.cloud, Cloud::Moving);
    assert_eq!(moves(&effects), 1);
    let ready = Effect::Log { line: "hybrid start step: machine-ready 4000 ms".into() };
    assert!(effects.contains(&ready));
    let (state, effects) = run(state, &[(Event::MoveCommitted, 4_800), (prompt("p2"), 5_000)]);
    assert_eq!((state.home, state.cloud), (Home::Cloud, Cloud::Live));
    assert!(effects.contains(&Effect::Log { line: "hybrid start step: live 4800 ms".into() }));
    assert_eq!(effects.last(), Some(&deliver("p2", Home::Cloud)));
}

#[test]
fn a_running_turn_moves_at_its_next_tool_boundary_never_under_a_tool() {
    let (state, effects) = run(
        State::default(),
        &[
            (Event::Begin, 0),
            (prompt("p1"), 1),
            (Event::TurnStarted, 2),
            (Event::ToolStarted, 10),
            (Event::ToolStarted, 11),
            (Event::MachineReady, 20),
            (Event::ToolEnded, 30),
        ],
    );
    // Ready under two tools, and one of them still runs: nothing moves.
    assert_eq!((state.cloud, state.turn, moves(&effects)), (Cloud::Ready, Turn::InTool, 0));
    let (state, effects) = run(state, &[(Event::ToolEnded, 40)]);
    assert_eq!((state.cloud, moves(&effects)), (Cloud::Moving, 1));
}

#[test]
fn a_turn_that_only_answers_goes_on_to_its_end() {
    let (state, effects) = run(
        State::default(),
        &[(Event::Begin, 0), (prompt("p1"), 1), (Event::TurnStarted, 2), (Event::MachineReady, 20)],
    );
    assert_eq!((state.cloud, moves(&effects)), (Cloud::Ready, 0));
    let (state, effects) = run(state, &[(Event::TurnEnded, 50)]);
    assert_eq!((state.cloud, moves(&effects)), (Cloud::Moving, 1));
}

#[test]
fn a_prompt_sent_while_the_chat_moves_is_delivered_once_to_where_it_landed() {
    let moving = run(State::default(), &[(Event::Begin, 0), (Event::MachineReady, 10)]).0;
    let (state, effects) = run(moving, &[(prompt("p1"), 11), (prompt("p2"), 12)]);
    assert_eq!(effects, [Effect::Hold { id: "p1".into() }, Effect::Hold { id: "p2".into() }]);
    let (landed, effects) = run(state.clone(), &[(Event::MoveCommitted, 20)]);
    let delivered: Vec<_> =
        effects.iter().filter(|effect| matches!(effect, Effect::Deliver { .. })).collect();
    assert_eq!(delivered, [&deliver("p1", Home::Cloud), &deliver("p2", Home::Cloud)]);
    assert!(landed.held.is_empty());
    // A second commit (a retried answer) delivers nothing again.
    assert!(step(landed, Event::MoveCommitted, 21).effects.is_empty());
    // The move failed for good: the same prompts go here, once, and the machine is paused.
    let failed = Event::MoveFailed { reason: "link-lost".into(), again: false };
    let (stayed, effects) = run(state, &[(failed, 20)]);
    assert_eq!((stayed.home, stayed.cloud), (Home::Here, Cloud::Failed));
    assert_eq!(stayed.reason.as_deref(), Some("link-lost"));
    assert!(effects.contains(&Effect::PauseMachine));
    let delivered: Vec<_> =
        effects.iter().filter(|effect| matches!(effect, Effect::Deliver { .. })).collect();
    assert_eq!(delivered, [&deliver("p1", Home::Here), &deliver("p2", Home::Here)]);
}

#[test]
fn a_move_that_may_work_again_is_tried_at_most_three_times() {
    let again = || Event::MoveFailed { reason: "busy".into(), again: true };
    let (state, effects) = run(
        State::default(),
        &[(Event::Begin, 0), (Event::MachineReady, 10), (again(), 20), (again(), 30)],
    );
    assert_eq!((state.cloud, state.tries, moves(&effects)), (Cloud::Moving, MOVE_TRIES, 3));
    let (state, effects) = run(state, &[(again(), 40)]);
    assert_eq!((state.cloud, moves(&effects)), (Cloud::Failed, 0));
    assert_eq!(state.reason.as_deref(), Some("busy"));
}

#[test]
fn a_held_prompt_of_a_failed_try_runs_here_and_the_move_waits_for_its_boundary() {
    let (state, effects) = run(
        State::default(),
        &[
            (Event::Begin, 0),
            (Event::MachineReady, 10),
            (prompt("p1"), 11),
            (Event::MoveFailed { reason: "busy".into(), again: true }, 20),
        ],
    );
    assert_eq!(effects.last(), Some(&deliver("p1", Home::Here)));
    assert_eq!((state.cloud, moves(&effects)), (Cloud::Ready, 1));
    let (state, effects) = run(state, &[(Event::TurnStarted, 21), (Event::TurnEnded, 30)]);
    assert_eq!((state.cloud, moves(&effects)), (Cloud::Moving, 1));
}

#[test]
fn a_machine_that_fails_leaves_the_chat_here_with_its_reason() {
    let failed = Event::MachineFailed { reason: "quota".into() };
    let (state, effects) = run(
        State::default(),
        &[(Event::Begin, 0), (prompt("p1"), 1), (Event::TurnStarted, 2), (failed, 30)],
    );
    assert_eq!((state.home, state.cloud, state.turn), (Home::Here, Cloud::Failed, Turn::Running));
    assert!(effects.contains(&Effect::Show { cloud: Cloud::Failed, reason: Some("quota".into()) }));
    assert!(!effects.contains(&Effect::PauseMachine));
    // A late ready of a start that failed moves nothing.
    assert!(step(state, Event::MachineReady, 40).effects.is_empty());
}

#[test]
fn a_chat_the_person_keeps_here_never_moves_and_its_machine_is_paused() {
    let (state, effects) = run(
        State::default(),
        &[(Event::Begin, 0), (Event::Stop, 5), (Event::MachineReady, 10), (Event::TurnEnded, 20)],
    );
    assert_eq!((state.home, state.cloud, moves(&effects)), (Home::Here, Cloud::Failed, 0));
    assert_eq!(state.reason.as_deref(), Some(STOPPED));
    assert_eq!(effects.iter().filter(|effect| **effect == Effect::PauseMachine).count(), 1);
    // Kept here while the machine waits for a boundary: the same.
    let (state, effects) = run(
        State::default(),
        &[(Event::Begin, 0), (Event::TurnStarted, 1), (Event::MachineReady, 10), (Event::Stop, 11)],
    );
    assert_eq!((state.cloud, moves(&effects)), (Cloud::Failed, 0));
    assert!(effects.contains(&Effect::PauseMachine));
}

#[test]
fn the_wire_names_are_the_ones_the_view_reads() {
    let answer = step(State::default(), Event::Begin, 7);
    let wire = serde_json::to_value(&answer).unwrap();
    assert_eq!(wire["state"]["home"], "here");
    assert_eq!(wire["state"]["cloud"], "booting");
    assert_eq!(wire["state"]["since"], 7);
    assert_eq!(wire["effects"][0]["do"], "startHere");
    assert_eq!(wire["effects"][2], serde_json::json!({ "do": "show", "cloud": "booting" }));
    let event: Event =
        serde_json::from_str(r#"{"on":"moveFailed","reason":"busy","again":true}"#).unwrap();
    assert_eq!(event, Event::MoveFailed { reason: "busy".into(), again: true });
}
