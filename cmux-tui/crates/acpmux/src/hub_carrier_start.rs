//! Starting the carrier from config: the node key (a cmux link's, else this process's own key
//! lock, [`KeyLease`]), the relay registration, direct and punched paths; and stopping it, split
//! from `hub_carrier.rs`.

use super::*;

/// How often a carrier on its own key lock asks whether a cmux link now serves this home's node
/// key (the transport's handoff asks as often, `daemon.rs` `LINK_HANDOFF_EVERY`).
pub(super) const LINK_HANDOFF_EVERY: Duration = Duration::from_secs(2);

/// Whether a cmux link serves the node key in `home` (or will at its next start): the link
/// recorded for it, else the one by this process's environment. The transport's rule
/// (`wireguard.rs`): there the link is the one key holder and acpmux takes no key lock.
pub(super) fn link_serves(home: &std::path::Path) -> bool {
    let link_dir = crate::cli::mesh_node_key::recorded_link_dir(home)
        .or_else(crate::wireguard::env_link_state_dir);
    crate::cli::mesh_node_key::link_serves_node_key(link_dir.as_deref(), home)
}

/// The key lock the carrier took itself, with no WireGuard transport running: held while the
/// carrier serves, and handed to the cmux link as soon as one serves this home's node key (as
/// `Transport::yield_to_link` hands the transport's), so `cmux link ensure` never waits on the
/// daemon. The carrier keeps only a weak share ([`KeyCheck`]): once the lock goes, its key check
/// fails, and it unregisters and refuses its dials. Dropping the lease frees the lock at once.
pub(crate) struct KeyLease {
    held: Arc<Mutex<Option<Arc<cmux_link::key_holder::KeyHolder>>>>,
    handoff: tokio::task::JoinHandle<()>,
}

impl KeyLease {
    /// Takes this machine's key lock in `home` (the caller checked that no cmux link serves its
    /// node key there, [`link_serves`]), unless another process holds the lock (a link, another
    /// daemon): then the carrier stays off.
    fn take(home: &std::path::Path) -> Option<(Self, Arc<cmux_link::key_holder::KeyHolder>)> {
        use cmux_link::key_holder::{KeyHolder, KeyHolderError};
        let holder = match KeyHolder::acquire(home) {
            Ok(holder) => Arc::new(holder),
            Err(KeyHolderError::KeyHeld { pid }) => {
                tracing::warn!(
                    holder_pid = ?pid,
                    "hub carrier off for this run: another process holds this machine's node key"
                );
                return None;
            }
            Err(KeyHolderError::Io(e)) => {
                tracing::warn!("hub carrier off: take the node key lock: {e}");
                return None;
            }
        };
        let held = Arc::new(Mutex::new(Some(holder.clone())));
        let handoff = Self::scope().spawn_named(
            "hub carrier key handoff",
            Self::hand_to_link(held.clone(), home.to_path_buf()),
        );
        Some((Self { held, handoff }, holder))
    }

    /// The owner of every lease's handoff task; a lease's drop aborts its own.
    fn scope() -> &'static cmux_scope::Scope {
        static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
        SCOPE.get_or_init(|| cmux_scope::Scope::new("hub carrier key lease"))
    }

    /// Frees the lock once a cmux link serves the node key in `home`.
    async fn hand_to_link(
        held: Arc<Mutex<Option<Arc<cmux_link::key_holder::KeyHolder>>>>,
        home: std::path::PathBuf,
    ) {
        loop {
            tokio::time::sleep(LINK_HANDOFF_EVERY).await;
            let at = home.clone();
            if tokio::task::spawn_blocking(move || link_serves(&at)).await.unwrap_or(false) {
                break;
            }
        }
        tracing::info!(
            "hub carrier: the cmux link now serves this machine's node key; the carrier gives \
             it the key lock and goes on serving on the Noise key alone"
        );
        drop(held.lock().unwrap_or_else(|e| e.into_inner()).take());
    }
}

impl Drop for KeyLease {
    fn drop(&mut self) {
        self.handoff.abort();
        drop(self.held.lock().unwrap_or_else(|e| e.into_inner()).take());
    }
}

/// The node key, read only under this machine's key lock (`cmux_link::key_holder`): the one this
/// daemon's WireGuard transport holds, or the carrier's own ([`KeyLease`]). Where the cmux link
/// is the key holder the carrier takes no lock (it would refuse the link's `cmux link ensure`,
/// `key_held`) and reads the key as a Noise static key instead ([`linked_node_key`]).
pub(super) fn node_key(
    state_dir: &std::path::Path,
    held: Arc<cmux_link::key_holder::KeyHolder>,
) -> Result<(Arc<cmux_link::key_holder::KeyHolder>, zeroize::Zeroizing<[u8; 32]>), String> {
    let (_, private) = crate::cli::mesh_node_key::load_or_create_held(state_dir, &held)
        .map_err(|e| format!("no node key: {e:#}"))?;
    Ok((held, private))
}

/// The node key where a cmux link serves it, read with no lock as a Noise static key (never
/// created: the link adopted the key, so it exists; none means the carrier stays off).
fn linked_node_key(state_dir: &std::path::Path) -> Result<zeroize::Zeroizing<[u8; 32]>, String> {
    crate::cli::mesh_node_key::read_noise_static(state_dir)
        .map_err(|e| format!("no node key to read beside the cmux link: {e:#}"))
}

/// The daemon's hub carrier: on when config.json names a mesh hub with the joined machine
/// credential (`meshRelay.credential: "join"`), this home is not a copy, and it holds the node
/// key: under the key lock the daemon's WireGuard transport hands it (`held`), else under its own
/// ([`KeyLease`]), which it takes only where no cmux link serves this home's node key. No
/// `transport.wireguard`, `wireguardStatic` or Labs switch is needed. Where the link holds the
/// key the carrier serves too, on a lockless read of the key as a Noise static key
/// ([`linked_node_key`]): a customer's Mac with the app's link running stays reachable over the
/// relay. It serves at once; peers find it through `hub.hub_carrier`.
pub async fn start_configured(
    hub: &Arc<crate::hub::Hub>,
    state_dir: &std::path::Path,
    websocket: Option<SocketAddr>,
    held: Option<Arc<cmux_link::key_holder::KeyHolder>>,
) -> Option<HubServe> {
    // Every way out says why, so a start's log always holds the carrier's state.
    let Some(config) = hub.config.read().await.mesh_relay.clone() else {
        tracing::info!(
            "hub carrier off: this machine is not joined (config.json has no meshRelay)"
        );
        return None;
    };
    if config.credential.as_deref() != Some("join") {
        tracing::info!("hub carrier off: meshRelay's credential is not the machine join");
        return None;
    }
    let Some(websocket) = websocket else {
        tracing::warn!("hub carrier off: the daemon has no loopback WebSocket listener");
        return None;
    };
    // Only this daemon's loopback listener, whose tokens stay mandatory, as WireGuard's bridge.
    let websocket = match crate::wireguard::local_websocket(websocket) {
        Ok(websocket) => websocket,
        Err(e) => {
            tracing::warn!("hub carrier off: {e:#}");
            return None;
        }
    };
    let client = match crate::mesh_http::HttpHub::new(&config) {
        Ok(client) => client,
        Err(e) => {
            tracing::warn!("hub carrier off: {e}");
            return None;
        }
    };
    // The transport's lock when it runs; else the carrier's own, unless the link holds the key
    // (then none: the carrier reads the key as a Noise static key).
    let linked = held.is_none() && link_serves(state_dir);
    let (lease, held) = match held {
        Some(held) => (None, Some(held)),
        None if linked => {
            tracing::info!(
                "hub carrier: the cmux link holds this machine's node key; serving on the Noise \
                 key alone, with no key lock"
            );
            (None, None)
        }
        None => {
            let (lease, held) = KeyLease::take(state_dir)?;
            (Some(lease), Some(held))
        }
    };
    let (holder, private) = match held {
        Some(held) => match node_key(state_dir, held) {
            Ok((holder, private)) => (Some(holder), private),
            Err(why) => {
                tracing::warn!("hub carrier off: {why}");
                return None;
            }
        },
        None => match linked_node_key(state_dir) {
            Ok(private) => (None, private),
            Err(why) => {
                tracing::warn!("hub carrier off: {why}");
                return None;
            }
        },
    };
    // A copy of another machine's home never serves (condition 3), whatever its credential.
    let copied_home = state_dir.to_path_buf();
    if tokio::task::spawn_blocking(move || {
        crate::cli::cloud_join::copied_from_another_box_at(&copied_home)
    })
    .await
    .unwrap_or(true)
    {
        tracing::warn!("hub carrier off: this home was copied from another machine");
        return None;
    }
    let home = state_dir.to_path_buf();
    // The carrier runs only while the transport or its lease holds the lock: it keeps no share of
    // it, so a transport or lease that yields to the cmux link (`Transport::yield_to_link`,
    // [`KeyLease`]) frees the key at once, and from then the check fails: the carrier unregisters
    // and refuses its dials.
    // A lock handed to the cmux link is no end of the carrier: it serves on the Noise key, so
    // while a link serves this home's key the check holds on the key alone.
    let holder = holder.as_ref().map(Arc::downgrade);
    let check: KeyCheck = Arc::new(move |public: &[u8; 32]| {
        let held =
            holder.as_ref().is_none_or(|holder| holder.upgrade().is_some()) || link_serves(&home);
        held && crate::cli::mesh_node_key::public_key_at(&home).is_some_and(|now| now == *public)
    });
    let carrier = HubCarrier::with_key_check(
        Arc::new(PlatformTickets { hub: client, shown: config.shown() }),
        *private,
        Timings::default(),
        check,
    );
    // Off unless the owner names the daemon (`remoteDaemon`) and grants control.
    carrier.set_cmux_tui_gate(Arc::new(crate::cmux_tui_service::ConfiguredGate::new(hub)));
    // Off unless the person on this machine allowed its other signed-in machines in.
    carrier.set_session_gate(Arc::new(crate::session_service::ConfiguredSessionGate::new(hub)));
    // Off under the same grant: this machine runs Computer Use calls for those machines.
    carrier.set_machine_call_gate(Arc::new(crate::machine_call_service::ConfiguredGate::new(hub)));
    // A move's pages, only to the machine its move names (`hub/transfer_pull.rs`); and this
    // machine's own way to the source of a move it pulls. A move needs `move` in
    // `meshRelay.controlFrom` on the target, off by default.
    carrier.set_transfer_gate(Arc::new(crate::transfer_service::ConfiguredTransferGate::new(hub)));
    // The lane-gh broker, to the machines the hub names, only once the owner names its socket.
    carrier.set_lane_gh_broker_gate(Arc::new(broker::ConfiguredBrokerGate::new(hub)));
    hub.set_transfer_dial(Arc::new(crate::transfer_service::CarrierDial::new(hub)));
    hub.hub_carrier.set(carrier.clone());
    carrier.keep_reopening();
    // The start's answer, whether or not the relay takes the registration yet (it retries).
    tracing::info!(
        "hub carrier: on, bridging admitted circuits to this daemon's listener {websocket}"
    );
    let direct_port = hub.config.read().await.direct_port;
    let mut serving = carrier.serve(websocket);
    serving.lease = lease;
    serving.direct = match direct_port {
        // `directPort` 0: no direct path at all.
        Some(0) => None,
        Some(port) => start_direct(hub, &carrier, port).await,
        // Unset: no dialing by name, but a port of its own for punches (on by default).
        None if punch::enabled() => start_punch(&carrier, 0),
        None => None,
    };
    Some(serving)
}

/// The direct path on `port` (`hub_carrier_direct.rs`): dial the person's other machines on it
/// first, by the name the hub's address book lists each by, and listen on it. A port that will
/// not bind leaves dialing on and says why.
async fn start_direct(
    hub: &Arc<crate::hub::Hub>,
    carrier: &Arc<HubCarrier>,
    port: u16,
) -> Option<tokio::task::JoinHandle<()>> {
    let book = Arc::downgrade(hub);
    carrier.set_direct(
        port,
        Some(Arc::new(move |daemon: &str| {
            let hub = book.upgrade()?;
            hub.mesh_book_machines()
                .into_iter()
                .find(|(key, _)| key == daemon)
                .map(|(_, host)| host)
        })),
    );
    let served = start_punch(carrier, port);
    if served.is_none() {
        tracing::warn!("hub carrier direct: port {port} will not bind; dialing only");
    }
    served
}

/// Listen for direct connections on `port` (0: a port of its own) where punches can open from
/// the same port, map it on the router when PCP or NAT-PMP grants one, and serve it.
fn start_punch(carrier: &Arc<HubCarrier>, port: u16) -> Option<tokio::task::JoinHandle<()>> {
    let listener = match punch::punch_listener(port) {
        Ok(listener) => listener,
        Err(e) => {
            tracing::warn!("hub carrier punch: no listener on port {port}: {e}");
            return None;
        }
    };
    let port = listener.local_addr().ok()?.port();
    tracing::info!("hub carrier direct: listening on port {port}");
    if punch::enabled() {
        carrier.set_punch_port(port);
        let mapping = Arc::downgrade(carrier);
        direct::scope().spawn_named("hub carrier port map", async move {
            punch::portmap::keep_mapped(mapping, port).await;
        });
    }
    Some(carrier.serve_direct(listener))
}

/// [`start_configured`] on the daemon's key lock (its WireGuard transport's, else the carrier's
/// own) and node key, kept on the hub (`Hub::hub_carrier_serve`) so a sign-out's leave can stop it
/// ([`stop_kept`]). A rekey (`machine_tunnel.rs`, which runs on the transport's lock) rotates the
/// node key under the carrier: it takes the new key with the key file and registers again, rather
/// than reading it as replaced.
pub async fn start_kept(hub: &Arc<crate::hub::Hub>, websocket: Option<SocketAddr>) {
    use crate::no_panic::LockExt;
    // The lock the WireGuard transport holds, when it runs; else the carrier takes its own.
    let held = hub.wireguard.as_ref().and_then(|transport| transport.key_holder());
    let Some(serving) = start_configured(hub, &crate::config::home(), websocket, held).await else {
        return;
    };
    if let (Some(transport), Some(carrier)) = (hub.wireguard.as_ref(), hub.hub_carrier.get()) {
        transport.add_key_user(Arc::new(move |private, write| carrier.rekey(*private, write)));
    }
    *hub.hub_carrier_serve.lock_or_recover() = Some(serving);
}

/// Stops the carrier [`start_kept`] started, if it runs: dropping its registration unregisters
/// this machine's slot on the relay. True when one was running.
pub fn stop_kept(hub: &crate::hub::Hub) -> bool {
    use crate::no_panic::LockExt;
    let carrier = hub.hub_carrier.clear();
    let serving = hub.hub_carrier_serve.lock_or_recover().take();
    // The workspace routes to the person's other machines go with the carrier they dial.
    hub.machine_routes.clear();
    carrier.is_some() || serving.is_some()
}
