//! Warm spare circuits and the opening of a circuit (split out of `hub_carrier.rs`).
//!
//! A fresh circuit costs a ticket call to the platform, a relay allocation, the far daemon's own
//! socket to the circuit and the Noise XX exchange: 1.5 to 2.5 s from a lane VM to a Mac, where
//! the service hello and its answer, the part a dial needs, is one relay round trip. So after a
//! dial that names a service, the carrier opens one more circuit to that machine in the
//! background, through the handshake, and parks it as that machine's spare. The next dial takes
//! it and sends only its hello ([`HubCarrier::dial_service`]), then a new spare opens behind it.
//!
//! Nothing changes on the wire or on the far machine: a circuit's first record names its
//! service, and the far machine waits for it on `link.receive()` however long it takes
//! (`Incoming::incoming`). Only circuits for a named service use spares. The acpmux listener's
//! circuits send no hello, and the far machine's listener closes a connection that sends no
//! request head within 5 s (`server::WS_HANDSHAKE_TIMEOUT`), so a spare for it would be stale.
//!
//! Bounds: one spare a machine, at most [`MAX_SPARES`] in all, each closed after
//! `timings.spare_ttl` unused (under the relay's 10 min idle bound on a circuit,
//! `relays/cloudflare-do/src/abuse.rs` `CIRCUIT_IDLE_TIMEOUT_MS`), and opened only right after a
//! dial to that machine, so a machine not dialed for that long has none. A spare that the far
//! side or the relay closes is noticed and dropped at once. A spare that went silent without a
//! close costs the dial `timings.spare_answer` before it opens a fresh circuit, with no error.
//! A rekey drops every spare (each was opened under the old key); a stopped carrier drops them
//! with it. A machine whose key changed is another `daemonId`, so its old spare goes unused and
//! closes at its TTL.
//!
//! The Connect ticket is kept per machine until shortly before its `expires_at`: the relay
//! checks only its signature, scope (permission, role, slot) and expiry, never how many times it
//! was used (`relays/cloudflare-do/src/auth.rs` `verify_ticket`), so a spare's refill reuses the
//! dial's ticket instead of asking the platform again. A relay that refuses a kept ticket gets
//! one fresh one.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_remote::crypto::{
    ClientAuthMode, ClientHandshake, ConnectionAttemptId, SecureLink, StaticIdentity,
    initiate_secure_link,
};
use cmux_remote::link::FrameLink;
use cmux_remote::provider::{
    ConnectRequest, LinkRequest, RelayClientConfig, RelayCredentialSource, RelayProvider,
    TransportProvider,
};
use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
use tokio::sync::oneshot;
use zeroize::Zeroizing;

use super::{
    CarrierAnswer, DEVICE_NAME, HubCarrier, MAX_FRAME_BYTES, ServiceRefusal, Tickets, Timings,
    carrier_not_serving, key_bytes, random_16, read_service_answer, relay_refusal, relay_url,
    ticket_refusal,
};

/// The most spares a carrier keeps, across all machines.
pub(super) const MAX_SPARES: usize = 8;
/// A kept Connect ticket is used only while it has this long left.
const TICKET_MARGIN_SECS: u64 = 60;
/// The longest a lost spare's close may take; it runs off the dial's path.
const SPARE_CLOSE_WAIT: Duration = Duration::from_secs(2);

/// A circuit's taker: the spare's watcher hands its circuit back on the inner channel.
type Take = oneshot::Sender<oneshot::Sender<SecureLink>>;

struct Spare {
    /// Told apart from a later spare for the same machine.
    id: u64,
    born: Instant,
    /// The carrier's key generation it was opened under.
    generation: u64,
    take: Take,
}

#[derive(Default)]
struct Parked {
    spares: HashMap<String, Spare>,
    /// Machines whose spare is being opened.
    filling: HashSet<String>,
}

/// A carrier's spares and kept tickets.
#[derive(Default)]
pub(super) struct Warm {
    parked: Mutex<Parked>,
    tickets: Mutex<HashMap<String, CarrierAnswer>>,
    next_id: AtomicU64,
}

impl Warm {
    fn parked(&self) -> std::sync::MutexGuard<'_, Parked> {
        self.parked.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn kept_tickets(&self) -> std::sync::MutexGuard<'_, HashMap<String, CarrierAnswer>> {
        self.tickets.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Drops every spare: each one's watcher closes its circuit.
    pub(super) fn drop_spares(&self) {
        let spares = std::mem::take(&mut self.parked().spares);
        drop(spares);
    }
}

/// What a service hello came back with.
pub(super) enum Asked {
    /// The machine answered and refused: the dial's answer.
    Refused(ServiceRefusal),
    /// No answer: the circuit is gone or silent.
    Lost(String),
}

/// Sends `hello` on `link` and reads the machine's answer within `wait`.
pub(super) async fn ask_service(
    link: &SecureLink,
    hello: Bytes,
    wait: Duration,
) -> Result<(), Asked> {
    link.send(hello).await.map_err(|e| Asked::Lost(e.to_string()))?;
    let answer = tokio::time::timeout(wait, link.receive())
        .await
        .map_err(|_| Asked::Lost("the machine did not answer the service hello in time".into()))?
        .map_err(|e| Asked::Lost(e.to_string()))?
        .ok_or_else(|| Asked::Lost("the machine closed the circuit before answering".into()))?;
    read_service_answer(&answer).map_err(Asked::Refused)
}

/// The owner of every spare's tasks. Each ends on its own: an opening at its timeouts, a watch at
/// its spare's take, TTL or close (a dropped carrier drops its spares' takers), a close bounded.
fn scope() -> &'static cmux_scope::Scope {
    static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
    SCOPE.get_or_init(|| cmux_scope::Scope::new("hub carrier spares"))
}

/// Closes `link` off the caller's path, bounded.
pub(super) fn close_soon(link: SecureLink) {
    scope().spawn_named("hub carrier spare close", async move {
        let _ = tokio::time::timeout(SPARE_CLOSE_WAIT, link.close()).await;
    });
}

/// Everything a circuit's opening needs, owned, so a spare opens on its own task.
pub(super) struct Opener {
    tickets: Arc<dyn Tickets>,
    identity: StaticIdentity,
    timings: Timings,
    warm: Arc<Warm>,
}

/// Where an opening failed: a relay that refused the connect may have refused a kept ticket.
enum OpenError {
    Connect(String),
    Other(String),
}

impl OpenError {
    fn text(self) -> String {
        match self {
            Self::Connect(text) | Self::Other(text) => text,
        }
    }
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl Opener {
    /// A relay circuit to `daemon` with the Noise handshake done, its key pinned to the
    /// platform's `peer_key`. Nothing is sent on it yet.
    pub(super) async fn open(&self, daemon: &str) -> Result<SecureLink, String> {
        let (answer, kept) = self.ticket(daemon).await?;
        match self.open_with(daemon, answer).await {
            Err(OpenError::Connect(_)) if kept => {
                self.warm.kept_tickets().remove(daemon);
                let (answer, _) = self.ticket(daemon).await?;
                self.open_with(daemon, answer).await.map_err(OpenError::text)
            }
            opened => opened.map_err(OpenError::text),
        }
    }

    /// A Connect ticket for `daemon`: the kept one while it has [`TICKET_MARGIN_SECS`] left,
    /// else the platform's (kept when it says how long it lasts). True when it was kept.
    async fn ticket(&self, daemon: &str) -> Result<(CarrierAnswer, bool), String> {
        let now = now_unix();
        if let Some(answer) = self.warm.kept_tickets().get(daemon)
            && answer.expires_at > now.saturating_add(TICKET_MARGIN_SECS)
        {
            return Ok((answer.clone(), true));
        }
        // No ticket is `credential-unavailable` on the peer's link (`peer_carrier::reason`),
        // unless the hub has no carrier for it at all ([`ticket_refusal`]).
        let answer = self.tickets.connect(daemon).await.map_err(|e| {
            if e.contains("machine.not_found") {
                ticket_refusal(e)
            } else {
                format!(
                    "{} no relay ticket: {e}",
                    crate::protocol::peer_state::CREDENTIAL_UNAVAILABLE
                )
            }
        })?;
        let mut kept = self.warm.kept_tickets();
        kept.retain(|_, answer| answer.expires_at > now.saturating_add(TICKET_MARGIN_SECS));
        if answer.expires_at > now.saturating_add(TICKET_MARGIN_SECS) {
            kept.insert(daemon.to_owned(), answer.clone());
        } else {
            kept.remove(daemon);
        }
        Ok((answer, false))
    }

    async fn open_with(
        &self,
        daemon: &str,
        answer: CarrierAnswer,
    ) -> Result<SecureLink, OpenError> {
        let other = OpenError::Other;
        let pinned = key_bytes(
            answer
                .peer_key
                .as_deref()
                .ok_or_else(|| other("the hub named no key to pin".into()))?,
        )
        .ok_or_else(|| other("the hub's peer key is not 32 bytes of base64".into()))?;
        if pinned != key_bytes(daemon).unwrap_or(pinned) {
            return Err(other("the hub's peer key is not the one asked for".into()));
        }
        let endpoint = relay_url(&answer.relay).map_err(other)?;
        // The ticket in hand first; a later relay authentication asks the platform again.
        let first = Arc::new(Mutex::new(Some(Zeroizing::new(answer.ticket.clone()))));
        let tickets = self.tickets.clone();
        let peer = daemon.to_owned();
        let credentials = RelayCredentialSource::callback(move || {
            let first = first.lock().unwrap_or_else(|e| e.into_inner()).take();
            let tickets = tickets.clone();
            let peer = peer.clone();
            async move {
                match first {
                    Some(ticket) => Ok(ticket.to_string()),
                    None => tickets.connect(&peer).await.map(|a| a.ticket),
                }
            }
        });
        let provider = RelayProvider::with_credentials(
            RelayClientConfig {
                slot: answer.slot.clone(),
                ticket: String::new(),
                maximum_frame_bytes: MAX_FRAME_BYTES,
                control_timeout: self.timings.control,
            },
            credentials,
        )
        .map_err(|e| other(e.to_string()))?;
        let session = SessionId(random_16().map_err(other)?);
        let group = provider
            .connect(ConnectRequest {
                endpoint,
                session,
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::new(),
            })
            .await
            .map_err(|e| {
                OpenError::Connect(relay_refusal(e.to_string(), self.timings.peer_join))
            })?;
        let opened = tokio::time::timeout(
            self.timings.peer_join,
            group.open(LinkRequest { lane: Lane::Control, generation: 0 }),
        )
        .await;
        // The circuit is its own socket: the allocation socket is not needed past this.
        let _ = group.close().await;
        let link = opened
            .map_err(|_| other(carrier_not_serving(self.timings.peer_join)))?
            .map_err(|e| other(relay_refusal(e.to_string(), self.timings.peer_join)))?;
        initiate_secure_link(
            link,
            ClientHandshake {
                identity: self.identity.clone(),
                expected_daemon: Some(pinned),
                auth: ClientAuthMode::Enrolled,
                device_name: DEVICE_NAME.into(),
                session,
                lane: Lane::Control,
                lanes: vec![Lane::Control],
                generation: 0,
                connection_attempt: ConnectionAttemptId(random_16().map_err(other)?),
                resume: BTreeMap::new(),
                handshake_timeout: self.timings.handshake,
            },
        )
        .await
        .map_err(|e| other(e.to_string()))
    }
}

impl HubCarrier {
    /// How many warm spare circuits are parked now.
    pub fn warm_spares(&self) -> usize {
        self.warm.parked().spares.len()
    }

    /// An [`Opener`] under this carrier's key now.
    pub(super) fn opener(&self) -> Opener {
        Opener {
            tickets: self.tickets.clone(),
            identity: self.identity(),
            timings: self.timings,
            warm: self.warm.clone(),
        }
    }

    /// `daemon`'s spare, when one is parked, opened under the key `generation`, younger than its
    /// TTL and still open. A spare that fails any of these is closed.
    pub(super) async fn take_spare(&self, daemon: &str, generation: u64) -> Option<SecureLink> {
        let spare = self.warm.parked().spares.remove(daemon)?;
        if spare.generation != generation || spare.born.elapsed() >= self.timings.spare_ttl {
            // Dropping its taker ends its watcher, which closes the circuit.
            return None;
        }
        let (give, given) = oneshot::channel();
        spare.take.send(give).ok()?;
        given.await.ok()
    }

    /// Opens a spare to `daemon` in the background, unless it has one, one is opening, the
    /// carrier holds [`MAX_SPARES`] or spares are off (`timings.spare_ttl` zero).
    pub(super) fn refill_spare(&self, daemon: &str) {
        if self.timings.spare_ttl.is_zero() {
            return;
        }
        {
            let mut parked = self.warm.parked();
            if parked.spares.contains_key(daemon)
                || parked.filling.contains(daemon)
                || parked.spares.len() + parked.filling.len() >= MAX_SPARES
            {
                return;
            }
            parked.filling.insert(daemon.to_owned());
        }
        // The generation before the key: a rekey between them leaves a spare that is dropped
        // at its take, never one used under a key it was not opened with.
        let generation = self.generation.load(Ordering::SeqCst);
        let opener = self.opener();
        let warm = Arc::downgrade(&self.warm);
        let stats = self.stats.clone();
        let ttl = self.timings.spare_ttl;
        let daemon = daemon.to_owned();
        scope().spawn_named("hub carrier spare open", async move {
            let opened = opener.open(&daemon).await;
            drop(opener);
            let Some(warm) = warm.upgrade() else { return };
            let mut parked = warm.parked();
            parked.filling.remove(&daemon);
            let link = match opened {
                Ok(link) => link,
                Err(e) => {
                    tracing::debug!("hub carrier: no spare circuit opened: {e}");
                    return;
                }
            };
            if parked.spares.contains_key(&daemon) || parked.spares.len() >= MAX_SPARES {
                drop(parked);
                close_soon(link);
                return;
            }
            let id = warm.next_id.fetch_add(1, Ordering::Relaxed);
            let (take, taken) = oneshot::channel();
            parked
                .spares
                .insert(daemon.clone(), Spare { id, born: Instant::now(), generation, take });
            drop(parked);
            stats.spares.fetch_add(1, Ordering::Relaxed);
            scope().spawn_named(
                "hub carrier spare watch",
                watch_spare(link, taken, ttl, Arc::downgrade(&warm), daemon, id),
            );
        });
    }
}

/// Holds a parked spare until a dial takes it, its TTL passes, its taker is dropped, or anything
/// arrives on it (the far machine sends nothing before the hello's answer, so anything is the
/// circuit's end). Only a take keeps the circuit open.
async fn watch_spare(
    link: SecureLink,
    taken: oneshot::Receiver<oneshot::Sender<SecureLink>>,
    ttl: Duration,
    warm: Weak<Warm>,
    daemon: String,
    id: u64,
) {
    enum End {
        Taken(Option<oneshot::Sender<SecureLink>>),
        Heard,
        Expired,
    }
    let end = tokio::select! {
        biased;
        give = taken => End::Taken(give.ok()),
        _ = link.receive() => End::Heard,
        () = tokio::time::sleep(ttl) => End::Expired,
    };
    match end {
        End::Taken(Some(give)) => {
            if let Err(link) = give.send(link) {
                let _ = tokio::time::timeout(SPARE_CLOSE_WAIT, link.close()).await;
            }
            return;
        }
        End::Taken(None) => {}
        End::Heard => tracing::debug!("hub carrier: a spare circuit closed while parked"),
        End::Expired => {}
    }
    if let Some(warm) = warm.upgrade() {
        let mut parked = warm.parked();
        if parked.spares.get(&daemon).is_some_and(|spare| spare.id == id) {
            parked.spares.remove(&daemon);
        }
    }
    let _ = tokio::time::timeout(SPARE_CLOSE_WAIT, link.close()).await;
}

#[cfg(test)]
#[path = "hub_carrier_spare_tests.rs"]
mod tests;
