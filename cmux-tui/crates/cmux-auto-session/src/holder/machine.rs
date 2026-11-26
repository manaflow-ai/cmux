//! A Cloud machine's states: `away`, `taking`, `serving`. One function per state, every event
//! written out.
//!
//! A machine never stops itself and a wake only renews: the store does not take a chat from a
//! machine that is at work or has something uncopied, however long it is quiet.
//!
//! The handback is the store's move. It gives the chat home to a laptop standing by at the
//! machine's renewal that says nothing is left to run, once the inbox and the assignment are
//! acked and the newest snapshot covers the last event; the machine's answer is "lost". So a
//! machine says "nothing left to run" only once the store has its last copy, and says "at
//! work" before it acks a message, so the store never gives away a chat whose last word is
//! only here.
//!
//! A move by hand is the machine's to give (`returning`, `give.rs`): it stops its turn, stores
//! its last copy and asks the store to take the chat, and has lost the chat once the store did.

use super::out::Out;
use super::{
    Answer, CopyState, Effect, Event, GiveStep, ImportReason, MoveTo, State, Verdict, give,
};
use crate::wire::AssignmentKind;

/// The chat is not this machine's any more.
fn leave(out: &mut Out) {
    out.chat.declined = false;
    out.chat.needs_run = false;
    out.chat.told_needs_run = false;
    out.chat.copy = CopyState::Stored;
    out.to(State::Away);
    out.rest();
}

/// Another holder has the chat while this machine ran it or had something uncopied: kill what
/// ran here and keep what it wrote since the last acknowledged copy.
fn gone(out: &mut Out) {
    out.push(Effect::KillTree);
    out.push(Effect::WriteLeftoverPatch);
    leave(out);
}

/// The store answered "lost". With nothing left to run and the last copy stored, this is the
/// handback: the laptop has everything, so there is nothing to keep. Otherwise the chat was
/// taken from under this machine.
fn lost(out: &mut Out) {
    if !out.chat.needs_run && out.chat.copy == CopyState::Stored {
        out.push(Effect::KillTree);
        leave(out);
    } else {
        gone(out);
    }
}

/// The store assigned the chat at `epoch`: import it. A tick tries a failed import again.
fn take(out: &mut Out, kind: AssignmentKind, epoch: u64, now: u64) {
    let reason = ImportReason::from(kind);
    out.rest();
    out.chat.declined = false;
    out.chat.needs_run = false;
    out.chat.told_needs_run = false;
    out.chat.copy = CopyState::Stored;
    out.to(State::Taking { epoch, reason, failed: false });
    out.push(Effect::Import { reason, epoch });
    out.tick_in_a_period(now);
}

/// Messages wait for the chat this machine runs at `epoch`: take them, then ack what the store
/// assigned (it keeps a `deliver` while a message is unread). The messages are work, and until
/// the next copy they are only here, so the store hears "at work" before they are acked.
fn drain(out: &mut Out, epoch: u64, now: u64) {
    out.chat.needs_run = true;
    if !out.chat.told_needs_run {
        out.renew(now);
    }
    out.push(Effect::DrainInbox);
    out.push(Effect::AckAssignment { epoch });
}

/// An assignment for a chat this machine runs at `epoch`. A newer epoch means the chat left
/// and came back, so what is here is stale. The same epoch is a delivery, or a repeat of the
/// assignment this machine already imported (its ack was lost).
fn assigned_while_running(out: &mut Out, epoch: u64, kind: AssignmentKind, at: u64, now: u64) {
    if at > epoch {
        out.push(Effect::KillTree);
        out.push(Effect::WriteLeftoverPatch);
        take(out, kind, at, now);
    } else if at == epoch {
        match kind {
            AssignmentKind::Deliver => drain(out, epoch, now),
            AssignmentKind::Takeover | AssignmentKind::Create => {
                out.push(Effect::AckAssignment { epoch });
            }
        }
    }
}

/// The store says this machine holds the chat. Messages come first. With none, a laptop
/// standing by and the store already told that nothing is left to run, the store's snapshot
/// does not cover its last event: one more copy does, and the renewal after it gives the chat
/// home.
fn served(out: &mut Out, answer: Answer, now: u64) {
    let epoch = answer.epoch;
    out.to(State::Serving { epoch });
    // The person moved the chat: it is given, and whoever gets it takes the inbox.
    if let Some(to) = give::wanted(out, answer.wish) {
        return give::begin(out, epoch, to);
    }
    if answer.inbox_pending {
        drain(out, epoch, now);
        return;
    }
    let idle = !out.chat.needs_run && !out.chat.told_needs_run;
    if answer.handback_due && idle && out.chat.copy == CopyState::Stored && !out.chat.too_large {
        out.copy(now);
    }
}

pub(super) fn away(out: &mut Out, event: Event, now: u64) {
    match event {
        Event::Assigned { kind, epoch } => take(out, kind, epoch, now),
        Event::AutoOn
        | Event::AutoOff
        | Event::Tick
        | Event::Wake
        | Event::Changed { .. }
        | Event::Answered { .. }
        | Event::Unanswered { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::SnapshotStored { .. }
        | Event::SnapshotFailed { .. }
        | Event::Closed { .. }
        | Event::Wished { .. }
        | Event::TurnStopped
        | Event::Gave { .. }
        | Event::GiveFailed { .. } => {}
    }
}

pub(super) fn taking(
    out: &mut Out,
    epoch: u64,
    reason: ImportReason,
    failed: bool,
    event: Event,
    now: u64,
) {
    match event {
        // The assignment stays until it is acked, so the reader sees it again: only a newer
        // one starts over.
        Event::Assigned { kind, epoch: at } => {
            if at > epoch {
                take(out, kind, at, now);
            }
        }
        Event::Tick => {
            if out.due(now) {
                if failed {
                    out.to(State::Taking { epoch, reason, failed: false });
                    out.push(Effect::Import { reason, epoch });
                }
                out.tick_in_a_period(now);
            }
        }
        Event::Wake => out.tick_in_a_period(now),
        // Nothing runs here before the import is done.
        Event::Changed { .. } => {}
        // The store gave the chat here because it has work: a turn to go on with, a first
        // message, or messages nobody read. Take the messages, ack, then renew as holder, at
        // work until the chat's next change says otherwise.
        Event::ImportDone { epoch: done, snapshot } => {
            if done == epoch {
                out.chat.snapshot = out.chat.snapshot.max(snapshot);
                out.chat.needs_run = true;
                out.to(State::Serving { epoch });
                out.push(Effect::DrainInbox);
                out.push(Effect::AckAssignment { epoch });
                out.renew(now);
            }
        }
        Event::ImportFailed { epoch: tried } => {
            if tried == epoch {
                out.to(State::Taking { epoch, reason, failed: true });
            }
        }
        Event::Closed { .. } => leave(out),
        Event::AutoOn
        | Event::AutoOff
        | Event::Answered { .. }
        | Event::Unanswered { .. }
        | Event::SnapshotStored { .. }
        | Event::SnapshotFailed { .. }
        | Event::Wished { .. }
        | Event::TurnStopped
        | Event::Gave { .. }
        | Event::GiveFailed { .. } => {}
    }
}

pub(super) fn serving(out: &mut Out, epoch: u64, event: Event, now: u64) {
    match event {
        Event::Assigned { kind, epoch: at } => assigned_while_running(out, epoch, kind, at, now),
        // An idle chat whose last copy failed is copied again: until the store has it, the
        // chat cannot go home.
        Event::Tick => {
            if out.due(now) {
                let failed = out.chat.copy == CopyState::Failed;
                if failed && !out.chat.needs_run && !out.chat.too_large {
                    out.copy(now);
                }
                out.renew(now);
            }
        }
        Event::Wake => out.renew(now),
        Event::Changed { change, needs_run } => out.work_changed(change, needs_run, now),
        Event::Answered { request, answer } => {
            if out.answered(request).is_some() {
                match answer.verdict {
                    Verdict::Holder => served(out, answer, now),
                    Verdict::Lost => lost(out),
                    Verdict::Standby | Verdict::Closed => gone(out),
                }
            }
        }
        Event::Unanswered { request } => {
            out.answered(request);
        }
        // Everything this machine did is in the Cloud copy. With nothing left to run it says
        // so at once: on that word the store gives the chat home to a laptop standing by.
        Event::SnapshotStored { copy, snapshot } => {
            if out.stored(copy, snapshot) && !out.chat.needs_run {
                out.renew(now);
            }
        }
        Event::SnapshotFailed { copy, too_large } => out.failed(copy, too_large),
        Event::Closed { .. } => gone(out),
        Event::Wished { to } => {
            out.chat.declined = false;
            if let Some(to) = give::wanted(out, Some(to)) {
                give::begin(out, epoch, to);
            }
        }
        Event::AutoOn
        | Event::AutoOff
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::TurnStopped
        | Event::Gave { .. }
        | Event::GiveFailed { .. } => {}
    }
}

/// This machine holds the chat and gives it to where the person moved it (`give.rs`). It is
/// the holder until the store took the chat, so it renews. Once the store did, the new holder
/// has everything this machine did: what ran here is killed and nothing is kept.
pub(super) fn returning(
    out: &mut Out,
    epoch: u64,
    step: GiveStep,
    to: MoveTo,
    event: Event,
    now: u64,
) {
    match event {
        // A newer assignment: the chat left and came back, so what is here is stale. One at
        // this epoch waits in the store for whoever holds the chat next.
        Event::Assigned { kind, epoch: at } => {
            if at > epoch {
                out.push(Effect::KillTree);
                out.push(Effect::WriteLeftoverPatch);
                take(out, kind, at, now);
            }
        }
        Event::Tick => give::tick(out, epoch, step, to, now),
        Event::Wake => out.renew(now),
        Event::Changed { needs_run, .. } => out.chat.needs_run = needs_run,
        Event::Answered { request, answer } => {
            if out.answered(request).is_some() {
                match answer.verdict {
                    // Still the holder. With no wish left the person took the move back, or
                    // it waited too long: the chat goes on here. A wish goes on as the store
                    // tells it now: its epoch, and where the chat goes.
                    Verdict::Holder => match answer.wish {
                        Some(to) => out.to(State::Returning { epoch: answer.epoch, step, to }),
                        None => {
                            out.push(Effect::Stay);
                            served(out, answer, now);
                        }
                    },
                    Verdict::Lost | Verdict::Standby | Verdict::Closed => gone(out),
                }
            }
        }
        Event::Unanswered { request } => {
            out.answered(request);
        }
        Event::TurnStopped => give::turn_stopped(out, epoch, step, to, now),
        Event::SnapshotStored { copy, snapshot } => {
            give::stored(out, epoch, step, to, copy, snapshot);
        }
        Event::SnapshotFailed { copy, too_large } => {
            give::copy_failed(out, epoch, to, copy, too_large);
        }
        Event::Gave { .. } => match step {
            GiveStep::Asking => {
                out.push(Effect::KillTree);
                leave(out);
            }
            GiveStep::Stopping | GiveStep::Copying => {}
        },
        Event::GiveFailed { why } => give::failed(out, epoch, step, to, why, now),
        Event::Closed { .. } => gone(out),
        Event::AutoOn
        | Event::AutoOff
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::Wished { .. } => {}
    }
}
