//! A Weft device: joins a tailnet, follows its netmap, and runs the
//! WireGuard mesh in-process.
//!
//! Data path today (v1): each peer gets a loopback UDP socket that stands in
//! for it. `cmux-wg`'s [`WgMesh`] sends the peer's WireGuard datagrams to
//! that socket; a task moves them over the peer's home relay. Datagrams from
//! a relay are written from the peer's socket into the mesh, so the mesh
//! sees an ordinary UDP peer and `cmux-wg` is used unchanged. Direct UDP
//! paths (M2) slot in as further routes of the same peer.
//!
//! The ACL is enforced here on receive: every accepted connection is checked
//! against the inbound filter by the WireGuard key of the session that
//! carried its SYN, and closed unread when the key may not use the port.

mod relay_pool;
mod state_file;

use std::collections::HashMap;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use anyhow::{Context, bail};
use cmux_wg::{InterfaceAddress, IpNetwork, WgMesh, WgMeshConfig, WgPeer, WgStream};
use reqwest::Method;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::mpsc;
use tokio::task::{JoinHandle, JoinSet};
use zeroize::Zeroizing;

use crate::admin::{check, http_client};
use crate::keys::{NodeKey, SigningKey};
use crate::policy::PortRange;
use crate::signing::{HEADER_NODE, HEADER_NONCE, HEADER_SIG, HEADER_TS, sign_request};
use crate::types::{
    EndpointsRequest, Netmap, NodeState, PeerView, RegisterRequest, RegisterResponse, RotateRequest,
};
use relay_pool::RelayPool;
pub use state_file::StateFile;

/// Inner MTU of the mesh. 1280 keeps every datagram inside one relay frame
/// and inside the IPv6 minimum MTU once direct UDP paths exist.
pub const MESH_MTU: u16 = 1280;
const KEEPALIVE_SECONDS: u16 = 25;

pub struct JoinOptions {
    /// Coordinator base URL, e.g. `https://cmux-weft-coord-staging.fly.dev`.
    pub coord: String,
    pub tailnet: String,
    pub auth_key: String,
    /// A name for this device (shown to admins).
    pub name: String,
}

/// What an overlay port serves.
#[derive(Clone, Debug)]
pub enum Service {
    /// Echo every byte back (diagnostics and latency measurement).
    Echo,
    /// Splice each allowed connection to a local TCP address.
    Forward(SocketAddr),
}

struct PeerLink {
    view: PeerView,
    socket: Arc<UdpSocket>,
    home_relay: Arc<RwLock<Option<String>>>,
    task: JoinHandle<()>,
}

/// A served overlay port: what it serves and its listener task.
type ServedPort = (Service, Option<JoinHandle<()>>);

struct Shared {
    coord: String,
    tailnet: String,
    node_id: String,
    address: Ipv6Addr,
    state_path: PathBuf,
    http: reqwest::Client,
    machine: SigningKey,
    node_key: RwLock<NodeKey>,
    mesh: RwLock<Option<Arc<WgMesh>>>,
    netmap: RwLock<Netmap>,
    filter: RwLock<HashMap<[u8; 32], Vec<PortRange>>>,
    peers: Mutex<HashMap<[u8; 32], PeerLink>>,
    services: Mutex<HashMap<u16, ServedPort>>,
    pool: Arc<RelayPool>,
    home_relay: RwLock<Option<String>>,
    /// Serializes netmap application and key rotation.
    apply: tokio::sync::Mutex<()>,
    revoked: std::sync::atomic::AtomicBool,
}

/// A joined device.
pub struct WeftNode {
    shared: Arc<Shared>,
    tasks: Mutex<Vec<JoinHandle<()>>>,
}

impl WeftNode {
    /// Load the device at `state_path`, or enroll it with `options` when the
    /// file does not exist yet, then start following the netmap.
    pub async fn join(state_path: &Path, options: Option<JoinOptions>) -> anyhow::Result<Self> {
        let http = http_client();
        let state = match StateFile::load(state_path).await? {
            Some(state) => state,
            None => {
                let options =
                    options.context("no state file yet: an auth key is needed to enroll")?;
                register(&http, state_path, options).await?
            }
        };
        let seed =
            crate::b64::decode_key(&state.machine_seed).context("state file: machine_seed")?;
        let private = Zeroizing::new(
            crate::b64::decode_key(&state.node_private).context("state file: node_private")?,
        );
        let (inbound_tx, inbound_rx) = mpsc::channel(4096);
        let shared = Arc::new(Shared {
            coord: state.coord.trim_end_matches('/').to_owned(),
            tailnet: state.tailnet.clone(),
            node_id: state.node_id.clone(),
            address: state.address,
            state_path: state_path.to_owned(),
            http,
            machine: SigningKey::from_seed(seed),
            node_key: RwLock::new(NodeKey::from_private(*private)),
            mesh: RwLock::new(None),
            netmap: RwLock::new(empty_netmap(&state)),
            filter: RwLock::new(HashMap::new()),
            peers: Mutex::new(HashMap::new()),
            services: Mutex::new(HashMap::new()),
            pool: RelayPool::new(inbound_tx),
            home_relay: RwLock::new(None),
            apply: tokio::sync::Mutex::new(()),
            revoked: std::sync::atomic::AtomicBool::new(false),
        });

        let first = shared.fetch_netmap(None).await?;
        if let Some(home) = pick_home_relay(&shared.http, &first).await {
            shared.pool.ensure(&home);
            write(&shared.home_relay, Some(home.clone()));
            shared.post_endpoints(Some(home)).await?;
        }
        shared.rebuild_mesh().await?;
        shared.apply_netmap(first).await;

        let node = Self { shared: shared.clone(), tasks: Mutex::new(Vec::new()) };
        node.spawn(deliver_inbound(shared.clone(), inbound_rx));
        node.spawn(follow_netmap(shared));
        Ok(node)
    }

    fn spawn(&self, future: impl Future<Output = ()> + Send + 'static) {
        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.push(tokio::spawn(future));
        }
    }

    pub fn node_id(&self) -> &str {
        &self.shared.node_id
    }

    pub fn tailnet(&self) -> &str {
        &self.shared.tailnet
    }

    pub fn address(&self) -> Ipv6Addr {
        self.shared.address
    }

    pub fn node_key(&self) -> [u8; 32] {
        read(&self.shared.node_key).public()
    }

    pub fn netmap(&self) -> Netmap {
        read(&self.shared.netmap).clone()
    }

    pub fn state(&self) -> NodeState {
        read(&self.shared.netmap).node.state
    }

    /// Whether the coordinator removed this device.
    pub fn revoked(&self) -> bool {
        self.shared.revoked.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub fn home_relay(&self) -> Option<String> {
        read(&self.shared.home_relay).clone()
    }

    /// Open a TCP connection to `target` (a peer's overlay address).
    pub async fn connect(&self, target: SocketAddr) -> anyhow::Result<WgStream> {
        let mesh = self.shared.mesh().context("mesh not running")?;
        Ok(mesh.connect(target).await?)
    }

    /// Serve `service` on overlay `port`, for the peers the filter allows.
    pub async fn serve(&self, port: u16, service: Service) -> anyhow::Result<()> {
        let mesh = self.shared.mesh().context("mesh not running")?;
        let task = spawn_listener(&self.shared, &mesh, port, service.clone()).await?;
        if let Ok(mut services) = self.shared.services.lock()
            && let Some((_, Some(old))) = services.insert(port, (service, Some(task)))
        {
            old.abort();
        }
        Ok(())
    }

    /// Accept local TCP connections on `local` and carry each to `remote`.
    pub async fn forward_local(
        &self,
        local: SocketAddr,
        remote: SocketAddr,
    ) -> anyhow::Result<SocketAddr> {
        let listener = TcpListener::bind(local).await?;
        let bound = listener.local_addr()?;
        let shared = self.shared.clone();
        self.spawn(async move {
            // The forward owns its connections: stopping the node ends them.
            let mut connections = JoinSet::new();
            while let Ok((mut tcp, _)) = listener.accept().await {
                while connections.try_join_next().is_some() {}
                let Some(mesh) = shared.mesh() else { continue };
                connections.spawn(async move {
                    if let Ok(mut stream) = mesh.connect(remote).await {
                        let _ = tokio::io::copy_bidirectional(&mut tcp, &mut stream).await;
                    }
                });
            }
        });
        Ok(bound)
    }

    /// Wait until `target` answers an echo, or `limit` passes.
    pub async fn wait_reachable(
        &self,
        target: SocketAddr,
        limit: Duration,
    ) -> anyhow::Result<Duration> {
        let started = Instant::now();
        while started.elapsed() < limit {
            if tokio::time::timeout(Duration::from_secs(3), echo_rounds(self, target, 1, 16))
                .await
                .is_ok_and(|r| r.is_ok())
            {
                return Ok(started.elapsed());
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        bail!("{target} not reachable within {limit:?}")
    }

    /// Measure echo round trips to `target`: one connection, `count` rounds
    /// of `size` bytes. Returns the connect time and each round's time.
    pub async fn bench(
        &self,
        target: SocketAddr,
        count: usize,
        size: usize,
    ) -> anyhow::Result<(Duration, Vec<Duration>)> {
        let started = Instant::now();
        let mut stream = self.connect(target).await?;
        let connect = started.elapsed();
        let payload: Vec<u8> = (0..size).map(|index| (index % 251) as u8).collect();
        let mut buffer = vec![0u8; size];
        let mut rounds = Vec::with_capacity(count);
        for _ in 0..count {
            let round = Instant::now();
            stream.write_all(&payload).await?;
            stream.read_exact(&mut buffer).await?;
            if buffer != payload {
                bail!("echo returned different bytes");
            }
            rounds.push(round.elapsed());
        }
        Ok((connect, rounds))
    }

    /// Replace the WireGuard key: report it (signed by the machine key),
    /// save it, and restart the mesh under it. The address stays.
    pub async fn rotate(&self) -> anyhow::Result<()> {
        let shared = &self.shared;
        let _guard = shared.apply.lock().await;
        let next = NodeKey::generate();
        let body = serde_json::to_vec(&RotateRequest {
            node_key: crate::b64::encode_key(&next.public()),
        })?;
        check(shared.signed(Method::POST, "/v1/rotate", body).await?).await?;
        let mut state =
            StateFile::load(&shared.state_path).await?.context("state file vanished")?;
        state.node_private = crate::b64::encode_key(next.private());
        state.save(&shared.state_path).await?;
        write(&shared.node_key, next);
        // Relay registrations carry the old key: drop them until the next
        // netmap brings a ticket for the new one.
        shared.pool.set_ticket(None);
        shared.pool.reset();
        if let Some(home) = read(&shared.home_relay).clone() {
            shared.pool.ensure(&home);
        }
        shared.rebuild_mesh_locked().await?;
        let netmap = read(&shared.netmap).clone();
        shared.apply_netmap_locked(netmap);
        Ok(())
    }

    pub async fn shutdown(&self) {
        if let Ok(mut tasks) = self.tasks.lock() {
            for task in tasks.drain(..) {
                task.abort();
            }
        }
        self.shared.stop();
    }
}

impl Drop for WeftNode {
    fn drop(&mut self) {
        if let Ok(mut tasks) = self.tasks.lock() {
            for task in tasks.drain(..) {
                task.abort();
            }
        }
        self.shared.stop();
    }
}

fn read<T>(lock: &RwLock<T>) -> std::sync::RwLockReadGuard<'_, T> {
    lock.read().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn write<T>(lock: &RwLock<T>, value: T) {
    *lock.write().unwrap_or_else(std::sync::PoisonError::into_inner) = value;
}

fn empty_netmap(state: &StateFile) -> Netmap {
    Netmap {
        version: 0,
        node: crate::types::SelfView {
            id: state.node_id.clone(),
            name: state.name.clone(),
            address: state.address,
            node_key: String::new(),
            tags: Vec::new(),
            state: NodeState::Pending,
            key_expires_ms: 0,
        },
        peers: Vec::new(),
        inbound: Vec::new(),
        relays: Vec::new(),
        relay_ticket: None,
    }
}

async fn register(
    http: &reqwest::Client,
    state_path: &Path,
    options: JoinOptions,
) -> anyhow::Result<StateFile> {
    let machine = SigningKey::generate();
    let node_key = NodeKey::generate();
    let coord = options.coord.trim_end_matches('/').to_owned();
    let body = serde_json::to_vec(&RegisterRequest {
        tailnet: options.tailnet.clone(),
        auth_key: options.auth_key,
        name: options.name.clone(),
        machine_key: crate::b64::encode_key(&machine.public()),
        node_key: crate::b64::encode_key(&node_key.public()),
    })?;
    let signed = sign_request(&machine, "register", "POST", "/v1/register", &body, crate::now_ms());
    let response = http
        .post(format!("{coord}/v1/register"))
        .header("content-type", "application/json")
        .header(HEADER_NODE, signed.node)
        .header(HEADER_TS, signed.ts)
        .header(HEADER_NONCE, signed.nonce)
        .header(HEADER_SIG, signed.sig)
        .body(body)
        .send()
        .await
        .context("register")?;
    let registered: RegisterResponse = check(response).await.context("register")?.json().await?;
    let state = StateFile {
        coord,
        tailnet: options.tailnet,
        node_id: registered.node_id,
        name: options.name,
        address: registered.address,
        machine_seed: crate::b64::encode_key(machine.seed()),
        node_private: crate::b64::encode_key(node_key.private()),
    };
    state.save(state_path).await?;
    Ok(state)
}

/// The relay with the lowest health-check round trip (best of three).
async fn pick_home_relay(http: &reqwest::Client, netmap: &Netmap) -> Option<String> {
    let mut best: Option<(Duration, String)> = None;
    for relay in &netmap.relays {
        let health = relay
            .url
            .replacen("wss://", "https://", 1)
            .replacen("ws://", "http://", 1)
            .replace("/v1/relay", "/healthz");
        let mut fastest = None;
        for _ in 0..3 {
            let started = Instant::now();
            let ok = tokio::time::timeout(Duration::from_secs(3), http.get(&health).send())
                .await
                .is_ok_and(|response| {
                    response.is_ok_and(|response| response.status().is_success())
                });
            if ok {
                let elapsed = started.elapsed();
                fastest = Some(fastest.map_or(elapsed, |current: Duration| current.min(elapsed)));
            }
        }
        if let Some(rtt) = fastest
            && best.as_ref().is_none_or(|(current, _)| rtt < *current)
        {
            best = Some((rtt, relay.url.clone()));
        }
    }
    best.map(|(_, url)| url)
}

impl Shared {
    fn mesh(&self) -> Option<Arc<WgMesh>> {
        read(&self.mesh).clone()
    }

    async fn signed(
        &self,
        method: Method,
        path: &str,
        body: Vec<u8>,
    ) -> anyhow::Result<reqwest::Response> {
        let headers = sign_request(
            &self.machine,
            &self.node_id,
            method.as_str(),
            path,
            &body,
            crate::now_ms(),
        );
        let mut request = self
            .http
            .request(method, format!("{}{path}", self.coord))
            .header(HEADER_NODE, headers.node)
            .header(HEADER_TS, headers.ts)
            .header(HEADER_NONCE, headers.nonce)
            .header(HEADER_SIG, headers.sig);
        if !body.is_empty() {
            request = request.header("content-type", "application/json").body(body);
        }
        Ok(request.send().await?)
    }

    async fn fetch_netmap(&self, since: Option<u64>) -> anyhow::Result<Netmap> {
        let path = match since {
            Some(version) => format!("/v1/netmap?since={version}"),
            None => "/v1/netmap".to_owned(),
        };
        let response = self.signed(Method::GET, &path, Vec::new()).await?;
        Ok(check(response).await?.json().await?)
    }

    async fn post_endpoints(&self, home_relay: Option<String>) -> anyhow::Result<()> {
        let body = serde_json::to_vec(&EndpointsRequest { home_relay })?;
        check(self.signed(Method::POST, "/v1/endpoints", body).await?).await?;
        Ok(())
    }

    async fn rebuild_mesh(self: &Arc<Self>) -> anyhow::Result<()> {
        let _guard = self.apply.lock().await;
        self.rebuild_mesh_locked().await
    }

    /// Start a fresh mesh under the current key, drop every peer link, and
    /// re-open the served ports on it. The caller holds `apply`.
    async fn rebuild_mesh_locked(self: &Arc<Self>) -> anyhow::Result<()> {
        if let Ok(mut peers) = self.peers.lock() {
            for (_, link) in peers.drain() {
                link.task.abort();
            }
        }
        let socket = UdpSocket::bind("127.0.0.1:0").await?;
        let config = WgMeshConfig {
            private_key: Zeroizing::new(*read(&self.node_key).private()),
            addresses: vec![InterfaceAddress { address: IpAddr::V6(self.address), prefix: 128 }],
            mtu: MESH_MTU,
        };
        let mesh = Arc::new(WgMesh::start(config, socket)?);
        write(&self.mesh, Some(mesh.clone()));
        let services: Vec<(u16, Service)> = match self.services.lock() {
            Ok(services) => {
                services.iter().map(|(port, (service, _))| (*port, service.clone())).collect()
            }
            Err(_) => Vec::new(),
        };
        for (port, service) in services {
            let task = spawn_listener(self, &mesh, port, service.clone()).await?;
            if let Ok(mut services) = self.services.lock()
                && let Some((_, Some(old))) = services.insert(port, (service, Some(task)))
            {
                old.abort();
            }
        }
        Ok(())
    }

    async fn apply_netmap(self: &Arc<Self>, netmap: Netmap) {
        let _guard = self.apply.lock().await;
        self.apply_netmap_locked(netmap);
    }

    /// Make the mesh match `netmap`: peers added, removed and re-keyed,
    /// home relays and the inbound filter updated. The caller holds `apply`.
    fn apply_netmap_locked(self: &Arc<Self>, netmap: Netmap) {
        let filter: HashMap<[u8; 32], Vec<PortRange>> = netmap
            .inbound
            .iter()
            .filter_map(|allow| {
                crate::b64::decode_key(&allow.node_key).map(|key| (key, allow.ports.clone()))
            })
            .collect();
        write(&self.filter, filter);
        self.pool.set_ticket(netmap.relay_ticket.clone());

        let wanted: HashMap<[u8; 32], PeerView> = netmap
            .peers
            .iter()
            .filter_map(|peer| {
                crate::b64::decode_key(&peer.node_key).map(|key| (key, peer.clone()))
            })
            .collect();
        let Some(mesh) = self.mesh() else {
            write(&self.netmap, netmap);
            return;
        };
        let Ok(mut peers) = self.peers.lock() else { return };
        let gone: Vec<[u8; 32]> = peers
            .iter()
            .filter(|(key, link)| {
                wanted.get(*key).is_none_or(|peer| peer.address != link.view.address)
            })
            .map(|(key, _)| *key)
            .collect();
        // Removals finish before any addition starts: a re-keyed peer keeps
        // its address, and two peers may never hold the same allowed IPs.
        let mut removed = Vec::new();
        for key in gone {
            if let Some(link) = peers.remove(&key) {
                link.task.abort();
                removed.push(key);
            }
        }
        let (removals_done, removals) = tokio::sync::watch::channel(removed.is_empty());
        if !removed.is_empty() {
            let mesh = mesh.clone();
            // supervise-allow: bounded (one remove_peer per gone key); its end, a panic included, drops `removals_done`, which wakes every link_peer waiter.
            tokio::spawn(async move {
                for key in removed {
                    let _ = mesh.remove_peer(key).await;
                }
                let _ = removals_done.send(true);
            });
        }
        for (key, view) in wanted {
            if let Some(link) = peers.get_mut(&key) {
                write(&link.home_relay, view.home_relay.clone());
                link.view = view;
                continue;
            }
            match self.link_peer(&mesh, key, view, removals.clone()) {
                Ok(link) => {
                    peers.insert(key, link);
                }
                Err(error) => eprintln!("weft: cannot add peer: {error:#}"),
            }
        }
        drop(peers);
        write(&self.netmap, netmap);
    }

    /// A loopback stand-in socket for one peer, and the mesh peer routed to it.
    fn link_peer(
        self: &Arc<Self>,
        mesh: &Arc<WgMesh>,
        key: [u8; 32],
        view: PeerView,
        mut removals: tokio::sync::watch::Receiver<bool>,
    ) -> anyhow::Result<PeerLink> {
        let std_socket = std::net::UdpSocket::bind("127.0.0.1:0")?;
        std_socket.set_nonblocking(true)?;
        let socket = Arc::new(UdpSocket::from_std(std_socket)?);
        let shim = socket.local_addr()?;
        let home_relay = Arc::new(RwLock::new(view.home_relay.clone()));
        let peer = WgPeer {
            public_key: key,
            preshared_key: None,
            allowed_ips: vec![
                IpNetwork::new(IpAddr::V6(view.address), 128)
                    .map_err(|error| anyhow::anyhow!("peer address: {error:?}"))?,
            ],
            route: Some(shim.into()),
            persistent_keepalive: Some(KEEPALIVE_SECONDS),
        };
        let mesh_for_add = mesh.clone();
        let pool = self.pool.clone();
        let relay = home_relay.clone();
        let reader = socket.clone();
        let task = tokio::spawn(async move {
            let _ = removals.wait_for(|done| *done).await;
            if let Err(error) = mesh_for_add.add_peer(peer).await {
                eprintln!("weft: add peer: {error}");
                return;
            }
            let mut buffer = vec![0u8; 65536];
            // Datagrams the mesh sends to this peer go out over its relay.
            while let Ok((count, _)) = reader.recv_from(&mut buffer).await {
                let url = read(&relay).clone();
                if let Some(url) = url {
                    pool.send(&url, &key, &buffer[..count]);
                }
            }
        });
        Ok(PeerLink { view, socket, home_relay, task })
    }

    fn stop(&self) {
        if let Ok(mut peers) = self.peers.lock() {
            for (_, link) in peers.drain() {
                link.task.abort();
            }
        }
        if let Ok(mut services) = self.services.lock() {
            for (_, (_, task)) in services.drain() {
                if let Some(task) = task {
                    task.abort();
                }
            }
        }
        self.pool.reset();
        write(&self.mesh, None);
    }
}

/// Datagrams from relays into the mesh, through the sender's stand-in socket.
async fn deliver_inbound(shared: Arc<Shared>, mut inbound: mpsc::Receiver<relay_pool::Inbound>) {
    while let Some((sender, datagram)) = inbound.recv().await {
        let Some(mesh) = shared.mesh() else { continue };
        let Ok(mesh_address) = mesh.local_addr() else { continue };
        let socket = match shared.peers.lock() {
            Ok(peers) => peers.get(&sender).map(|link| link.socket.clone()),
            Err(_) => None,
        };
        // A sender that is not in the netmap gets nothing delivered: the
        // mesh would refuse it anyway, but this keeps it off the socket.
        if let Some(socket) = socket {
            let _ = socket.send_to(&datagram, mesh_address).await;
        }
    }
}

async fn follow_netmap(shared: Arc<Shared>) {
    let mut failures = 0u32;
    loop {
        let since = read(&shared.netmap).version;
        match shared.fetch_netmap(Some(since)).await {
            Ok(netmap) => {
                failures = 0;
                let relays_changed = read(&shared.netmap).relays != netmap.relays;
                shared.apply_netmap(netmap.clone()).await;
                if relays_changed && let Some(home) = pick_home_relay(&shared.http, &netmap).await {
                    shared.pool.ensure(&home);
                    write(&shared.home_relay, Some(home.clone()));
                    let _ = shared.post_endpoints(Some(home)).await;
                }
            }
            Err(error) => {
                let text = format!("{error:#}");
                if text.contains("401") && text.contains("unknown node") {
                    eprintln!("weft: this device was removed from the tailnet");
                    shared.revoked.store(true, std::sync::atomic::Ordering::Relaxed);
                    let mut empty = read(&shared.netmap).clone();
                    empty.peers.clear();
                    empty.inbound.clear();
                    empty.relay_ticket = None;
                    shared.apply_netmap(empty).await;
                    return;
                }
                failures += 1;
                // Bounded, cancellable backoff between failed polls.
                let delay = Duration::from_millis(250 * u64::from(failures.min(20)));
                tokio::time::sleep(delay).await;
            }
        }
    }
}

async fn spawn_listener(
    shared: &Arc<Shared>,
    mesh: &Arc<WgMesh>,
    port: u16,
    service: Service,
) -> anyhow::Result<JoinHandle<()>> {
    let mut listener = mesh.listen(port).await?;
    let shared = Arc::downgrade(shared);
    Ok(tokio::spawn(async move {
        // The listener owns its connections: replacing or stopping the
        // service ends them with it.
        let mut connections = JoinSet::new();
        while let Some((stream, key)) = listener.accept().await {
            while connections.try_join_next().is_some() {}
            let Some(strong) = shared.upgrade() else { return };
            let allowed = read(&strong.filter)
                .get(&key)
                .is_some_and(|ports| PortRange::any_contains(ports, port));
            drop(strong);
            if !allowed {
                // Refused at the receiver: close without reading a byte.
                drop(stream);
                continue;
            }
            let service = service.clone();
            connections.spawn(async move {
                match service {
                    Service::Echo => echo(stream).await,
                    Service::Forward(target) => {
                        if let Ok(mut tcp) = TcpStream::connect(target).await {
                            let mut stream = stream;
                            let _ = tokio::io::copy_bidirectional(&mut stream, &mut tcp).await;
                        }
                    }
                }
            });
        }
    }))
}

async fn echo(mut stream: WgStream) {
    let mut buffer = vec![0u8; 16 * 1024];
    loop {
        match stream.read(&mut buffer).await {
            Ok(0) | Err(_) => break,
            Ok(count) => {
                if stream.write_all(&buffer[..count]).await.is_err() {
                    break;
                }
            }
        }
    }
    let _ = stream.shutdown().await;
}

async fn echo_rounds(
    node: &WeftNode,
    target: SocketAddr,
    count: usize,
    size: usize,
) -> anyhow::Result<()> {
    node.bench(target, count, size).await.map(|_| ())
}
