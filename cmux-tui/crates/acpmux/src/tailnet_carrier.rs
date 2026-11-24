//! The tailnet path of acpmux peer links (`peer_tailnet.rs`), for a person who runs Tailscale
//! and turns it on. RFD 0164 "Tailnet carrier", slice T6. Opt-in, default off.
//!
//! - **Setting.** `CMUX_TAILNET_CARRIER` = `off` (default; also unset or unknown) |
//!   `direct-only` | `on`: the daemon-side form of the setting `transport.tailnetCarrier`.
//!   `off` makes no tailscale call at all, in either direction.
//! - **Learning the address.** Locally and read-only: the peer record's host (the ssh
//!   destination's host or the URL's host) is matched against this machine's tailscaled status
//!   (an address, the MagicDNS name, its short name or the OS host name; one node only, online,
//!   never this machine). The status is read from tailscaled's LocalAPI
//!   (`cmux_tailnet_local::TailnetLocal`, about 2 ms, no process) and from `tailscale status
//!   --json` only when the LocalAPI is unavailable ([`PathSource`]). Nothing is advertised on
//!   the wire, so old and new daemons need no negotiation: see "Lockstep" below.
//! - **Which hint is offered.** The status says how this machine reaches the node: `CurAddr`
//!   set is direct, a peer relay or a DERP region is not. Only a direct path is offered, under
//!   `direct-only` and `on` alike: a DERP or peer-relay path loses to the paths cmux owns, so it
//!   is never raced (the setting `transport.tailnetCarrier` says so too).
//! - **No wait on tailscaled.** The status is a snapshot read from memory: the LocalAPI's
//!   refreshes itself on its own thread; the CLI fallback ([`Snapshots`]) makes one background
//!   call at most every [`FRESH`], a failed one every [`FAILED_FRESH`].
//! - **Receiving side.** With the setting on, the daemon also listens on its own tailnet
//!   address at the port of its loopback listener ([`serve_peers`]). A connection is admitted
//!   only when `whois` of its source names a node of the same person (the pattern of
//!   `server/tailnet_ingress.rs::owner_allowed`: same owner, not tagged, not shared), and then
//!   still presents acpmux's token and peer token as on every path. That whois is the proof the
//!   `ssh -W` tunnel's loopback source is for the peer token (`server/peer_auth.rs`).
//! - **Lockstep.** No message changes: the new client dials `tailnet-address:port` of the port
//!   it already knows, and an old server has nothing listening there (refused at once, the race
//!   moves on); an old client never dials it, and a new server's extra listener is just an extra
//!   admission-gated socket. Both directions are tested (`tailnet_carrier_tests.rs`).
//!
//! The decisions are pure ([`route_for`], [`admits_identity`]); the clocks and the CLI are
//! passed in, so the rules are tested without tailscale.

use crate::tailnet::{Identity, Node, PeerPath, Status, Tailnet, is_tailnet_ip};
use cmux_tailnet_local::{TailnetLocal, TailnetView};
use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::Notify;

/// The setting, as the daemon reads it.
pub const ENV: &str = "CMUX_TAILNET_CARRIER";
/// A status younger than this is read as it is.
pub const FRESH: Duration = Duration::from_secs(5);
/// A failed read (no tailscale, not running) is not tried again for this long.
pub const FAILED_FRESH: Duration = Duration::from_secs(30);
/// How long a whois verdict of an admitted source is kept; a refused one is kept [`REFUSED_FOR`].
const ADMITTED_FOR: Duration = Duration::from_secs(60);
const REFUSED_FOR: Duration = Duration::from_secs(10);
/// The most whois verdicts kept.
const MAX_VERDICTS: usize = 256;
/// How long the receiving side waits for tailscale to answer a first status or whois.
const GATE_WAIT: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Mode {
    /// No tailscale call, no tailnet path, no tailnet listener.
    #[default]
    Off,
    /// Only a path tailscale reports as direct.
    DirectOnly,
    /// Reserved for relayed tailnet paths once their cost is measured; today the same as
    /// `direct-only`.
    On,
}

impl Mode {
    pub fn parse(text: &str) -> Option<Self> {
        match text.trim().to_ascii_lowercase().as_str() {
            "off" | "false" | "0" | "" => Some(Self::Off),
            "direct-only" | "direct_only" | "directonly" => Some(Self::DirectOnly),
            "on" | "true" | "1" => Some(Self::On),
            _ => None,
        }
    }

    /// The setting from the environment; off when unset or not understood.
    pub fn from_env() -> Self {
        std::env::var(ENV).ok().and_then(|text| Self::parse(&text)).unwrap_or_default()
    }

    /// Whether a path tailscale reports as `path` is offered as a candidate: only a direct one.
    pub fn offers(self, path: PeerPath) -> bool {
        match self {
            Self::Off => false,
            Self::DirectOnly | Self::On => path == PeerPath::Direct,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::DirectOnly => "direct-only",
            Self::On => "on",
        }
    }
}

/// Where the peer is on this machine's tailnet and how the path to it runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Route {
    pub ip: IpAddr,
    pub path: PeerPath,
}

impl Route {
    /// Not a direct WireGuard path: the relayed class (never offered today, see [`Mode::offers`]).
    pub fn relayed(&self) -> bool {
        self.path != PeerPath::Direct
    }
}

fn names(node: &Node, host: &str) -> bool {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return node.ips.contains(&ip);
    }
    [node.dns_name.as_str(), node.host_name.as_str(), node.short_name().as_str()]
        .iter()
        .any(|name| !name.is_empty() && name.eq_ignore_ascii_case(host))
}

/// The tailnet route to the peer whose configured host is `host`, under `mode`: tailscale
/// `Running`, this machine and the node both on this tailnet (the status lists the node), the
/// node named by `host` once, online, with a tailnet address of a family this machine has, and
/// a path `mode` offers. None otherwise (never a guess).
pub fn route_for(status: &Status, host: &str, mode: Mode) -> Option<Route> {
    if mode == Mode::Off || status.backend_state != "Running" {
        return None;
    }
    let host = host.trim().trim_start_matches('[').trim_end_matches(']').trim_end_matches('.');
    if host.is_empty() {
        return None;
    }
    let mut named = status.peers.iter().filter(|node| names(node, host));
    let node = named.next()?;
    if named.next().is_some() || !node.online {
        return None;
    }
    let ip = node.dial_ip().filter(|ip| is_tailnet_ip(*ip))?;
    status
        .this
        .ips
        .iter()
        .any(|mine| mine.is_ipv4() == ip.is_ipv4() && is_tailnet_ip(*mine))
        .then_some(())?;
    mode.offers(node.path).then_some(Route { ip, path: node.path })
}

/// Whether `who` (whois of a connection's source) is a node of the same person as this
/// machine, which tailscale is `Running` for: the owner's login matches, neither node is tagged,
/// and the source was not shared in from another tailnet (a login that is not proof of who runs
/// it).
pub fn admits_identity(me: &Status, who: &Identity) -> bool {
    let Some(owner) = me.this.login.as_deref() else { return false };
    me.backend_state == "Running"
        && !me.this.tagged()
        && who.tags.is_empty()
        && !who.shared
        && who.login.as_deref().is_some_and(|login| login.eq_ignore_ascii_case(owner))
}

// ------------------------------------------------------------------ snapshot

type Loader = dyn Fn() -> anyhow::Result<Status> + Send + Sync;

struct Slot {
    at: Option<Instant>,
    status: Option<Arc<Status>>,
}

/// A cached `tailscale status`, refreshed in the background so a caller reads memory.
pub struct Snapshots {
    slot: StdMutex<Slot>,
    loading: AtomicBool,
    done: Notify,
    load: Arc<Loader>,
}

impl Snapshots {
    pub fn new(load: Arc<Loader>) -> Arc<Self> {
        Arc::new(Self {
            slot: StdMutex::new(Slot { at: None, status: None }),
            loading: AtomicBool::new(false),
            done: Notify::new(),
            load,
        })
    }

    /// The installed `tailscale` CLI's status: the process-wide one.
    pub fn global() -> Arc<Self> {
        static GLOBAL: OnceLock<Arc<Snapshots>> = OnceLock::new();
        GLOBAL.get_or_init(|| Self::new(Arc::new(load_cli))).clone()
    }

    fn read(&self, now: Instant) -> (Option<Arc<Status>>, bool) {
        let slot = self.slot.lock().unwrap_or_else(|e| e.into_inner());
        let Some(at) = slot.at else { return (None, false) };
        let age = now.saturating_duration_since(at);
        let fresh = age < if slot.status.is_some() { FRESH } else { FAILED_FRESH };
        (slot.status.clone(), fresh)
    }

    /// Whether a status was ever read (or failed to be).
    pub fn loaded(&self) -> bool {
        self.slot.lock().unwrap_or_else(|e| e.into_inner()).at.is_some()
    }

    fn kick(self: &Arc<Self>) {
        if self.loading.swap(true, Ordering::SeqCst) {
            return;
        }
        let snaps = self.clone();
        // A detached blocking task: a caller that stopped waiting does not lose the read.
        tokio::task::spawn_blocking(move || {
            let loaded = (snaps.load)();
            if let Err(error) = &loaded {
                tracing::debug!("tailnet carrier: no tailscale status: {error:#}");
            }
            {
                let mut slot = snaps.slot.lock().unwrap_or_else(|e| e.into_inner());
                slot.at = Some(Instant::now());
                slot.status = loaded.ok().map(Arc::new);
            }
            snaps.loading.store(false, Ordering::SeqCst);
            snaps.done.notify_waiters();
        });
    }

    /// The status now: memory when fresh; else a refresh is started and awaited up to `wait`
    /// (zero: never awaited), and the last one read, if any, answers when it did not finish.
    pub async fn get(self: &Arc<Self>, wait: Duration) -> Option<Arc<Status>> {
        let (status, fresh) = self.read(Instant::now());
        if fresh {
            return status;
        }
        let mut done = std::pin::pin!(self.done.notified());
        done.as_mut().enable();
        self.kick();
        if !wait.is_zero() {
            let _ = tokio::time::timeout(wait, done).await;
        }
        self.read(Instant::now()).0
    }
}

fn load_cli() -> anyhow::Result<Status> {
    static CLI: OnceLock<Tailnet> = OnceLock::new();
    if let Some(cli) = CLI.get() {
        return cli.status();
    }
    let cli = Tailnet::locate()?;
    let status = cli.status();
    let _ = CLI.set(cli);
    status
}

// ------------------------------------------------------------- LocalAPI first

/// What tailscaled's LocalAPI snapshot holds right now.
#[derive(Debug, Clone)]
pub enum LocalRead {
    /// A view, as the CLI's status shape.
    View(Status),
    /// The first read is still on its way.
    Pending,
    /// No LocalAPI answered (not installed, not running, refused): use the CLI.
    Unavailable,
}

/// Reads the LocalAPI snapshot without waiting.
pub type LocalReader = dyn Fn() -> LocalRead + Send + Sync;

/// How often a cold first read is looked at while it is awaited.
const LOCAL_POLL: Duration = Duration::from_millis(10);

/// Where the peer path reads tailscale: the LocalAPI snapshot first, the CLI's [`Snapshots`]
/// only when the LocalAPI is unavailable. The receiving side's [`Gate`] keeps the CLI's status:
/// it needs the owner's login, which the LocalAPI view does not carry.
pub struct PathSource {
    local: Arc<LocalReader>,
    cli: Arc<Snapshots>,
}

impl PathSource {
    pub fn new(local: Arc<LocalReader>, cli: Arc<Snapshots>) -> Arc<Self> {
        Arc::new(Self { local, cli })
    }

    /// The system tailscaled: `TailnetLocal::global()`, else the installed CLI.
    pub fn global() -> Arc<Self> {
        static GLOBAL: OnceLock<Arc<PathSource>> = OnceLock::new();
        GLOBAL.get_or_init(|| Self::new(Arc::new(read_local), Snapshots::global())).clone()
    }

    /// The CLI's status only (no LocalAPI).
    pub fn cli_only(cli: Arc<Snapshots>) -> Arc<Self> {
        Self::new(Arc::new(|| LocalRead::Unavailable), cli)
    }

    /// Whether a status (or a failure) was read, so a cold connect need not wait.
    pub fn loaded(&self) -> bool {
        match (self.local)() {
            LocalRead::View(_) => true,
            LocalRead::Pending => false,
            LocalRead::Unavailable => self.cli.loaded(),
        }
    }

    /// The status now, awaiting a first read up to `wait` (zero: never awaited).
    pub async fn get(&self, wait: Duration) -> Option<Arc<Status>> {
        let start = Instant::now();
        loop {
            let left = wait.saturating_sub(start.elapsed());
            match (self.local)() {
                LocalRead::View(status) => return Some(Arc::new(status)),
                LocalRead::Unavailable => return self.cli.get(left).await,
                LocalRead::Pending if left.is_zero() => return None,
                LocalRead::Pending => tokio::time::sleep(left.min(LOCAL_POLL)).await,
            }
        }
    }
}

fn read_local() -> LocalRead {
    let local = TailnetLocal::global();
    match local.snapshot() {
        Some(view) => LocalRead::View(status_from_view(&view)),
        None if local.last_error().is_some() => LocalRead::Unavailable,
        None => LocalRead::Pending,
    }
}

fn path_from_local(path: &cmux_tailnet_local::PeerPath) -> PeerPath {
    use cmux_tailnet_local::PeerPath as Local;
    match path {
        Local::Direct { .. } => PeerPath::Direct,
        Local::PeerRelay { .. } => PeerPath::PeerRelay,
        Local::Derp { .. } => PeerPath::Derp,
        // No path chosen yet, offline or unclassified: never offered.
        Local::Idle { .. } | Local::Offline | Local::Unknown => PeerPath::Unknown,
    }
}

/// A LocalAPI view in the CLI status shape [`route_for`] reads. Logins are not in the view
/// (`login` stays None): this status is for routes, never for [`admits_identity`].
pub fn status_from_view(view: &TailnetView) -> Status {
    let this = Node {
        path: PeerPath::Unknown,
        host_name: view.this.host_name.clone(),
        dns_name: view.this.dns_name.clone(),
        os: String::new(),
        login: None,
        tags: view.this.tags.clone(),
        ips: view.this.ips.clone(),
        online: true,
        shared: false,
    };
    let peers = view
        .peers
        .iter()
        .map(|peer| Node {
            path: path_from_local(&peer.path),
            host_name: peer.host_name.clone(),
            dns_name: peer.dns_name.clone(),
            os: peer.os.clone(),
            login: None,
            tags: peer.tags.clone(),
            ips: peer.ips.clone(),
            online: peer.online,
            shared: peer.sharee_node,
        })
        .collect();
    Status { backend_state: view.backend_state.clone(), this, peers }
}

// ----------------------------------------------------------- receiving side

type Whois = dyn Fn(IpAddr) -> anyhow::Result<Identity> + Send + Sync;

/// Admission of a tailnet connection by its source address (see the module doc).
pub struct Gate {
    snaps: Arc<Snapshots>,
    whois: Arc<Whois>,
    verdicts: StdMutex<HashMap<IpAddr, (Instant, bool)>>,
}

impl Gate {
    pub fn new(snaps: Arc<Snapshots>, whois: Arc<Whois>) -> Arc<Self> {
        Arc::new(Self { snaps, whois, verdicts: StdMutex::new(HashMap::new()) })
    }

    /// The installed CLI's gate.
    pub fn cli() -> Arc<Self> {
        Self::new(
            Snapshots::global(),
            Arc::new(|ip| {
                static CLI: OnceLock<Tailnet> = OnceLock::new();
                if CLI.get().is_none() {
                    let _ = CLI.set(Tailnet::locate()?);
                }
                CLI.get().ok_or_else(|| anyhow::anyhow!("no tailscale CLI"))?.whois(ip)
            }),
        )
    }

    fn remembered(&self, ip: IpAddr) -> Option<bool> {
        let verdicts = self.verdicts.lock().unwrap_or_else(|e| e.into_inner());
        let (at, admitted) = *verdicts.get(&ip)?;
        let keep = if admitted { ADMITTED_FOR } else { REFUSED_FOR };
        (at.elapsed() < keep).then_some(admitted)
    }

    fn remember(&self, ip: IpAddr, admitted: bool) {
        let mut verdicts = self.verdicts.lock().unwrap_or_else(|e| e.into_inner());
        if verdicts.len() >= MAX_VERDICTS {
            verdicts.retain(|_, (at, _)| at.elapsed() < ADMITTED_FOR);
        }
        if verdicts.len() < MAX_VERDICTS {
            verdicts.insert(ip, (Instant::now(), admitted));
        }
    }

    /// Whether a connection from `remote` is a node of this person's tailnet.
    pub async fn admits(self: &Arc<Self>, remote: SocketAddr) -> bool {
        let ip = remote.ip().to_canonical();
        if !is_tailnet_ip(ip) {
            return false;
        }
        if let Some(verdict) = self.remembered(ip) {
            return verdict;
        }
        let Some(me) = self.snaps.get(GATE_WAIT).await else { return false };
        let whois = self.whois.clone();
        let asked =
            tokio::time::timeout(GATE_WAIT, tokio::task::spawn_blocking(move || whois(ip))).await;
        let admitted = match asked {
            Ok(Ok(Ok(who))) => admits_identity(&me, &who),
            _ => return false,
        };
        self.remember(ip, admitted);
        admitted
    }
}

/// Listen on this machine's own tailnet address at `port` (the port of the loopback listener,
/// which is the port peers know), behind `gate`, until the daemon shuts down. Does nothing under
/// [`Mode::Off`]. Waits for tailscale to be running with an address, and for the port to be
/// free; neither stops the daemon.
pub async fn serve_peers(
    hub: Arc<crate::hub::Hub>,
    port: u16,
    token: String,
    auth: crate::server::WsAuth,
    shutdown: crate::server::WsShutdown,
    mode: Mode,
    gate: Arc<Gate>,
) {
    if mode == Mode::Off {
        return;
    }
    loop {
        let bound = bind_tailnet(&gate.snaps, port).await;
        match bound {
            Ok(listener) => {
                tracing::info!(
                    "acpmux listens on its tailnet address {:?} for this person's own machines (whois-admitted)",
                    listener.local_addr().ok()
                );
                if let Err(error) = crate::server::serve_ws_gated(
                    hub.clone(),
                    listener,
                    token.clone(),
                    auth.clone(),
                    shutdown.clone(),
                    Some(gate.clone()),
                )
                .await
                {
                    tracing::warn!("tailnet listener ended: {error:#}");
                }
                return;
            }
            Err(error) => {
                tracing::debug!("tailnet listener not up: {error:#}");
                tokio::time::sleep(FAILED_FRESH).await;
            }
        }
    }
}

async fn bind_tailnet(
    snaps: &Arc<Snapshots>,
    port: u16,
) -> anyhow::Result<tokio::net::TcpListener> {
    let status = snaps
        .get(Duration::from_secs(10))
        .await
        .ok_or_else(|| anyhow::anyhow!("tailscale did not answer"))?;
    anyhow::ensure!(status.backend_state == "Running", "tailscale is not running");
    let ip = status
        .this
        .dial_ip()
        .filter(|ip| is_tailnet_ip(*ip))
        .ok_or_else(|| anyhow::anyhow!("no tailnet address"))?;
    Ok(tokio::net::TcpListener::bind(SocketAddr::new(ip, port)).await?)
}

#[cfg(test)]
#[path = "tailnet_carrier_tests.rs"]
mod tests;
