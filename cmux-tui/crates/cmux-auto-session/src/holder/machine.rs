//! A Cloud machine's states: `away`, `taking`, `serving`, `handing_back`, `releasing`.
//! One function per state, every event written out.
//!
//! A machine's lease does not run out to another holder (a paused machine is not a lost one),
//! so a machine never stops itself and a wake only renews.

use super::out::Out;
use super::{Answer, Effect, Event, ImportReason, State, Verdict};
use crate::wire::AssignmentKind;

/// The chat is not this machine's any more.
fn leave(out: &mut Out) {
    out.chat.needs_run = false;
    out.chat.told_needs_run = false;
    out.to(State::Away);
    out.rest();
}

/// Another holder has the chat while this machine thought it ran it: kill what ran here and
/// keep what it wrote since the last acknowledged copy.
fn gone(out: &mut Out) {
    out.push(Effect::KillTree);
    out.push(Effect::WriteLeftoverPatch);
    leave(out);
}

/// The store assigned the chat at `epoch`: import it. A tick tries a failed import again.
fn take(out: &mut Out, kind: AssignmentKind, epoch: u64, now: u64) {
    let reason = ImportReason::from(kind);
    out.rest();
    out.to(State::Taking { epoch, reason, failed: false });
    out.push(Effect::Import { reason, epoch });
    out.tick_in_a_period(now);
}

/// An assignment for a chat this machine runs at `epoch`. A newer epoch means the chat left
/// and came back, so what is here is stale. The same epoch is a repeat of the assignment this
/// machine already imported (its ack was lost), or a delivery.
fn assigned_while_running(out: &mut Out, epoch: u64, kind: AssignmentKind, at: u64, now: u64) {
    if at > epoch {
        out.push(Effect::KillTree);
        out.push(Effect::WriteLeftoverPatch);
        take(out, kind, at, now);
    } else if at == epoch {
        if kind == AssignmentKind::Deliver {
            out.to(State::Serving { epoch });
            out.push(Effect::DrainInbox);
        }
        out.push(Effect::AckAssignment { epoch });
    }
}

/// The store says this machine holds the chat. Messages come first; with none, a laptop
/// standing by and no work here, the chat goes home: copy, then release.
fn served(out: &mut Out, answer: Answer, now: u64) {
    let epoch = answer.epoch;
    out.to(State::Serving { epoch });
    if answer.inbox_pending {
        out.push(Effect::DrainInbox);
    } else if answer.handback_due && !out.chat.needs_run && !out.chat.too_large {
        let copy = out.copy(now);
        out.to(State::HandingBack { epoch, copy });
    }
}

pub(super) fn away(out: &mut Out, event: Event, now: u64) {
    match event {
        Event::Assigned { kind, epoch } => take(out, kind, epoch, now),
        Event::Changed { needs_run, .. } => out.chat.needs_run = needs_run,
        Event::AutoOn
        | Event::AutoOff
        | Event::Tick
        | Event::Wake
        | Event::Answered { .. }
        | Event::Unanswered { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::SnapshotStored { .. }
        | Event::SnapshotFailed { .. }
        | Event::Released
        | Event::Closed => {}
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
        Event::Changed { needs_run, .. } => out.chat.needs_run = needs_run,
        // Import, ack, then renew as holder. A takeover or a create may come with messages.
        Event::ImportDone { epoch: done, snapshot } => {
            if done == epoch {
                out.chat.snapshot = out.chat.snapshot.max(snapshot);
                out.to(State::Serving { epoch });
                out.push(Effect::AckAssignment { epoch });
                out.push(Effect::DrainInbox);
                out.renew(now);
            }
        }
        Event::ImportFailed { epoch: tried } => {
            if tried == epoch {
                out.to(State::Taking { epoch, reason, failed: true });
            }
        }
        Event::Closed => leave(out),
        Event::AutoOn
        | Event::AutoOff
        | Event::Answered { .. }
        | Event::Unanswered { .. }
        | Event::SnapshotStored { .. }
        | Event::SnapshotFailed { .. }
        | Event::Released => {}
    }
}

pub(super) fn serving(out: &mut Out, epoch: u64, event: Event, now: u64) {
    match event {
        Event::Assigned { kind, epoch: at } => assigned_while_running(out, epoch, kind, at, now),
        Event::Tick => {
            if out.due(now) {
                out.renew(now);
            }
        }
        Event::Wake => out.renew(now),
        Event::Changed { change, needs_run } => out.work_changed(change, needs_run, now),
        Event::Answered { request, answer } => {
            if out.answered(request).is_some() {
                match answer.verdict {
                    Verdict::Holder => served(out, answer, now),
                    Verdict::Standby | Verdict::Lost | Verdict::Closed => gone(out),
                }
            }
        }
        Event::Unanswered { request } => {
            out.answered(request);
        }
        Event::SnapshotStored { snapshot, .. } => {
            out.chat.snapshot = out.chat.snapshot.max(snapshot);
            out.chat.too_large = false;
        }
        Event::SnapshotFailed { too_large, .. } => out.chat.too_large |= too_large,
        Event::Closed => gone(out),
        Event::AutoOn
        | Event::AutoOff
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::Released => {}
    }
}

pub(super) fn handing_back(out: &mut Out, epoch: u64, copy: u64, event: Event, now: u64) {
    match event {
        Event::Assigned { kind, epoch: at } => assigned_while_running(out, epoch, kind, at, now),
        Event::Tick => {
            if out.due(now) {
                out.renew(now);
            }
        }
        Event::Wake => out.renew(now),
        // New work ends the handback. Any other change makes the copy on its way an old one.
        Event::Changed { change, needs_run } => {
            if needs_run {
                out.to(State::Serving { epoch });
                out.work_changed(change, needs_run, now);
            } else {
                out.chat.needs_run = false;
                let copy = out.copy(now);
                out.to(State::HandingBack { epoch, copy });
            }
        }
        Event::Answered { request, answer } => {
            if out.answered(request).is_some() {
                match answer.verdict {
                    // Still due, and no message came: the copy goes on.
                    Verdict::Holder if answer.handback_due && !answer.inbox_pending => {
                        out.to(State::HandingBack { epoch: answer.epoch, copy });
                    }
                    Verdict::Holder => {
                        out.to(State::Serving { epoch: answer.epoch });
                        if answer.inbox_pending {
                            out.push(Effect::DrainInbox);
                        }
                    }
                    Verdict::Standby | Verdict::Lost | Verdict::Closed => gone(out),
                }
            }
        }
        Event::Unanswered { request } => {
            out.answered(request);
        }
        Event::SnapshotStored { copy: stored, snapshot } => {
            out.chat.snapshot = out.chat.snapshot.max(snapshot);
            out.chat.too_large = false;
            if stored == copy {
                out.rest();
                out.to(State::Releasing { epoch });
                out.push(Effect::Release { epoch });
                out.tick_in_a_period(now);
            }
        }
        // The next answered renewal starts the handback again, unless the chat is too large.
        Event::SnapshotFailed { copy: tried, too_large } => {
            out.chat.too_large |= too_large;
            if tried == copy {
                out.to(State::Serving { epoch });
            }
        }
        Event::Closed => gone(out),
        Event::AutoOn
        | Event::AutoOff
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::Released => {}
    }
}

pub(super) fn releasing(out: &mut Out, epoch: u64, event: Event, now: u64) {
    match event {
        // The chat is another holder's now, and it was idle: nothing to keep.
        Event::Released | Event::Closed => {
            out.push(Effect::KillTree);
            leave(out);
        }
        // The release was taken and the chat came back.
        Event::Assigned { kind, epoch: at } => {
            if at > epoch {
                out.push(Effect::KillTree);
                take(out, kind, at, now);
            }
        }
        // No answer yet: send it again.
        Event::Tick => {
            if out.due(now) {
                out.push(Effect::Release { epoch });
                out.tick_in_a_period(now);
            }
        }
        Event::Wake => {
            out.push(Effect::Release { epoch });
            out.tick_in_a_period(now);
        }
        Event::Changed { needs_run, .. } => out.chat.needs_run = needs_run,
        Event::SnapshotStored { snapshot, .. } => {
            out.chat.snapshot = out.chat.snapshot.max(snapshot);
        }
        // No renewal is awaited while releasing.
        Event::AutoOn
        | Event::AutoOff
        | Event::Answered { .. }
        | Event::Unanswered { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::SnapshotFailed { .. } => {}
    }
}
