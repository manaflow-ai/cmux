//! Weft move 2: the hub carrier's direct path (cmuxterm-hq RFD 0060, "acpmux peer links ..., ssh
//! as fallback"). Two of one person's machines that can reach each other on a private network
//! (lane VMs in one GCP region's VPC: a 0.3 ms round trip) carry their circuits over a TCP
//! connection between them instead of through the relay (one hub round trip, 0.16 s warm from a
//! GCP lane). Leo, 2026-11-23: "i feel like there should be ways for you guys to incrementally
//! fast-patch controllers and etc etc stuff that goes over network intra network etc".
//!
//! Nothing about trust changes: the direct connection carries the same Noise XX the relay
//! carries (the dialer pins the far machine's node key, the far machine admits only the keys
//! its Register ticket lets in) and then the same kept, multiplexed circuit and service hellos
//! ([`super::mux`]). The relay only moved bytes; here the kernel does.
//!
//! - Serving: with `directPort` set ([`crate::config::Config::direct_port`]) the carrier listens
//!   on that port and hands each connection from a private or loopback address to the same
//!   [`super::Incoming`] a relay circuit reaches. Before its first registration it has no list
//!   of admitted keys, so it closes them.
//! - Dialing: a named service (or an acpmux stream) to a machine first tries that machine's
//!   direct address: one a caller set ([`super::HubCarrier::set_direct_route`]), else the name
//!   the hub's address book lists it by, resolved, when it resolves to a private address. Any
//!   failure short of the far machine's own refusal falls back to the relay and keeps that
//!   machine off the direct path for [`MISS_HOLD`], so a machine with no direct listener costs
//!   one refused connect per hold, not one per dial.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex, RwLock, Weak};
use std::time::{Duration, Instant};

use cmux_remote::crypto::NetworkPeer;
use cmux_remote::provider::LengthDelimitedLink;

use super::{DialStages, HubCarrier, Incoming, MAX_FRAME_BYTES, key_bytes};

/// A direct connect inside one region answers in about a millisecond; past this the path is
/// not one worth taking over the relay.
pub(crate) const CONNECT_BOUND: Duration = Duration::from_millis(250);
/// The direct Noise handshake's bound: the far machine answers in a few milliseconds.
pub(crate) const HANDSHAKE_BOUND: Duration = Duration::from_secs(2);
/// How long a machine whose direct path failed is dialed over the relay only.
pub(crate) const MISS_HOLD: Duration = Duration::from_secs(300);
/// How long a resolved address is kept before the name is resolved again.
const RESOLVED_KEEP: Duration = Duration::from_secs(600);
/// A name lookup's bound (systemd-resolved answers a VPC name from its cache in microseconds).
const RESOLVE_BOUND: Duration = Duration::from_millis(200);
/// At most this many direct connections handshaking or carried at once.
const MAX_INCOMING: usize = 256;

/// The name the hub lists a machine (`daemonId`) by, for resolving its direct address.
pub type NameOf = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// Which path a dial took, as `_acpmux/remote.pipe`'s reply names it (`via`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Via {
    /// Through the relay.
    #[default]
    Hub,
    /// Over a direct connection to the far machine.
    Direct,
}

impl Via {
    pub fn name(self) -> &'static str {
        match self {
            Self::Hub => "hub",
            Self::Direct => "direct",
        }
    }
}

/// The carrier's direct-path state.
#[derive(Default)]
pub(crate) struct Direct {
    /// The far machines' direct port (this machine's `directPort`): none dials no direct path.
    port: RwLock<Option<u16>>,
    names: RwLock<Option<NameOf>>,
    /// Addresses a caller named, by `daemonId`.
    routes: Mutex<HashMap<String, SocketAddr>>,
    /// Addresses resolved from names, by `daemonId`, and when.
    resolved: Mutex<HashMap<String, (SocketAddr, Instant)>>,
    /// Machines whose direct path failed, until when.
    misses: Mutex<HashMap<String, Instant>>,
    /// The kept circuits on direct connections, by machine and lane.
    pub(crate) kept: super::mux::KeptCircuits,
    /// The current registration's admission of incoming circuits.
    incoming: RwLock<Option<Weak<Incoming>>>,
    /// Punches toward machines on other networks (`hub_carrier_punch.rs`).
    pub(crate) punch: super::punch::Punches,
}

impl Direct {
    pub(crate) fn set_incoming(&self, incoming: &Arc<Incoming>) {
        *self.incoming.write().unwrap_or_else(|e| e.into_inner()) = Some(Arc::downgrade(incoming));
    }

    pub(crate) fn incoming(&self) -> Option<Arc<Incoming>> {
        self.incoming.read().unwrap_or_else(|e| e.into_inner()).as_ref()?.upgrade()
    }

    pub(crate) fn miss(&self, daemon: &str) {
        self.misses
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(daemon.to_owned(), Instant::now() + MISS_HOLD);
        self.resolved.lock().unwrap_or_else(|e| e.into_inner()).remove(daemon);
    }

    fn held_off(&self, daemon: &str) -> bool {
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
}

/// Whether a direct path may go to or come from `ip`: a private (RFC 1918), unique-local or
/// loopback address. Tailscale's own ranges are left to Tailscale: a mesh address is not the
/// private network this path is for, and the tailnet is the fallback it runs beside.
pub fn private_address(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_private() || v4.is_loopback(),
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return private_address(IpAddr::V4(v4));
            }
            let s = v6.segments();
            // fd7a:115c:a1e0::/48 is Tailscale's.
            let tailscale = s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0;
            v6.is_loopback() || ((s[0] & 0xfe00) == 0xfc00 && !tailscale)
        }
    }
}

impl HubCarrier {
    /// Dial the person's other machines on `port` first (their `directPort`), finding each by
    /// the name `names` gives for its `daemonId`.
    pub fn set_direct(&self, port: u16, names: Option<NameOf>) {
        *self.direct.port.write().unwrap_or_else(|e| e.into_inner()) = Some(port);
        *self.direct.names.write().unwrap_or_else(|e| e.into_inner()) = names;
    }

    /// Reach the machine whose `daemonId` is `daemon` at `address` first (tests, and a caller
    /// that knows where a machine is).
    pub fn set_direct_route(&self, daemon: &str, address: SocketAddr) {
        self.direct
            .routes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(daemon.to_owned(), address);
    }

    /// How many kept direct circuits to `daemon` are open now.
    pub fn kept_direct_circuits(&self, daemon: &str) -> usize {
        self.direct.kept.live(daemon).len()
    }

    /// The direct address to try for `daemon` now, if any.
    pub(crate) async fn direct_address(&self, daemon: &str) -> Option<SocketAddr> {
        if self.direct.held_off(daemon) {
            return None;
        }
        if let Some(address) =
            self.direct.routes.lock().unwrap_or_else(|e| e.into_inner()).get(daemon).copied()
        {
            return Some(address);
        }
        let port = (*self.direct.port.read().unwrap_or_else(|e| e.into_inner()))?;
        if let Some((address, at)) =
            self.direct.resolved.lock().unwrap_or_else(|e| e.into_inner()).get(daemon).copied()
            && at.elapsed() < RESOLVED_KEEP
        {
            return Some(address);
        }
        let names = self.direct.names.read().unwrap_or_else(|e| e.into_inner()).clone()?;
        let name = names(daemon)?;
        let found =
            tokio::time::timeout(RESOLVE_BOUND, tokio::net::lookup_host((name.as_str(), port)))
                .await
                .ok()
                .and_then(Result::ok)
                .and_then(|mut all| all.find(|a| private_address(a.ip()) && !a.ip().is_loopback()));
        match found {
            Some(address) => {
                self.direct
                    .resolved
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(daemon.to_owned(), (address, Instant::now()));
                Some(address)
            }
            None => {
                // No private address for it (another network, or a name the resolver does not
                // know): the relay, and no lookup per dial.
                self.direct.miss(daemon);
                None
            }
        }
    }

    /// A direct connection to `daemon` at `address` with the Noise handshake done, its key
    /// pinned to `daemon`, and how long it took (`relay` holds the TCP connect).
    pub(crate) async fn open_direct(
        &self,
        daemon: &str,
        address: SocketAddr,
    ) -> Result<(cmux_remote::crypto::SecureLink, DialStages), String> {
        let mut stages = DialStages::default();
        let step = Instant::now();
        let tcp = tokio::time::timeout(CONNECT_BOUND, tokio::net::TcpStream::connect(address))
            .await
            .map_err(|_| format!("direct: no connect to {address} in {CONNECT_BOUND:?}"))?
            .map_err(|e| format!("direct: connect to {address}: {e}"))?;
        stages.relay = step.elapsed();
        self.secure_direct(daemon, tcp, address, stages).await
    }

    /// The Noise handshake, as the initiator with `daemon`'s key pinned, on a direct
    /// connection to it (dialed or punched).
    pub(crate) async fn secure_direct(
        &self,
        daemon: &str,
        tcp: tokio::net::TcpStream,
        address: SocketAddr,
        mut stages: DialStages,
    ) -> Result<(cmux_remote::crypto::SecureLink, DialStages), String> {
        let pinned = key_bytes(daemon).ok_or("a direct dial needs the machine's node key")?;
        let _ = tcp.set_nodelay(true);
        let (read, write) = tcp.into_split();
        let link = LengthDelimitedLink::new(
            format!("hub carrier direct {address}"),
            MAX_FRAME_BYTES,
            read,
            write,
        );
        let step = Instant::now();
        let secure = tokio::time::timeout(
            HANDSHAKE_BOUND,
            cmux_remote::crypto::initiate_secure_link_pipelined(
                Box::new(link),
                self.client_handshake(pinned, HANDSHAKE_BOUND)?,
            ),
        )
        .await
        .map_err(|_| format!("direct: no handshake with {address} in {HANDSHAKE_BOUND:?}"))?
        .map_err(|e| format!("direct: handshake with {address}: {e}"))?;
        stages.noise = step.elapsed();
        Ok((secure, stages))
    }

    /// Listen on `listen` for direct circuits from the person's other machines, until the
    /// returned task is aborted ([`super::HubServe`]'s drop) or the carrier is gone.
    pub fn serve_direct(
        self: &Arc<Self>,
        listener: tokio::net::TcpListener,
    ) -> tokio::task::JoinHandle<()> {
        let carrier = Arc::downgrade(self);
        let room = Arc::new(tokio::sync::Semaphore::new(MAX_INCOMING));
        scope().spawn_named("hub carrier direct listener", async move {
            loop {
                let (tcp, from) = match listener.accept().await {
                    Ok(accepted) => accepted,
                    Err(e) => {
                        tracing::debug!("hub carrier direct: accept failed: {e}");
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        continue;
                    }
                };
                let Some(carrier) = carrier.upgrade() else { return };
                // From any address: a punched connection comes from another network. The Noise
                // handshake admits only the keys the hub names, as on the relay.
                let Some(incoming) = carrier.direct.incoming() else {
                    // Not registered yet: no admitted keys to check a handshake against.
                    continue;
                };
                let Ok(permit) = room.clone().try_acquire_owned() else {
                    tracing::warn!(
                        "hub carrier direct: {MAX_INCOMING} connections open; closed one"
                    );
                    continue;
                };
                let _ = tcp.set_nodelay(true);
                let (read, write) = tcp.into_split();
                let link = LengthDelimitedLink::new(
                    format!("hub carrier direct from {from}"),
                    MAX_FRAME_BYTES,
                    read,
                    write,
                );
                scope().spawn_named("hub carrier direct circuit", async move {
                    incoming.accept(Box::new(link), NetworkPeer::Tcp).await;
                    drop(permit);
                });
            }
        })
    }
}

pub(crate) fn scope() -> &'static cmux_scope::Scope {
    static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
    SCOPE.get_or_init(|| cmux_scope::Scope::new("hub carrier direct links"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_private_and_loopback_addresses_take_the_direct_path() {
        for yes in [
            "10.138.0.38",
            "172.16.0.1",
            "192.168.1.2",
            "127.0.0.1",
            "::1",
            "fd00::1",
            "::ffff:10.0.0.1",
        ] {
            assert!(private_address(yes.parse().unwrap()), "{yes}");
        }
        for no in ["8.8.8.8", "100.127.178.43", "fd7a:115c:a1e0::1", "2600::1", "::ffff:1.1.1.1"] {
            assert!(!private_address(no.parse().unwrap()), "{no}");
        }
    }

    #[test]
    fn a_miss_holds_a_machine_off_the_direct_path() {
        let direct = Direct::default();
        assert!(!direct.held_off("k"));
        direct.miss("k");
        assert!(direct.held_off("k"));
        assert!(!direct.held_off("other"));
    }
}
