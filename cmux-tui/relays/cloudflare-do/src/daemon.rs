//! Which registered daemon control socket a client `Connect` is allocated to.
//!
//! A Connect allocated to a daemon sends that daemon `Incoming`; the client
//! then waits on the circuit for the daemon to join. A daemon that is gone
//! never joins, and the client waits out its whole join timeout (15 s)
//! before it tries again.
//!
//! A daemon that goes away without closing its socket (a machine that
//! reboots, or a session host restarted while its old socket is still open
//! at the edge) leaves a registration that reads OPEN until its 45 s idle
//! deadline. So a Connect is allocated only to a daemon heard from within
//! [`DAEMON_LIVENESS_WINDOW_MS`]; otherwise it parks, and the next Register
//! or Ping on the slot answers it.
//!
//! A daemon that died less than the window ago still gets the Connect. The
//! circuit it never joins is handed to the next daemon that registers
//! (`CircuitLedger::unjoined`), so the client is joined one hop after that
//! Register either way.

use cmux_remote_protocol::RelayRole;

use crate::abuse::{websocket_counts_toward_capacity, websocket_is_open};
use crate::attachment::{SlotAttachment, SlotPhase};

/// How recently a daemon's control socket must have spoken for a Connect to
/// be allocated to it. A daemon pings every `lease_seconds / 3` (10 s for the
/// relay's 30 s lease) and treats a ping unanswered for 3 s as dead, so a
/// live daemon is always heard from within 13 s; 2 s more covers the network.
pub(crate) const DAEMON_LIVENESS_WINDOW_MS: u64 = 15_000;

/// Whether `attachment` is a daemon registration on `slot` that a Connect
/// may be allocated to at `now_ms`.
pub(crate) fn accepts_connects(
    attachment: &SlotAttachment,
    ready_state: u16,
    slot: &str,
    now_ms: u64,
) -> bool {
    websocket_counts_toward_capacity(ready_state, attachment.idle_deadline_ms, now_ms)
        && attachment.phase == SlotPhase::Registered
        && attachment.relay.role == RelayRole::Daemon
        && attachment.relay.slot == slot
        && attachment.expires_at > now_ms / 1_000
        && heard_within_window(attachment, now_ms)
}

/// Whether this daemon's control socket spoke within
/// [`DAEMON_LIVENESS_WINDOW_MS`] before `now_ms`.
pub(crate) fn heard_within_window(attachment: &SlotAttachment, now_ms: u64) -> bool {
    attachment.last_seen_ms.saturating_add(DAEMON_LIVENESS_WINDOW_MS) > now_ms
}

/// The candidate a Connect on `slot` may be allocated to at `now_ms`. Each
/// candidate is a handle, its socket's ready state and its attachment; the
/// candidates are all the slot's control sockets.
///
/// The slot's current registration (`current_registration`) takes every
/// Connect: while it is silent past the window the Connect parks, even if
/// a replaced socket's daemon still speaks. When no registration is current,
/// the only open registrations are legacy ones (number 0): two or more of
/// them carry no order, so none is current (a numbered one, when open, is
/// always the highest and so current). Their Connects go to the first that
/// accepts Connects, as before registration numbers: parking them instead
/// would leave every client waiting out its expiry until a numbered Register
/// or a socket close. Only the Connect allocation falls back this way; a
/// non-current registration's Ping still hands over nothing. A fallback
/// allocation to a daemon that never joins leaves its circuit unjoined, so
/// the slot's other open registrations are owed it
/// (`owed_handover_after_fallback`).
pub(crate) fn live_daemon<T>(
    candidates: impl IntoIterator<Item = (T, u16, SlotAttachment)>,
    slot: &str,
    now_ms: u64,
) -> Option<T> {
    let candidates: Vec<_> = candidates.into_iter().collect();
    let sockets: Vec<_> = candidates
        .iter()
        .map(|(_, ready_state, attachment)| (*ready_state, attachment.clone()))
        .collect();
    let current: Vec<bool> = candidates
        .iter()
        .enumerate()
        .map(|(index, (_, ready_state, attachment))| {
            let others = sockets
                .iter()
                .enumerate()
                .filter(|(other, _)| *other != index)
                .map(|(_, (ready_state, other))| (*ready_state, other.clone()));
            current_registration(attachment, *ready_state, others)
        })
        .collect();
    let any_current = current.iter().any(|current| *current);
    candidates.into_iter().zip(current).find_map(|((handle, ready_state, attachment), current)| {
        let eligible = if any_current { current } else { attachment.generation == 0 };
        (eligible && accepts_connects(&attachment, ready_state, slot, now_ms)).then_some(handle)
    })
}

/// Whether a Connect allocation chosen as `chosen` (a handle and its
/// registration number) before an await still goes to it after: the slot's
/// choice now (`live_daemon` over `candidates`) is the same socket with the
/// same registration number. A Register that replaced it, or a close,
/// while the allocation waited makes this false, and the Connect parks.
pub(crate) fn still_allocated_to<T: PartialEq>(
    candidates: impl IntoIterator<Item = (T, u16, SlotAttachment)>,
    slot: &str,
    now_ms: u64,
    chosen: &T,
    registration: u64,
) -> bool {
    let candidates: Vec<_> = candidates
        .into_iter()
        .map(|(handle, ready_state, attachment)| {
            let number = attachment.generation;
            ((handle, number), ready_state, attachment)
        })
        .collect();
    live_daemon(candidates, slot, now_ms)
        .is_some_and(|(handle, number)| handle == *chosen && number == registration)
}

/// Whether `other`, another control socket on `slot` in `ready_state`, is
/// owed the slot's unjoined circuits after a Connect went to a registration
/// that isn't current (`live_daemon`'s legacy fallback): it is an open
/// registration, so it may become current when the others close, and its
/// next Ping would then be a heartbeat that hands over nothing, leaving the
/// circuit of a fallback daemon that never joined to wait out its deadline.
/// Its `pending_handover` is set, so its first current Ping hands them over.
pub(crate) fn owed_handover_after_fallback(
    other: &SlotAttachment,
    ready_state: u16,
    slot: &str,
) -> bool {
    websocket_is_open(ready_state) && replaced_by_register(other, slot)
}

/// Whether `other`, another control socket on `slot` in `ready_state`, is
/// owed the slot's unjoined circuits when `closed`, a control socket on the
/// slot, closes (its peer closed it or went away, or the cleanup alarm
/// closed it past its idle deadline).
///
/// While two or more legacy registrations (number 0) are open, none is
/// current, and an unjoined circuit may be waiting on any of them: the relay
/// before registration numbers gave each Connect to the first live one, and
/// `live_daemon`'s fallback still does. When that daemon is dead, the circuit
/// waits for a hand-over. A surviving legacy registration becomes current
/// only when the others close, and its next Ping is then a heartbeat that
/// hands over nothing, so the circuit would wait out its deadline. So when a
/// legacy registration closes, every other open legacy registration on the
/// slot gets `pending_handover`, and its first current Ping hands it the
/// unjoined circuits. This covers circuits given out before the upgrade,
/// which no fallback allocation after it recorded.
///
/// A numbered registration is never owed this way: it is current from its
/// Register, which handed it every unjoined circuit and closed every other
/// registration, and while it is open every Connect goes to it.
pub(crate) fn owed_handover_after_close(
    closed: &SlotAttachment,
    other: &SlotAttachment,
    ready_state: u16,
    slot: &str,
) -> bool {
    closed.generation == 0
        && replaced_by_register(closed, slot)
        && other.generation == 0
        && owed_handover_after_fallback(other, ready_state, slot)
}

/// Whether a new daemon `Register` on `slot` closes this existing control
/// socket: one slot has one daemon registration at a time.
pub(crate) fn replaced_by_register(attachment: &SlotAttachment, slot: &str) -> bool {
    attachment.phase == SlotPhase::Registered && attachment.relay.slot == slot
}

/// The registration number a daemon `Register` on `slot` gets: one more than
/// the highest on the slot's control sockets (`existing`, including the one
/// registering). Every registration it replaces is closed.
pub(crate) fn next_registration_number(
    existing: impl IntoIterator<Item = SlotAttachment>,
    slot: &str,
) -> u64 {
    existing
        .into_iter()
        .filter(|attachment| replaced_by_register(attachment, slot))
        .map(|attachment| attachment.generation)
        .max()
        .unwrap_or(0)
        .saturating_add(1)
}

/// Whether `own`, a daemon registration whose socket is in `ready_state`,
/// is still its slot's current one: open, registered, and not replaced by a
/// newer Register on the slot (`others`: the slot's other control sockets,
/// each with its ready state). A socket that is closing or closed is gone:
/// it never makes another registration non-current.
///
/// A registration number of 0 is one written before numbers existed. Two of
/// those carry no order, so a legacy registration is current only while it
/// is the slot's only registration: with another one on the slot, its Ping
/// takes over nothing until that socket closes or a numbered Register
/// replaces both.
pub(crate) fn current_registration(
    own: &SlotAttachment,
    ready_state: u16,
    others: impl IntoIterator<Item = (u16, SlotAttachment)>,
) -> bool {
    websocket_is_open(ready_state)
        && own.phase == SlotPhase::Registered
        && !others.into_iter().any(|(ready_state, other)| {
            websocket_is_open(ready_state)
                && replaced_by_register(&other, &own.relay.slot)
                && (other.generation > own.generation || own.generation == 0)
        })
}

/// What a registered daemon's Ping hands it: the slot's unjoined circuits
/// (`CircuitLedger::unjoined`) and its parked Connects.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PingHandover {
    pub unjoined: bool,
    pub parked: bool,
}

/// Records on `attachment` a Ping its daemon sent at `now_ms`, and says what
/// the Ping hands over. `current` is `current_registration` for the socket.
/// A daemon silent past the window resumed: circuits sent to it meanwhile
/// may never have arrived, so it is handed the unjoined ones. A Ping from a
/// registration that isn't current hands over nothing, and a resumed one
/// leaves `pending_handover` set, so the first Ping after it becomes current
/// is handed them instead.
pub(crate) fn record_ping(
    attachment: &mut SlotAttachment,
    current: bool,
    now_ms: u64,
) -> PingHandover {
    let resumed = !heard_within_window(attachment, now_ms) || attachment.pending_handover;
    attachment.last_seen_ms = now_ms;
    attachment.pending_handover = resumed && !current;
    if !current {
        return PingHandover { unjoined: false, parked: false };
    }
    PingHandover { unjoined: resumed, parked: true }
}

#[cfg(test)]
#[path = "daemon_tests.rs"]
mod tests;
