//! A cold dial in one hop (RFD 0039 cut 5). The circuit-DO route takes two relay hops: a
//! client's Connect goes to the slot, which answers `Allocated` (and sends the daemon `Incoming`),
//! then both ends open a second WebSocket to a circuit object, `Join`, and wait for `Ready`. Between
//! two lane VMs that is ~730 ms of a ~1.5 s dial.
//!
//! Here the daemon keeps [`STANDBY_SOCKETS`] sockets open on its slot, each sent `Standby` with
//! the registration's ticket. A client's Connect sets `inline`, and a relay with a Standby free
//! answers `Ready` on the client's own socket, sends `Ready` on the Standby, and forwards binary
//! frames between the two: no second socket and no second object. The circuit-DO route stays the
//! fallback, second in the order:
//! - A relay with no Standby free, or one older than this, answers the Connect with `Allocated`.
//! - A relay that does not know `Standby` refuses it, and the daemon asks again only after
//!   [`STANDBY_UNSUPPORTED_WAIT`].
//!
//! `CMUX_RELAY_INLINE=0` turns the client's `inline` off (the A/B for the dial's numbers).

use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use cmux_remote_protocol::{CircuitId, REMOTE_PROTOCOL_VERSION, RelayControl};
use futures_util::StreamExt;
use futures_util::stream::FuturesUnordered;
use tokio::time::Instant;

use super::{
    RelayCircuitFraming, RelayCircuitLink, RelayCredential, RelayDaemonConfig, RelayLinkGroup,
    RelaySocket, RelayTls, connect_relay_socket_once, read_control, relay_authentication_error,
    sanitized_route, send_control,
};
use crate::link::FrameLink;

/// Standby sockets a registration keeps: one for each link a client opens at once. A Cloud
/// client's `Auto` lanes are three links (Interactive, Control, Tunnel and Bulk), and a reconnect
/// that holds the daemon's key opens all three together (`cmux_braid_session::open_lanes_at_once`),
/// so a third link with no Standby free would fall back to the two-hop circuit route and hold the
/// whole reconnect up by its ~730 ms. The relay holds up to four per slot
/// (`MAX_STANDBY_SOCKETS_PER_SLOT`), which leaves one for a replacement in flight.
pub(super) const STANDBY_SOCKETS: usize = 3;
/// A Standby says it is alive this often, and gives up on a relay that does not answer within
/// [`STANDBY_PONG_WAIT`]: a dial paired with a dead Standby would wait on it.
const STANDBY_PING: Duration = Duration::from_secs(20);
const STANDBY_PONG_WAIT: Duration = Duration::from_secs(5);
/// A Standby is replaced this long before its ticket runs out, so the relay never pairs one it is
/// about to close.
const STANDBY_MARGIN: Duration = Duration::from_secs(30);
const STANDBY_RETRY: Duration = Duration::from_secs(5);
const STANDBY_RETRY_MAX: Duration = Duration::from_secs(60);
/// After a relay refused `Standby` (it predates it).
const STANDBY_UNSUPPORTED_WAIT: Duration = Duration::from_secs(600);

/// Whether a client's Connect asks for an inline circuit.
pub(super) fn inline_wanted() -> bool {
    std::env::var_os("CMUX_RELAY_INLINE").is_none_or(|value| value != "0")
}

/// An early Connect (`RelayProvider::with_early_connect`) the relay answered with `Allocated`:
/// no Standby was free, so the frames sent behind the Connect reached no circuit. The caller
/// dials again with early Connect off.
pub const EARLY_CONNECT_NOT_INLINE: &str =
    "relay answered the early Connect with a two-hop circuit";

/// The early Connect's default: `CMUX_RELAY_EARLY_CONNECT=1` turns it on (off unset).
pub(super) fn early_connect_wanted() -> bool {
    std::env::var_os("CMUX_RELAY_EARLY_CONNECT").is_some_and(|value| value == "1")
}

impl RelayLinkGroup {
    /// Whether this lane's Connect is early: asked for, inline, a first meeting (a resume keeps
    /// the read-the-answer-first allocation), and one frame per WebSocket message (the batched
    /// `relay+do` route keeps it too).
    pub(super) fn early_connect(&self, generation: u64) -> bool {
        self.early_connect
            && generation == 0
            && inline_wanted()
            && self.framing == RelayCircuitFraming::Single
    }

    /// This socket as the circuit an early Connect asked for: its first receive reads the
    /// relay's answer, `Ready` for `lane` and `generation`, before any frame.
    pub(super) fn inline_link_awaiting(
        &self,
        socket: RelaySocket,
        lane: cmux_remote_protocol::LaneToken,
        generation: u64,
    ) -> Box<dyn FrameLink> {
        Box::new(
            RelayCircuitLink::new_with_framing(
                sanitized_route(&self.endpoint),
                self.config.maximum_frame_bytes,
                self.framing,
                socket,
            )
            .awaiting_ready(lane, generation),
        )
    }

    /// The client's control socket as the circuit the relay answered `Ready` on.
    pub(super) fn inline_link(&self, socket: RelaySocket) -> Box<dyn FrameLink> {
        Box::new(RelayCircuitLink::new_with_framing(
            sanitized_route(&self.endpoint),
            self.config.maximum_frame_bytes,
            self.framing,
            socket,
        ))
    }
}

/// How one Standby ended.
pub(super) enum StandbyEnd {
    /// The relay paired it with a client's Connect: serve `link`.
    Paired(CircuitId, Box<dyn FrameLink>),
    /// Its ticket is near its end, unpaired: open the next one now.
    Lapsed,
    Failed,
    Unsupported,
}

type StandbyFuture<'a> = Pin<Box<dyn Future<Output = StandbyEnd> + Send + 'a>>;

/// The ticket a Standby authenticates with: the registration's current one, and when it ends on
/// this machine's monotonic clock (None: a credential whose lifetime is not readable).
#[derive(Clone)]
pub(super) struct StandbyTicket {
    pub credential: RelayCredential,
    pub expires: Option<Instant>,
}

/// A registration's Standby sockets, polled by its loop (`run_registration_once`): each one that
/// ends is replaced by [`Standbys::replace`].
pub(super) struct Standbys<'a> {
    config: &'a RelayDaemonConfig,
    framing: RelayCircuitFraming,
    tls: &'a RelayTls,
    pending: FuturesUnordered<StandbyFuture<'a>>,
    failures: u32,
}

impl<'a> Standbys<'a> {
    pub(super) fn new(
        config: &'a RelayDaemonConfig,
        framing: RelayCircuitFraming,
        tls: &'a RelayTls,
        ticket: &StandbyTicket,
    ) -> Self {
        let mut standbys =
            Self { config, framing, tls, pending: FuturesUnordered::new(), failures: 0 };
        // Both relays pair Standbys: the Durable Object and `cmux-relay` (`relay_inline.rs`). A
        // self-hosted relay older than that refuses `Standby` (`unexpected-control`), which is
        // `Unsupported`: three refused sockets, then one more ask per `STANDBY_UNSUPPORTED_WAIT`.
        for _ in 0..STANDBY_SOCKETS {
            standbys.open(ticket.clone(), Duration::ZERO);
        }
        standbys
    }

    fn open(&mut self, ticket: StandbyTicket, wait: Duration) {
        self.pending.push(Box::pin(hold_standby(
            self.config,
            self.framing,
            self.tls,
            ticket,
            wait,
        )));
    }

    pub(super) fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    pub(super) async fn next(&mut self) -> Option<StandbyEnd> {
        self.pending.next().await
    }

    /// Open the Standby that replaces one that ended as `end` did, with `ticket`.
    pub(super) fn replace(&mut self, end: &StandbyEnd, ticket: StandbyTicket) {
        let wait = match end {
            StandbyEnd::Paired(..) | StandbyEnd::Lapsed => {
                self.failures = 0;
                Duration::ZERO
            }
            StandbyEnd::Failed => {
                self.failures = self.failures.saturating_add(1);
                STANDBY_RETRY.saturating_mul(1 << self.failures.min(4)).min(STANDBY_RETRY_MAX)
            }
            StandbyEnd::Unsupported => STANDBY_UNSUPPORTED_WAIT,
        };
        self.open(ticket, wait);
    }
}

async fn hold_standby(
    config: &RelayDaemonConfig,
    framing: RelayCircuitFraming,
    tls: &RelayTls,
    ticket: StandbyTicket,
    wait: Duration,
) -> StandbyEnd {
    tokio::time::sleep(wait).await;
    let lapse =
        ticket.expires.map(|expires| expires.checked_sub(STANDBY_MARGIN).unwrap_or(expires));
    // A ticket this close to its end gets no Standby: the registration's renewal brings the next.
    if lapse.is_some_and(|lapse| lapse <= Instant::now() + STANDBY_MARGIN) {
        return StandbyEnd::Failed;
    }
    let limit = framing.websocket_message_limit(config.maximum_frame_bytes);
    let Ok(mut socket) =
        connect_relay_socket_once(&config.endpoint, Some(&ticket.credential), limit, tls).await
    else {
        return StandbyEnd::Failed;
    };
    let standby = RelayControl::Standby {
        protocol: REMOTE_PROTOCOL_VERSION,
        slot: config.slot.clone(),
        ticket: ticket.credential.expose().to_owned(),
    };
    if send_control(&mut socket, &standby).await.is_err() {
        return StandbyEnd::Failed;
    }
    match tokio::time::timeout(config.control_timeout, read_control(&mut socket)).await {
        Ok(Ok(RelayControl::Registered { .. })) => {}
        Ok(Ok(RelayControl::Error { code, retryable, .. }))
            if !retryable && !relay_authentication_error(&code) =>
        {
            return StandbyEnd::Unsupported;
        }
        _ => return StandbyEnd::Failed,
    }
    let mut nonce = 0_u64;
    let mut pong_by: Option<Instant> = None;
    loop {
        let now = Instant::now();
        let wake = [Some(now + STANDBY_PING), pong_by, lapse].into_iter().flatten().min();
        let wake = wake.unwrap_or(now + STANDBY_PING);
        match tokio::time::timeout_at(wake, read_control(&mut socket)).await {
            Ok(Ok(RelayControl::Ready { circuit, .. })) => {
                let link = RelayCircuitLink::new_with_framing(
                    sanitized_route(&config.endpoint),
                    config.maximum_frame_bytes,
                    framing,
                    socket,
                );
                return StandbyEnd::Paired(circuit, Box::new(link));
            }
            Ok(Ok(RelayControl::Pong { nonce: answered })) if answered == nonce => pong_by = None,
            Ok(Ok(RelayControl::Ping { nonce })) => {
                if send_control(&mut socket, &RelayControl::Pong { nonce }).await.is_err() {
                    return StandbyEnd::Failed;
                }
            }
            Ok(Ok(_)) => {}
            Ok(Err(_)) => return StandbyEnd::Failed,
            Err(_) => {
                let now = Instant::now();
                if pong_by.is_some_and(|by| by <= now) {
                    return StandbyEnd::Failed;
                }
                if lapse.is_some_and(|lapse| lapse <= now) {
                    let _ = socket.close(None).await;
                    return StandbyEnd::Lapsed;
                }
                if pong_by.is_none() {
                    nonce = nonce.wrapping_add(1);
                    if send_control(&mut socket, &RelayControl::Ping { nonce }).await.is_err() {
                        return StandbyEnd::Failed;
                    }
                    pong_by = Some(now + STANDBY_PONG_WAIT);
                }
            }
        }
    }
}
