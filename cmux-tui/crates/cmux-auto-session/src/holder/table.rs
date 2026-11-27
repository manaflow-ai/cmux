//! The transition table as data: every sample state against every sample event.

use serde_json::{Map, Value, json};

use super::{
    Answer, Change, Chat, CopyState, Effect, Event, GiveFailure, GiveStep, ImportReason, MoveTo,
    Sent, Side, State, Stop, Verdict, step,
};
use crate::consts::{LEASE_MS, RENEW_MS, SELF_STOP_MS, STREAM_COPY_MS};
use crate::wire::AssignmentKind;

/// The time the sample chats were last stepped, and their last renewal was sent and answered.
pub const SAMPLE_AT: u64 = 1_000_000;
/// The epoch the sample chats hold or last heard of.
pub const SAMPLE_EPOCH: u64 = 4;
/// The request the sample chats await.
pub const SAMPLE_REQUEST: u64 = 7;
/// The snapshot the sample chats last stored, and the copy a sample handback waits for.
pub const SAMPLE_SNAPSHOT: u64 = 3;
pub const SAMPLE_COPY: u64 = 5;

/// A chat's name in the table: its state's kind, with why a stopped laptop is stopped, whether
/// a serving machine has a copy the store does not have yet, and how far a give is.
fn name(chat: &Chat) -> &'static str {
    match chat.state {
        State::Stopped { why: Stop::Wake, .. } => "stopped_wake",
        State::Stopped { why: Stop::Offline, .. } => "stopped_offline",
        State::Serving { .. } if chat.copy != CopyState::Stored => "serving_uncopied",
        State::Giving { step: GiveStep::Stopping, .. } => "giving_stopping",
        State::Giving { step: GiveStep::Copying, .. } => "giving_copying",
        State::Giving { step: GiveStep::Asking, .. } => "giving_asking",
        State::Returning { step: GiveStep::Stopping, .. } => "returning_stopping",
        State::Returning { step: GiveStep::Copying, .. } => "returning_copying",
        State::Returning { step: GiveStep::Asking, .. } => "returning_asking",
        other => other.kind(),
    }
}

/// One chat per state (two for `stopped` and for `serving`, three for `giving` and for
/// `returning`), by its name in the table. Each is idle; it was last stepped at [`SAMPLE_AT`],
/// when its last renewal was sent, and the next one is due [`RENEW_MS`] later. The store has
/// its newest copy and was told it is idle, except `serving_uncopied`, `giving_copying` and
/// `returning_copying`: their copy [`SAMPLE_COPY`] is on its way, so the store was told a
/// machine is at work. A laptop gives its chat to the Cloud and a machine to a laptop.
pub fn sample_chats() -> Vec<(&'static str, Chat)> {
    let epoch = SAMPLE_EPOCH;
    let awaiting = Some(Sent { request: SAMPLE_REQUEST, at: SAMPLE_AT });
    let due = Some(SAMPLE_AT + RENEW_MS);
    let (stored, sending) = (CopyState::Stored, CopyState::Sending);
    let giving = |step| State::Giving { epoch, step, to: MoveTo::Cloud };
    let returning = |step| State::Returning { epoch, step, to: MoveTo::Local };
    // (state, a renewal or registration awaits its answer, a tick is scheduled, the copy)
    let states = [
        (State::Off, false, false, stored),
        (State::Registering, true, true, stored),
        (State::Holding { epoch }, true, true, stored),
        (State::Stopped { epoch, why: Stop::Wake }, true, true, stored),
        (State::Stopped { epoch, why: Stop::Offline }, true, true, stored),
        (State::Standby { epoch }, true, true, stored),
        (State::ComingHome { epoch, failed: false }, true, true, stored),
        (giving(GiveStep::Stopping), true, true, stored),
        (giving(GiveStep::Copying), true, true, sending),
        (giving(GiveStep::Asking), true, true, stored),
        (State::Away, false, false, stored),
        (
            State::Taking { epoch, reason: ImportReason::Takeover, failed: false },
            false,
            true,
            stored,
        ),
        (State::Serving { epoch }, true, true, stored),
        (State::Serving { epoch }, true, true, sending),
        (returning(GiveStep::Stopping), true, true, stored),
        (returning(GiveStep::Copying), true, true, sending),
        (returning(GiveStep::Asking), true, true, stored),
    ];
    states
        .into_iter()
        .map(|(state, awaits, scheduled, copy)| {
            let chat = Chat {
                state,
                told_needs_run: state.side() == Side::Machine && copy != stored,
                snapshot: SAMPLE_SNAPSHOT,
                copies: SAMPLE_COPY,
                copy,
                copied_at: SAMPLE_AT,
                requests: SAMPLE_REQUEST,
                awaiting: if awaits { awaiting } else { None },
                renew_at: if scheduled { due } else { None },
                ..Chat::new(state.side(), SAMPLE_AT)
            };
            (name(&chat), chat)
        })
        .collect()
}

/// One event per row of the table: its name, the event, and how long after [`SAMPLE_AT`] it
/// happens. Answers are for [`SAMPLE_REQUEST`] unless the name says otherwise.
pub fn sample_events() -> Vec<(&'static str, Event, u64)> {
    let changed = |change, needs_run| Event::Changed { change, needs_run };
    let answer = |verdict, epoch, snapshot| Answer {
        verdict,
        epoch,
        snapshot,
        inbox_pending: false,
        handback_due: false,
        wish: None,
        wish_at: None,
    };
    let holder = answer(Verdict::Holder, SAMPLE_EPOCH, SAMPLE_SNAPSHOT);
    let answered = |answer| Event::Answered { request: SAMPLE_REQUEST, answer };
    let assigned = |kind, epoch| Event::Assigned { kind, epoch };
    let give_failed = |why| Event::GiveFailed { why };
    vec![
        ("auto_on", Event::AutoOn, 0),
        ("auto_off", Event::AutoOff, 0),
        ("tick_early", Event::Tick, 1_000),
        ("tick_renewal_due", Event::Tick, RENEW_MS),
        ("tick_unanswered_35s", Event::Tick, SELF_STOP_MS),
        ("tick_after_clock_jump", Event::Tick, LEASE_MS + 1),
        ("wake", Event::Wake, 0),
        ("turn_started", changed(Change::TurnStarted, true), 0),
        ("streaming_within_5s", changed(Change::Streaming, true), 1_000),
        ("streaming_after_5s", changed(Change::Streaming, true), STREAM_COPY_MS),
        ("tool_ended", changed(Change::ToolEnded, true), 0),
        ("turn_ended_idle", changed(Change::TurnEnded, false), 0),
        ("queue_changed", changed(Change::QueueChanged, true), 0),
        ("answered_holder", answered(holder), 0),
        ("answered_holder_inbox", answered(Answer { inbox_pending: true, ..holder }), 0),
        ("answered_holder_handback_due", answered(Answer { handback_due: true, ..holder }), 0),
        ("answered_holder_new_epoch", answered(Answer { epoch: SAMPLE_EPOCH + 2, ..holder }), 0),
        ("answered_holder_35s_late", answered(holder), SELF_STOP_MS),
        ("answered_holder_wish_cloud", answered(holder.wishing(Some(MoveTo::Cloud))), 0),
        ("answered_holder_wish_local", answered(holder.wishing(Some(MoveTo::Local))), 0),
        ("answered_standby", answered(answer(Verdict::Standby, SAMPLE_EPOCH + 1, 0)), 0),
        ("answered_lost", answered(answer(Verdict::Lost, SAMPLE_EPOCH + 1, 0)), 0),
        ("answered_closed", answered(answer(Verdict::Closed, SAMPLE_EPOCH + 1, 0)), 0),
        (
            "answered_closed_after_another_holder",
            answered(answer(Verdict::Closed, SAMPLE_EPOCH + 3, 0)),
            0,
        ),
        (
            "answered_other_request",
            Event::Answered { request: SAMPLE_REQUEST - 1, answer: holder },
            0,
        ),
        ("unanswered", Event::Unanswered { request: SAMPLE_REQUEST }, 0),
        ("assigned_takeover_newer", assigned(AssignmentKind::Takeover, SAMPLE_EPOCH + 1), 0),
        ("assigned_create_newer", assigned(AssignmentKind::Create, SAMPLE_EPOCH + 1), 0),
        ("assigned_takeover_same_epoch", assigned(AssignmentKind::Takeover, SAMPLE_EPOCH), 0),
        ("assigned_deliver_same_epoch", assigned(AssignmentKind::Deliver, SAMPLE_EPOCH), 0),
        ("import_done", Event::ImportDone { epoch: SAMPLE_EPOCH, snapshot: SAMPLE_SNAPSHOT }, 0),
        ("import_failed", Event::ImportFailed { epoch: SAMPLE_EPOCH }, 0),
        (
            "snapshot_stored",
            Event::SnapshotStored { copy: SAMPLE_COPY, snapshot: SAMPLE_SNAPSHOT + 1 },
            0,
        ),
        ("snapshot_failed", Event::SnapshotFailed { copy: SAMPLE_COPY, too_large: false }, 0),
        ("snapshot_too_large", Event::SnapshotFailed { copy: SAMPLE_COPY, too_large: true }, 0),
        ("closed", Event::Closed { epoch: SAMPLE_EPOCH + 1 }, 0),
        ("closed_after_another_holder", Event::Closed { epoch: SAMPLE_EPOCH + 3 }, 0),
        ("wished_cloud", Event::Wished { to: MoveTo::Cloud, at: None }, 0),
        ("wished_local", Event::Wished { to: MoveTo::Local, at: None }, 0),
        ("turn_stopped", Event::TurnStopped, 0),
        ("gave", Event::Gave { epoch: SAMPLE_EPOCH + 1 }, 0),
        ("give_not_copied", give_failed(GiveFailure::NotCopied), 0),
        ("give_no_move", give_failed(GiveFailure::NoMove), 0),
        ("give_refused", give_failed(GiveFailure::Refused), 0),
        ("give_lost", give_failed(GiveFailure::Lost), 0),
        ("give_unanswered", give_failed(GiveFailure::Unanswered), 0),
        ("give_stuck", give_failed(GiveFailure::Stuck), 0),
    ]
}

/// One pair's outcome as the table writes it: the state the chat moves to, then its effects in
/// order; `-` when the chat stays in its state and the daemon does nothing.
fn outcome(from: &str, to: &str, effects: &[Effect]) -> String {
    let effects: Vec<String> = effects.iter().map(Effect::label).collect();
    match (from == to, effects.is_empty()) {
        (true, true) => "-".to_owned(),
        (false, true) => to.to_owned(),
        (true | false, false) => format!("{to}: {}", effects.join(", ")),
    }
}

/// The whole transition table as data: every sample state against every sample event. It is
/// one object per state, with one line per event: what [`step`] answers for that pair.
pub fn table() -> Value {
    let chats = sample_chats();
    let events = sample_events();
    let mut transitions = Map::new();
    for (from, chat) in &chats {
        let mut row = Map::new();
        for (event_name, event, after) in &events {
            let (next, effects) = step(*chat, *event, SAMPLE_AT + after);
            let cell = outcome(from, name(&next), &effects);
            row.insert((*event_name).to_owned(), Value::String(cell));
        }
        transitions.insert((*from).to_owned(), Value::Object(row));
    }
    let states: Vec<Value> = chats
        .iter()
        .map(|(state, chat)| {
            json!({
                "state": state,
                "side": chat.side().as_str(),
                "here": chat.here(),
                "mayRun": chat.may_run(),
            })
        })
        .collect();
    let side = |side: Side| {
        chats
            .iter()
            .filter(|(_, chat)| chat.side() == side)
            .map(|(name, _)| *name)
            .collect::<Vec<_>>()
    };
    json!({
        "version": 1,
        "source": "cmux-tui/crates/cmux-auto-session/src/holder.rs",
        "design": "plans/cmux-next/auto-mode/DESIGN.md",
        "samples": "Each sample chat is idle. It holds or last heard of epoch 4, stored snapshot 3, awaits the answer to request 7 where it awaits one, and was last stepped when that request was sent. The store has its newest copy (number 5) and was told the chat is idle; serving_uncopied is a serving machine whose copy 5 is still on its way, so the store was told it is at work. giving_* is a laptop that gives its chat to the Cloud and returning_* a machine that gives it to a laptop, at each step of the give (stopping its turn, copying, asking the store); the copy of the two copying samples is on its way. gave names epoch 5. answered_closed and closed name epoch 5, their after_another_holder rows epoch 7. An event's row happens 0 ms later unless its name says a time: tick_early 1 s, tick_renewal_due and streaming_after_5s at their period, tick_unanswered_35s and answered_holder_35s_late at SELF_STOP_MS, tick_after_clock_jump just past LEASE_MS.",
        "rules": [
            "The store answers a renewal with a role: holder (go on at the answer's epoch; to a standby's renewal, import first), standby, or lost (stop, then renew as standby).",
            "A Cloud machine tells the store it has nothing left to run only once the store has its newest copy. On that word the store gives the chat home to a laptop standing by, and answers the machine lost.",
            "A clock that jumped past LEASE_MS or went back is a wake: the chat is stepped with wake first, then with the event.",
            "A laptop that holds the chat and has had no renewal answered for SELF_STOP_MS stops its tree, whatever the event.",
            "Only the answer to the newest request counts; any other is ignored.",
            "Auto off for a stopped chat continues its tree only at the epoch one past the laptop's (nobody else held the chat since); at any other the tree is killed and what it wrote is kept.",
            "A move by hand is given by the chat's holder. A wish in the store's answer (or wished, when this daemon asked for the move) stops the turn that runs here (stop_turn), then stores a copy, then asks the store to take the chat (give): not_copied copies again and asks again. After gave a laptop stands by and a machine is away, in any state where it holds the chat: the answer to a give may come after the move was taken back, and at an epoch past the holder's it says the chat is another holder's. A give that does not happen leaves the chat here (stay), and a wish the store refused is not tried again until an answer comes without one, or with one the person asked at another time (asking again starts a wish's time again). not_moved tells the person, once for a wish, why the chat was not given: it is too large to copy, the store refused, or its turn did not stop.",
            "show_blocked goes out when the chat's blocked reason changed, schedule_at when its next tick moved; a tick always schedules the next one.",
        ],
        "laptop": side(Side::Laptop),
        "machine": side(Side::Machine),
        "states": states,
        "events": events.iter().map(|(name, _, _)| *name).collect::<Vec<_>>(),
        "reading": "transitions[state][event] is the state the chat moves to, then a colon and what the daemon does, in order. A dash is an event that means nothing there: the chat stays in its state and the daemon does nothing.",
        "transitions": transitions,
    })
}
