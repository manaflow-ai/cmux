//! A laptop's states: `off`, `registering`, `holding`, `stopped`, `standby`, `coming_home`,
//! `giving`. One function per state, every event written out.

use super::out::Out;
use super::{
    Answer, CopyState, Effect, Event, GiveStep, ImportReason, MoveTo, State, Stop, Verdict, give,
};
use crate::consts::SELF_STOP_MS;

/// Another holder runs the chat: kill what ran here, keep what it wrote since the last
/// acknowledged copy, and stand by.
fn lose(out: &mut Out, epoch: u64, now: u64) {
    out.push(Effect::KillTree);
    out.push(Effect::WriteLeftoverPatch);
    out.chat.needs_run = false;
    give::forget(out);
    out.to(State::Standby { epoch });
    out.renew(now);
}

/// The store took a give of this chat, and the chat's epoch is `at` since. The answer is true
/// whenever it arrives, also after the laptop left the give it asked with: past the epoch this
/// laptop holds, the chat is another holder's, as a renewal answered "lost" says. At that
/// epoch or below, the answer is to a give from before this laptop got the chat back.
fn gave(out: &mut Out, epoch: u64, at: u64, now: u64) {
    if at > epoch {
        lose(out, at, now);
    }
}

/// Auto is off for the chat.
fn close(out: &mut Out) {
    give::forget(out);
    out.to(State::Off);
    out.rest();
}

/// Auto went off while the tree was stopped; `at` is the chat's epoch in the store. A close
/// moves the epoch one past its holder's, so one past this laptop's says nobody else held the
/// chat since: the tree is the whole chat and goes on. At any other epoch another holder ran
/// the chat, or the answer named none: the tree may be behind, so it is killed and what it
/// wrote is kept.
fn closed_while_stopped(out: &mut Out, epoch: u64, at: u64) {
    if at == epoch.saturating_add(1) {
        out.push(Effect::ContinueTree);
    } else {
        out.push(Effect::KillTree);
        out.push(Effect::WriteLeftoverPatch);
    }
    close(out);
}

/// The store gave the chat to this laptop with a copy this laptop does not have: bring it in.
fn come_home(out: &mut Out, epoch: u64) {
    out.to(State::ComingHome { epoch, failed: false });
    out.push(Effect::Import { reason: ImportReason::Handback, epoch });
}

/// The store says this laptop holds the chat, which it held before: go on, at the answer's
/// epoch. At a new epoch the store had parked the chat when this laptop's lease ran out. It
/// gives a parked chat back as it is only to the laptop that held it last, so nobody ran it
/// since; after any other holder, this renewal is answered "lost".
///
/// A wish in the answer comes first: the person moved the chat, so it is given, and whoever
/// gets it takes the inbox. A tree that was stopped is continued and the give begins in the
/// same step, so nothing of the chat starts here in between: a give this laptop asked before
/// it stopped may still reach the store, and a turn that went on here meanwhile would run
/// beside the same turn where the chat went.
fn held_again(out: &mut Out, answer: Answer, stopped: bool) {
    if stopped {
        out.push(Effect::ContinueTree);
    }
    out.to(State::Holding { epoch: answer.epoch });
    if let Some(to) = give::wanted(out, answer.wish, answer.wish_at) {
        return give::begin(out, answer.epoch, to);
    }
    if answer.inbox_pending {
        out.push(Effect::DrainInbox);
    }
}

/// The person asked this daemon to move the chat it holds, and the store took the wish at
/// `at`: a new wish, whatever was refused before.
fn wished(out: &mut Out, epoch: u64, to: MoveTo, at: Option<u64>) {
    give::forget(out);
    if let Some(to) = give::wanted(out, Some(to), at) {
        give::begin(out, epoch, to);
    }
}

pub(super) fn off(out: &mut Out, event: Event, now: u64) {
    match event {
        Event::AutoOn => {
            out.to(State::Registering);
            out.register(now);
        }
        Event::Changed { needs_run, .. } => out.chat.needs_run = needs_run,
        Event::AutoOff
        | Event::Tick
        | Event::Wake
        | Event::Answered { .. }
        | Event::Unanswered { .. }
        | Event::Assigned { .. }
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

pub(super) fn registering(out: &mut Out, event: Event, now: u64) {
    match event {
        // The registration may have reached the store, so it is closed there too.
        Event::AutoOff => {
            out.push(Effect::Close);
            close(out);
        }
        Event::Tick => {
            if out.due(now) {
                out.register(now);
            }
        }
        Event::Wake => out.register(now),
        Event::Changed { needs_run, .. } => out.chat.needs_run = needs_run,
        Event::Answered { request, answer } => {
            let Some(sent_at) = out.answered(request) else { return };
            match answer.verdict {
                // The first copy goes at once: until the store has one, a lapsed lease parks.
                Verdict::Holder => {
                    out.chat.fresh_at = sent_at;
                    out.to(State::Holding { epoch: answer.epoch });
                    out.copy(now);
                }
                // The store knows this chat as another holder's.
                Verdict::Standby | Verdict::Lost => lose(out, answer.epoch, now),
                Verdict::Closed => close(out),
            }
        }
        Event::Unanswered { request } => {
            out.answered(request);
        }
        Event::Closed { .. } => close(out),
        Event::AutoOn
        | Event::Assigned { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::SnapshotStored { .. }
        | Event::SnapshotFailed { .. }
        | Event::Wished { .. }
        | Event::TurnStopped
        | Event::Gave { .. }
        | Event::GiveFailed { .. } => {}
    }
}

pub(super) fn holding(out: &mut Out, epoch: u64, event: Event, now: u64) {
    match event {
        Event::AutoOff => out.push(Effect::Close),
        // Replicate a running chat even when it emits nothing, and retry failed copies.
        Event::Tick => {
            if out.due(now) {
                out.checkpoint(now);
                out.renew(now);
            }
        }
        // Stop first, then ask. The answer continues the tree or kills it.
        Event::Wake => {
            out.push(Effect::StopTree);
            out.to(State::Stopped { epoch, why: Stop::Wake });
            out.renew(now);
        }
        Event::Changed { change, needs_run } => out.work_changed(change, needs_run, now),
        Event::Answered { request, answer } => {
            let Some(sent_at) = out.answered(request) else { return };
            match answer.verdict {
                Verdict::Holder => {
                    out.chat.fresh_at = out.chat.fresh_at.max(sent_at);
                    out.renew_answered(sent_at, now);
                    held_again(out, answer, false);
                }
                Verdict::Standby | Verdict::Lost => lose(out, answer.epoch.max(epoch), now),
                Verdict::Closed => close(out),
            }
        }
        Event::Unanswered { request } => {
            if out.answered(request).is_some() {
                out.renew_unanswered(now);
            }
        }
        Event::SnapshotStored { copy, snapshot } => {
            out.stored(copy, snapshot);
            out.renew_if_work_changed(now);
        }
        Event::SnapshotFailed { copy, too_large } => {
            out.failed(copy, too_large);
            out.renew_if_work_changed(now);
        }
        Event::Closed { .. } => close(out),
        Event::Wished { to, at } => wished(out, epoch, to, at),
        // A give this laptop asked before the move was taken back, answered only now.
        Event::Gave { epoch: at } => gave(out, epoch, at, now),
        Event::AutoOn
        | Event::Assigned { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::TurnStopped
        | Event::GiveFailed { .. } => {}
    }
}

/// This laptop holds the chat and gives it to where the person moved it (`give.rs`). It is the
/// holder until the store took the chat, so it renews, and it stands by after.
pub(super) fn giving(
    out: &mut Out,
    epoch: u64,
    step: GiveStep,
    to: MoveTo,
    event: Event,
    now: u64,
) {
    match event {
        Event::AutoOff => out.push(Effect::Close),
        Event::Tick => give::tick(out, epoch, step, to, now),
        // The store was asked to take the chat and may have: the give is not over until it
        // or the renewal answers, so nothing of the chat starts here meanwhile. A turn that
        // went on here now would run beside the same turn on the machine that got the chat.
        Event::Wake if step == GiveStep::Asking => out.renew(now),
        // Stop first, then ask, as a laptop that holds does. Nothing was asked of the store
        // yet, so the give is over: the answer says whether the chat is still here, and a
        // wish in it starts another.
        Event::Wake => {
            out.push(Effect::StopTree);
            out.push(Effect::Stay);
            out.to(State::Stopped { epoch, why: Stop::Wake });
            out.renew(now);
        }
        Event::Changed { needs_run, .. } => out.chat.needs_run = needs_run,
        Event::Answered { request, answer } => {
            let Some(sent_at) = out.answered(request) else { return };
            match answer.verdict {
                // Still the holder. With no wish left the person took the move back, or it
                // waited too long: the chat goes on here. A wish goes on as the store tells it
                // now: its epoch, and where the chat goes.
                Verdict::Holder => {
                    out.chat.fresh_at = out.chat.fresh_at.max(sent_at);
                    match answer.wish {
                        Some(to) => {
                            give::told(out, answer.wish_at);
                            out.to(State::Giving { epoch: answer.epoch, step, to });
                        }
                        None => {
                            out.push(Effect::Stay);
                            held_again(out, answer, false);
                        }
                    }
                }
                Verdict::Standby | Verdict::Lost => lose(out, answer.epoch.max(epoch), now),
                Verdict::Closed => {
                    out.push(Effect::Stay);
                    close(out);
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
        // The chat is another holder's: what ran here is killed and this laptop stands by. At
        // any step: a give asked before this one may be answered in the middle of it.
        Event::Gave { epoch: at } => gave(out, epoch, at, now),
        Event::GiveFailed { why } => give::failed(out, epoch, step, to, why, now),
        Event::Closed { .. } => {
            out.push(Effect::Stay);
            close(out);
        }
        Event::AutoOn
        | Event::Assigned { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::Wished { .. } => {}
    }
}

pub(super) fn stopped(out: &mut Out, epoch: u64, event: Event, now: u64) {
    match event {
        Event::AutoOff => out.push(Effect::Close),
        // A whole period with no answer: the chat waits for the network.
        Event::Tick => {
            if out.due(now) {
                out.to(State::Stopped { epoch, why: Stop::Offline });
                out.renew(now);
            }
        }
        Event::Wake => out.renew(now),
        Event::Changed { needs_run, .. } => out.chat.needs_run = needs_run,
        Event::Answered { request, answer } => {
            let Some(sent_at) = out.answered(request) else { return };
            match answer.verdict {
                // An answer this old does not show the lease still runs: ask again.
                Verdict::Holder if now >= sent_at.saturating_add(SELF_STOP_MS) => out.renew(now),
                Verdict::Holder => {
                    out.chat.fresh_at = sent_at;
                    out.renew_answered(sent_at, now);
                    held_again(out, answer, true);
                }
                Verdict::Standby | Verdict::Lost => lose(out, answer.epoch.max(epoch), now),
                Verdict::Closed => closed_while_stopped(out, epoch, answer.epoch),
            }
        }
        Event::Unanswered { request } => {
            if out.answered(request).is_some() {
                out.to(State::Stopped { epoch, why: Stop::Offline });
                out.renew_unanswered(now);
            }
        }
        Event::SnapshotStored { copy, snapshot } => {
            out.stored(copy, snapshot);
        }
        Event::SnapshotFailed { copy, too_large } => out.failed(copy, too_large),
        Event::Closed { epoch: at } => closed_while_stopped(out, epoch, at),
        // A give asked before the tree was stopped, answered only now.
        Event::Gave { epoch: at } => gave(out, epoch, at, now),
        // A chat whose tree is stopped is not given: the store's answer comes first, and a
        // wish it still tells then starts the give.
        Event::AutoOn
        | Event::Assigned { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::Wished { .. }
        | Event::TurnStopped
        | Event::GiveFailed { .. } => {}
    }
}

pub(super) fn standby(out: &mut Out, epoch: u64, event: Event, now: u64) {
    match event {
        // The store refuses while a machine holds the chat; the daemon tells the person.
        Event::AutoOff => out.push(Effect::Close),
        Event::Tick => {
            if out.due(now) {
                out.renew(now);
            }
        }
        Event::Wake => out.renew(now),
        Event::Changed { needs_run, .. } => out.chat.needs_run = needs_run,
        Event::Answered { request, answer } => {
            let Some(sent_at) = out.answered(request) else { return };
            match answer.verdict {
                // The handback: import, then hold.
                Verdict::Holder => {
                    out.chat.fresh_at = sent_at;
                    come_home(out, answer.epoch);
                }
                Verdict::Standby | Verdict::Lost => {
                    out.to(State::Standby { epoch: answer.epoch.max(epoch) });
                }
                Verdict::Closed => close(out),
            }
        }
        Event::Unanswered { request } => {
            out.answered(request);
        }
        Event::Closed { .. } => close(out),
        // A move is given by the chat's holder. This laptop hears of it at its next renewal.
        Event::AutoOn
        | Event::Assigned { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::SnapshotStored { .. }
        | Event::SnapshotFailed { .. }
        | Event::Wished { .. }
        | Event::TurnStopped
        | Event::Gave { .. }
        | Event::GiveFailed { .. } => {}
    }
}

pub(super) fn coming_home(out: &mut Out, epoch: u64, failed: bool, event: Event, now: u64) {
    match event {
        Event::AutoOff => out.push(Effect::Close),
        // The laptop is the holder while it imports, so it renews; a failed import tries again.
        Event::Tick => {
            if out.due(now) {
                if failed {
                    come_home(out, epoch);
                }
                out.renew(now);
            }
        }
        Event::Wake => out.renew(now),
        Event::Changed { needs_run, .. } => out.chat.needs_run = needs_run,
        Event::Answered { request, answer } => {
            let Some(sent_at) = out.answered(request) else { return };
            match answer.verdict {
                Verdict::Holder => {
                    out.chat.fresh_at = sent_at;
                    // Parked and granted again while importing: import at the new epoch.
                    if answer.epoch != epoch {
                        come_home(out, answer.epoch);
                    }
                }
                // Nothing runs here yet, so there is nothing to kill.
                Verdict::Standby | Verdict::Lost => {
                    out.to(State::Standby { epoch: answer.epoch.max(epoch) });
                    out.renew(now);
                }
                Verdict::Closed => close(out),
            }
        }
        Event::Unanswered { request } => {
            out.answered(request);
        }
        Event::ImportDone { epoch: done, snapshot } => {
            // An import that finished after the lease may have gone to another holder is not
            // accepted: ask the store again and keep the chat frozen until it answers.
            if done == epoch && now >= out.chat.fresh_at.saturating_add(SELF_STOP_MS) {
                out.to(State::ComingHome { epoch, failed: true });
                out.renew(now);
            } else if done == epoch {
                out.chat.snapshot = out.chat.snapshot.max(snapshot);
                out.chat.too_large = false;
                out.to(State::Holding { epoch });
                // The store counts the Cloud copy as the only one until this laptop stores a
                // copy of its own: that is how it learns the import is done, and from then on
                // Auto off is allowed and a lapsed lease parks the chat as this laptop's.
                out.copy(now);
                // The answer says whether the inbox has messages to drain.
                out.renew(now);
            }
        }
        Event::ImportFailed { epoch: tried } => {
            if tried == epoch {
                out.to(State::ComingHome { epoch, failed: true });
            }
        }
        Event::Closed { .. } => close(out),
        Event::AutoOn
        | Event::Assigned { .. }
        | Event::SnapshotStored { .. }
        | Event::SnapshotFailed { .. }
        | Event::Wished { .. }
        | Event::TurnStopped
        | Event::Gave { .. }
        | Event::GiveFailed { .. } => {}
    }
}
