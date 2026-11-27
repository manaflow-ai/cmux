//! One-hop cold dial (RFD 0039 cut 5), as the Durable Object relay runs it
//! (`relays/cloudflare-do/src/inline.rs`): the relay pairs a client's inline `Connect` with a daemon
//! `Standby` socket and forwards binary frames between the two, with no second circuit socket.
//!
//! A daemon keeps up to [`MAX_STANDBY_SOCKETS_PER_SLOT`] spare sockets, each authenticated with its
//! Register ticket (`RelayControl::Standby`, answered `Registered`). A standby is not the slot's
//! registration: it replaces nothing, is never sent `Incoming` and takes no control-socket place. A
//! Connect with `inline: true` that finds the slot's daemon registered and a standby free takes it:
//! both sockets become one ready circuit, the client gets `Ready` and then the standby gets `Ready`.
//! Any other Connect, and one that finds no standby, is answered `Allocated`/`Incoming` as before.
//!
//! Quota: an inline circuit is a ready circuit, so it counts toward the relay's circuit limit, the
//! slot's active-circuit limit and the slot's allocation-rate window, as a classic one does.

use std::time::{Duration, Instant, SystemTime};

use axum::extract::ws::WebSocket;
use cmux_remote_protocol::{CircuitId, LaneToken, RelayControl, RelayPermission, RelayRole};
use futures_util::stream::SplitStream;
use tokio::sync::oneshot;
use uuid::Uuid;

use super::{
    ALLOCATION_RATE_WINDOW, Attachment, Circuit, CloseNotice, ConnectionEnd, ConnectionId,
    ConnectionResult, Peer, Relay, RelayError, RelayState, expiry_as_instant,
    release_control_socket, validate_protocol, validate_slot, validate_ticket_size,
};
use crate::ticket::{TicketExpectation, tickets_equal};

/// Standby sockets one slot holds at once; a further one is refused with a retryable capacity error.
pub(super) const MAX_STANDBY_SOCKETS_PER_SLOT: usize = 4;
/// A standby must outlive its pairing by this long: a ticket that expires mid-dial would drop the circuit.
const STANDBY_MIN_REMAINING: Duration = Duration::from_millis(5_000);
const STANDBY_CAPACITY_CODE: &str = "standby-capacity";
const STANDBY_CAPACITY_MESSAGE: &str = "slot standby limit was reached";

/// A daemon's spare socket waiting on its slot for an inline Connect.
pub(super) struct StandbyRegistration {
    peer: Peer,
    /// The Register ticket it authenticated with: an open (unsigned) relay pairs it only with the
    /// registration holding the same ticket, as an open relay lets only that ticket re-register.
    ticket: String,
    /// When its ticket runs out (`None`: an open relay's unsigned ticket).
    expiry: Option<Instant>,
    /// When its daemon last spoke on it: of several free standbys, the one heard last is taken.
    last_seen: Instant,
    /// Tells the standby's socket task which circuit it now carries.
    paired: oneshot::Sender<CircuitId>,
}

/// What a Connect was answered with.
pub(super) enum Allocation {
    /// `Allocated` to the client and `Incoming` to the daemon: the two-socket circuit.
    Classic,
    /// `Ready` on the client's own socket, which now carries the circuit.
    Inline(CircuitId),
}

impl StandbyRegistration {
    fn takeable(&self, now: Instant) -> bool {
        self.peer.shutdown.borrow().is_none()
            && self.expiry.is_none_or(|expiry| expiry > now + STANDBY_MIN_REMAINING)
    }
}

impl Relay {
    /// A daemon's `Standby`: checked as a Register is, then held until a Connect takes it.
    pub(super) async fn hold_standby(
        &self,
        reader: &mut SplitStream<WebSocket>,
        peer: &Peer,
        protocol: u8,
        slot: String,
        ticket: String,
    ) -> ConnectionResult {
        let paired = self
            .admit_standby(peer, protocol, &slot, ticket)
            .await
            .map_err(ConnectionEnd::Failed)?;
        self.run_standby(reader, peer, &slot, paired).await
    }

    async fn admit_standby(
        &self,
        peer: &Peer,
        protocol: u8,
        slot: &str,
        ticket: String,
    ) -> Result<oneshot::Receiver<CircuitId>, RelayError> {
        validate_protocol(protocol)?;
        validate_slot(slot)?;
        validate_ticket_size(&ticket)?;
        let system_now = SystemTime::now();
        let instant_now = Instant::now();
        let claims = self
            .inner
            .tickets
            .verify_provider(
                &ticket,
                TicketExpectation {
                    permission: RelayPermission::Register,
                    role: RelayRole::Daemon,
                    slot,
                    circuit: None,
                    lane: None,
                    generation: None,
                    require_route_binding: false,
                },
                system_now,
            )
            .map_err(|error| RelayError::policy("invalid-ticket", error.to_string(), false))?;
        let expiry = claims
            .as_ref()
            .map(|claims| expiry_as_instant(claims.expires_at_unix, system_now, instant_now))
            .transpose()?;
        let deadline = expiry.map_or(instant_now + self.inner.config.lease_duration, |expiry| {
            expiry.min(instant_now + self.inner.config.lease_duration)
        });

        let (paired, receiver) = oneshot::channel();
        {
            let mut state = self.inner.state.lock().await;
            let held = state.standbys.entry(slot.to_owned()).or_default();
            held.retain(|standby| standby.peer.shutdown.borrow().is_none());
            if held.len() >= MAX_STANDBY_SOCKETS_PER_SLOT {
                return Err(RelayError::capacity(STANDBY_CAPACITY_CODE, STANDBY_CAPACITY_MESSAGE));
            }
            held.push(StandbyRegistration {
                peer: peer.clone(),
                ticket,
                expiry,
                last_seen: instant_now,
                paired,
            });
            state.attachments.insert(peer.id, Attachment::Standby { slot: slot.to_owned() });
        }

        let lease_seconds =
            deadline.saturating_duration_since(instant_now).as_secs().min(u64::from(u32::MAX))
                as u32;
        peer.send_control(RelayControl::Registered { lease_seconds })?;
        Ok(receiver)
    }

    /// A standby's socket: Ping is answered Pong until a Connect takes it, then it carries the
    /// circuit's binary frames.
    async fn run_standby(
        &self,
        reader: &mut SplitStream<WebSocket>,
        peer: &Peer,
        slot: &str,
        mut paired: oneshot::Receiver<CircuitId>,
    ) -> ConnectionResult {
        loop {
            tokio::select! {
                biased;
                circuit = &mut paired => {
                    let Ok(circuit) = circuit else {
                        return Err(ConnectionEnd::Closed);
                    };
                    return self.run_circuit(reader, peer, circuit).await;
                }
                control = self.read_authenticated_control(reader, peer) => {
                    match control? {
                        RelayControl::Ping { nonce } => {
                            self.touch_standby(peer.id, slot).await;
                            peer.send_control(RelayControl::Pong { nonce })
                                .map_err(ConnectionEnd::Failed)?;
                        }
                        _ => {
                            peer.send_control(
                                RelayError::protocol(
                                    "unexpected-control",
                                    "standby sockets accept only ping until a connect takes them",
                                )
                                .control(),
                            )
                            .map_err(ConnectionEnd::Failed)?;
                        }
                    }
                }
            }
        }
    }

    async fn touch_standby(&self, peer_id: ConnectionId, slot: &str) {
        let mut state = self.inner.state.lock().await;
        if let Some(standby) = state
            .standbys
            .get_mut(slot)
            .and_then(|held| held.iter_mut().find(|standby| standby.peer.id == peer_id))
        {
            standby.last_seen = Instant::now();
        }
    }
}

/// Pairs `client` with a free standby on `slot`, under the state lock, once its Connect passed the
/// ticket and registration checks. `Ok(None)`: no standby is free, answer the Connect classically.
/// The caller sends `Ready` to the client and then to the returned standby.
pub(super) fn pair_inline(
    state: &mut RelayState,
    limits: InlineLimits,
    client: &Peer,
    slot: &str,
    lane: &LaneToken,
    generation: u64,
    now: Instant,
) -> Result<Option<(CircuitId, Peer)>, RelayError> {
    let registration_ticket =
        state.controls.get(slot).map(|control| control.provider_ticket.clone());
    let Some(index) = state.standbys.get(slot).and_then(|held| {
        held.iter()
            .enumerate()
            .filter(|(_, standby)| standby.takeable(now))
            .filter(|(_, standby)| {
                limits.signed
                    || registration_ticket
                        .as_deref()
                        .is_some_and(|ticket| tickets_equal(ticket, &standby.ticket))
            })
            .max_by_key(|(_, standby)| standby.last_seen)
            .map(|(index, _)| index)
    }) else {
        return Ok(None);
    };

    let client_was_control = match state.attachments.get(&client.id) {
        Some(Attachment::ClientControl { slot: attached }) if attached == slot => true,
        Some(_) => {
            return Err(RelayError::policy(
                "invalid-control-attachment",
                "relay socket already has a different attachment",
                false,
            ));
        }
        None => false,
    };
    if state.circuits.len() >= limits.max_circuits {
        return Err(RelayError::capacity("circuit-limit", "relay circuit limit was reached"));
    }
    {
        let usage = state.slot_usage.entry(slot.to_owned()).or_default();
        while usage.recent_allocations.front().is_some_and(|allocation| {
            now.saturating_duration_since(*allocation) >= ALLOCATION_RATE_WINDOW
        }) {
            usage.recent_allocations.pop_front();
        }
        if usage.recent_allocations.len() >= limits.max_allocations_per_second {
            return Err(RelayError::capacity(
                "slot-allocation-rate-limit",
                "relay allocation rate limit for this slot was reached",
            ));
        }
        if usage.active_circuits >= limits.max_active_circuits {
            return Err(RelayError::capacity(
                "slot-active-circuit-limit",
                "relay active circuit limit for this slot was reached",
            ));
        }
        usage.recent_allocations.push_back(now);
    }

    let Some(standby) = state.standbys.get_mut(slot).map(|held| held.swap_remove(index)) else {
        return Ok(None);
    };
    if state.standbys.get(slot).is_some_and(Vec::is_empty) {
        state.standbys.remove(slot);
    }
    if client_was_control {
        release_control_socket(state, slot);
    }
    let circuit = CircuitId(Uuid::new_v4().simple().to_string());
    state.circuits.insert(
        circuit.clone(),
        Circuit {
            slot: slot.to_owned(),
            lane: lane.clone(),
            generation,
            // Both roles are attached, so no Join can take this circuit (`role-already-joined`).
            client_join_ticket: String::new(),
            daemon_join_ticket: String::new(),
            created_at: now,
            last_activity: now,
            client: Some(client.clone()),
            daemon: Some(standby.peer.clone()),
            ready: true,
        },
    );
    state.slot_usage.entry(slot.to_owned()).or_default().active_circuits += 1;
    state.attachments.insert(
        client.id,
        Attachment::Circuit { circuit: circuit.clone(), role: RelayRole::Client },
    );
    state.attachments.insert(
        standby.peer.id,
        Attachment::Circuit { circuit: circuit.clone(), role: RelayRole::Daemon },
    );
    // The standby's task moves to the circuit before its daemon reads `Ready`, so its first frame
    // finds the circuit.
    let _ = standby.paired.send(circuit.clone());
    Ok(Some((circuit, standby.peer)))
}

/// The limits an inline pairing counts against, copied from the relay's config.
#[derive(Clone, Copy)]
pub(super) struct InlineLimits {
    /// Whether tickets are signed; an open relay matches a standby's ticket to the registration's.
    pub signed: bool,
    pub max_circuits: usize,
    pub max_active_circuits: usize,
    pub max_allocations_per_second: usize,
}

/// Drops the standby `peer_id` held on `slot` (its socket closed).
pub(super) fn remove_standby(state: &mut RelayState, slot: &str, peer_id: ConnectionId) {
    if let Some(held) = state.standbys.get_mut(slot) {
        held.retain(|standby| standby.peer.id != peer_id);
        if held.is_empty() {
            state.standbys.remove(slot);
        }
    }
}

/// Removes the standbys whose ticket ran out by `now` and returns their peers to close.
pub(super) fn expire_standbys(state: &mut RelayState, now: Instant) -> Vec<Peer> {
    let mut expired = Vec::new();
    for held in state.standbys.values_mut() {
        let mut index = 0;
        while index < held.len() {
            if held.get(index).is_some_and(|standby| standby.expiry.is_some_and(|at| at <= now)) {
                expired.push(held.swap_remove(index).peer);
            } else {
                index += 1;
            }
        }
    }
    state.standbys.retain(|_, held| !held.is_empty());
    for peer in &expired {
        state.attachments.remove(&peer.id);
    }
    expired
}

/// Closes `peers`, standbys whose ticket ran out.
pub(super) fn close_expired_standbys(peers: Vec<Peer>) {
    for peer in peers {
        peer.shutdown(CloseNotice::error(RelayError::policy(
            "lease-expired",
            "daemon standby ticket expired",
            true,
        )));
    }
}
