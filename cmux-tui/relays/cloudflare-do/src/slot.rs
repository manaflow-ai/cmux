use std::cell::RefCell;
use std::collections::HashMap;
use std::time::Duration;

use cmux_remote_protocol::{
    CircuitId, LaneToken, MAX_RELAY_BATCH_BYTES, REMOTE_PROTOCOL_VERSION, RelayControl,
    RelayPermission, RelayRole, RelaySocketAttachment, RelayTicketClaims,
};
use worker::{
    Date, DurableObject, Env, Method, Request, Response, Result, State, WebSocket,
    WebSocketIncomingMessage, WebSocketPair, durable_object,
};

use crate::abuse::{
    CIRCUIT_IDLE_TIMEOUT_MS, CIRCUITS_STORAGE_KEY, CLIENT_CONTROL_IDLE_TIMEOUT_MS, CapacityRefusal,
    CircuitLedger, DAEMON_CONTROL_IDLE_TIMEOUT_MS, InlineLoad, PendingRoute,
    SLOT_HANDSHAKE_TIMEOUT_MS, SlotEndpoint, SlotSocketCounts, admit_slot_socket,
    websocket_counts_toward_capacity,
};
use crate::attachment::{InlineState, SlotAttachment, SlotPhase};
use crate::auth::{DEFAULT_TICKET_ISSUER, TicketExpectation, issue_ticket, verify_ticket};
use crate::daemon::{
    current_registration, live_daemon, next_registration_number, owed_handover_after_close,
    owed_handover_after_fallback, record_ping, replaced_by_register, still_allocated_to,
};
use crate::forward::{
    CLOSE_OVERLOADED, CLOSE_UNSUPPORTED, outbound_queue_close, persist_peer_before_forward,
    reserve_outbound_frame,
};
use crate::inline::{
    InlineWindow, STANDBY_CAPACITY_CODE, STANDBY_CAPACITY_MESSAGE, inline_peer,
    latest_inline_deadline, live_inline_circuits, live_standby, standby_count, standby_has_room,
};
use crate::park::{
    ConnectDisposition, DAEMON_OFFLINE_CODE, DAEMON_OFFLINE_MESSAGE, ParkedConnect,
    connect_disposition, expired_while_parked, pairing_order, parked_and_live, parked_notice,
};
use crate::placement::{REGION_HEADER, is_region};
use crate::retire::{close_deadline_ms, closed_by_awake_daemon};
use crate::wire::{
    close, decode_control, send_control, upgrade_required, valid_circuit_id,
    valid_opaque_identifier, websocket_upgrade,
};

const CONTROL_TAG: &str = "daemon-control";
const CONNECT_TAG: &str = "client-allocation";
/// A socket's tag naming the location hint of the caller that opened it (`crate::placement`): `region:weur`.
/// `[vars]` switch, "1" to place far viewers' circuits near them. Off unless set (merge default-off).
const VIEWER_CIRCUITS_VAR: &str = "CMUX_RELAY_VIEWER_CIRCUITS";
const REGION_TAG_PREFIX: &str = "region:";
const MAX_SLOT_ID_BYTES: usize = 128;
const MAX_LANE_TOKEN_BYTES: usize = 128;
const JOIN_TICKET_TTL_SECONDS: u64 = 30;
const REGISTRATION_HEARTBEAT_SECONDS: u64 = 30;
const CLOSE_POLICY: u16 = 1008;

#[durable_object]
pub struct RelaySlot {
    state: State,
    env: Env,
    /// Inline circuits' sockets by circuit id, so a frame finds its peer without scanning the slot's sockets.
    /// Memory only: a hibernated object rebuilds an entry from the sockets' attachments on its first frame
    /// (`RelaySlot::inline_peer_of`), and the entry is checked against the peer's attachment every time.
    inline_sockets: RefCell<HashMap<String, Vec<WebSocket>>>,
    /// Inline allocations in the current window (`crate::inline`).
    inline_window: RefCell<InlineWindow>,
}

/// What `RelaySlot::pair_inline` did with an inline Connect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InlineOutcome {
    /// Paired with a standby: the client and the standby are answered `Ready`, or closed if a send failed.
    Paired,
    /// Refused for the slot's circuit quota or allocation rate: the client was answered.
    Refused,
    /// No live standby is free (none ever, or another Connect took it): answer as a classic Connect.
    NoStandby,
}

/// What `RelaySlot::allocate` did with a Connect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Allocation {
    /// The client was answered: allocated, refused for capacity, or closed
    /// because its own socket failed.
    Sent,
    /// The daemon's socket failed and was closed, as was the client's.
    DaemonFailed,
    /// The daemon was replaced or closed while the allocation waited; the
    /// circuit was released and nothing was sent. The Connect should park.
    Superseded,
}

struct ConnectRequest {
    protocol: u8,
    slot: String,
    ticket: String,
    lane: LaneToken,
    generation: u64,
    accepts_parked: bool,
    inline: bool,
}

impl RelaySlot {
    fn now_ms(&self) -> u64 {
        Date::now().as_millis()
    }

    /// Whether this Connect leaves the inline path for a classic circuit: the relay is set to place circuits
    /// near the viewer (`CMUX_RELAY_VIEWER_CIRCUITS`) and the viewer's region differs from the daemon's. An
    /// inline circuit carries its frames in this slot's object, which sits by the daemon, so only a classic
    /// circuit, created in the viewer's region by its join ticket, can move the data path.
    fn far_viewer_takes_classic(&self, client: &WebSocket, daemon: Option<&WebSocket>) -> bool {
        if !self.viewer_circuits() {
            return false;
        }
        let viewer = self.socket_region(client);
        let daemon = daemon.and_then(|daemon| self.socket_region(daemon));
        matches!((viewer, daemon), (Some(viewer), Some(daemon)) if viewer != daemon)
    }

    /// Whether `CMUX_RELAY_VIEWER_CIRCUITS` is "1". Off, no ticket names a region and every circuit is
    /// placed near the slot, as before this switch.
    fn viewer_circuits(&self) -> bool {
        self.env.var(VIEWER_CIRCUITS_VAR).is_ok_and(|value| value.to_string() == "1")
    }

    /// The location hint the router tagged `socket` with from its caller's `cf` (`crate::placement`).
    fn socket_region(&self, socket: &WebSocket) -> Option<String> {
        self.state.get_tags(socket).into_iter().find_map(|tag| {
            tag.strip_prefix(REGION_TAG_PREFIX)
                .filter(|region| is_region(region))
                .map(str::to_owned)
        })
    }

    fn now(&self) -> u64 {
        self.now_ms() / 1_000
    }

    fn ticket_key(&self) -> Result<String> {
        Ok(self.env.secret("CMUX_RELAY_TICKET_KEY")?.to_string())
    }

    fn ticket_issuer(&self) -> String {
        self.env
            .var("CMUX_RELAY_TICKET_ISSUER")
            .map(|value| value.to_string())
            .unwrap_or_else(|_| DEFAULT_TICKET_ISSUER.into())
    }

    fn attachment(socket: &WebSocket) -> Result<SlotAttachment> {
        socket
            .deserialize_attachment()?
            .ok_or_else(|| worker::Error::RustError("relay slot socket has no attachment".into()))
    }

    fn fail(socket: &WebSocket, code: &str, message: &str, close_code: u16) {
        let _ = send_control(
            socket,
            &RelayControl::Error { code: code.into(), message: message.into(), retryable: false },
        );
        close(socket, close_code, message);
    }

    fn capacity(socket: &WebSocket, code: &str, message: &str) {
        let _ = send_control(
            socket,
            &RelayControl::Error { code: code.into(), message: message.into(), retryable: true },
        );
    }

    fn socket_counts(&self, now_ms: u64) -> SlotSocketCounts {
        let mut counts = SlotSocketCounts::default();
        for socket in self.state.get_websockets() {
            let Ok(attachment) = Self::attachment(&socket) else {
                continue;
            };
            if !websocket_counts_toward_capacity(
                socket.as_ref().ready_state(),
                attachment.idle_deadline_ms,
                now_ms,
            ) {
                continue;
            }
            // An inline circuit's two sockets are bounded by the circuit quota, not by the control-socket limits.
            if attachment.phase == SlotPhase::Inline {
                continue;
            }
            counts.total += 1;
            if attachment.phase == SlotPhase::Pending {
                counts.pending += 1;
            }
            if attachment.relay.role == RelayRole::Client {
                counts.client += 1;
            } else if attachment.phase == SlotPhase::Pending {
                counts.daemon_pending += 1;
            }
        }
        counts
    }

    fn registered_daemon(&self, slot: &str, now_ms: u64) -> Option<(WebSocket, SlotAttachment)> {
        let candidates =
            self.state.get_websockets_with_tag(CONTROL_TAG).into_iter().filter_map(|socket| {
                let attachment = Self::attachment(&socket).ok()?;
                let ready_state = socket.as_ref().ready_state();
                Some(((socket, attachment.clone()), ready_state, attachment))
            });
        live_daemon(candidates, slot, now_ms)
    }

    /// Whether a Connect allocation that chose `daemon` (registration number
    /// `registration`) before an await still goes to it
    /// (`crate::daemon::still_allocated_to`).
    fn still_allocates_to(
        &self,
        slot: &str,
        daemon: &WebSocket,
        registration: u64,
        now_ms: u64,
    ) -> bool {
        let candidates =
            self.state.get_websockets_with_tag(CONTROL_TAG).into_iter().filter_map(|socket| {
                let attachment = Self::attachment(&socket).ok()?;
                let ready_state = socket.as_ref().ready_state();
                Some((socket, ready_state, attachment))
            });
        still_allocated_to(candidates, slot, now_ms, daemon, registration)
    }

    /// A Connect went to `chosen`, a legacy registration that isn't current
    /// (`crate::daemon::live_daemon`'s fallback): the slot's other open
    /// registrations are owed its circuit if it never joins
    /// (`crate::daemon::owed_handover_after_fallback`).
    fn owe_handover_after_fallback(&self, slot: &str, chosen: &WebSocket) {
        self.owe_handover(chosen, |other, ready_state| {
            owed_handover_after_fallback(other, ready_state, slot)
        });
    }

    /// `closed`, a control socket, closed: if it was a legacy registration,
    /// the slot's other open legacy registrations are owed the circuits it
    /// may have held (`crate::daemon::owed_handover_after_close`).
    fn owe_handover_after_close(&self, closed: &WebSocket) {
        let Ok(attachment) = Self::attachment(closed) else {
            return;
        };
        let slot = attachment.relay.slot.clone();
        self.owe_handover(closed, |other, ready_state| {
            owed_handover_after_close(&attachment, other, ready_state, &slot)
        });
    }

    /// Sets `pending_handover` on every control socket but `except` that
    /// `owed` picks (given its attachment and ready state).
    fn owe_handover(&self, except: &WebSocket, owed: impl Fn(&SlotAttachment, u16) -> bool) {
        for other in self.state.get_websockets_with_tag(CONTROL_TAG) {
            if other == *except {
                continue;
            }
            let Ok(mut attachment) = Self::attachment(&other) else {
                continue;
            };
            if attachment.pending_handover || !owed(&attachment, other.as_ref().ready_state()) {
                continue;
            }
            attachment.pending_handover = true;
            if let Err(error) = other.serialize_attachment(&attachment) {
                worker::console_error!("RelaySlot pending hand-over error: {error}");
            }
        }
    }

    /// Closes the slot's retired standbys (`crate::retire::closed_by_awake_daemon`) but `socket`: its daemon just
    /// sent a Register or Standby, so its machine is awake and the close frame wakes nothing.
    fn close_retired_standbys(&self, socket: &WebSocket, slot: &str, now_ms: u64) {
        for other in self.state.get_websockets_with_tag(CONTROL_TAG) {
            if other == *socket {
                continue;
            }
            if Self::attachment(&other).is_ok_and(|attachment| {
                closed_by_awake_daemon(&attachment, other.as_ref().ready_state(), slot, now_ms)
            }) {
                close(&other, CLOSE_POLICY, "relay socket expired");
            }
        }
    }

    /// Whether `socket`, a registered daemon, is still its slot's current
    /// registration (`crate::daemon::current_registration`).
    fn is_current_registration(&self, socket: &WebSocket, attachment: &SlotAttachment) -> bool {
        let others = self
            .state
            .get_websockets_with_tag(CONTROL_TAG)
            .into_iter()
            .filter(|other| other != socket)
            .filter_map(|other| {
                Some((other.as_ref().ready_state(), Self::attachment(&other).ok()?))
            });
        current_registration(attachment, socket.as_ref().ready_state(), others)
    }

    /// The slot's live inline circuits and their allocations in the window: read from the open sockets' attachments
    /// and memory, with no storage access (`crate::inline`).
    fn inline_load(&self, now_ms: u64) -> InlineLoad {
        let live = live_inline_circuits(
            self.state.get_websockets().into_iter().filter_map(|socket| {
                Some((socket.as_ref().ready_state(), Self::attachment(&socket).ok()?))
            }),
            now_ms,
        );
        self.inline_window.borrow().load(live, now_ms)
    }

    /// The standby a Connect on `slot` takes now (`crate::inline::live_standby`).
    fn takeable_standby(&self, slot: &str, now_ms: u64) -> Option<(WebSocket, SlotAttachment)> {
        let candidates =
            self.state.get_websockets_with_tag(CONTROL_TAG).into_iter().filter_map(|socket| {
                let attachment = Self::attachment(&socket).ok()?;
                let ready_state = socket.as_ref().ready_state();
                Some(((socket, attachment.clone()), ready_state, attachment))
            });
        live_standby(candidates, slot, now_ms)
    }

    async fn circuits(&self) -> Result<CircuitLedger> {
        Ok(self.state.storage().get(CIRCUITS_STORAGE_KEY).await?.unwrap_or_default())
    }

    async fn write_circuits(&self, ledger: &CircuitLedger) -> Result<()> {
        if !ledger.is_empty() {
            self.state.storage().put(CIRCUITS_STORAGE_KEY, ledger).await
        } else {
            self.state.storage().delete(CIRCUITS_STORAGE_KEY).await.map(|_| ())
        }
    }

    async fn reserve_pending_circuit(
        &self,
        circuit: &CircuitId,
        deadline_ms: u64,
        now_ms: u64,
        route: PendingRoute,
    ) -> Result<Result<(), CapacityRefusal>> {
        let mut ledger = self.circuits().await?;
        let load = self.inline_load(now_ms);
        if let Err(refusal) =
            ledger.try_reserve_beside(circuit.0.clone(), deadline_ms, now_ms, Some(route), load)
        {
            return Ok(Err(refusal));
        }
        self.write_circuits(&ledger).await?;
        self.ensure_cleanup_alarm(deadline_ms).await?;
        Ok(Ok(()))
    }

    async fn activate_circuit(&self, circuit: &str, now_ms: u64) -> Result<bool> {
        let mut ledger = self.circuits().await?;
        if !ledger.activate(circuit, now_ms) {
            return Ok(false);
        }
        let deadline = ledger.next_deadline_ms();
        self.write_circuits(&ledger).await?;
        if let Some(deadline) = deadline {
            self.ensure_cleanup_alarm(deadline).await?;
        }
        Ok(true)
    }

    async fn renew_circuit(&self, circuit: &str, now_ms: u64) -> Result<bool> {
        let mut ledger = self.circuits().await?;
        if !ledger.renew(circuit, now_ms) {
            return Ok(false);
        }
        let deadline = ledger.next_deadline_ms();
        self.write_circuits(&ledger).await?;
        if let Some(deadline) = deadline {
            self.ensure_cleanup_alarm(deadline).await?;
        }
        Ok(true)
    }

    async fn release_circuit(&self, circuit: &str) -> Result<()> {
        let mut ledger = self.circuits().await?;
        if ledger.release(circuit) {
            self.write_circuits(&ledger).await?;
        }
        Ok(())
    }

    async fn ensure_cleanup_alarm(&self, deadline_ms: u64) -> Result<()> {
        let storage = self.state.storage();
        let deadline = i64::try_from(deadline_ms).unwrap_or(i64::MAX);
        if storage.get_alarm().await?.is_some_and(|current| current <= deadline) {
            return Ok(());
        }
        let delay_ms = deadline_ms.saturating_sub(self.now_ms()).max(1);
        storage.set_alarm(Duration::from_millis(delay_ms)).await
    }

    async fn schedule_next_cleanup(&self, now_ms: u64) -> Result<()> {
        let socket_deadline = self
            .state
            .get_websockets()
            .into_iter()
            .filter_map(|socket| Self::attachment(&socket).ok())
            .map(|attachment| close_deadline_ms(&attachment))
            .filter(|deadline| *deadline > now_ms)
            .min();
        let mut ledger = self.circuits().await?;
        ledger.prune(now_ms);
        let ledger_deadline = ledger.next_deadline_ms();
        self.write_circuits(&ledger).await?;
        if let Some(deadline) = socket_deadline.into_iter().chain(ledger_deadline).min() {
            self.ensure_cleanup_alarm(deadline).await?;
        }
        Ok(())
    }

    async fn handle_register(
        &self,
        socket: &WebSocket,
        mut attachment: SlotAttachment,
        protocol: u8,
        slot: String,
        ticket: String,
    ) -> Result<()> {
        if protocol != REMOTE_PROTOCOL_VERSION
            || attachment.relay.role != RelayRole::Daemon
            || attachment.relay.slot != slot
        {
            Self::fail(
                socket,
                "invalid-register",
                "registration does not match this slot",
                CLOSE_POLICY,
            );
            return Ok(());
        }

        let now_ms = self.now_ms();
        let now = now_ms / 1_000;
        let key = self.ticket_key()?;
        let issuer = self.ticket_issuer();
        let claims = match verify_ticket(
            &ticket,
            key.as_bytes(),
            &issuer,
            TicketExpectation {
                permission: RelayPermission::Register,
                role: RelayRole::Daemon,
                slot: &slot,
                circuit: None,
                lane: None,
                generation: None,
                now,
            },
        ) {
            Ok(claims) => claims,
            Err(_) => {
                Self::fail(
                    socket,
                    "unauthorized",
                    "registration ticket was rejected",
                    CLOSE_POLICY,
                );
                return Ok(());
            }
        };

        // Each registration on the slot gets the next registration number
        // (kept in `generation`, which a daemon socket has no other use for),
        // so a replaced socket's late Ping knows it is no longer current.
        let existing = self.state.get_websockets_with_tag(CONTROL_TAG);
        let number = next_registration_number(
            existing.iter().filter_map(|other| Self::attachment(other).ok()),
            &slot,
        );
        for other in &existing {
            if other != socket
                && Self::attachment(other)
                    .is_ok_and(|current| replaced_by_register(&current, &slot))
            {
                Self::fail(other, "replaced", "daemon control connection was replaced", 4001);
            }
        }
        self.close_retired_standbys(socket, &slot, now_ms);

        attachment.phase = SlotPhase::Registered;
        attachment.generation = number;
        attachment.last_seen_ms = now_ms;
        // The Register itself is handed the unjoined circuits.
        attachment.pending_handover = false;
        attachment.expires_at = claims.expires_at_unix;
        attachment.idle_deadline_ms = now_ms
            .saturating_add(DAEMON_CONTROL_IDLE_TIMEOUT_MS)
            .min(claims.expires_at_unix.saturating_mul(1_000));
        socket.serialize_attachment(&attachment)?;
        self.ensure_cleanup_alarm(attachment.idle_deadline_ms).await?;

        let lease_seconds = claims
            .expires_at_unix
            .saturating_sub(now)
            .min(REGISTRATION_HEARTBEAT_SECONDS)
            .min(u32::MAX.into()) as u32;
        send_control(socket, &RelayControl::Registered { lease_seconds })?;
        // Circuits allocated to a daemon that never joined them (it went away
        // without closing its socket) go to this one; the client is still
        // waiting on them.
        if let Err(error) = self.hand_over_unjoined(&slot, socket, attachment.expires_at).await {
            worker::console_error!("RelaySlot circuit hand-over error: {error}");
        }
        // A failure answering a waiting client must not fail the daemon's
        // registration; that client is answered with a retryable error.
        if let Err(error) = self.pair_parked(&slot, socket, &attachment).await {
            worker::console_error!("RelaySlot parked pairing error: {error}");
        }
        Ok(())
    }

    /// A daemon's spare socket (`RelayControl::Standby`): checked as a Register is, but it is not the slot's
    /// registration. It replaces nothing, takes no registration number and is sent no `Incoming`; its ticket's
    /// expiry is its idle deadline, and it waits for a Connect to take it (`pair_inline`).
    async fn handle_standby(
        &self,
        socket: &WebSocket,
        mut attachment: SlotAttachment,
        protocol: u8,
        slot: String,
        ticket: String,
    ) -> Result<()> {
        if protocol != REMOTE_PROTOCOL_VERSION
            || attachment.relay.role != RelayRole::Daemon
            || attachment.relay.slot != slot
        {
            Self::fail(socket, "invalid-standby", "standby does not match this slot", CLOSE_POLICY);
            return Ok(());
        }

        let now_ms = self.now_ms();
        let now = now_ms / 1_000;
        let key = self.ticket_key()?;
        let issuer = self.ticket_issuer();
        let claims = match verify_ticket(
            &ticket,
            key.as_bytes(),
            &issuer,
            TicketExpectation {
                permission: RelayPermission::Register,
                role: RelayRole::Daemon,
                slot: &slot,
                circuit: None,
                lane: None,
                generation: None,
                now,
            },
        ) {
            Ok(claims) => claims,
            Err(_) => {
                Self::fail(socket, "unauthorized", "standby ticket was rejected", CLOSE_POLICY);
                return Ok(());
            }
        };

        self.close_retired_standbys(socket, &slot, now_ms);
        // No await between this count and the attachment below: two standbys upgrading together cannot both
        // find room for the last place.
        let held = standby_count(
            self.state
                .get_websockets_with_tag(CONTROL_TAG)
                .into_iter()
                .filter(|other| other != socket)
                .filter_map(|other| {
                    Some((other.as_ref().ready_state(), Self::attachment(&other).ok()?))
                }),
            &slot,
            now_ms,
        );
        if !standby_has_room(held) {
            Self::capacity(socket, STANDBY_CAPACITY_CODE, STANDBY_CAPACITY_MESSAGE);
            close(socket, CLOSE_OVERLOADED, STANDBY_CAPACITY_MESSAGE);
            return Ok(());
        }

        attachment.phase = SlotPhase::Standby;
        attachment.generation = 0;
        attachment.last_seen_ms = now_ms;
        attachment.pending_handover = false;
        attachment.expires_at = claims.expires_at_unix;
        attachment.idle_deadline_ms = claims.expires_at_unix.saturating_mul(1_000);
        socket.serialize_attachment(&attachment)?;
        self.ensure_cleanup_alarm(attachment.idle_deadline_ms).await?;

        let lease_seconds = claims
            .expires_at_unix
            .saturating_sub(now)
            .min(REGISTRATION_HEARTBEAT_SECONDS)
            .min(u32::MAX.into()) as u32;
        send_control(socket, &RelayControl::Registered { lease_seconds })
    }

    /// Pairs the client on `socket`, whose inline Connect passed its ticket check, with a standby:
    /// both sockets become one inline circuit, answered `Ready` (client first), and `handle_message` forwards
    /// their binary frames. Nothing goes to storage on this path: the quota is read from the ledger's cached
    /// copy and the open sockets (`crate::inline`), and the first alarm is the one the Connect already set.
    async fn pair_inline(
        &self,
        socket: &WebSocket,
        client: &SlotAttachment,
        request: &ConnectRequest,
    ) -> Result<InlineOutcome> {
        if self.takeable_standby(&request.slot, self.now_ms()).is_none() {
            return Ok(InlineOutcome::NoStandby);
        }
        let ledger = self.circuits().await?;

        // Everything below is synchronous: the standby chosen is the one taken.
        let now_ms = self.now_ms();
        let load = self.inline_load(now_ms);
        if let Some(refusal) = ledger.inline_refusal(now_ms, load) {
            worker::console_warn!("slot-circuit-capacity (inline): {refusal}");
            Self::capacity(socket, "slot-circuit-capacity", &refusal.to_string());
            return Ok(InlineOutcome::Refused);
        }
        let Some((standby, standby_attachment)) = self.takeable_standby(&request.slot, now_ms)
        else {
            return Ok(InlineOutcome::NoStandby);
        };
        let circuit =
            CircuitId(self.env.durable_object("RELAY_CIRCUITS")?.unique_id()?.to_string());
        self.inline_window.borrow_mut().note(now_ms);

        let deadline_ms = now_ms.saturating_add(CIRCUIT_IDLE_TIMEOUT_MS);
        let side = |role: RelayRole, base: &SlotAttachment| {
            let mut attachment = base.clone();
            attachment.phase = SlotPhase::Inline;
            attachment.relay = RelaySocketAttachment::circuit(
                role,
                request.slot.clone(),
                circuit.clone(),
                request.lane.clone(),
            );
            attachment.generation = request.generation;
            attachment.parked = None;
            attachment.pending_handover = false;
            attachment.idle_deadline_ms = deadline_ms;
            attachment.inline = InlineState::default();
            attachment
        };
        let paired = socket.serialize_attachment(side(RelayRole::Client, client)).and_then(|()| {
            standby.serialize_attachment(side(RelayRole::Daemon, &standby_attachment))
        });
        let ready = RelayControl::Ready {
            circuit: circuit.clone(),
            lane: request.lane.clone(),
            generation: request.generation,
        };
        if paired.is_err() || send_control(socket, &ready).is_err() {
            close(socket, 1011, "circuit pairing failed");
            close(&standby, 1011, "circuit pairing failed");
            return Ok(InlineOutcome::Paired);
        }
        if send_control(&standby, &ready).is_err() {
            close(&standby, 1011, "circuit pairing failed");
            close(socket, 1011, "circuit pairing failed");
            return Ok(InlineOutcome::Paired);
        }
        self.inline_sockets.borrow_mut().insert(circuit.0, vec![socket.clone(), standby]);
        Ok(InlineOutcome::Paired)
    }

    /// The other socket of `own`'s inline circuit, with its attachment: from the in-memory map when it still
    /// names an open peer, else found among the slot's sockets (after hibernation) and remembered.
    fn inline_peer_of(
        &self,
        socket: &WebSocket,
        own: &SlotAttachment,
    ) -> Option<(WebSocket, SlotAttachment)> {
        let circuit = own.relay.circuit.as_ref()?.0.clone();
        let remembered = self
            .inline_sockets
            .borrow()
            .get(&circuit)
            .and_then(|pair| pair.iter().find(|other| *other != socket).cloned());
        if let Some(found) = remembered.and_then(|candidate| self.checked_peer(own, candidate)) {
            return Some(found);
        }
        let found = self
            .state
            .get_websockets()
            .into_iter()
            .filter(|other| other != socket)
            .find_map(|other| self.checked_peer(own, other))?;
        self.inline_sockets.borrow_mut().insert(circuit, vec![socket.clone(), found.0.clone()]);
        Some(found)
    }

    fn checked_peer(
        &self,
        own: &SlotAttachment,
        candidate: WebSocket,
    ) -> Option<(WebSocket, SlotAttachment)> {
        let attachment = Self::attachment(&candidate).ok()?;
        let ready_state = candidate.as_ref().ready_state();
        inline_peer(own, [((), ready_state, attachment.clone())])?;
        Some((candidate, attachment))
    }

    /// A message on an inline circuit's socket: binary frames go to the peer; anything else closes the socket,
    /// as it does on a ready circuit.
    fn handle_inline_message(
        &self,
        socket: &WebSocket,
        attachment: SlotAttachment,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        let WebSocketIncomingMessage::Binary(bytes) = message else {
            close(socket, CLOSE_UNSUPPORTED, "ready circuits accept binary frames only");
            return Ok(());
        };
        if bytes.len() > MAX_RELAY_BATCH_BYTES {
            close(socket, 1009, "relay frame is too large");
            return Ok(());
        }
        let Some((peer, mut peer_attachment)) = self.inline_peer_of(socket, &attachment) else {
            close(socket, 1011, "circuit peer disconnected");
            return Ok(());
        };
        if let Err(error) = reserve_outbound_frame(
            &mut peer_attachment.inline.outbound,
            peer.as_ref().buffered_amount(),
            bytes.len(),
        ) {
            let (close_code, sender_reason, peer_reason) = outbound_queue_close(error);
            close(socket, close_code, sender_reason);
            close(&peer, close_code, peer_reason);
            return Ok(());
        }
        let now_ms = self.now_ms();
        let result = persist_peer_before_forward(
            now_ms,
            &mut peer_attachment,
            |attachment| peer.serialize_attachment(attachment),
            || peer.send_with_bytes(bytes),
        );
        if let Err(error) = result {
            close(socket, 1011, "circuit peer unavailable");
            close(&peer, 1011, "circuit forwarding failed");
            return Err(error);
        }
        Ok(())
    }

    /// `socket`, one side of an inline circuit, closed: close the other side.
    async fn close_inline(&self, socket: &WebSocket, reason: &str) {
        let Ok(own) = Self::attachment(socket) else {
            return;
        };
        if own.phase != SlotPhase::Inline {
            return;
        }
        let peer = self.inline_peer_of(socket, &own);
        if let Some(circuit) = own.relay.circuit.as_ref() {
            self.inline_sockets.borrow_mut().remove(&circuit.0);
        }
        if let Some((peer, _)) = peer {
            close(&peer, 1011, reason);
        }
    }

    async fn handle_connect(
        &self,
        socket: &WebSocket,
        mut attachment: SlotAttachment,
        request: ConnectRequest,
    ) -> Result<()> {
        if request.protocol != REMOTE_PROTOCOL_VERSION
            || attachment.relay.role != RelayRole::Client
            || attachment.relay.slot != request.slot
            || !valid_opaque_identifier(&request.lane.0, MAX_LANE_TOKEN_BYTES)
        {
            Self::fail(socket, "invalid-connect", "connection request is invalid", CLOSE_POLICY);
            return Ok(());
        }

        let now_ms = self.now_ms();
        let now = now_ms / 1_000;
        let key = self.ticket_key()?;
        let issuer = self.ticket_issuer();
        let claims = match verify_ticket(
            &request.ticket,
            key.as_bytes(),
            &issuer,
            TicketExpectation {
                permission: RelayPermission::Connect,
                role: RelayRole::Client,
                slot: &request.slot,
                circuit: None,
                lane: Some(&request.lane),
                generation: Some(request.generation),
                now,
            },
        ) {
            Ok(claims) => claims,
            Err(_) => {
                Self::fail(socket, "unauthorized", "connection ticket was rejected", CLOSE_POLICY);
                return Ok(());
            }
        };

        attachment.phase = SlotPhase::ClientControl;
        attachment.generation = request.generation;
        attachment.expires_at = claims.expires_at_unix;
        attachment.idle_deadline_ms = now_ms
            .saturating_add(CLIENT_CONTROL_IDLE_TIMEOUT_MS)
            .min(claims.expires_at_unix.saturating_mul(1_000));
        // A new Connect on this socket supersedes one it left waiting: the
        // client reads only the answer for the lane it asked for last.
        attachment.parked = None;

        let daemon = self.registered_daemon(&request.slot, now_ms);
        let disposition = if daemon.is_some() {
            connect_disposition(true, 0, 0)
        } else {
            let pending = self.circuits().await?.pending_count(now_ms);
            connect_disposition(false, self.parked_on_other_sockets(socket, now_ms), pending)
        };
        if disposition == ConnectDisposition::Park {
            attachment.parked = Some(ParkedConnect {
                lane: request.lane.clone(),
                generation: request.generation,
                parked_at_ms: now_ms,
            });
        }
        socket.serialize_attachment(&attachment)?;
        self.ensure_cleanup_alarm(attachment.idle_deadline_ms).await?;

        let far_viewer =
            self.far_viewer_takes_classic(socket, daemon.as_ref().map(|(daemon, _)| daemon));
        if request.inline
            && !far_viewer
            && disposition == ConnectDisposition::Allocate
            && daemon.is_some()
            && self.pair_inline(socket, &attachment, &request).await? != InlineOutcome::NoStandby
        {
            return Ok(());
        }

        match (disposition, daemon) {
            (ConnectDisposition::Allocate, Some((daemon, daemon_attachment))) => {
                let fallback = !self.is_current_registration(&daemon, &daemon_attachment);
                let allocation = self
                    .allocate(
                        socket,
                        &request.slot,
                        request.lane.clone(),
                        request.generation,
                        claims.expires_at_unix,
                        &daemon,
                        &daemon_attachment,
                    )
                    .await?;
                // The daemon was replaced or closed while the allocation
                // waited: the Connect waits for the slot's next Register or
                // current Ping, as one that found no daemon does.
                if allocation == Allocation::Sent && fallback {
                    self.owe_handover_after_fallback(&request.slot, &daemon);
                }
                if allocation == Allocation::Superseded {
                    attachment.parked = Some(ParkedConnect {
                        lane: request.lane.clone(),
                        generation: request.generation,
                        parked_at_ms: now_ms,
                    });
                    socket.serialize_attachment(&attachment)?;
                    if let Some(notice) =
                        parked_notice(request.accepts_parked, &request.lane, request.generation)
                    {
                        send_control(socket, &notice)?;
                    }
                }
            }
            (ConnectDisposition::Park, _) => {
                if let Some(notice) =
                    parked_notice(request.accepts_parked, &request.lane, request.generation)
                {
                    send_control(socket, &notice)?;
                }
            }
            _ => Self::capacity(socket, DAEMON_OFFLINE_CODE, DAEMON_OFFLINE_MESSAGE),
        }
        Ok(())
    }

    /// Parked Connects on client sockets other than `socket`.
    fn parked_on_other_sockets(&self, socket: &WebSocket, now_ms: u64) -> usize {
        self.state
            .get_websockets_with_tag(CONNECT_TAG)
            .into_iter()
            .filter(|other| other != socket)
            .filter(|other| {
                Self::attachment(other).is_ok_and(|attachment| {
                    attachment.parked.is_some()
                        && websocket_counts_toward_capacity(
                            other.as_ref().ready_state(),
                            attachment.idle_deadline_ms,
                            now_ms,
                        )
                })
            })
            .count()
    }

    /// Answers every Connect that waited for this daemon, oldest first, with
    /// the same Allocated/Incoming pair a registered slot sends at once.
    async fn pair_parked(
        &self,
        slot: &str,
        daemon: &WebSocket,
        daemon_attachment: &SlotAttachment,
    ) -> Result<()> {
        let now_ms = self.now_ms();
        let waiting = self
            .state
            .get_websockets_with_tag(CONNECT_TAG)
            .into_iter()
            .filter_map(|client| {
                let attachment = Self::attachment(&client).ok()?;
                if !parked_and_live(&attachment, client.as_ref().ready_state(), slot, now_ms) {
                    return None;
                }
                let parked = attachment.parked.clone()?;
                Some(((client, attachment), parked))
            })
            .collect();
        for ((client, mut attachment), parked) in pairing_order(waiting) {
            attachment.parked = None;
            client.serialize_attachment(&attachment)?;
            let allocation = self
                .allocate(
                    &client,
                    slot,
                    parked.lane.clone(),
                    parked.generation,
                    attachment.expires_at,
                    daemon,
                    daemon_attachment,
                )
                .await;
            match allocation {
                Ok(Allocation::Sent) => {}
                Ok(Allocation::DaemonFailed) => break,
                // The daemon was replaced or closed: this Connect, and the
                // ones after it, wait for the slot's next current daemon.
                Ok(Allocation::Superseded) => {
                    attachment.parked = Some(parked);
                    client.serialize_attachment(&attachment)?;
                    break;
                }
                Err(error) => {
                    Self::capacity(&client, "internal-error", "relay could not allocate a circuit");
                    return Err(error);
                }
            }
        }
        Ok(())
    }

    /// Sends `daemon` an `Incoming`, with a new join ticket, for every
    /// pending circuit on `slot` that no daemon has joined.
    async fn hand_over_unjoined(
        &self,
        slot: &str,
        daemon: &WebSocket,
        daemon_expires_at: u64,
    ) -> Result<()> {
        let now_ms = self.now_ms();
        let now = now_ms / 1_000;
        let ledger = self.circuits().await?;
        // A Register that replaced `daemon` while the ledger was read owns
        // the slot's unjoined circuits now; it was handed them itself.
        if !Self::attachment(daemon)
            .is_ok_and(|attachment| self.is_current_registration(daemon, &attachment))
        {
            return Ok(());
        }
        for unjoined in ledger.unjoined(now_ms) {
            let expires_at = now
                .saturating_add(JOIN_TICKET_TTL_SECONDS)
                .min(unjoined.deadline_ms / 1_000)
                .min(daemon_expires_at);
            if expires_at <= now {
                continue;
            }
            let circuit = CircuitId(unjoined.circuit);
            let join_ticket = self.join_ticket(
                RelayRole::Daemon,
                slot,
                &circuit,
                &unjoined.route.lane,
                unjoined.route.generation,
                now,
                expires_at,
                unjoined.route.region.as_deref(),
            )?;
            send_control(
                daemon,
                &RelayControl::Incoming {
                    circuit,
                    lane: unjoined.route.lane,
                    generation: unjoined.route.generation,
                    join_ticket,
                },
            )?;
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn join_ticket(
        &self,
        role: RelayRole,
        slot: &str,
        circuit: &CircuitId,
        lane: &LaneToken,
        generation: u64,
        now: u64,
        expires_at: u64,
        region: Option<&str>,
    ) -> Result<String> {
        let key = self.ticket_key()?;
        let issuer = self.ticket_issuer();
        let claims = RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: issuer.clone(),
            permission: RelayPermission::Join,
            role,
            slot: slot.into(),
            circuit: Some(circuit.clone()),
            lane: Some(lane.clone()),
            generation: Some(generation),
            issued_at_unix: now,
            expires_at_unix: expires_at,
            grant: None,
            region: region.map(str::to_owned),
        };
        issue_ticket(&claims, key.as_bytes(), &issuer).map_err(|error| {
            worker::Error::RustError(format!("failed to mint {role:?} join ticket: {error}"))
        })
    }

    /// Reserves a circuit and sends `Allocated` to the client and `Incoming`
    /// to the daemon (`daemon_attachment` is the daemon's registration as
    /// read when it was chosen).
    #[allow(clippy::too_many_arguments)]
    async fn allocate(
        &self,
        socket: &WebSocket,
        slot: &str,
        lane: LaneToken,
        generation: u64,
        client_expires_at: u64,
        daemon: &WebSocket,
        daemon_attachment: &SlotAttachment,
    ) -> Result<Allocation> {
        let daemon_expires_at = daemon_attachment.expires_at;
        let now_ms = self.now_ms();
        let now = now_ms / 1_000;
        let namespace = self.env.durable_object("RELAY_CIRCUITS")?;
        let circuit = CircuitId(namespace.unique_id()?.to_string());
        // The viewer's region rides in both join tickets only with the switch on (`crate::placement`).
        let region = self.viewer_circuits().then(|| self.socket_region(socket)).flatten();
        let join_expires_at = now
            .saturating_add(JOIN_TICKET_TTL_SECONDS)
            .min(client_expires_at)
            .min(daemon_expires_at);
        let client_join_ticket = self.join_ticket(
            RelayRole::Client,
            slot,
            &circuit,
            &lane,
            generation,
            now,
            join_expires_at,
            region.as_deref(),
        )?;
        let daemon_join_ticket = self.join_ticket(
            RelayRole::Daemon,
            slot,
            &circuit,
            &lane,
            generation,
            now,
            join_expires_at,
            region.as_deref(),
        )?;
        let join_deadline_ms = join_expires_at.saturating_mul(1_000);
        let route = PendingRoute { lane: lane.clone(), generation, region: region.clone() };
        if let Err(refusal) =
            self.reserve_pending_circuit(&circuit, join_deadline_ms, now_ms, route).await?
        {
            worker::console_warn!("slot-circuit-capacity: {refusal}");
            Self::capacity(socket, "slot-circuit-capacity", &refusal.to_string());
            return Ok(Allocation::Sent);
        }
        // The awaits above let a Register replace the daemon, or its socket
        // close: send nothing to a daemon that no longer takes the slot's
        // Connects. The caller parks the Connect.
        if !self.still_allocates_to(slot, daemon, daemon_attachment.generation, self.now_ms()) {
            self.release_circuit(&circuit.0).await?;
            return Ok(Allocation::Superseded);
        }

        let incoming = RelayControl::Incoming {
            circuit: circuit.clone(),
            lane: lane.clone(),
            generation,
            join_ticket: daemon_join_ticket,
        };
        let allocated = RelayControl::Allocated {
            circuit: circuit.clone(),
            lane,
            generation,
            join_ticket: client_join_ticket,
        };
        if send_control(socket, &allocated).is_err() {
            self.release_circuit(&circuit.0).await?;
            close(socket, 1011, "circuit allocation failed");
            return Ok(Allocation::Sent);
        }
        if send_control(daemon, &incoming).is_err() {
            self.release_circuit(&circuit.0).await?;
            close(daemon, 1011, "circuit allocation failed");
            close(socket, 1011, "circuit allocation failed");
            return Ok(Allocation::DaemonFailed);
        }
        self.place_circuit(&circuit, region.as_deref());
        Ok(Allocation::Sent)
    }

    /// Create `circuit` before either side's Join reaches it (`crate::placement`): in `region`, the
    /// viewer's its tickets name, or else near this slot, and so near the daemon. Off the answer's
    /// path; a Join that comes first places it with the same hint.
    fn place_circuit(&self, circuit: &CircuitId, region: Option<&str>) {
        let env = self.env.clone();
        let circuit = circuit.0.clone();
        let region = region.filter(|region| is_region(region)).map(str::to_owned);
        self.state.wait_until(async move {
            let placed = async {
                let namespace = env.durable_object("RELAY_CIRCUITS")?;
                let id = namespace.id_from_string(&circuit)?;
                let stub = match region.as_deref() {
                    Some(region) => id.get_stub_with_location_hint(region)?,
                    None => id.get_stub()?,
                };
                let request = Request::new(
                    &format!("https://relay.internal{}", crate::placement::PLACE_PATH),
                    Method::Post,
                )?;
                stub.fetch_with_request(request).await.map(|_| ())
            };
            if let Err(error) = placed.await {
                worker::console_error!("RelaySlot circuit placement error: {error}");
            }
        });
    }

    async fn handle_message(
        &self,
        socket: &WebSocket,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        let mut attachment = Self::attachment(socket)?;
        if attachment.phase == SlotPhase::Inline {
            return self.handle_inline_message(socket, attachment, message);
        }
        let control = match decode_control(message) {
            Ok(control) => control,
            Err(message) => {
                Self::fail(socket, "invalid-control", message, CLOSE_UNSUPPORTED);
                return Ok(());
            }
        };

        match control {
            RelayControl::Register { protocol, slot, ticket } => {
                self.handle_register(socket, attachment, protocol, slot, ticket).await
            }
            RelayControl::Standby { protocol, slot, ticket }
                if attachment.phase == SlotPhase::Pending =>
            {
                self.handle_standby(socket, attachment, protocol, slot, ticket).await
            }
            RelayControl::Connect {
                protocol,
                slot,
                ticket,
                lane,
                generation,
                accepts_parked,
                inline,
                ..
            } if matches!(attachment.phase, SlotPhase::Pending | SlotPhase::ClientControl) => {
                self.handle_connect(
                    socket,
                    attachment,
                    ConnectRequest {
                        protocol,
                        slot,
                        ticket,
                        lane,
                        generation,
                        accepts_parked,
                        inline,
                    },
                )
                .await
            }
            RelayControl::Ping { nonce }
                if attachment.phase == SlotPhase::Registered
                    && attachment.expires_at > self.now() =>
            {
                let now_ms = self.now_ms();
                // A Ping from a registration a newer Register replaced (it
                // was in flight when the replacement ran) hands nothing to
                // this closing socket: the current registration owns the
                // slot's parked Connects and unjoined circuits.
                let current = self.is_current_registration(socket, &attachment);
                let handover = record_ping(&mut attachment, current, now_ms);
                attachment.idle_deadline_ms = now_ms
                    .saturating_add(DAEMON_CONTROL_IDLE_TIMEOUT_MS)
                    .min(attachment.expires_at.saturating_mul(1_000));
                socket.serialize_attachment(&attachment)?;
                self.ensure_cleanup_alarm(attachment.idle_deadline_ms).await?;
                send_control(socket, &RelayControl::Pong { nonce })?;
                let slot = attachment.relay.slot.clone();
                if handover.unjoined
                    && let Err(error) =
                        self.hand_over_unjoined(&slot, socket, attachment.expires_at).await
                {
                    worker::console_error!("RelaySlot circuit hand-over error: {error}");
                }
                // A Connect parked while this daemon was past the liveness
                // window (crate::daemon) is answered now that it spoke.
                if handover.parked
                    && let Err(error) = self.pair_parked(&slot, socket, &attachment).await
                {
                    worker::console_error!("RelaySlot parked pairing error: {error}");
                }
                Ok(())
            }
            RelayControl::Ping { nonce }
                if attachment.phase == SlotPhase::Standby && attachment.expires_at > self.now() =>
            {
                // A standby's idle deadline is its ticket's expiry; a Ping only shows its daemon is alive
                // (`live_standby` prefers the one heard last).
                attachment.last_seen_ms = self.now_ms();
                socket.serialize_attachment(&attachment)?;
                send_control(socket, &RelayControl::Pong { nonce })
            }
            RelayControl::Ping { .. }
                if matches!(attachment.phase, SlotPhase::Registered | SlotPhase::Standby) =>
            {
                Self::fail(
                    socket,
                    "registration-expired",
                    "daemon registration ticket has expired",
                    CLOSE_POLICY,
                );
                Ok(())
            }
            _ => {
                Self::fail(
                    socket,
                    "unexpected-control",
                    "control message is not valid in this state",
                    CLOSE_POLICY,
                );
                Ok(())
            }
        }
    }

    async fn handle_internal_circuit(&self, request: &Request) -> Result<Option<Response>> {
        if request.method() != Method::Post {
            return Ok(None);
        }
        let path = request.path();
        let segments: Vec<_> = path.split('/').filter(|part| !part.is_empty()).collect();
        let ["internal", "v1", "circuits", circuit, event @ ("active" | "renew" | "release")] =
            segments.as_slice()
        else {
            return Ok(None);
        };
        if !valid_circuit_id(circuit) {
            return Response::error("Invalid circuit", 400).map(Some);
        }
        match *event {
            "active" => {
                if !self.activate_circuit(circuit, self.now_ms()).await? {
                    return Response::error("Circuit allocation is missing or expired", 409)
                        .map(Some);
                }
            }
            "renew" => {
                if !self.renew_circuit(circuit, self.now_ms()).await? {
                    return Response::error("Circuit lease is missing or expired", 409).map(Some);
                }
            }
            "release" => self.release_circuit(circuit).await?,
            _ => unreachable!(),
        }
        Response::ok("ok").map(Some)
    }
}

impl DurableObject for RelaySlot {
    fn new(state: State, env: Env) -> Self {
        Self {
            state,
            env,
            inline_sockets: RefCell::new(HashMap::new()),
            inline_window: RefCell::new(InlineWindow::default()),
        }
    }

    async fn fetch(&self, request: Request) -> Result<Response> {
        if let Some(response) = self.handle_internal_circuit(&request).await? {
            return Ok(response);
        }
        if !websocket_upgrade(&request)? {
            return upgrade_required();
        }

        let path = request.path();
        let segments: Vec<_> = path.split('/').filter(|part| !part.is_empty()).collect();
        let ["v1", "slots", slot, endpoint] = segments.as_slice() else {
            return Response::error("Not found", 404);
        };
        if !valid_opaque_identifier(slot, MAX_SLOT_ID_BYTES) {
            return Response::error("Invalid slot", 400);
        }

        let (role, tag, admission_endpoint) = match *endpoint {
            "control" => (RelayRole::Daemon, CONTROL_TAG, SlotEndpoint::Daemon),
            "connect" => (RelayRole::Client, CONNECT_TAG, SlotEndpoint::Client),
            _ => return Response::error("Not found", 404),
        };
        if !admit_slot_socket(self.socket_counts(self.now_ms()), admission_endpoint) {
            return Response::error("Slot connection limit reached", 429);
        }

        let pair = WebSocketPair::new()?;
        let relay = if role == RelayRole::Daemon {
            RelaySocketAttachment::control((*slot).into())
        } else {
            RelaySocketAttachment { role, slot: (*slot).into(), circuit: None, lane: None }
        };
        let idle_deadline_ms = self.now_ms().saturating_add(SLOT_HANDSHAKE_TIMEOUT_MS);
        pair.server.serialize_attachment(SlotAttachment {
            relay,
            phase: SlotPhase::Pending,
            generation: 0,
            expires_at: 0,
            idle_deadline_ms,
            parked: None,
            last_seen_ms: 0,
            pending_handover: false,
            inline: InlineState::default(),
        })?;
        // The caller's place rides on the socket as a tag, so it survives hibernation with no attachment field.
        let region_tag = request
            .headers()
            .get(REGION_HEADER)
            .ok()
            .flatten()
            .filter(|region| is_region(region))
            .map(|region| format!("{REGION_TAG_PREFIX}{region}"));
        let mut tags = vec![tag];
        tags.extend(region_tag.as_deref());
        self.state.accept_websocket_with_tags(&pair.server, &tags);
        if let Err(error) = self.ensure_cleanup_alarm(idle_deadline_ms).await {
            close(&pair.server, 1011, "cleanup scheduling failed");
            return Err(error);
        }
        Response::from_websocket(pair.client)
    }

    async fn alarm(&self) -> Result<Response> {
        let now_ms = self.now_ms();
        let sockets = self
            .state
            .get_websockets()
            .into_iter()
            .filter_map(|socket| {
                let attachment = Self::attachment(&socket).ok()?;
                Some((socket, attachment))
            })
            .collect::<Vec<_>>();
        for (socket, attachment) in &sockets {
            if expired_while_parked(attachment, now_ms) {
                Self::capacity(socket, DAEMON_OFFLINE_CODE, DAEMON_OFFLINE_MESSAGE);
            }
            // An inline circuit's two sockets share the later of their idle deadlines: forwarding refreshes only
            // the destination.
            let deadline = if attachment.phase == SlotPhase::Inline {
                latest_inline_deadline(
                    attachment.relay.circuit.as_ref(),
                    sockets.iter().map(|(_, other)| other),
                )
            } else {
                // A daemon socket past its idle deadline is retired, not closed: a close frame wakes a paused
                // machine (`crate::retire`).
                close_deadline_ms(attachment)
            };
            if deadline <= now_ms {
                close(socket, CLOSE_POLICY, "relay socket expired");
                self.owe_handover_after_close(socket);
            }
        }
        self.schedule_next_cleanup(now_ms).await?;
        Response::ok("cleaned")
    }

    async fn websocket_message(
        &self,
        socket: WebSocket,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        if let Err(error) = self.handle_message(&socket, message).await {
            Self::fail(&socket, "internal-error", "relay could not process the message", 1011);
            worker::console_error!("RelaySlot message error: {error}");
        }
        Ok(())
    }

    async fn websocket_close(
        &self,
        socket: WebSocket,
        _code: usize,
        _reason: String,
        _was_clean: bool,
    ) -> Result<()> {
        self.close_inline(&socket, "circuit peer disconnected").await;
        self.owe_handover_after_close(&socket);
        Ok(())
    }

    async fn websocket_error(&self, socket: WebSocket, error: worker::Error) -> Result<()> {
        worker::console_error!("RelaySlot WebSocket error: {error}");
        self.close_inline(&socket, "circuit peer failed").await;
        self.owe_handover_after_close(&socket);
        Ok(())
    }
}
