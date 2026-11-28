use cmux_remote_protocol::RelaySocketAttachment;

use super::*;
use crate::abuse::{DAEMON_CONTROL_IDLE_TIMEOUT_MS, websocket_counts_toward_capacity};
use crate::attachment::InlineState;
use crate::daemon::{accepts_connects, live_daemon};
use crate::inline::{standby_count, takeable_standby};

const SLOT: &str = "slot-a";
const OPEN: u16 = 1;
const CLOSED: u16 = 3;
const T: u64 = 1_800_000_000_000;
const TICKET_S: u64 = T / 1_000 + 300;

fn socket(phase: SlotPhase, generation: u64, idle_deadline_ms: u64) -> SlotAttachment {
    SlotAttachment {
        relay: RelaySocketAttachment::control(SLOT.into()),
        phase,
        generation,
        expires_at: TICKET_S,
        idle_deadline_ms,
        parked: None,
        last_seen_ms: T,
        pending_handover: false,
        inline: InlineState::default(),
    }
}

fn registration(generation: u64) -> SlotAttachment {
    socket(SlotPhase::Registered, generation, T + DAEMON_CONTROL_IDLE_TIMEOUT_MS)
}

fn standby() -> SlotAttachment {
    socket(SlotPhase::Standby, 0, TICKET_S * 1_000)
}

/// The probe's case: a machine paused right after its last Ping. Its registration's 45 s idle deadline
/// passes, and the alarm does not close it (a close frame would wake the machine); it stays open for a day.
#[test]
fn a_paused_machines_registration_is_not_closed_at_its_idle_deadline() {
    let paused = registration(3);
    let idle = paused.idle_deadline_ms;
    assert!(retires_when_silent(&paused));
    assert_eq!(close_deadline_ms(&paused), idle + RETIRED_DAEMON_HOLD_MS);
    assert!(close_deadline_ms(&paused) > idle + 60 * 60_000, "an hour's pause gets no close frame");
    assert!(retired(&paused, OPEN, SLOT, idle));
    assert!(!retired(&paused, OPEN, SLOT, idle - 1), "before its deadline it is live");
    assert!(!retired(&paused, CLOSED, SLOT, idle), "a closed socket is gone, not retired");
    assert!(!retired(&paused, OPEN, "other-slot", idle));
}

/// The same for a standby at its ticket's expiry, its idle deadline.
#[test]
fn a_paused_machines_standby_is_not_closed_at_its_ticket_expiry() {
    let paused = standby();
    assert!(retires_when_silent(&paused));
    assert_eq!(close_deadline_ms(&paused), TICKET_S * 1_000 + RETIRED_DAEMON_HOLD_MS);
    assert!(retired(&paused, OPEN, SLOT, TICKET_S * 1_000));
}

/// Every socket that is not a numbered registration or a standby closes at its idle deadline, as before: a
/// legacy registration (its close hands over the circuits it held), a pending upgrade, a client control and
/// an inline circuit socket.
#[test]
fn other_sockets_still_close_at_their_idle_deadline() {
    let deadline = T + 15_000;
    let mut client = socket(SlotPhase::ClientControl, 0, deadline);
    client.relay.role = RelayRole::Client;
    for other in [
        registration(0),
        socket(SlotPhase::Pending, 0, deadline),
        socket(SlotPhase::Inline, 1, deadline),
        client,
    ] {
        assert!(!retires_when_silent(&other), "{:?} gen {}", other.phase, other.generation);
        assert_eq!(close_deadline_ms(&other), other.idle_deadline_ms);
        assert!(!retired(&other, OPEN, SLOT, other.idle_deadline_ms));
    }
}

/// What the 45 s close protected still holds for a retired socket: it takes no Connect (the Connect parks
/// for the next Register, as with no registration), takes no standby pairing, and counts toward no limit, so
/// the Register and standbys its machine sends on resume are admitted.
#[test]
fn a_retired_socket_takes_no_connect_and_holds_no_capacity() {
    let paused = registration(3);
    let now = paused.idle_deadline_ms;
    assert!(retired(&paused, OPEN, SLOT, now));
    assert!(!accepts_connects(&paused, OPEN, SLOT, now));
    assert_eq!(live_daemon([("paused", OPEN, paused.clone())], SLOT, now), None);
    assert!(!websocket_counts_toward_capacity(OPEN, paused.idle_deadline_ms, now));

    let spare = standby();
    let expired = TICKET_S * 1_000;
    assert!(!takeable_standby(&spare, OPEN, SLOT, expired));
    let four_retired = (0..4).map(|_| (OPEN, spare.clone()));
    assert_eq!(standby_count(four_retired, SLOT, expired), 0, "resume's standbys find room");

    assert!(!websocket_counts_toward_capacity(OPEN, spare.idle_deadline_ms, expired));
}

/// A machine that is awake (it sent a Register or Standby) closes the slot's retired standbys, so retired
/// sockets never pile up across pauses; its live standbys and the registration are left alone (the
/// registration is closed by the Register's replacement).
#[test]
fn an_awake_daemon_closes_retired_standbys_only() {
    let expired = TICKET_S * 1_000;
    let later = socket(SlotPhase::Standby, 0, expired + 60_000);
    assert!(closed_by_awake_daemon(&standby(), OPEN, SLOT, expired));
    assert!(!closed_by_awake_daemon(&later, OPEN, SLOT, expired), "still live");
    assert!(!closed_by_awake_daemon(&standby(), CLOSED, SLOT, expired));
    assert!(!closed_by_awake_daemon(&standby(), OPEN, "other-slot", expired));
    assert!(!closed_by_awake_daemon(&registration(3), OPEN, SLOT, expired));
}
