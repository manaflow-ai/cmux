//! Moving a chat by hand: the real store's `move.ts`, function for function.
//!
//! A move is two steps, because only the holder can stop its agent and store the last copy:
//!
//! - `move` (the owner) writes a wish on the record and, in the same write, whether the chat is
//!   kept in the Cloud (`true` to the Cloud, `false` to a laptop). The holder reads the wish in
//!   its lease answer and in the chat's view.
//! - `give` (the holder) hands the chat over once its copy is whole: epoch + 1, the wish gone,
//!   and the chat with the Auto machine as a `takeover`, or with the laptop, which owes an
//!   import.
//!
//! A parked chat has no holder to give it, so `move` hands it over itself. A chat that is
//! already where it is asked to go only has its wish dropped. Every other change of holder
//! drops the wish (`rules.rs`), and so does the alarm once the holder has not acted on it for
//! `MOVE_MS`.

use super::record::{Record, Wish};
use super::rules::{Decision, Refuse, Step, assign, fence, has_copy, laptop_for, taken_by};
use super::store::Caller;
use crate::wire::{AssignmentKind, ErrorCode, Holder, MachineSetting, MoveRefusal, MoveTo};

/// The chat is where it was asked to go: its wish goes and it is kept as asked. Nothing is
/// written when that changes nothing.
fn kept(r: &Record, keep_in_cloud: bool) -> Step<()> {
    if r.wish.is_none() && r.keep_in_cloud == keep_in_cloud {
        return Step::same(());
    }
    Step::loud((), Record { keep_in_cloud, wish: None, ..r.clone() })
}

fn no_machine() -> Refuse {
    Refuse::new(ErrorCode::NoMachine, "the owner has no Cloud machine to move this chat to")
}

fn no_laptop(device: Option<&Holder>) -> Refuse {
    let message = match device {
        Some(device) => format!("{device} is not standing by for this chat"),
        None => "no laptop is standing by for this chat".to_owned(),
    };
    Refuse::new(MoveRefusal::NoLaptop, message)
}

fn to_cloud(r: &Record, machine: Option<&MachineSetting>, now: u64) -> Decision<()> {
    // A machine runs it already, whichever of the owner's machines that is.
    if r.holder.is_vm() {
        return Ok(kept(r, true));
    }
    let Some(machine) = machine else { return Err(no_machine()) };
    if r.holder.is_parked() {
        // A machine imports a snapshot: without one the laptop has the only chat there is.
        if !has_copy(r) {
            return Err(Refuse::new(
                MoveRefusal::NotCopied,
                "the Cloud has no copy of this chat to start from; open it on its laptop first",
            ));
        }
        let given = assign(r, machine, AssignmentKind::Takeover);
        return Ok(Step::loud((), Record { keep_in_cloud: true, ..given }));
    }
    // The machine is started now, so it is up when the laptop gives the chat.
    let wish =
        Wish { to: MoveTo::Cloud, device: None, at: now, wake: Some(machine.machine.clone()) };
    Ok(Step::loud((), Record { keep_in_cloud: true, wish: Some(wish), ..r.clone() }))
}

fn to_laptop(r: &Record, device: Option<&Holder>, now: u64) -> Decision<()> {
    if r.holder.is_device() && device.is_none_or(|device| *device == r.holder) {
        return Ok(kept(r, false));
    }
    let Some(target) = laptop_for(r, device, now) else { return Err(no_laptop(device)) };
    // As a standby's renewal takes a parked chat (`rules::renew`): the laptop imports the Cloud
    // copy first, unless it is the one the chat was parked from, since nobody ran it after
    // that.
    if r.holder.is_parked() {
        let owes = r.parked_from.as_ref() != Some(&target);
        let taken = taken_by(r, &target, false, now, owes);
        return Ok(Step::loud((), Record { keep_in_cloud: false, ..taken }));
    }
    // A machine that holds the chat may be paused: it is started, so it reads the wish at its
    // next renewal.
    let wake = if r.holder.is_vm() && r.team.is_some() { r.machine.clone() } else { None };
    let wish = Wish { to: MoveTo::Local, device: device.cloned(), at: now, wake };
    Ok(Step::loud((), Record { keep_in_cloud: false, wish: Some(wish), ..r.clone() }))
}

/// `POST move`: the person asks for the chat to run in the Cloud (`machine`: the owner's Auto
/// machine) or on a laptop (`device`: the one named; None: the one that stands by). Asking
/// again for a move that still waits starts its time again.
pub(super) fn move_to(
    r: &Record,
    to: MoveTo,
    device: Option<&Holder>,
    machine: Option<&MachineSetting>,
    now: u64,
) -> Decision<()> {
    if !r.auto {
        return Err(Refuse::new(
            MoveRefusal::Off,
            "this chat is not an Auto chat; set its mode before moving it",
        ));
    }
    match to {
        MoveTo::Cloud => to_cloud(r, machine, now),
        MoveTo::Local => to_laptop(r, device, now),
    }
}

/// `POST give`: the holder hands the chat over as the wish says. Fenced like every holder
/// write. A chat never changes hands ahead of its copy: the store must have a snapshot that
/// covers the last event, so the holder stores its events and its snapshot first and gives
/// again when told `auto.not_copied`.
pub(super) fn give(
    r: &Record,
    by: &Caller,
    holder: &Holder,
    epoch: u64,
    machine: Option<&MachineSetting>,
    now: u64,
) -> Decision<()> {
    fence(r, by, holder, epoch)?;
    let Some(wish) = &r.wish else {
        return Err(Refuse::new(MoveRefusal::NoMove, "nobody asked to move this chat"));
    };
    if !has_copy(r) || r.snapshot_seq < r.last_seq {
        return Err(Refuse::new(
            MoveRefusal::NotCopied,
            "the Cloud copy is behind the chat; store its events and a snapshot, \
             then give it again",
        ));
    }
    if wish.to == MoveTo::Cloud {
        let Some(machine) = machine else { return Err(no_machine()) };
        return Ok(Step::loud((), assign(r, machine, AssignmentKind::Takeover)));
    }
    let Some(target) = laptop_for(r, wish.device.as_ref(), now) else {
        return Err(no_laptop(wish.device.as_ref()));
    };
    // What the holder stopped for the move is still to run (`needs_run` as it last said): a
    // laptop that never renews after this leaves the chat to the lease rules, which give work
    // to the Auto machine.
    Ok(Step::loud((), taken_by(r, &target, r.needs_run, now, true)))
}
