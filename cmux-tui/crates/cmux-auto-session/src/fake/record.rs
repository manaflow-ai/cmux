//! One chat's record and the view every route answers: the real store's `model.ts`.

use crate::wire::{AssignmentKind, Blocked, Holder, MoveTo, MoveWish, Repo, SessionView, State};

/// Laptops remembered as waiting for one chat.
pub(super) const MAX_STANDBY: usize = 8;
/// Messages a chat holds for a holder that has not acked them.
pub(super) const MAX_INBOX_PENDING: u64 = 256;
/// One message's text, in UTF-16 units as the real store counts it.
pub(super) const MAX_INBOX_TEXT: usize = 256 * 1024;
/// One manifest, as JSON, and the chunks it may name.
pub(super) const MAX_MANIFEST_BYTES: usize = 1 << 20;
pub(super) const MAX_MANIFEST_CHUNKS: usize = 4096;

/// A laptop that is online, has the chat, and does not hold it. It stops counting when it
/// stops renewing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Standby {
    pub holder: Holder,
    pub expires_at: u64,
}

/// The person asked to move the chat by hand, and its holder has not given it yet.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Wish {
    pub to: MoveTo,
    /// The laptop that was named, if one was.
    pub device: Option<Holder>,
    pub at: u64,
    /// The machine the store keeps started while the wish waits: the Auto machine the chat goes
    /// to, or the machine that holds it and has to read the wish.
    pub wake: Option<String>,
}

/// One chat's record. The rules of `rules.rs` take one and answer the next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Record {
    pub id: String,
    pub owner: String,
    /// The team the chat runs in: its creator's, then its machine's.
    pub team: Option<String>,
    pub title: String,
    pub harness: String,
    /// False once the owner turned Auto off for the chat (closed).
    pub auto: bool,
    pub keep_in_cloud: bool,
    pub holder: Holder,
    pub epoch: u64,
    /// What the holder said at its last renewal.
    pub needs_run: bool,
    pub standby: Vec<Standby>,
    /// Only `no_machine` is the store's to set.
    pub blocked: Option<Blocked>,
    /// What the holding machine still has to pick up; None once it acked.
    pub assignment: Option<AssignmentKind>,
    /// The Cloud machine that holds the chat or held it last.
    pub machine: Option<String>,
    /// The laptop whose lease ran straight into `parked`: nobody ran the chat since, so it may
    /// take it back as it is.
    pub parked_from: Option<Holder>,
    /// The epoch a laptop named when it took its own parked chat back (0: none), so a repeat
    /// of that renewal after a lost answer is the same renewal.
    pub resumed_epoch: u64,
    /// The holder is a laptop that was given the chat (a hand-back, or a parked chat another
    /// holder ran last) and has stored no snapshot of its own since: what the last holder did
    /// may be in the Cloud copy alone. Auto off is refused until it has, and its lease running
    /// out parks the chat as the Cloud's, not as that laptop's.
    pub owes_import: bool,
    /// The wish to move the chat by hand, until its holder gives the chat, the holder changes
    /// another way, or `MOVE_MS` passes.
    pub wish: Option<Wish>,
    pub last_seq: u64,
    /// The newest snapshot's number, and the `lastSeq` its manifest names (at most the
    /// chat's).
    pub snapshot: u64,
    pub snapshot_seq: u64,
    pub inbox: u64,
    pub inbox_acked: u64,
    pub repo: Option<Repo>,
    /// The size of the chat's stored events.
    pub event_bytes: u64,
    /// Counts every change a viewer can see; a wait passes the last one it saw.
    pub version: u64,
    pub created_at: u64,
    pub updated_at: u64,
    pub lease_expires_at: u64,
}

/// The standbys that renewed within the last lease.
pub(super) fn live_standby(r: &Record, now: u64) -> impl Iterator<Item = &Standby> {
    r.standby.iter().filter(move |standby| standby.expires_at > now)
}

pub(super) fn pending_inbox(r: &Record) -> bool {
    r.inbox > r.inbox_acked
}

/// What a client shows: `resuming` until the machine acked what it was given, `coming_back`
/// when the chat goes home at the next turn end.
pub(super) fn state_of(r: &Record, now: u64) -> State {
    match &r.holder {
        Holder::Parked => State::Parked,
        Holder::Device(_) => State::Local,
        Holder::Vm(_) if r.assignment.is_some() => State::Resuming,
        Holder::Vm(_) if !r.keep_in_cloud && live_standby(r, now).next().is_some() => {
            State::ComingBack
        }
        Holder::Vm(_) => State::Cloud,
    }
}

/// The view every route answers.
pub(super) fn view_of(r: &Record, now: u64) -> SessionView {
    SessionView {
        id: r.id.clone(),
        title: r.title.clone(),
        harness: r.harness.clone(),
        team: r.team.clone(),
        owner: r.owner.clone(),
        auto: r.auto,
        keep_in_cloud: r.keep_in_cloud,
        holder: r.holder.clone(),
        epoch: r.epoch,
        state: state_of(r, now),
        blocked: r.blocked,
        needs_run: r.needs_run,
        standby: live_standby(r, now).map(|standby| standby.holder.clone()).collect(),
        moving: r.wish.as_ref().map(|wish| MoveWish {
            to: wish.to,
            device: wish.device.clone(),
            at: wish.at,
        }),
        last_seq: r.last_seq,
        snapshot: r.snapshot,
        inbox: r.inbox,
        inbox_acked: r.inbox_acked,
        repo: r.repo.clone(),
        version: r.version,
        created_at: r.created_at,
        updated_at: r.updated_at,
        lease_expires_at: r.lease_expires_at,
    }
}
