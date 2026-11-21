use std::time::Duration;

use cmux_remote_protocol::{
    CircuitId, LaneToken, REMOTE_PROTOCOL_VERSION, RelayControl, RelayPermission, RelayRole,
    RelaySocketAttachment, RelayTicketClaims,
};
use worker::{
    Date, DurableObject, Env, Method, Request, Response, Result, State, WebSocket,
    WebSocketIncomingMessage, WebSocketPair, durable_object,
};

use crate::abuse::{
    CIRCUITS_STORAGE_KEY, CLIENT_CONTROL_IDLE_TIMEOUT_MS, CircuitLedger,
    DAEMON_CONTROL_IDLE_TIMEOUT_MS, PendingRoute, SLOT_HANDSHAKE_TIMEOUT_MS, SlotEndpoint,
    SlotSocketCounts, admit_slot_socket, websocket_counts_toward_capacity,
};
use crate::attachment::{SlotAttachment, SlotPhase};
use crate::auth::{DEFAULT_TICKET_ISSUER, TicketExpectation, issue_ticket, verify_ticket};
use crate::daemon::{
    current_registration, live_daemon, next_registration_number, owed_handover_after_close,
    owed_handover_after_fallback, record_ping, replaced_by_register, still_allocated_to,
};
use crate::park::{
    ConnectDisposition, DAEMON_OFFLINE_CODE, DAEMON_OFFLINE_MESSAGE, ParkedConnect,
    connect_disposition, expired_while_parked, pairing_order, parked_and_live, parked_notice,
};
use crate::wire::{
    close, decode_control, send_control, upgrade_required, valid_circuit_id,
    valid_opaque_identifier, websocket_upgrade,
};

const CONTROL_TAG: &str = "daemon-control";
const CONNECT_TAG: &str = "client-allocation";
const MAX_SLOT_ID_BYTES: usize = 128;
const MAX_LANE_TOKEN_BYTES: usize = 128;
const JOIN_TICKET_TTL_SECONDS: u64 = 30;
const REGISTRATION_HEARTBEAT_SECONDS: u64 = 30;
const CLOSE_POLICY: u16 = 1008;
const CLOSE_UNSUPPORTED: u16 = 1003;

#[durable_object]
pub struct RelaySlot {
    state: State,
    env: Env,
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
}

impl RelaySlot {
    fn now_ms(&self) -> u64 {
        Date::now().as_millis()
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
    ) -> Result<bool> {
        let mut ledger = self.circuits().await?;
        if !ledger.reserve_for(circuit.0.clone(), deadline_ms, now_ms, Some(route)) {
            return Ok(false);
        }
        self.write_circuits(&ledger).await?;
        self.ensure_cleanup_alarm(deadline_ms).await?;
        Ok(true)
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
            .map(|attachment| attachment.idle_deadline_ms)
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
        )?;
        let daemon_join_ticket = self.join_ticket(
            RelayRole::Daemon,
            slot,
            &circuit,
            &lane,
            generation,
            now,
            join_expires_at,
        )?;
        let join_deadline_ms = join_expires_at.saturating_mul(1_000);
        let route = PendingRoute { lane: lane.clone(), generation };
        if !self.reserve_pending_circuit(&circuit, join_deadline_ms, now_ms, route).await? {
            Self::capacity(
                socket,
                "slot-circuit-capacity",
                "slot circuit quota or allocation rate limit was reached",
            );
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
        Ok(Allocation::Sent)
    }

    async fn handle_message(
        &self,
        socket: &WebSocket,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        let mut attachment = Self::attachment(socket)?;
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
            RelayControl::Connect { protocol, slot, ticket, lane, generation, accepts_parked }
                if matches!(attachment.phase, SlotPhase::Pending | SlotPhase::ClientControl) =>
            {
                self.handle_connect(
                    socket,
                    attachment,
                    ConnectRequest { protocol, slot, ticket, lane, generation, accepts_parked },
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
            RelayControl::Ping { .. } if attachment.phase == SlotPhase::Registered => {
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
        Self { state, env }
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
        })?;
        self.state.accept_websocket_with_tags(&pair.server, &[tag]);
        if let Err(error) = self.ensure_cleanup_alarm(idle_deadline_ms).await {
            close(&pair.server, 1011, "cleanup scheduling failed");
            return Err(error);
        }
        Response::from_websocket(pair.client)
    }

    async fn alarm(&self) -> Result<Response> {
        let now_ms = self.now_ms();
        for socket in self.state.get_websockets() {
            let Ok(attachment) = Self::attachment(&socket) else {
                continue;
            };
            if expired_while_parked(&attachment, now_ms) {
                Self::capacity(&socket, DAEMON_OFFLINE_CODE, DAEMON_OFFLINE_MESSAGE);
            }
            if attachment.idle_deadline_ms <= now_ms {
                close(&socket, CLOSE_POLICY, "relay socket expired");
                self.owe_handover_after_close(&socket);
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
        self.owe_handover_after_close(&socket);
        Ok(())
    }

    async fn websocket_error(&self, socket: WebSocket, error: worker::Error) -> Result<()> {
        worker::console_error!("RelaySlot WebSocket error: {error}");
        self.owe_handover_after_close(&socket);
        Ok(())
    }
}
