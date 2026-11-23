//! A laptop's states: `off`, `registering`, `holding`, `stopped`, `standby`, `coming_home`.
//! One function per state, every event written out.

use super::out::Out;
use super::{Answer, Effect, Event, ImportReason, State, Stop, Verdict};
use crate::consts::SELF_STOP_MS;

/// Another holder runs the chat: kill what ran here, keep what it wrote since the last
/// acknowledged copy, and stand by.
fn lose(out: &mut Out, epoch: u64, now: u64) {
    out.push(Effect::KillTree);
    out.push(Effect::WriteLeftoverPatch);
    out.chat.needs_run = false;
    out.to(State::Standby { epoch });
    out.renew(now);
}

/// Auto is off for the chat.
fn close(out: &mut Out) {
    out.to(State::Off);
    out.rest();
}

/// The store gave the chat to this laptop with a copy this laptop does not have: bring it in.
fn come_home(out: &mut Out, epoch: u64) {
    out.to(State::ComingHome { epoch, failed: false });
    out.push(Effect::Import { reason: ImportReason::Handback, epoch });
}

/// The store says this laptop holds the chat, which it held before. At a new epoch the store
/// had parked it. If another holder ran it since and left a newer copy, that copy is the chat
/// now: what ran here is killed and kept as a leftover patch.
fn held_again(out: &mut Out, epoch: u64, answer: Answer, stopped: bool) {
    if answer.epoch != epoch && answer.snapshot > out.chat.snapshot {
        out.push(Effect::KillTree);
        out.push(Effect::WriteLeftoverPatch);
        out.chat.needs_run = false;
        come_home(out, answer.epoch);
        return;
    }
    if stopped {
        out.push(Effect::ContinueTree);
    }
    out.to(State::Holding { epoch: answer.epoch });
    if answer.inbox_pending {
        out.push(Effect::DrainInbox);
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
        | Event::Released
        | Event::Closed => {}
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
        Event::Closed => close(out),
        Event::AutoOn
        | Event::Assigned { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::SnapshotStored { .. }
        | Event::SnapshotFailed { .. }
        | Event::Released => {}
    }
}

pub(super) fn holding(out: &mut Out, epoch: u64, event: Event, now: u64) {
    match event {
        Event::AutoOff => out.push(Effect::Close),
        Event::Tick => {
            if out.due(now) {
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
                    held_again(out, epoch, answer, false);
                }
                Verdict::Standby | Verdict::Lost => lose(out, answer.epoch.max(epoch), now),
                Verdict::Closed => close(out),
            }
        }
        Event::Unanswered { request } => {
            out.answered(request);
        }
        Event::SnapshotStored { snapshot, .. } => {
            out.chat.snapshot = out.chat.snapshot.max(snapshot);
            out.chat.too_large = false;
            out.renew_if_work_changed(now);
        }
        Event::SnapshotFailed { too_large, .. } => {
            out.chat.too_large |= too_large;
            out.renew_if_work_changed(now);
        }
        Event::Closed => close(out),
        Event::AutoOn
        | Event::Assigned { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::Released => {}
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
                    held_again(out, epoch, answer, true);
                }
                Verdict::Standby | Verdict::Lost => lose(out, answer.epoch.max(epoch), now),
                Verdict::Closed => {
                    out.push(Effect::ContinueTree);
                    close(out);
                }
            }
        }
        Event::Unanswered { request } => {
            if out.answered(request).is_some() {
                out.to(State::Stopped { epoch, why: Stop::Offline });
            }
        }
        Event::SnapshotStored { snapshot, .. } => {
            out.chat.snapshot = out.chat.snapshot.max(snapshot);
            out.chat.too_large = false;
        }
        Event::SnapshotFailed { too_large, .. } => out.chat.too_large |= too_large,
        // The store closes a chat only while no machine holds it, so this copy is the only one.
        Event::Closed => {
            out.push(Effect::ContinueTree);
            close(out);
        }
        Event::AutoOn
        | Event::Assigned { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::Released => {}
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
        Event::Closed => close(out),
        Event::AutoOn
        | Event::Assigned { .. }
        | Event::ImportDone { .. }
        | Event::ImportFailed { .. }
        | Event::SnapshotStored { .. }
        | Event::SnapshotFailed { .. }
        | Event::Released => {}
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
            if done == epoch {
                out.chat.snapshot = out.chat.snapshot.max(snapshot);
                out.chat.too_large = false;
                out.to(State::Holding { epoch });
                // The answer says whether the inbox has messages to drain.
                out.renew(now);
            }
        }
        Event::ImportFailed { epoch: tried } => {
            if tried == epoch {
                out.to(State::ComingHome { epoch, failed: true });
            }
        }
        Event::Closed => close(out),
        Event::AutoOn
        | Event::Assigned { .. }
        | Event::SnapshotStored { .. }
        | Event::SnapshotFailed { .. }
        | Event::Released => {}
    }
}
