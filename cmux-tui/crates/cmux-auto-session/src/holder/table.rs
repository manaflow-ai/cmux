//! The transition table as data: every sample state against every sample event.

use serde_json::{Map, Value, json};

use super::{
    Answer, Change, Chat, Effect, Event, ImportReason, Sent, Side, State, Stop, Verdict, step,
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

/// A state's name in the table: its kind, with why a stopped laptop is stopped.
fn name(state: &State) -> &'static str {
    match state {
        State::Stopped { why: Stop::Wake, .. } => "stopped_wake",
        State::Stopped { why: Stop::Offline, .. } => "stopped_offline",
        other => other.kind(),
    }
}

/// One chat per state (two for `stopped`), by its name in the table. Each is idle and the store
/// was told so; it was last stepped at [`SAMPLE_AT`], when its last renewal was sent, and the
/// next one is due [`RENEW_MS`] later.
pub fn sample_chats() -> Vec<(&'static str, Chat)> {
    let epoch = SAMPLE_EPOCH;
    let awaiting = Some(Sent { request: SAMPLE_REQUEST, at: SAMPLE_AT });
    let due = Some(SAMPLE_AT + RENEW_MS);
    // (state, a renewal or registration awaits its answer, a tick is scheduled)
    let states = [
        (State::Off, false, false),
        (State::Registering, true, true),
        (State::Holding { epoch }, true, true),
        (State::Stopped { epoch, why: Stop::Wake }, true, true),
        (State::Stopped { epoch, why: Stop::Offline }, true, true),
        (State::Standby { epoch }, true, true),
        (State::ComingHome { epoch, failed: false }, true, true),
        (State::Away, false, false),
        (State::Taking { epoch, reason: ImportReason::Takeover, failed: false }, false, true),
        (State::Serving { epoch }, true, true),
        (State::HandingBack { epoch, copy: SAMPLE_COPY }, true, true),
        (State::Releasing { epoch }, false, true),
    ];
    states
        .into_iter()
        .map(|(state, awaits, scheduled)| {
            let chat = Chat {
                state,
                snapshot: SAMPLE_SNAPSHOT,
                copies: SAMPLE_COPY,
                copied_at: SAMPLE_AT,
                requests: SAMPLE_REQUEST,
                awaiting: if awaits { awaiting } else { None },
                renew_at: if scheduled { due } else { None },
                ..Chat::new(state.side(), SAMPLE_AT)
            };
            (name(&state), chat)
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
    };
    let holder = answer(Verdict::Holder, SAMPLE_EPOCH, SAMPLE_SNAPSHOT);
    let answered = |answer| Event::Answered { request: SAMPLE_REQUEST, answer };
    let assigned = |kind, epoch| Event::Assigned { kind, epoch };
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
        (
            "answered_holder_new_epoch_newer_copy",
            answered(answer(Verdict::Holder, SAMPLE_EPOCH + 2, SAMPLE_SNAPSHOT + 1)),
            0,
        ),
        ("answered_holder_35s_late", answered(holder), SELF_STOP_MS),
        ("answered_standby", answered(answer(Verdict::Standby, SAMPLE_EPOCH + 1, 0)), 0),
        ("answered_lost", answered(answer(Verdict::Lost, SAMPLE_EPOCH + 1, 0)), 0),
        ("answered_closed", answered(answer(Verdict::Closed, 0, 0)), 0),
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
        ("released", Event::Released, 0),
        ("closed", Event::Closed, 0),
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
            let cell = outcome(from, name(&next.state), &effects);
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
        "samples": "Each sample chat is idle and the store was told so. It holds or last heard of epoch 4, stored snapshot 3, awaits the answer to request 7 where it awaits one, and was last stepped when that request was sent. An event's row happens 0 ms later unless its name says a time: tick_early 1 s, tick_renewal_due and streaming_after_5s at their period, tick_unanswered_35s and answered_holder_35s_late at SELF_STOP_MS, tick_after_clock_jump just past LEASE_MS.",
        "rules": [
            "A clock that jumped past LEASE_MS or went back is a wake: the chat is stepped with wake first, then with the event.",
            "A laptop that holds the chat and has had no renewal answered for SELF_STOP_MS stops its tree, whatever the event.",
            "Only the answer to the newest request counts; any other is ignored.",
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
