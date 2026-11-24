//! The holder move's answers: what the Auto store said to one planned holder change
//! `device -> vm` (AutoCloud proof plan: "A move done today by transfer becomes `device -> vm`
//! through a planned, clean holder handoff").
//!
//! | Answer | Then |
//! |---|---|
//! | given at `epoch` | the machine holds the chat: live, held prompts go there |
//! | `auto.not_copied` | ready again; the next ask waits for the turn's end (no timer); past [`MOVE_TRIES`] asks, the transfer |
//! | `auto.no_machine`, `auto.off`, a code this build does not know | the transfer, at once if at a boundary |
//! | `auto.stale_epoch` | the chat stays here, the machine is paused |
//! | lost to another holder | the drive ends: the chat is not this start's to move, the machine is paused |
//!
//! Each answer counts only while the chat is moving by the holder route; any other is late and
//! ignored.

use super::{
    Cloud, Effect, MOVE_TRIES, MoveRoute, Refusal, State, line, live, move_if_due, release, show,
    stay,
};

/// The reason of a chat whose ask was fenced at an old epoch.
pub const STALE: &str = "auto.stale_epoch";

/// The reason of a chat another holder took while the move was asked.
pub const LOST: &str = "holder-lost";

fn asking(state: &State) -> bool {
    state.cloud == Cloud::Moving && state.route == MoveRoute::Holder
}

pub(super) fn given(state: &mut State, epoch: u64, now: u64, effects: &mut Vec<Effect>) {
    if asking(state) {
        state.epoch = Some(epoch);
        live(state, now, effects);
    }
}

/// Ready again at the boundary the ask was made at; a held prompt starts a turn here first and
/// the move waits for its boundary, as a failed transfer does.
fn ready_again(state: &mut State, now: u64, effects: &mut Vec<Effect>) {
    show(state, Cloud::Ready, now, effects);
    if state.held.is_empty() {
        move_if_due(state, false, now, effects);
    } else {
        release(state, effects);
    }
}

fn fall_back(state: &mut State, now: u64, effects: &mut Vec<Effect>) {
    state.route = MoveRoute::Transfer;
    state.copy_owed = false;
    effects.push(line("holder-fallback", state, now));
    ready_again(state, now, effects);
}

pub(super) fn refused(state: &mut State, code: Refusal, now: u64, effects: &mut Vec<Effect>) {
    if !asking(state) {
        return;
    }
    match code {
        Refusal::NotCopied if state.tries < MOVE_TRIES && !state.stopped => {
            state.copy_owed = true;
            effects.push(line("holder-not-copied", state, now));
            show(state, Cloud::Ready, now, effects);
            release(state, effects);
        }
        Refusal::NotCopied | Refusal::NoMachine | Refusal::Off | Refusal::Unknown => {
            if state.stopped {
                stay(state, super::STOPPED.to_owned(), true, now, effects);
            } else {
                fall_back(state, now, effects);
            }
        }
        Refusal::StaleEpoch => stay(state, STALE.to_owned(), true, now, effects),
    }
}

pub(super) fn lost(state: &mut State, now: u64, effects: &mut Vec<Effect>) {
    if asking(state) {
        stay(state, LOST.to_owned(), true, now, effects);
    }
}

#[cfg(test)]
mod tests;
