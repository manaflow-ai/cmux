//! Weft step 2 for machines with no private network between them (a Freestyle slot and a GCP
//! lane): the hub carrier's iroh path. Leo: "small, chatty calls stay on whichever machine holds
//! the files, batched over one always-open connection, never a new connection per call."
//!
//! Both ends dial out over QUIC (iroh, hole punched where the NATs let it, else iroh's relay), so
//! no firewall opens. Nothing about trust changes: the iroh connection's one bidirectional stream
//! carries the same Noise XX the relay and the direct path carry (the dialer pins the far
//! machine's node key, the far machine admits only the keys its Register ticket lets in), then the
//! same kept, multiplexed circuit and service hellos ([`super::mux`]). The iroh key is a pipe key
//! only.
//!
//! - On where `irohDirect` is true, or unset on a machine whose `directPort` names a port (it
//!   opted into direct links already; every lane VM has) ([`crate::config::Config::iroh_on`]);
//!   off on any other machine and wherever `irohDirect` is false. On, the carrier
//!   binds one iroh endpoint (its key kept in `~/.acpmux/iroh.key`) and hands each accepted
//!   connection's stream to the same [`super::Incoming`] a relay circuit reaches.
//! - Upgrade, not a race: a machine's first dial rides the relay. Beside it the carrier asks the
//!   far machine for its iroh address over that relay circuit ([`super::CircuitService::IrohAddr`])
//!   and opens a kept circuit over iroh. Once that circuit is open, new streams take it; the relay
//!   circuit stays kept as the fallback. A failure falls back to the relay and holds the machine
//!   off iroh for [`MISS_HOLD`], as the direct path does.
//! - `via` says which iroh path carried a stream: `iroh-direct` (a hole-punched UDP path) or
//!   `iroh-relay` (iroh's own relay).

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex, RwLock, Weak};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use cmux_remote::crypto::NetworkPeer;
use cmux_remote::provider::LengthDelimitedLink;
pub use iroh::EndpointAddr;
use iroh::endpoint::{Connection, RecvStream, SendStream, WeakConnectionHandle};
use iroh::{Endpoint, RelayMode, SecretKey};
use tokio::io::{AsyncRead, ReadBuf};

use super::direct::Via;
use super::{CircuitLane, DialStages, HubCarrier, MAX_FRAME_BYTES, key_bytes};

/// The ALPN of a hub carrier circuit over iroh (not cmux-remote's: a different protocol).
pub const ALPN: &[u8] = b"acpmux/hub-carrier/1";
/// An iroh connect, hole punch included, past this is not a path worth taking over the relay.
pub(crate) const CONNECT_BOUND: Duration = Duration::from_secs(5);
/// The Noise handshake's bound over an open iroh connection.
pub(crate) const HANDSHAKE_BOUND: Duration = Duration::from_secs(3);
/// How long a machine whose iroh path failed is dialed over the relay only.
pub(crate) const MISS_HOLD: Duration = super::direct::MISS_HOLD;
/// The far machine's iroh address answer is a few hundred bytes.
const MAX_ADDR_BYTES: usize = 4096;
/// At most this many iroh connections handshaking or carried at once.
const MAX_INCOMING: usize = 256;

/// How the carrier binds its iroh endpoint.
#[derive(Clone, Debug, Default)]
pub struct IrohConfig {
    /// The endpoint's key file (`~/.acpmux/iroh.key`); none: a new key each start.
    pub secret: Option<PathBuf>,
    /// Use iroh's relays for hole punching and as its own fallback. Off: direct addresses only
    /// (tests on loopback).
    pub relay: bool,
    /// The UDP address to bind; none: every interface, any port.
    pub bind: Option<SocketAddr>,
}

/// The carrier's iroh-path state.
#[derive(Default)]
pub(crate) struct Iroh {
    endpoint: RwLock<Option<Endpoint>>,
    /// The carrier itself, so a dial can open the iroh path beside the relay dial.
    me: RwLock<Option<Weak<HubCarrier>>>,
    /// The far machines' iroh addresses, by `daemonId`.
    routes: Mutex<HashMap<String, EndpointAddr>>,
    /// Machines whose iroh path failed, until when.
    misses: Mutex<HashMap<String, Instant>>,
    /// Upgrades running now, by machine and lane: one at a time each.
    opening: Mutex<HashSet<(String, CircuitLane)>>,
    /// The iroh connection under each machine's newest kept circuit, for `via`.
    connections: Mutex<HashMap<String, WeakConnectionHandle>>,
    /// The kept circuits over iroh, by machine and lane.
    pub(crate) kept: super::mux::KeptCircuits,
}

impl Iroh {
    fn endpoint(&self) -> Option<Endpoint> {
        self.endpoint.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub(crate) fn on(&self) -> bool {
        self.endpoint.read().unwrap_or_else(|e| e.into_inner()).is_some()
    }

    pub(crate) fn miss(&self, daemon: &str) {
        self.misses
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(daemon.to_owned(), Instant::now() + MISS_HOLD);
        self.connections.lock().unwrap_or_else(|e| e.into_inner()).remove(daemon);
    }

    pub(crate) fn held_off(&self, daemon: &str) -> bool {
        let mut misses = self.misses.lock().unwrap_or_else(|e| e.into_inner());
        match misses.get(daemon) {
            Some(until) if Instant::now() < *until => true,
            Some(_) => {
                misses.remove(daemon);
                false
            }
            None => false,
        }
    }

    pub(crate) fn route(&self, daemon: &str) -> Option<EndpointAddr> {
        self.routes.lock().unwrap_or_else(|e| e.into_inner()).get(daemon).cloned()
    }

    /// `iroh-direct` while the connection to `daemon` sends on a UDP path, else `iroh-relay`.
    pub(crate) fn via(&self, daemon: &str) -> Via {
        let connection = self
            .connections
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(daemon)
            .and_then(WeakConnectionHandle::upgrade);
        match connection {
            Some(connection)
                if connection.paths().iter().any(|path| path.is_selected() && path.is_ip()) =>
            {
                Via::IrohDirect
            }
            _ => Via::IrohRelay,
        }
    }
}

/// An iroh stream's read half that holds its connection: the connection closes when the link
/// that reads it is dropped, not before.
struct Held {
    recv: RecvStream,
    _connection: Connection,
}

impl AsyncRead for Held {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.recv).poll_read(cx, buf)
    }
}

fn link(
    description: String,
    connection: Connection,
    send: SendStream,
    recv: RecvStream,
) -> Box<LengthDelimitedLink<Held, SendStream>> {
    Box::new(LengthDelimitedLink::new(
        description,
        MAX_FRAME_BYTES,
        Held { recv, _connection: connection },
        send,
    ))
}

impl HubCarrier {
    /// Bind this carrier's iroh endpoint and serve circuits on it, until the returned task is
    /// aborted ([`super::HubServe`]'s drop) or the carrier is gone. Dials then upgrade to iroh.
    pub async fn start_iroh(
        self: &Arc<Self>,
        config: IrohConfig,
    ) -> Result<tokio::task::JoinHandle<()>, String> {
        use iroh::endpoint::presets;
        let mut builder = Endpoint::builder(presets::Minimal)
            .alpns(vec![ALPN.to_vec()])
            .relay_mode(if config.relay { RelayMode::Default } else { RelayMode::Disabled })
            .ca_tls_config(iroh::tls::CaTlsConfig::system());
        if let Some(path) = &config.secret {
            let secret = cmux_remote::provider::load_or_create_iroh_secret(path)
                .map_err(|e| format!("iroh: the key at {}: {e}", path.display()))?;
            builder = builder.secret_key(secret);
        } else {
            let mut bytes = [0_u8; 32];
            getrandom::fill(&mut bytes).map_err(|e| format!("iroh: randomness: {e}"))?;
            builder = builder.secret_key(SecretKey::from_bytes(&bytes));
        }
        if let Some(bind) = config.bind {
            builder = builder.bind_addr(bind).map_err(|e| format!("iroh: bind {bind}: {e}"))?;
        }
        let endpoint = builder.bind().await.map_err(|e| format!("iroh: bind: {e}"))?;
        *self.iroh.endpoint.write().unwrap_or_else(|e| e.into_inner()) = Some(endpoint.clone());
        *self.iroh.me.write().unwrap_or_else(|e| e.into_inner()) = Some(Arc::downgrade(self));
        Ok(self.serve_iroh(endpoint))
    }

    /// This machine's iroh address, once its endpoint is bound.
    pub fn iroh_addr(&self) -> Option<EndpointAddr> {
        Some(self.iroh.endpoint()?.addr())
    }

    /// Reach the machine whose `daemonId` is `daemon` at `address` over iroh (tests, and the
    /// answer of its [`super::CircuitService::IrohAddr`]).
    pub fn set_iroh_route(&self, daemon: &str, address: EndpointAddr) {
        self.iroh
            .routes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(daemon.to_owned(), address);
    }

    /// How many kept iroh circuits to `daemon` are open now.
    pub fn kept_iroh_circuits(&self, daemon: &str) -> usize {
        self.iroh.kept.live(daemon).len()
    }

    /// The answer this machine gives [`super::CircuitService::IrohAddr`]: its address as JSON,
    /// none while iroh is off.
    pub(crate) fn iroh_addr_record(&self) -> Option<Vec<u8>> {
        serde_json::to_vec(&self.iroh_addr()?).ok()
    }

    /// An iroh connection to `daemon` with the Noise handshake done, its key pinned to `daemon`,
    /// and how long it took (`relay` holds the iroh connect).
    pub(crate) async fn open_iroh(
        &self,
        daemon: &str,
    ) -> Result<(cmux_remote::crypto::SecureLink, DialStages), String> {
        let mut stages = DialStages::default();
        let endpoint = self.iroh.endpoint().ok_or("iroh is off")?;
        let address = self.iroh.route(daemon).ok_or("no iroh address for the machine")?;
        let pinned = key_bytes(daemon).ok_or("an iroh dial needs the machine's node key")?;
        let id = address.id;
        let step = Instant::now();
        let connection = tokio::time::timeout(CONNECT_BOUND, endpoint.connect(address, ALPN))
            .await
            .map_err(|_| format!("iroh: no connect to {id} in {CONNECT_BOUND:?}"))?
            .map_err(|e| format!("iroh: connect to {id}: {e}"))?;
        if connection.remote_id() != id {
            return Err(format!("iroh: {} answered for {id}", connection.remote_id()));
        }
        let (send, recv) = connection.open_bi().await.map_err(|e| format!("iroh: open: {e}"))?;
        stages.relay = step.elapsed();
        self.iroh
            .connections
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(daemon.to_owned(), connection.weak_handle());
        let link = link(format!("hub carrier iroh {id}"), connection, send, recv);
        let step = Instant::now();
        let secure = tokio::time::timeout(
            HANDSHAKE_BOUND,
            cmux_remote::crypto::initiate_secure_link_pipelined(
                link,
                self.client_handshake(pinned, HANDSHAKE_BOUND)?,
            ),
        )
        .await
        .map_err(|_| format!("iroh: no handshake with {id} in {HANDSHAKE_BOUND:?}"))?
        .map_err(|e| format!("iroh: handshake with {id}: {e}"))?;
        stages.noise = step.elapsed();
        Ok((secure, stages))
    }

    /// Whether the `lane` iroh circuit to `daemon` is open now; when it is not, start opening it
    /// beside this dial (learning the far machine's address over the relay first if need be).
    pub(crate) async fn iroh_ready(&self, daemon: &str, lane: CircuitLane) -> bool {
        if !self.iroh.on() || self.iroh.held_off(daemon) {
            return false;
        }
        let slot = self.iroh.kept.slot(daemon, lane);
        // Never wait here on an upgrade that holds the slot: this dial takes the relay then.
        let Ok(kept) = slot.try_lock() else { return false };
        if kept.live.as_ref().is_some_and(|mux| !mux.is_closed()) {
            return true;
        }
        drop(kept);
        let key = (daemon.to_owned(), lane);
        if !self.iroh.opening.lock().unwrap_or_else(|e| e.into_inner()).insert(key.clone()) {
            return false;
        }
        let Some(me) = self.iroh.me.read().unwrap_or_else(|e| e.into_inner()).clone() else {
            return false;
        };
        scope().spawn_named("hub carrier iroh upgrade", async move {
            let Some(carrier) = me.upgrade() else { return };
            if let Err(why) = carrier.upgrade_iroh(&key.0, key.1).await {
                tracing::info!("hub carrier iroh: no iroh path ({why}); the relay");
                carrier.iroh.miss(&key.0);
            }
            carrier.iroh.opening.lock().unwrap_or_else(|e| e.into_inner()).remove(&key);
        });
        false
    }

    /// Open the `lane` kept circuit to `daemon` over iroh, with no stream on it yet.
    async fn upgrade_iroh(&self, daemon: &str, lane: CircuitLane) -> Result<(), String> {
        if self.iroh.route(daemon).is_none() {
            let address = self.ask_iroh_addr(daemon).await?;
            self.set_iroh_route(daemon, address);
        }
        let slot = self.iroh.kept.slot(daemon, lane);
        let mut kept = slot.lock().await;
        if kept.live.as_ref().is_some_and(|mux| !mux.is_closed()) {
            return Ok(());
        }
        let (mux, said, stages) = self.open_kept(daemon, lane, super::Path::Iroh).await?;
        match tokio::time::timeout(self.timings.handshake, said).await {
            Ok(Ok(Ok(()))) => {
                stages.log(daemon, "iroh");
                self.stats.kept_circuits.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                kept.live = Some(mux);
                // So the reopen loop opens it again over iroh if it ends.
                kept.path = Some(super::Path::Iroh);
                Ok(())
            }
            Ok(Ok(Err(refusal))) => {
                mux.close().await;
                Err(format!("the machine keeps no circuits over iroh: {refusal}"))
            }
            Ok(Err(_)) | Err(_) => {
                mux.close().await;
                Err(mux.ended().unwrap_or_else(|| "no answer to the kept hello".into()))
            }
        }
    }

    /// The far machine's iroh address, asked on the relay's kept circuit.
    async fn ask_iroh_addr(&self, daemon: &str) -> Result<EndpointAddr, String> {
        use tokio::io::AsyncReadExt;
        let hello = super::hello_record(super::CircuitService::IrohAddr);
        let mut report = super::DialReport::default();
        let stream = match self
            .kept_open(daemon, CircuitLane::Cheap, hello, &[], &mut report, super::Path::Relay)
            .await
        {
            super::KeptOpen::Stream(stream) => stream,
            super::KeptOpen::Refused(refusal) => return Err(refusal.to_string()),
            super::KeptOpen::Failed(e) | super::KeptOpen::Lost(e) | super::KeptOpen::Plain(e) => {
                return Err(e);
            }
        };
        let mut answer = Vec::new();
        tokio::time::timeout(
            self.timings.handshake,
            stream.take(MAX_ADDR_BYTES as u64).read_to_end(&mut answer),
        )
        .await
        .map_err(|_| "no iroh address in time".to_owned())?
        .map_err(|e| format!("the iroh address: {e}"))?;
        serde_json::from_slice(&answer).map_err(|e| format!("the iroh address: {e}"))
    }

    /// Accept iroh connections from the person's other machines into [`super::Incoming`].
    fn serve_iroh(self: &Arc<Self>, endpoint: Endpoint) -> tokio::task::JoinHandle<()> {
        let carrier = Arc::downgrade(self);
        let room = Arc::new(tokio::sync::Semaphore::new(MAX_INCOMING));
        scope().spawn_named("hub carrier iroh listener", async move {
            while let Some(accepting) = endpoint.accept().await {
                let Some(carrier) = carrier.upgrade() else { break };
                let Some(incoming) = carrier.direct.incoming() else {
                    // Not registered yet: no admitted keys to check a handshake against.
                    accepting.refuse();
                    continue;
                };
                let Ok(permit) = room.clone().try_acquire_owned() else {
                    tracing::warn!(
                        "hub carrier iroh: {MAX_INCOMING} connections open; refused one"
                    );
                    accepting.refuse();
                    continue;
                };
                scope().spawn_named("hub carrier iroh circuit", async move {
                    let Ok(Ok(connection)) =
                        tokio::time::timeout(CONNECT_BOUND, async { accepting.await }).await
                    else {
                        return;
                    };
                    if connection.alpn() != ALPN {
                        connection.close(2_u8.into(), b"unexpected ALPN");
                        return;
                    }
                    let id = connection.remote_id();
                    let Ok(Ok((send, recv))) =
                        tokio::time::timeout(HANDSHAKE_BOUND, connection.accept_bi()).await
                    else {
                        return;
                    };
                    let link = link(format!("hub carrier iroh from {id}"), connection, send, recv);
                    incoming.accept(link, NetworkPeer::Iroh).await;
                    drop(permit);
                });
            }
            endpoint.close().await;
        })
    }
}

fn scope() -> &'static cmux_scope::Scope {
    static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
    SCOPE.get_or_init(|| cmux_scope::Scope::new("hub carrier iroh links"))
}

#[cfg(test)]
#[path = "hub_carrier_iroh_tests.rs"]
mod tests;
