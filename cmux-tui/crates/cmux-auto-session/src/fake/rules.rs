//! The rules that move a chat's record: the real store's `lease.ts`, function for function
//! and in its order, so the two can be read side by side.
//!
//! Every function is pure: it takes the record, the caller's words and the time, and answers
//! the next record or a refusal. `Store::apply` writes what one answers.
//!
//! One rule holds across all of them: the epoch grows by exactly one when the holder changes,
//! and never otherwise.
//!
//! Moving a chat by hand is in `moves.rs` (the real store's `move.ts`): a wish on the record,
//! which the holder answers by giving the chat. Every change of holder here drops the wish, and
//! the alarm drops one its holder did not act on for `MOVE_MS`.

use super::record::{MAX_STANDBY, Record, Standby, live_standby, pending_inbox};
use super::store::Caller;
use crate::consts::{LEASE_MS, MOVE_MS};
use crate::wire::{
    AssignmentKind, Blocked, CreateRequest, Delivery, ErrorCode, Holder, LeaseRequest,
    MachineSetting, MoveRefusal, MoveTo, PutRequest, Role,
};

/// The code a rule refuses with: one of the store's own, or one only `move` and `give` use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Code {
    Auto(ErrorCode),
    Move(MoveRefusal),
}

impl Code {
    pub fn as_str(self) -> &'static str {
        match self {
            Code::Auto(code) => code.as_str(),
            Code::Move(code) => code.as_str(),
        }
    }

    pub fn status(self) -> u16 {
        match self {
            Code::Auto(code) => code.status(),
            Code::Move(code) => code.status(),
        }
    }
}

impl From<ErrorCode> for Code {
    fn from(code: ErrorCode) -> Code {
        Code::Auto(code)
    }
}

impl From<MoveRefusal> for Code {
    fn from(code: MoveRefusal) -> Code {
        Code::Move(code)
    }
}

/// A refusal: the code, and what the code promises beside it.
#[derive(Debug)]
pub(super) struct Refuse {
    pub code: Code,
    pub message: String,
    pub last_seq: Option<u64>,
    pub missing: Vec<String>,
}

impl Refuse {
    pub fn new(code: impl Into<Code>, message: impl Into<String>) -> Refuse {
        Refuse { code: code.into(), message: message.into(), last_seq: None, missing: Vec::new() }
    }
}

/// An answer with the record to write, if any. `loud`: a viewer can see the change, so the
/// chat's version grows and its waits wake.
#[derive(Debug)]
pub(super) struct Step<T> {
    pub out: T,
    pub rec: Option<Record>,
    pub loud: bool,
}

impl<T> Step<T> {
    /// Nothing is written.
    pub fn same(out: T) -> Step<T> {
        Step { out, rec: None, loud: false }
    }

    /// A write no viewer sees (a renewal that only moves the lease's end).
    pub fn quiet(out: T, rec: Record) -> Step<T> {
        Step { out, rec: Some(rec), loud: false }
    }

    pub fn loud(out: T, rec: Record) -> Step<T> {
        Step { out, rec: Some(rec), loud: true }
    }
}

pub(super) type Decision<T> = Result<Step<T>, Refuse>;

fn closed() -> Refuse {
    Refuse::new(ErrorCode::Closed, "Auto is off for this chat")
}

/// An owner's credential speaks for laptops only and a machine's only for itself.
fn speaks_for(by: &Caller, holder: &Holder) -> bool {
    match (by, holder) {
        (Caller::Owner, Holder::Device(_)) => true,
        (Caller::Machine(machine), Holder::Vm(named)) => machine == named,
        (Caller::Owner | Caller::Machine(_), _) => false,
    }
}

/// Whether `by` may write as `holder` at `epoch` now: the caller can be that holder, then the
/// epoch is the current one and the holder the current holder.
pub(super) fn fence(r: &Record, by: &Caller, holder: &Holder, epoch: u64) -> Result<(), Refuse> {
    if !r.auto {
        return Err(closed());
    }
    if !speaks_for(by, holder) {
        return Err(Refuse::new(
            ErrorCode::NotHolder,
            format!("this caller cannot write as {holder}"),
        ));
    }
    if epoch != r.epoch {
        let message = format!("epoch {epoch} is over; the current epoch is {}", r.epoch);
        return Err(Refuse::new(ErrorCode::StaleEpoch, message));
    }
    if *holder != r.holder {
        let message = format!("the chat is held by {}", r.holder);
        return Err(Refuse::new(ErrorCode::NotHolder, message));
    }
    Ok(())
}

fn park(r: &Record, from: Option<Holder>) -> Record {
    Record {
        holder: Holder::Parked,
        epoch: r.epoch.saturating_add(1),
        parked_from: from,
        resumed_epoch: 0,
        owes_import: false,
        wish: None,
        assignment: None,
        needs_run: false,
        lease_expires_at: 0,
        ..r.clone()
    }
}

/// The chat goes to a Cloud machine, which has to pick it up (`kind`) before it shows as
/// running there.
pub(super) fn assign(r: &Record, m: &MachineSetting, kind: AssignmentKind) -> Record {
    Record {
        holder: Holder::vm(m.machine.clone()),
        epoch: r.epoch.saturating_add(1),
        team: Some(m.team.clone()),
        machine: Some(m.machine.clone()),
        assignment: Some(kind),
        blocked: None,
        parked_from: None,
        resumed_epoch: 0,
        owes_import: false,
        wish: None,
        needs_run: true,
        lease_expires_at: 0,
        ..r.clone()
    }
}

/// Whether a message alone may send the chat to a machine: the store has a snapshot to import.
/// A machine given a chat with events and no snapshot cannot import it, and one given an empty
/// copy would start a chat the laptop already has.
pub(super) fn has_copy(r: &Record) -> bool {
    r.snapshot > 0
}

/// Whether the laptop a parked chat was parked from may take it back as it is. Not a chat kept
/// in the Cloud that has a snapshot: it stays parked until work arrives, which goes to the Auto
/// machine. Without a snapshot the laptop has the only chat there is, so it takes it back
/// whatever the chat is kept as.
fn takes_back(r: &Record, keep_in_cloud: bool) -> bool {
    !(keep_in_cloud && has_copy(r))
}

/// A parked chat with a message waiting goes to the Auto machine, or is marked as waiting for
/// one. Without a snapshot it stays as it is: the message waits for the laptop.
fn settle(r: Record, machine: Option<&MachineSetting>) -> Record {
    if !r.holder.is_parked() || !pending_inbox(&r) || !has_copy(&r) {
        return r;
    }
    match machine {
        Some(m) => assign(&r, m, AssignmentKind::Takeover),
        None => Record { blocked: Some(Blocked::NoMachine), ..r },
    }
}

/// A laptop takes the chat. `owes`: it did not hold the chat last, so it has to import the
/// Cloud copy (`owes_import`).
pub(super) fn taken_by(
    r: &Record,
    holder: &Holder,
    needs_run: bool,
    now: u64,
    owes: bool,
) -> Record {
    Record {
        holder: holder.clone(),
        epoch: r.epoch.saturating_add(1),
        needs_run,
        assignment: None,
        blocked: None,
        parked_from: None,
        resumed_epoch: 0,
        owes_import: owes,
        wish: None,
        lease_expires_at: now.saturating_add(LEASE_MS),
        standby: r.standby.iter().filter(|standby| standby.holder != *holder).cloned().collect(),
        ..r.clone()
    }
}

/// The laptop a move to a laptop goes to: the one named, when it stands by; with none named,
/// the standby that renewed last.
pub(super) fn laptop_for(r: &Record, device: Option<&Holder>, now: u64) -> Option<Holder> {
    if let Some(device) = device {
        return live_standby(r, now)
            .find(|standby| standby.holder == *device)
            .map(|standby| standby.holder.clone());
    }
    let mut best: Option<&Standby> = None;
    for standby in live_standby(r, now) {
        if best.is_none_or(|best| standby.expires_at > best.expires_at) {
            best = Some(standby);
        }
    }
    best.map(|standby| standby.holder.clone())
}

/// The laptop a wish to move the chat to a laptop names, if it names one.
fn wished(r: &Record) -> Option<&Holder> {
    let wish = r.wish.as_ref()?;
    if wish.to == MoveTo::Local { wish.device.as_ref() } else { None }
}

/// The laptop a machine's chat goes home to, unless the chat is kept in the Cloud: the one a
/// wish names when it stands by, else the standby that renewed last.
fn handback_to(r: &Record, now: u64) -> Option<Holder> {
    if r.keep_in_cloud {
        return None;
    }
    let named = wished(r).and_then(|named| laptop_for(r, Some(named), now));
    named.or_else(|| laptop_for(r, None, now))
}

/// Whether a machine's renewal ends its hold: nothing left to run, nothing unread, its
/// assignment acked, and its newest snapshot taken after its last event, so the laptop imports
/// everything the machine did.
fn idle_for_handback(r: &Record) -> bool {
    !r.needs_run && !pending_inbox(r) && r.assignment.is_none() && r.snapshot_seq >= r.last_seq
}

/// A first `PUT`: the chat as the laptop that made it holds it, epoch 1.
pub(super) fn open_record(
    id: &str,
    owner: &str,
    team: Option<String>,
    input: &PutRequest,
    now: u64,
) -> Record {
    Record {
        id: id.to_owned(),
        owner: owner.to_owned(),
        team,
        title: input.title.trim().to_owned(),
        harness: input.harness.clone(),
        auto: true,
        keep_in_cloud: input.keep_in_cloud.unwrap_or(false),
        holder: Holder::device(input.device.clone()),
        epoch: 1,
        needs_run: false,
        standby: Vec::new(),
        blocked: None,
        assignment: None,
        machine: None,
        parked_from: None,
        resumed_epoch: 0,
        owes_import: false,
        wish: None,
        last_seq: 0,
        snapshot: 0,
        snapshot_seq: 0,
        inbox: 0,
        inbox_acked: 0,
        repo: input.repo.clone(),
        event_bytes: 0,
        version: 1,
        created_at: now,
        updated_at: now,
        lease_expires_at: now.saturating_add(LEASE_MS),
    }
}

/// A chat started with no laptop: the Auto machine holds it from the start and has to create
/// it. Its first message is inbox message 1. `keep_in_cloud`: the chat is made in Cloud mode.
pub(super) fn cloud_record(
    id: &str,
    owner: &str,
    machine: &MachineSetting,
    input: &CreateRequest,
    keep_in_cloud: bool,
    now: u64,
) -> Record {
    let made = PutRequest {
        auto: true,
        title: input.title.clone().unwrap_or_default(),
        harness: input.harness.clone(),
        device: String::new(),
        keep_in_cloud: Some(keep_in_cloud),
        repo: Some(input.repo.clone()),
    };
    Record {
        holder: Holder::vm(machine.machine.clone()),
        machine: Some(machine.machine.clone()),
        needs_run: true,
        assignment: Some(AssignmentKind::Create),
        inbox: 1,
        lease_expires_at: 0,
        ..open_record(id, owner, Some(machine.team.clone()), &made, now)
    }
}

/// A later `PUT` with Auto on: the chat's title, harness, keep-in-Cloud and repository follow;
/// a closed chat opens again, empty, at the next epoch. From the laptop a parked chat was
/// parked from, it also takes the chat back as it is (nobody ran it since): a registration
/// whose first answer was lost, sent again after the lease ran out, still answers that laptop
/// as the holder. Its renewal at the epoch it held is then that renewal (`resumed_epoch`).
/// A chat that is kept in the Cloud after this `PUT` and has a snapshot is not taken back
/// ([`takes_back`]). From the holder it is also a renewal: the laptop reads the answer as the
/// lease's, so the lease runs from it.
pub(super) fn edit(r: &Record, input: &PutRequest, now: u64) -> Decision<()> {
    let title = input.title.trim().to_owned();
    let harness = input.harness.clone();
    let repo = input.repo.clone().or_else(|| r.repo.clone());
    let me = Holder::device(input.device.clone());
    if !r.auto {
        let keep_in_cloud = input.keep_in_cloud.unwrap_or(false);
        let opened = taken_by(r, &me, false, now, false);
        return Ok(Step::loud(
            (),
            Record { title, harness, repo, auto: true, keep_in_cloud, ..opened },
        ));
    }
    let keep_in_cloud = input.keep_in_cloud.unwrap_or(r.keep_in_cloud);
    let mine = r.holder.is_parked() && r.parked_from.as_ref() == Some(&me);
    if mine && takes_back(r, keep_in_cloud) {
        let taken = taken_by(r, &me, false, now, false);
        let resumed_epoch = r.epoch.saturating_sub(1);
        return Ok(Step::loud(
            (),
            Record { title, harness, keep_in_cloud, repo, resumed_epoch, ..taken },
        ));
    }
    let same = title == r.title
        && harness == r.harness
        && keep_in_cloud == r.keep_in_cloud
        && repo == r.repo;
    // From the holder it is also a renewal: the laptop reads the answer as the lease's.
    if r.holder == me {
        let lease_expires_at = now.saturating_add(LEASE_MS);
        let rec = Record { title, harness, keep_in_cloud, repo, lease_expires_at, ..r.clone() };
        return Ok(if same { Step::quiet((), rec) } else { Step::loud((), rec) });
    }
    if same {
        return Ok(Step::same(()));
    }
    Ok(Step::loud((), Record { title, harness, keep_in_cloud, repo, ..r.clone() }))
}

/// Auto off: the chat closes and its Cloud copy goes. Refused while the Cloud has something no
/// laptop has: a machine holds the chat, a machine was the last to run a parked one, a parked
/// one has a message nobody read, or the laptop that holds it was given it and has not
/// imported the Cloud copy yet (`owes_import`). A laptop takes the chat first (a standby's
/// renewal), imports it, then turns Auto off.
pub(super) fn close(r: &Record) -> Decision<()> {
    if !r.auto {
        return Ok(Step::same(()));
    }
    if r.holder.is_vm() {
        return Err(Refuse::new(
            ErrorCode::HeldInCloud,
            "the chat is running in the Cloud; bring it back before turning Auto off",
        ));
    }
    if r.holder.is_parked() && (r.parked_from.is_none() || pending_inbox(r)) {
        return Err(Refuse::new(
            ErrorCode::HeldInCloud,
            "the Cloud has the only copy of this chat; \
             bring it back to a laptop before turning Auto off",
        ));
    }
    if r.owes_import {
        return Err(Refuse::new(
            ErrorCode::HeldInCloud,
            "the chat is still coming back from the Cloud; turn Auto off once it is here",
        ));
    }
    let parked = if r.holder.is_parked() { r.clone() } else { park(r, None) };
    Ok(Step::loud(
        (),
        Record {
            auto: false,
            parked_from: None,
            standby: Vec::new(),
            blocked: None,
            last_seq: 0,
            snapshot: 0,
            snapshot_seq: 0,
            inbox_acked: r.inbox,
            event_bytes: 0,
            ..parked
        },
    ))
}

pub(super) fn keep(r: &Record, keep_in_cloud: bool) -> Decision<()> {
    if !r.auto {
        return Err(closed());
    }
    if r.keep_in_cloud == keep_in_cloud {
        return Ok(Step::same(()));
    }
    Ok(Step::loud((), Record { keep_in_cloud, ..r.clone() }))
}

/// `POST lease`: the holder renews, a laptop takes a parked chat, or a laptop waits as
/// standby. The answer is a role, never a stale-epoch refusal, beside the chat with its
/// current epoch:
/// - `holder` to a renewal that is not a standby's: go on as you are, at the answer's epoch.
/// - `holder` to a standby's renewal: the chat is yours now. Import the Cloud copy, then go on
///   at the answer's epoch.
/// - `standby`: remembered as waiting.
/// - `lost`: what you were running is not the chat any more. Stop it, then renew as a standby.
pub(super) fn renew(r: &Record, by: &Caller, input: &LeaseRequest, now: u64) -> Decision<Role> {
    if !r.auto {
        return Err(closed());
    }
    let (holder, epoch, needs_run) = (&input.holder, input.epoch, input.needs_run);
    let as_standby = input.standby == Some(true);
    if !speaks_for(by, holder) {
        return Err(Refuse::new(
            ErrorCode::NotHolder,
            format!("this caller cannot renew as {holder}"),
        ));
    }
    let lease_expires_at = now.saturating_add(LEASE_MS);
    if *holder == r.holder {
        // The renewal that took a parked chat back, sent again because its answer was lost, is
        // that renewal again.
        let current = epoch == r.epoch || (r.resumed_epoch > 0 && epoch == r.resumed_epoch);
        // The holder at an older epoch. A standby that was handed the chat learns it here, and
        // its lease runs on while it imports the Cloud copy. Anything else it still runs from
        // that epoch may be behind what another holder did since, so it is told to stop, and
        // nothing is written.
        if !current {
            return Ok(if as_standby && *by == Caller::Owner {
                Step::quiet(Role::Holder, Record { lease_expires_at, ..r.clone() })
            } else {
                Step::same(Role::Lost)
            });
        }
        let standby: Vec<Standby> =
            r.standby.iter().filter(|standby| standby.holder != *holder).cloned().collect();
        let loud = needs_run != r.needs_run || standby.len() != r.standby.len();
        let next = Record { needs_run, lease_expires_at, standby, ..r.clone() };
        let home =
            if holder.is_vm() && idle_for_handback(&next) { handback_to(&next, now) } else { None };
        return Ok(match home {
            Some(home) => Step::loud(Role::Lost, taken_by(&next, &home, false, now, true)),
            None => Step { out: Role::Holder, rec: Some(next), loud },
        });
    }
    // A machine that no longer holds the chat, or a laptop whose chat a machine or another
    // laptop holds.
    if matches!(by, Caller::Machine(_)) {
        return Ok(Step::same(Role::Lost));
    }
    if r.holder.is_parked() {
        // Nobody ran the chat since this laptop's own lease ran out: it goes on as it is, unless
        // the chat is kept in the Cloud and has a snapshot (`takes_back`).
        let mine = r.parked_from.as_ref() == Some(holder);
        let held = epoch.checked_add(1) == Some(r.epoch);
        if !as_standby && mine && held && takes_back(r, r.keep_in_cloud) {
            let taken = taken_by(r, holder, needs_run, now, false);
            return Ok(Step::loud(Role::Holder, Record { resumed_epoch: epoch, ..taken }));
        }
        // A standby takes a parked chat too (it imports the Cloud copy first), unless the chat
        // is kept in the Cloud.
        if as_standby && !r.keep_in_cloud {
            return Ok(Step::loud(Role::Holder, taken_by(r, holder, false, now, !mine)));
        }
    }
    if !as_standby {
        return Ok(Step::same(Role::Lost));
    }
    // A machine that said it had nothing left to run, has all it did in the Cloud copy and
    // then stopped renewing is paused. It has no turn end left to hand the chat back at, so
    // the chat goes home to this laptop now. A machine at work renews, and one that is idle
    // and awake hands the chat back at its own next renewal. A wish that names a laptop keeps
    // the chat for that laptop.
    let paused = r.lease_expires_at > 0 && r.lease_expires_at <= now;
    let for_me = wished(r).is_none_or(|named| named == holder);
    if r.holder.is_vm() && !r.keep_in_cloud && paused && idle_for_handback(r) && for_me {
        return Ok(Step::loud(Role::Holder, taken_by(r, holder, false, now, true)));
    }
    let mut standby: Vec<Standby> = live_standby(r, now).cloned().collect();
    let live = standby.len();
    let mine = Standby { holder: holder.clone(), expires_at: lease_expires_at };
    let listed = standby.iter_mut().find(|standby| standby.holder == *holder);
    let new = listed.is_none();
    match listed {
        Some(listed) => *listed = mine,
        None => {
            standby.push(mine);
            let over = standby.len().saturating_sub(MAX_STANDBY);
            standby.drain(..over);
        }
    }
    let loud = new || live != r.standby.len();
    Ok(Step { out: Role::Standby, rec: Some(Record { standby, ..r.clone() }), loud })
}

/// `POST release`: a machine's chat goes home to its standby laptop, else the chat is parked.
/// With a message still unread it is not left with nobody: it goes to the Auto machine, and
/// when the Auto machine is the one releasing, the chat stays with it (same epoch) with a
/// `deliver` to pick up, so the answer still names it as the holder.
pub(super) fn release(
    r: &Record,
    by: &Caller,
    holder: &Holder,
    epoch: u64,
    machine: Option<&MachineSetting>,
    now: u64,
) -> Decision<()> {
    fence(r, by, holder, epoch)?;
    let home = if r.holder.is_vm() { handback_to(r, now) } else { None };
    if let Some(home) = home {
        return Ok(Step::loud((), taken_by(r, &home, false, now, true)));
    }
    let unread = pending_inbox(r);
    if let (true, Some(m)) = (unread, machine)
        && Holder::vm(m.machine.clone()) == r.holder
    {
        return Ok(if r.assignment.is_some() {
            Step::same(())
        } else {
            Step::loud((), Record { assignment: Some(AssignmentKind::Deliver), ..r.clone() })
        });
    }
    // To another machine only with a snapshot to import; without one the message waits in the
    // parked chat.
    let movable = unread && has_copy(r);
    if let (true, Some(m)) = (movable, machine) {
        return Ok(Step::loud((), assign(r, m, AssignmentKind::Takeover)));
    }
    let parked = park(r, r.holder.is_device().then(|| r.holder.clone()));
    Ok(Step::loud(
        (),
        if movable { Record { blocked: Some(Blocked::NoMachine), ..parked } } else { parked },
    ))
}

/// `POST assignment/ack`: the machine picked up what it was given, so the chat shows as
/// running in the Cloud. While a message is still unread the machine keeps a `deliver` to pick
/// up: a message that arrived between its read of the inbox and this ack is never left waiting
/// on a machine that thinks it has nothing to do.
pub(super) fn ack_assignment(
    r: &Record,
    by: &Caller,
    holder: &Holder,
    epoch: u64,
    now: u64,
) -> Decision<()> {
    fence(r, by, holder, epoch)?;
    let left = pending_inbox(r).then_some(AssignmentKind::Deliver);
    let lease_expires_at = now.saturating_add(LEASE_MS);
    if r.assignment.is_none() || r.assignment == left {
        return Ok(Step::quiet((), Record { lease_expires_at, ..r.clone() }));
    }
    Ok(Step::loud((), Record { assignment: left, lease_expires_at, ..r.clone() }))
}

/// `POST inbox/ack`: the holder took every message through `through` into its own log. None
/// when that acks nothing new. A machine that was not heard from since it was given the chat is
/// heard from now: from here some of the chat's messages are only in its log, so the chat no
/// longer follows a change of the Auto machine ([`machine_set`]).
pub(super) fn acked_inbox(r: &Record, through: u64, now: u64) -> Option<Record> {
    let acked = through.min(r.inbox);
    if acked <= r.inbox_acked {
        return None;
    }
    let lease_expires_at = if r.holder.is_vm() && r.lease_expires_at == 0 {
        now.saturating_add(LEASE_MS)
    } else {
        r.lease_expires_at
    };
    Some(Record { inbox_acked: acked, lease_expires_at, ..r.clone() })
}

/// A new inbox message (already counted in `r.inbox`): who gets it, and what the sender is
/// told. `delivered`: a holder that is running reads it; `resuming`: a machine is being
/// started for it; `queued`: nobody can run the chat until the owner has an Auto machine or a
/// laptop comes back (always a laptop, for a chat with no snapshot).
pub(super) fn deliver(r: Record, machine: Option<&MachineSetting>, now: u64) -> (Record, Delivery) {
    match r.holder {
        Holder::Device(_) => (r, Delivery::Delivered),
        Holder::Vm(_) => {
            let running = r.assignment.is_none() && r.lease_expires_at > now;
            let assignment = r.assignment.or(Some(AssignmentKind::Deliver));
            let state = if running { Delivery::Delivered } else { Delivery::Resuming };
            (Record { assignment, ..r }, state)
        }
        Holder::Parked => {
            let rec = settle(r, machine);
            let state = if rec.holder.is_vm() { Delivery::Resuming } else { Delivery::Queued };
            (rec, state)
        }
    }
}

pub(super) fn lease_due(r: &Record, now: u64) -> bool {
    r.auto && r.holder.is_device() && r.lease_expires_at <= now
}

/// The alarm's move: a laptop's lease that ran out gives the chat to the Auto machine when
/// work waits, parks it otherwise; standbys that stopped renewing are dropped. None when
/// nothing is due. A message is work for a machine only with a snapshot to import
/// ([`has_copy`]); without one the chat is parked and the message waits for the laptop. A wish
/// to move the chat that its holder did not act on for `MOVE_MS` is dropped: the chat stays
/// where it is.
pub(super) fn tick(r: &Record, machine: Option<&MachineSetting>, now: u64) -> Option<Record> {
    let mut next = r.clone();
    let mut changed = false;
    if lease_due(r, now) {
        let work = r.needs_run || (pending_inbox(r) && has_copy(r));
        next = match machine {
            Some(m) if work => assign(r, m, AssignmentKind::Takeover),
            Some(_) | None => Record {
                needs_run: work,
                blocked: work.then_some(Blocked::NoMachine),
                ..park(r, (!r.owes_import).then(|| r.holder.clone()))
            },
        };
        changed = true;
    }
    if next.wish.as_ref().is_some_and(|wish| wish.at.saturating_add(MOVE_MS) <= now) {
        next.wish = None;
        changed = true;
    }
    let live: Vec<Standby> = live_standby(&next, now).cloned().collect();
    if live.len() != next.standby.len() {
        next.standby = live;
        changed = true;
    }
    changed.then_some(next)
}

/// The owner set their Auto machine: a chat that was waiting for one goes to it. So does a
/// chat given to another machine that was never heard from since (`lease_expires_at` is still
/// 0: no renewal, no ack of the assignment or of a message), so nothing of the chat is only
/// there: a machine that was deleted or cannot start does not keep the chat for good. A machine
/// that was heard from keeps it, acked assignment or not: the messages it acked are in its log
/// alone until its next copy. None when the chat stays as it is.
pub(super) fn machine_set(r: &Record, machine: &MachineSetting) -> Option<Record> {
    if !r.auto {
        return None;
    }
    match (&r.holder, r.assignment) {
        (Holder::Parked, _) => (r.blocked == Some(Blocked::NoMachine))
            .then(|| assign(r, machine, AssignmentKind::Takeover)),
        (Holder::Vm(held), Some(kind @ (AssignmentKind::Takeover | AssignmentKind::Create))) => {
            let unheard = r.lease_expires_at == 0;
            (*held != machine.machine && unheard).then(|| assign(r, machine, kind))
        }
        (Holder::Vm(_) | Holder::Device(_), _) => None,
    }
}

/// When the alarm has to look again: a laptop's lease end, the first standby to lapse, or the
/// end of a wish to move the chat.
pub(super) fn next_due(r: &Record) -> Option<u64> {
    let lease = (r.auto && r.holder.is_device()).then_some(r.lease_expires_at);
    let wish = r.wish.as_ref().map(|wish| wish.at.saturating_add(MOVE_MS));
    r.standby.iter().map(|standby| standby.expires_at).chain(lease).chain(wish).min()
}
