//! The table, and what holds for every state against every event. The journeys are in
//! `tests/laptop.rs` and `tests/machine.rs`.

mod laptop;
mod machine;

use std::path::PathBuf;

use super::*;
use crate::consts::{LEASE_MS, RENEW_MS, SELF_STOP_MS};

/// The effects' names, in order.
fn kinds(effects: &[Effect]) -> Vec<&'static str> {
    effects.iter().map(Effect::kind).collect()
}

fn has(effects: &[Effect], kind: &str) -> bool {
    effects.iter().any(|effect| effect.kind() == kind)
}

/// The request number of the renewal or registration among `effects`.
fn request(effects: &[Effect]) -> u64 {
    effects
        .iter()
        .find_map(|effect| match effect {
            Effect::Renew { request, .. } | Effect::Register { request } => Some(*request),
            _ => None,
        })
        .expect("a renewal or a registration")
}

/// A store answer with nothing pending.
fn answer(verdict: Verdict, epoch: u64, snapshot: u64) -> Answer {
    Answer { verdict, epoch, snapshot, inbox_pending: false, handback_due: false }
}

fn table_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../schemas/auto-session-holder/table.json")
}

fn rendered() -> String {
    let mut text = serde_json::to_string_pretty(&table()).expect("table renders");
    text.push('\n');
    text
}

/// The committed table is the one `step` answers. `CMUX_UPDATE_AUTO_SESSION_HOLDER_TABLE=1`
/// rewrites it.
#[test]
fn committed_table_is_current() {
    let path = table_path();
    let now = rendered();
    if std::env::var("CMUX_UPDATE_AUTO_SESSION_HOLDER_TABLE").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().expect("parent")).expect("schemas dir");
        std::fs::write(&path, &now).expect("write table");
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("{}: {e}; run with CMUX_UPDATE_AUTO_SESSION_HOLDER_TABLE=1", path.display())
    });
    assert!(
        committed == now,
        "{} is stale: rerun `CMUX_UPDATE_AUTO_SESSION_HOLDER_TABLE=1 cargo test -p cmux-auto-session holder` and commit it",
        path.display()
    );
}

/// Every state against every event is decided, the table holds exactly those pairs, and the
/// samples cover every state and every event.
#[test]
fn every_state_against_every_event_is_decided() {
    let chats = sample_chats();
    let events = sample_events();
    for kind in State::KINDS {
        assert!(chats.iter().any(|(_, chat)| chat.state.kind() == kind), "no sample {kind}");
    }
    for kind in Event::KINDS {
        assert!(events.iter().any(|(_, event, _)| event.kind() == kind), "no sample {kind}");
    }
    let table = table();
    let rows = table["transitions"].as_object().expect("transitions");
    assert_eq!(rows.len(), chats.len());
    let pairs: usize = rows.values().map(|row| row.as_object().expect("a row").len()).sum();
    assert_eq!(pairs, chats.len() * events.len());
    assert_eq!(table["states"].as_array().expect("states").len(), chats.len());
    assert_eq!(table["events"].as_array().expect("events").len(), events.len());
    println!("holder table: {} states x {} events = {pairs} pairs", chats.len(), events.len());
}

/// One sample pair's run: (the state's name, the event's name, before, after, effects).
type Pair = (&'static str, &'static str, Chat, Chat, Vec<Effect>);

/// One run of every sample pair.
fn every_pair() -> Vec<Pair> {
    let mut pairs = Vec::new();
    for (from, chat) in sample_chats() {
        for (event_name, event, after) in sample_events() {
            let (next, effects) = step(chat, event, SAMPLE_AT + after);
            pairs.push((from, event_name, chat, next, effects));
        }
    }
    pairs
}

#[test]
fn step_is_pure() {
    for (from, chat) in sample_chats() {
        for (event_name, event, after) in sample_events() {
            let now = SAMPLE_AT + after;
            assert_eq!(step(chat, event, now), step(chat, event, now), "{from} {event_name}");
        }
    }
}

/// A chat never changes side: a laptop's chat stays in a laptop's states.
#[test]
fn a_chat_stays_on_its_side() {
    for (from, event, before, after, _) in every_pair() {
        assert_eq!(before.side(), after.side(), "{from} {event}");
    }
}

/// SIGCONT only goes to a tree this laptop stopped, and never with a kill.
#[test]
fn a_tree_is_continued_only_from_stopped_and_never_killed_too() {
    for (from, event, before, after, effects) in every_pair() {
        if has(&effects, "continue_tree") {
            assert!(matches!(before.state, State::Stopped { .. }), "{from} {event}");
            assert!(!has(&effects, "kill_tree"), "{from} {event}");
            assert!(after.may_run(), "{from} {event}");
        }
        if matches!(before.state, State::Stopped { .. }) && after.may_run() {
            assert!(has(&effects, "continue_tree"), "{from} {event}");
        }
    }
}

/// A chat that ran here and may no longer run had its tree stopped or killed in the same step,
/// or was already idle and released.
#[test]
fn a_chat_that_may_no_longer_run_was_stopped_or_killed() {
    for (from, event, before, after, effects) in every_pair() {
        let ran = matches!(
            before.state,
            State::Holding { .. } | State::Serving { .. } | State::HandingBack { .. }
        );
        if ran && !after.may_run() {
            let releasing = matches!(after.state, State::Releasing { .. });
            assert!(
                has(&effects, "stop_tree") || has(&effects, "kill_tree") || releasing,
                "{from} {event}: {:?}",
                kinds(&effects)
            );
        }
    }
}

/// What a laptop wrote since the last acknowledged copy is kept whenever its tree is killed.
#[test]
fn a_laptop_kill_keeps_a_leftover_patch() {
    for (from, event, before, _, effects) in every_pair() {
        if before.side() == Side::Laptop && has(&effects, "kill_tree") {
            assert!(has(&effects, "write_leftover_patch"), "{from} {event}");
        }
    }
}

/// Only a laptop stops by itself: a machine's lease does not run out to another holder.
#[test]
fn a_machine_never_stops_or_continues_a_tree() {
    for (from, event, before, _, effects) in every_pair() {
        if before.side() == Side::Machine {
            assert!(!has(&effects, "stop_tree"), "{from} {event}");
            assert!(!has(&effects, "continue_tree"), "{from} {event}");
        }
    }
}

/// An import starts exactly when the chat enters an importing state anew, and nothing runs
/// until it is done.
#[test]
fn an_import_starts_with_its_state() {
    for (from, event, _, after, effects) in every_pair() {
        let importing = matches!(after.state, State::ComingHome { .. } | State::Taking { .. });
        if has(&effects, "import") {
            assert!(importing, "{from} {event}");
            assert!(!after.may_run(), "{from} {event}");
        }
    }
}

/// Every write names the epoch of the state the chat is left in.
#[test]
fn every_write_names_the_chats_epoch() {
    for (from, event, _, after, effects) in every_pair() {
        for effect in &effects {
            let named = match effect {
                Effect::Renew { epoch, .. }
                | Effect::Release { epoch }
                | Effect::UploadEvents { epoch }
                | Effect::UploadSnapshot { epoch, .. }
                | Effect::Import { epoch, .. }
                | Effect::AckAssignment { epoch } => Some(*epoch),
                _ => None,
            };
            if let Some(epoch) = named {
                assert_eq!(Some(epoch), after.epoch(), "{from} {event}: {effect:?}");
            }
        }
    }
}

/// The daemon is told the chat's next tick whenever it moved, and a tick never leaves the next
/// one due at once.
#[test]
fn the_schedule_follows_the_chat() {
    for (from, event_name, before, after, effects) in every_pair() {
        let told = effects.iter().rev().find_map(|effect| match effect {
            Effect::ScheduleAt { at } => Some(*at),
            _ => None,
        });
        let ticked = event_name.starts_with("tick");
        match after.wake_at() {
            Some(at) => {
                if ticked {
                    assert!(at > after.seen_at, "{from} {event_name}: due at once");
                }
                if ticked || before.wake_at() != Some(at) {
                    assert_eq!(told, Some(at), "{from} {event_name}");
                }
            }
            None => assert_eq!(told, None, "{from} {event_name}"),
        }
    }
}

/// A laptop that holds the chat is always stopped before the Cloud's lease can run out,
/// whatever events arrive, as long as no renewal is answered.
#[test]
fn a_holding_laptop_stops_before_the_lease_runs_out() {
    let (_, holding) = sample_chats()
        .into_iter()
        .find(|(name, _)| *name == "holding")
        .expect("the holding sample");
    for (name, event, _) in sample_events() {
        if matches!(event, Event::Answered { .. } | Event::Closed | Event::Wake) {
            continue;
        }
        // The event arrives at the moment the self-stop is due.
        let (after, effects) = step(holding, event, SAMPLE_AT + SELF_STOP_MS);
        assert!(matches!(after.state, State::Stopped { .. }), "{name}");
        assert_eq!(effects.first(), Some(&Effect::StopTree), "{name}");
    }
}

// The self-stop and one more renewal period fit in the lease.
const _: () = assert!(SELF_STOP_MS + RENEW_MS <= LEASE_MS);
