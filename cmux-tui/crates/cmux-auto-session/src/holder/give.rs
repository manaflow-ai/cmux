//! A give: the person moved the chat, and its holder hands it to where they want it.
//!
//! Both sides do the same three things in order, so a chat never changes hands ahead of its
//! copy: stop the turn that runs here ([`GiveStep::Stopping`]), store a copy that covers the
//! chat's last event ([`GiveStep::Copying`]), ask the store to take the chat
//! ([`GiveStep::Asking`]). A laptop is in `giving` meanwhile and a Cloud machine in
//! `returning`; nothing of the chat starts on either. What ends a give differs by side and is
//! in `laptop.rs` and `machine.rs`.

use super::out::Out;
use super::{CopyState, Declined, Effect, GiveFailure, GiveStep, MoveTo, Side, State};

/// The chat's state in the middle of a give, on its side.
fn giving(out: &Out, epoch: u64, step: GiveStep, to: MoveTo) -> State {
    match out.chat.side() {
        Side::Laptop => State::Giving { epoch, step, to },
        Side::Machine => State::Returning { epoch, step, to },
    }
}

/// The chat as its holder runs it, on its side.
fn held(out: &Out, epoch: u64) -> State {
    match out.chat.side() {
        Side::Laptop => State::Holding { epoch },
        Side::Machine => State::Serving { epoch },
    }
}

/// The chat is not given for this wish: the person is told why, once, and the wish is not
/// acted on again while the store still tells it.
fn decline(out: &mut Out, to: MoveTo, why: Declined) {
    if !out.chat.declined {
        out.chat.declined = true;
        out.push(Effect::NotMoved { to, why });
    }
}

/// The wish a holder acts on now, from what the store's answer said. An answer with no wish
/// clears a refusal: the next wish is a new one. A chat too large to copy cannot be given, and
/// a wish the store refused to act on is not tried again while the store still tells it.
pub(super) fn wanted(out: &mut Out, wish: Option<MoveTo>) -> Option<MoveTo> {
    match wish {
        None => {
            out.chat.declined = false;
            None
        }
        Some(_) if out.chat.declined => None,
        Some(to) if out.chat.too_large => {
            decline(out, to, Declined::TooLarge);
            None
        }
        Some(to) => Some(to),
    }
}

/// Starts a give of the chat this machine holds at `epoch`: the turn that runs is stopped
/// first.
pub(super) fn begin(out: &mut Out, epoch: u64, to: MoveTo) {
    let state = giving(out, epoch, GiveStep::Stopping, to);
    out.to(state);
    out.push(Effect::StopTurn);
}

/// The give did not happen: the chat goes on here, and the turn that was stopped is continued
/// here.
pub(super) fn stay(out: &mut Out, epoch: u64) {
    out.push(Effect::Stay);
    let state = held(out, epoch);
    out.to(state);
}

/// The store has the copy: ask it to take the chat.
fn ask(out: &mut Out, epoch: u64, to: MoveTo) {
    let state = giving(out, epoch, GiveStep::Asking, to);
    out.to(state);
    out.push(Effect::Give { epoch });
}

/// No turn runs here any more: the chat's last copy goes to the store.
pub(super) fn turn_stopped(out: &mut Out, epoch: u64, step: GiveStep, to: MoveTo, now: u64) {
    match step {
        GiveStep::Stopping => {
            let state = giving(out, epoch, GiveStep::Copying, to);
            out.to(state);
            out.copy(now);
        }
        GiveStep::Copying | GiveStep::Asking => {}
    }
}

/// A copy reached the store. The one this give waits for is followed by the ask.
pub(super) fn stored(
    out: &mut Out,
    epoch: u64,
    step: GiveStep,
    to: MoveTo,
    copy: u64,
    snapshot: u64,
) {
    let newest = out.stored(copy, snapshot);
    match step {
        GiveStep::Copying if newest => ask(out, epoch, to),
        GiveStep::Stopping | GiveStep::Copying | GiveStep::Asking => {}
    }
}

/// A copy did not reach the store. A chat past the size cap cannot be given: it goes on here.
/// Any other failure is sent again at the next tick.
pub(super) fn copy_failed(out: &mut Out, epoch: u64, to: MoveTo, copy: u64, too_large: bool) {
    out.failed(copy, too_large);
    if out.chat.too_large {
        decline(out, to, Declined::TooLarge);
        stay(out, epoch);
    }
}

/// A tick in the middle of a give: a copy that failed is sent again, a give the store did not
/// answer is asked again, and the holder renews, as it holds the chat until the store took it.
pub(super) fn tick(out: &mut Out, epoch: u64, step: GiveStep, to: MoveTo, now: u64) {
    if !out.due(now) {
        return;
    }
    match (step, out.chat.copy) {
        (GiveStep::Copying, CopyState::Failed) => {
            out.copy(now);
        }
        (GiveStep::Copying, CopyState::Stored) => ask(out, epoch, to),
        (GiveStep::Copying, CopyState::Sending) | (GiveStep::Stopping | GiveStep::Asking, _) => {}
    }
    out.renew(now);
}

/// The store did not take the chat.
pub(super) fn failed(
    out: &mut Out,
    epoch: u64,
    step: GiveStep,
    to: MoveTo,
    why: GiveFailure,
    now: u64,
) {
    match (step, why) {
        // The turn did not stop: nothing was copied or asked for this give.
        (GiveStep::Stopping, GiveFailure::Stuck) => {
            decline(out, to, Declined::Stuck);
            return stay(out, epoch);
        }
        (GiveStep::Asking, _) => {}
        (GiveStep::Stopping | GiveStep::Copying, _) => return,
    }
    let copying = giving(out, epoch, GiveStep::Copying, to);
    match why {
        // Only a `StopTurn` fails so, and it is over by now.
        GiveFailure::Stuck => {}
        // Something was written after the copy: copy again, then ask again.
        GiveFailure::NotCopied => {
            out.to(copying);
            out.copy(now);
        }
        GiveFailure::NoMove => stay(out, epoch),
        GiveFailure::Refused => {
            decline(out, to, Declined::Refused);
            stay(out, epoch);
        }
        // The renewal's answer says whose the chat is.
        GiveFailure::Lost => {
            out.to(copying);
            out.renew(now);
        }
        // The next tick asks again.
        GiveFailure::Unanswered => out.to(copying),
    }
}
