//! The table, and what holds for every state against every event. The journeys are in
//! `tests/laptop.rs` and `tests/machine.rs`, and a move by hand in `tests/give_laptop.rs`,
//! `tests/give_machine.rs` and `tests/give_late.rs`.

mod give_again;
mod give_laptop;
mod give_late;
mod give_machine;
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

/// A store answer with nothing pending and no wish.
fn answer(verdict: Verdict, epoch: u64, snapshot: u64) -> Answer {
    let (inbox_pending, handback_due) = (false, false);
    Answer { verdict, epoch, snapshot, inbox_pending, handback_due, wish: None, wish_at: None }
}

/// The effects' names in order, without the schedule and the row's `blocked`.
fn acts(effects: &[Effect]) -> Vec<&'static str> {
    kinds(effects)
        .into_iter()
        .filter(|kind| !matches!(*kind, "schedule_at" | "show_blocked"))
        .collect()
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

/// SIGCONT only goes to a tree this laptop stopped, and never with a kill. The chat may run
/// after it, or is given in that same step: its turn is stopped as a running one is, so
/// nothing of the chat starts here before the give. A stopped tree that may run again was
/// continued, or killed for a chat that starts over from what it kept.
#[test]
fn a_tree_is_continued_only_from_stopped_and_never_killed_too() {
    for (from, event, before, after, effects) in every_pair() {
        if has(&effects, "continue_tree") {
            assert!(matches!(before.state, State::Stopped { .. }), "{from} {event}");
            assert!(!has(&effects, "kill_tree"), "{from} {event}");
            let given = has(&effects, "stop_turn") && after.moving().is_some();
            assert!(after.may_run() || given, "{from} {event}");
        }
        if matches!(before.state, State::Stopped { .. }) && after.may_run() {
            let continued = has(&effects, "continue_tree");
            assert!(continued || has(&effects, "kill_tree"), "{from} {event}");
        }
    }
}

/// A chat that ran here and may no longer run had its tree stopped or killed in the same step,
/// or its turn stopped for a give.
#[test]
fn a_chat_that_may_no_longer_run_was_stopped_or_killed() {
    for (from, event, before, after, effects) in every_pair() {
        let ran = matches!(before.state, State::Holding { .. } | State::Serving { .. });
        if ran && !after.may_run() {
            let giving = has(&effects, "stop_turn") && after.moving().is_some();
            assert!(
                has(&effects, "stop_tree") || has(&effects, "kill_tree") || giving,
                "{from} {event}: {:?}",
                kinds(&effects)
            );
        }
    }
}

/// A machine that loses a chat keeps what it wrote since its last stored copy, unless it had
/// nothing left to run and the store has that copy: then the next holder has everything,
/// whether a renewal says the chat is lost or the late answer to a give does. The store that
/// took the give a machine asked with its newest copy has everything too; a give answered in
/// an earlier step of a new one was asked before what ran here since.
#[test]
fn a_machine_kill_keeps_a_leftover_patch_unless_everything_is_copied() {
    for (from, event, before, _, effects) in every_pair() {
        if before.side() == Side::Machine && has(&effects, "kill_tree") {
            let copied = !before.needs_run && before.copy == CopyState::Stored;
            let lost = matches!(event, "answered_lost" | "gave");
            let handed_back = copied && lost && matches!(before.state, State::Serving { .. });
            let asked = before.state.giving().map(|(step, _)| step) == Some(GiveStep::Asking);
            let given = event == "gave" && asked;
            assert_eq!(
                has(&effects, "write_leftover_patch"),
                !(handed_back || given),
                "{from} {event}"
            );
        }
    }
}

/// A give starts with the turn's stop, on a chat that runs or on one whose stopped tree is
/// continued in that step. The store is asked only once it has the chat's newest copy, and
/// nothing of the chat runs here in between.
#[test]
fn a_give_stops_the_turn_then_copies_then_asks() {
    for (from, event, before, after, effects) in every_pair() {
        if has(&effects, "stop_turn") {
            let continued = matches!(before.state, State::Stopped { .. })
                && effects.first() == Some(&Effect::ContinueTree);
            assert!(before.may_run() || continued, "{from} {event}");
            let step = after.state.giving().map(|(step, _)| step);
            assert_eq!(step, Some(GiveStep::Stopping), "{from} {event}");
        }
        if has(&effects, "give") {
            let step = after.state.giving().map(|(step, _)| step);
            assert_eq!(step, Some(GiveStep::Asking), "{from} {event}");
            assert_eq!(after.copy, CopyState::Stored, "{from} {event}");
        }
        if after.moving().is_some() {
            assert!(after.here() && !after.may_run(), "{from} {event}");
        }
    }
}

/// A give that ends with the chat still here says so (`stay`), so the turn it stopped goes on
/// here. One that ends with the chat gone, or with Auto's own stop, kills or stops the tree.
#[test]
fn a_give_that_ends_is_stayed_or_the_chat_is_gone() {
    for (from, event, before, after, effects) in every_pair() {
        if has(&effects, "stay") {
            assert!(before.moving().is_some() && after.moving().is_none(), "{from} {event}");
            assert!(!has(&effects, "kill_tree"), "{from} {event}");
        }
        if before.moving().is_some() && after.moving().is_none() {
            assert!(
                has(&effects, "stay") || has(&effects, "kill_tree"),
                "{from} {event}: {:?}",
                kinds(&effects)
            );
        }
        if has(&effects, "not_moved") {
            assert!(after.declined && !before.declined, "{from} {event}");
            assert!(after.moving().is_none(), "{from} {event}");
        }
    }
}

/// A machine never tells the store it has nothing left to run while a copy is not stored.
#[test]
fn a_machine_says_idle_only_once_its_copy_is_stored() {
    for (from, event, _, after, effects) in every_pair() {
        if after.side() != Side::Machine {
            continue;
        }
        for effect in &effects {
            if let Effect::Renew { needs_run: false, .. } = effect {
                assert_eq!(after.copy, CopyState::Stored, "{from} {event}");
                assert!(!after.needs_run, "{from} {event}");
            }
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
                | Effect::UploadEvents { epoch }
                | Effect::UploadSnapshot { epoch, .. }
                | Effect::Import { epoch, .. }
                | Effect::AckAssignment { epoch }
                | Effect::Give { epoch } => Some(*epoch),
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
/// whatever events arrive, as long as the store answers nothing: no renewal, and no give it
/// took (after that one the laptop holds nothing).
#[test]
fn a_holding_laptop_stops_before_the_lease_runs_out() {
    let (_, holding) = sample_chats()
        .into_iter()
        .find(|(name, _)| *name == "holding")
        .expect("the holding sample");
    for (name, event, _) in sample_events() {
        let answer = matches!(event, Event::Answered { .. } | Event::Closed { .. });
        if answer || matches!(event, Event::Gave { .. } | Event::Wake) {
            continue;
        }
        // The event arrives at the moment the self-stop is due.
        let (after, effects) = step(holding, event, SAMPLE_AT + SELF_STOP_MS);
        assert!(matches!(after.state, State::Stopped { .. }), "{name}");
        assert_eq!(effects.first(), Some(&Effect::StopTree), "{name}");
        // A give that would begin at that moment does not: the chat is stopped, not given.
        assert!(!has(&effects, "stop_turn"), "{name}");
    }
}

/// A laptop in the middle of a give holds the chat too: it stops before the lease can run out,
/// unless the store took the chat by then.
#[test]
fn a_giving_laptop_stops_before_the_lease_runs_out() {
    for (from, giving) in sample_chats() {
        if !matches!(giving.state, State::Giving { .. }) {
            continue;
        }
        for (name, event, _) in sample_events() {
            if matches!(event, Event::Answered { .. } | Event::Closed { .. } | Event::Wake) {
                continue;
            }
            let (after, effects) = step(giving, event, SAMPLE_AT + SELF_STOP_MS);
            if matches!(after.state, State::Standby { .. }) {
                assert_eq!(name, "gave", "{from}");
                continue;
            }
            assert!(matches!(after.state, State::Stopped { .. }), "{from} {name}");
            assert_eq!(effects.first(), Some(&Effect::StopTree), "{from} {name}");
            // The turn the give stopped is continued here once the chat may run again.
            assert!(has(&effects, "stay"), "{from} {name}");
        }
    }
}

// The self-stop and one more renewal period fit in the lease.
const _: () = assert!(SELF_STOP_MS + RENEW_MS <= LEASE_MS);
