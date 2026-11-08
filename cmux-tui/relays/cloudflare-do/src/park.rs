//! A client `Connect` that reaches the slot before its daemon has registered
//! waits on the client's allocation socket instead of being refused. The
//! daemon's accepted `Register` is the readiness event: the slot then sends
//! `Allocated` and `Incoming` for every waiting request, so the client is
//! paired one WebSocket hop after the daemon comes up, with no retry.
//!
//! The waiting request lives in the socket attachment, so it survives
//! hibernation. It ends at the socket's idle deadline, which is already bounded
//! by the Connect ticket's expiry; the alarm then answers it with the same
//! retryable `daemon-offline` error an offline slot gave before, so a client
//! that expects an immediate answer behaves as it did.

use cmux_remote_protocol::{LaneToken, RelayControl, RelayRole};
use serde::{Deserialize, Serialize};

use crate::abuse::{MAX_PENDING_CIRCUITS_PER_SLOT, websocket_counts_toward_capacity};
use crate::attachment::{SlotAttachment, SlotPhase};

pub(crate) const DAEMON_OFFLINE_CODE: &str = "daemon-offline";
pub(crate) const DAEMON_OFFLINE_MESSAGE: &str = "daemon is not connected";

/// One verified Connect waiting for the slot's daemon. The ticket was checked
/// when it arrived; its expiry is the attachment's `expires_at`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ParkedConnect {
    pub lane: LaneToken,
    pub generation: u64,
    pub parked_at_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ConnectDisposition {
    /// A daemon is registered: allocate the circuit now.
    Allocate,
    /// No daemon yet: hold the request until one registers.
    Park,
    /// No daemon and the slot already holds as many waiting or pending
    /// allocations as it may: answer `daemon-offline` now.
    Offline,
}

/// Decides what a verified Connect gets. A waiting request counts against the
/// same 16 pending allocations as a pending circuit, since each one becomes a
/// pending circuit when the daemon registers.
pub(crate) fn connect_disposition(
    daemon_registered: bool,
    parked_on_other_sockets: usize,
    pending_circuits: usize,
) -> ConnectDisposition {
    if daemon_registered {
        ConnectDisposition::Allocate
    } else if parked_on_other_sockets.saturating_add(pending_circuits)
        < MAX_PENDING_CIRCUITS_PER_SLOT
    {
        ConnectDisposition::Park
    } else {
        ConnectDisposition::Offline
    }
}

/// The `Parked` notice a client gets when its Connect waits. Only a client
/// that set `accepts_parked` gets one: an older client fails on a control
/// type it does not know, and keeps waiting for `Allocated` without it.
pub(crate) fn parked_notice(
    accepts_parked: bool,
    lane: &LaneToken,
    generation: u64,
) -> Option<RelayControl> {
    accepts_parked.then(|| RelayControl::Parked { lane: lane.clone(), generation })
}

/// Whether this socket holds a Connect that a newly registered daemon on
/// `slot` should answer now.
pub(crate) fn parked_and_live(
    attachment: &SlotAttachment,
    ready_state: u16,
    slot: &str,
    now_ms: u64,
) -> bool {
    attachment.parked.is_some()
        && attachment.phase == SlotPhase::ClientControl
        && attachment.relay.role == RelayRole::Client
        && attachment.relay.slot == slot
        && attachment.expires_at > now_ms / 1_000
        && websocket_counts_toward_capacity(ready_state, attachment.idle_deadline_ms, now_ms)
}

/// Orders the waiting requests a registration answers: oldest first.
pub(crate) fn pairing_order<T>(mut waiting: Vec<(T, ParkedConnect)>) -> Vec<(T, ParkedConnect)> {
    waiting.sort_by_key(|(_, parked)| parked.parked_at_ms);
    waiting
}

/// Whether the alarm, closing this expired socket, must first answer a
/// waiting Connect with `daemon-offline`.
pub(crate) fn expired_while_parked(attachment: &SlotAttachment, now_ms: u64) -> bool {
    attachment.parked.is_some() && attachment.idle_deadline_ms <= now_ms
}

#[cfg(test)]
mod tests {
    use cmux_remote_protocol::RelaySocketAttachment;

    use super::*;
    use crate::abuse::CLIENT_CONTROL_IDLE_TIMEOUT_MS;

    const OPEN: u16 = 1;
    const CLOSING: u16 = 2;
    const NOW_MS: u64 = 1_000_000_000;

    fn client(parked: Option<ParkedConnect>) -> SlotAttachment {
        SlotAttachment {
            relay: RelaySocketAttachment {
                role: RelayRole::Client,
                slot: "slot".into(),
                circuit: None,
                lane: None,
            },
            phase: SlotPhase::ClientControl,
            generation: 3,
            expires_at: NOW_MS / 1_000 + 300,
            idle_deadline_ms: NOW_MS + CLIENT_CONTROL_IDLE_TIMEOUT_MS,
            parked,
            last_seen_ms: 0,
        }
    }

    fn request(lane: &str, parked_at_ms: u64) -> ParkedConnect {
        ParkedConnect { lane: LaneToken(lane.into()), generation: 3, parked_at_ms }
    }

    /// The client's Connect reaches the slot first; the daemon registers
    /// later. The slot holds the request across hibernation and the daemon's
    /// Register answers it, so the client needs no second Connect.
    #[test]
    fn connect_before_register_is_paired_on_register_without_retry() {
        assert_eq!(connect_disposition(false, 0, 0), ConnectDisposition::Park);

        let mut attachment = client(None);
        attachment.parked = Some(request("lane-a", NOW_MS));
        let hibernated = serde_json::to_vec(&attachment).unwrap();
        let woken: SlotAttachment = serde_json::from_slice(&hibernated).unwrap();
        assert_eq!(woken, attachment);

        let register_ms = NOW_MS + 4_000;
        assert!(parked_and_live(&woken, OPEN, "slot", register_ms));
        let paired = pairing_order(vec![(0, woken.parked.unwrap())]);
        assert_eq!(paired.len(), 1);
        assert_eq!(paired[0].1.lane, LaneToken("lane-a".into()));
        assert_eq!(paired[0].1.generation, 3);
    }

    #[test]
    fn registered_daemon_still_allocates_at_once() {
        assert_eq!(connect_disposition(true, 0, 0), ConnectDisposition::Allocate);
        assert_eq!(
            connect_disposition(true, 0, MAX_PENDING_CIRCUITS_PER_SLOT),
            ConnectDisposition::Allocate
        );
    }

    #[test]
    fn parking_stays_within_the_pending_allocation_limit() {
        assert_eq!(
            connect_disposition(false, 5, MAX_PENDING_CIRCUITS_PER_SLOT - 6),
            ConnectDisposition::Park
        );
        assert_eq!(
            connect_disposition(false, 5, MAX_PENDING_CIRCUITS_PER_SLOT - 5),
            ConnectDisposition::Offline
        );
        assert_eq!(
            connect_disposition(false, 0, MAX_PENDING_CIRCUITS_PER_SLOT),
            ConnectDisposition::Offline
        );
    }

    #[test]
    fn register_answers_only_live_parked_requests_on_its_slot() {
        let parked = client(Some(request("lane-a", NOW_MS)));
        assert!(parked_and_live(&parked, OPEN, "slot", NOW_MS + 1));
        assert!(!parked_and_live(&client(None), OPEN, "slot", NOW_MS + 1));
        assert!(!parked_and_live(&parked, OPEN, "other-slot", NOW_MS + 1));
        assert!(!parked_and_live(&parked, CLOSING, "slot", NOW_MS + 1));
        assert!(!parked_and_live(&parked, OPEN, "slot", parked.idle_deadline_ms));
        assert!(!parked_and_live(&parked, OPEN, "slot", parked.expires_at * 1_000));
    }

    #[test]
    fn register_pairs_waiting_requests_oldest_first() {
        let order = pairing_order(vec![
            ("late", request("lane-b", NOW_MS + 20)),
            ("early", request("lane-a", NOW_MS + 10)),
        ]);
        let labels: Vec<_> = order.iter().map(|(label, _)| *label).collect();
        assert_eq!(labels, ["early", "late"]);
    }

    /// A request that waits out its deadline gets the answer an offline slot
    /// gave before parking existed, then its socket closes.
    #[test]
    fn parked_connect_expires_with_daemon_offline() {
        let mut attachment = client(Some(request("lane-a", NOW_MS)));
        attachment.idle_deadline_ms =
            (attachment.expires_at * 1_000).min(attachment.idle_deadline_ms);
        assert!(!expired_while_parked(&attachment, attachment.idle_deadline_ms - 1));
        assert!(expired_while_parked(&attachment, attachment.idle_deadline_ms));
        assert!(!expired_while_parked(&client(None), attachment.idle_deadline_ms));
        assert!(!parked_and_live(&attachment, OPEN, "slot", attachment.idle_deadline_ms));
        assert_eq!(DAEMON_OFFLINE_CODE, "daemon-offline");
    }

    #[test]
    fn parked_notice_goes_only_to_clients_that_ask_for_it() {
        let lane = LaneToken("lane-a".into());
        assert_eq!(
            parked_notice(true, &lane, 3),
            Some(RelayControl::Parked { lane: lane.clone(), generation: 3 })
        );
        assert_eq!(parked_notice(false, &lane, 3), None);

        let legacy = r#"{"type":"connect","protocol":1,"slot":"slot","ticket":"t","lane":"lane-a","generation":3}"#;
        let RelayControl::Connect { accepts_parked, .. } = serde_json::from_str(legacy).unwrap()
        else {
            panic!("expected connect");
        };
        assert!(!accepts_parked, "an older client's Connect never gets Parked");
    }

    #[test]
    fn attachment_from_before_parking_reads_as_not_parked() {
        let encoded = br#"{
            "relay":{"role":"client","slot":"slot","circuit":null,"lane":null},
            "phase":"client-control",
            "generation":0,
            "expires_at":1000,
            "idle_deadline_ms":2000
        }"#;
        let decoded: SlotAttachment = serde_json::from_slice(encoded).unwrap();
        assert!(decoded.parked.is_none());
    }
}
