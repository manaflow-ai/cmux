//! The paths of one peer link (`peer_paths.rs` has the rules): which paths a peer has, how
//! each is dialed, the cold connect that tries them, and the probe that keeps every path that
//! does not carry the session open and measured.
//!
//! - Direct: acpmux's own Labs WireGuard transport while it holds this machine's key lock
//!   (`cmux_link::key_holder`), else the cmux link's `acpmux` service when this peer is a paired
//!   install. Never both: one process runs the machine's WireGuard key.
//! - ssh: `ssh -W` to the configured `ssh://` URL. Always kept: it reaches a machine when the
//!   platform is down and the network allows nothing else.
//! - The configured `ws://`/`wss://` URL of a peer that is not ssh.
//! - The hub relay (`peer_hub.rs`), with the `hub-carrier` feature: the daemon's hub carrier,
//!   for a peer with a hub `daemonId`. Without the feature it carries no stream (`Via::streams`).
//!   With it the peer is relay first (`peer_paths.rs`): the cold connect dials the relay and
//!   the remembered path at once, and the link moves to a direct path after its probes.

use super::carrier::{DialError, connect_fail, fail_of_chain};
use super::{
    DIAL_TIMED_OUT, EARLY_TUNNEL_FOR, Peer, RESTART_AFTER, connect_timed_out, ssh_errors, tokens,
};
use crate::no_panic::LockExt;
use crate::peer_link::{Heard, HeardStream};
use crate::peer_paths::{PROBE_EVERY, Paths, Via};
use futures_util::stream::FuturesUnordered;
use futures_util::{SinkExt, StreamExt};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio_tungstenite::tungstenite::Message as Frame;

/// A cold connect dials the first path now and each next one this long after the one before
/// (at once when the one before failed): a dead path never holds up a live one by more.
pub(super) const STAGGER: Duration = Duration::from_millis(250);
/// The longest a probe's dial may take (a dead path's connect is cut off well before the
/// link's own connect deadline; it is probed again on its recovery backoff).
const PROBE_CONNECT: Duration = Duration::from_secs(10);
/// A route that already carried this peer must get a fresh attempt after a
/// freeze. Bound its transport dial and WebSocket upgrade together; the cold
/// connect budget still accommodates a first handshake or a slow ssh login.
const DIRECT_REDIAL_CONNECT: Duration = Duration::from_secs(4);

/// Who a dial is for. Only the link's own dial carries its `initialize` behind the upgrade
/// (`Peer::early_initialize`). A probe's socket greets the peer with its observer `probe_hello`;
/// a full `initialize` ahead of it made the hub probe a second full client of the peer, and its
/// dual send stopped delivering (#54052: mac-mac direct failover 2.4-2.9 s became 7.9 s).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum For {
    Link,
    Probe,
}

/// How often a redial of a URL that already carried this peer starts a fresh TCP connect while
/// none has connected. The pair matrix's direct path after a 60 s outage: the link opened 9.9 s
/// after the network came back, its dial waiting on the SYN sent 16 s before.
const URL_REDIAL_AGAIN: Duration = Duration::from_secs(2);

pub(crate) trait Duplex: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Duplex for T {}
pub(crate) type BoxDuplex = Box<dyn Duplex>;

type BoxedWs = tokio_tungstenite::WebSocketStream<HeardStream<BoxDuplex>>;
type UrlWs = tokio_tungstenite::WebSocketStream<
    tokio_tungstenite::MaybeTlsStream<HeardStream<tokio::net::TcpStream>>,
>;

/// An opened WebSocket of one path.
pub(super) enum OpenedWs {
    Boxed(Box<BoxedWs>),
    Url(Box<UrlWs>),
}

/// An ssh path probe's own `ssh -W` process (spawned `kill_on_drop`) and its stderr reader.
type ProbeTunnel = (tokio::process::Child, ssh_errors::Capture);

/// The WebSocket the cold connect opened (its path comes back beside it from `race`).
pub(super) struct Opened {
    pub ws: OpenedWs,
    pub heard: Heard,
    /// The peer token it presented (`Peer::presented`).
    pub presented: Option<String>,
    /// ssh's stderr, read for why an ssh link ended.
    pub ssh_errors: Option<ssh_errors::Capture>,
    /// The id of the `initialize` that left with the upgrade request (`Peer::early_initialize`).
    pub early_id: Option<i64>,
}

/// Which direct path this machine has for a peer: acpmux's own WireGuard transport runs only
/// while it holds the key lock, so a running transport means acpmux holds the key; otherwise
/// the cmux link holds it (or will), and a paired peer is dialed through the link.
pub(crate) fn direct_via(wireguard_running: bool, link_host: bool) -> Option<Via> {
    if wireguard_running {
        Some(Via::Wireguard)
    } else if link_host {
        Some(Via::Link)
    } else {
        None
    }
}

/// Dial `candidates` in order: the first at once, each next one [`STAGGER`] (`stagger`) after
/// the one before, or at once when every one started so far failed. The first to open wins;
/// the rest are dropped, which cancels them. Returns the winner and the failures seen before
/// it, or every failure, in the order they came.
#[cfg(test)]
#[allow(clippy::type_complexity)]
pub(super) async fn race<T, E, F>(
    candidates: Vec<(Via, F)>,
    stagger: Duration,
) -> Result<(Via, T, Vec<(Via, E)>), Vec<(Via, E)>>
where
    F: Future<Output = Result<T, E>>,
{
    race_together(candidates, 1, stagger).await
}

/// `race` with the first `together` candidates dialed at once (relay first: the hub relay
/// and the remembered path, `Paths::dial_together`), the rest staggered after them.
#[allow(clippy::type_complexity)]
pub(super) async fn race_together<T, E, F>(
    candidates: Vec<(Via, F)>,
    together: usize,
    stagger: Duration,
) -> Result<(Via, T, Vec<(Via, E)>), Vec<(Via, E)>>
where
    F: Future<Output = Result<T, E>>,
{
    let mut together = together.max(1);
    async fn tagged<T, E, F: Future<Output = Result<T, E>>>(
        via: Via,
        dial: F,
    ) -> (Via, Result<T, E>) {
        (via, dial.await)
    }
    let mut waiting = candidates.into_iter();
    let mut running = FuturesUnordered::new();
    let mut failed = Vec::new();
    let mut next_at: Option<tokio::time::Instant> = None;
    loop {
        let now = tokio::time::Instant::now();
        if running.is_empty() || next_at.is_some_and(|at| at <= now) {
            match waiting.next() {
                Some((via, dial)) => {
                    running.push(tagged(via, dial));
                    together = together.saturating_sub(1);
                    next_at = Some(if together > 0 { now } else { now + stagger });
                }
                None if running.is_empty() => return Err(failed),
                None => next_at = None,
            }
            continue;
        }
        tokio::select! {
            Some((via, result)) = running.next() => match result {
                Ok(value) => return Ok((via, value, failed)),
                Err(error) => {
                    failed.push((via, error));
                    // Nothing is left running: the next one starts now.
                    if running.is_empty() {
                        next_at = Some(tokio::time::Instant::now());
                    }
                }
            },
            () = tokio::time::sleep_until(next_at.unwrap_or(now)), if next_at.is_some() => {}
        }
    }
}

/// The log line of a cold connect of a peer with an ssh path (`has_ssh`) that `via`, another
/// path, won: which path carries the link and why ssh does not (its failure class,
/// `peer_ssh.rs`, never ssh's stderr; or that it had not answered first). None when ssh won
/// or the peer has no ssh path.
pub(super) fn backup_line<E: std::fmt::Display>(
    via: Via,
    has_ssh: bool,
    failed: &[(Via, E)],
) -> Option<String> {
    if via == Via::Ssh || !has_ssh {
        return None;
    }
    let why = match failed.iter().find(|(failed, _)| *failed == Via::Ssh) {
        Some((_, error)) => format!("ssh did not connect ({error})"),
        None => "ssh had not connected first".to_owned(),
    };
    Some(format!("{why}; the link runs on the {} path", via.as_str()))
}

/// One line for a connect whose every path failed.
pub(super) fn failures_line<E: std::fmt::Display>(failed: &[(Via, E)]) -> String {
    match failed {
        [(_, only)] => only.to_string(),
        many => many
            .iter()
            .map(|(via, error)| format!("{}: {error}", via.as_str()))
            .collect::<Vec<_>>()
            .join("; "),
    }
}

/// The running cmux link's local socket, from its registration (`link.json`); None when no
/// link runs. Reads the file and connects to check it: call off the async workers.
fn link_socket() -> Option<PathBuf> {
    let dir = cmux_tui_platform::platform::workspace_state_dir()?;
    cmux_link::registration::read_live(&dir).map(|live| live.socket)
}

/// The paired install of the cmux link whose key is `wireguard_key` (the peer's acpmux
/// WireGuard key, which the link adopts as this machine's one key), from the link's
/// pairings; None when the link has no such peer.
pub(crate) fn paired_install(wireguard_key: &str) -> Option<String> {
    crate::wireguard::paired_install_in(&crate::wireguard::link_state_dir()?, wireguard_key)
}

/// Open a stream to the `acpmux` service of paired install `host` through the link at
/// `socket` (`cmux link dial --service acpmux`, without the process): one `link.dial` line,
/// one reply line, then the stream.
#[cfg(unix)]
pub(crate) async fn dial_link(socket: &Path, host: &str) -> Result<tokio::net::UnixStream, String> {
    use cmux_link::dial::{
        DialOp, DialReply, DialRequest, MAX_LINE_BYTES, Service, line, parse_line,
    };
    let mut stream = tokio::net::UnixStream::connect(socket)
        .await
        .map_err(|e| format!("cmux link is not running: {e}"))?;
    // The listener must be this user's cmux link, not a socket squatter.
    let fd = std::os::fd::AsRawFd::as_raw_fd(&stream);
    match tokio::task::spawn_blocking(move || cmux_link::caller::verify_fd(fd)).await {
        Ok(Ok(())) => {}
        Ok(Err(refused)) => return Err(format!("cmux link refused as not ours: {refused}")),
        Err(e) => return Err(format!("cmux link check: {e}")),
    }
    let request = DialRequest { op: DialOp::Dial, host: host.to_owned(), service: Service::Acpmux };
    stream.write_all(line(&request).as_bytes()).await.map_err(|e| e.to_string())?;
    // One byte at a time, so the stream's first bytes stay unread.
    let mut bytes = Vec::with_capacity(128);
    loop {
        let byte = stream.read_u8().await.map_err(|_| "cmux link closed the dial".to_owned())?;
        if byte == b'\n' {
            break;
        }
        if bytes.len() >= MAX_LINE_BYTES {
            return Err("cmux link sent an invalid reply".to_owned());
        }
        bytes.push(byte);
    }
    let text =
        String::from_utf8(bytes).map_err(|_| "cmux link sent an invalid reply".to_owned())?;
    let reply: DialReply =
        parse_line(&text).ok_or_else(|| "cmux link sent an invalid reply".to_owned())?;
    if !reply.ok {
        return Err(format!(
            "cmux link refused the dial: {:?}{}",
            reply.error_code,
            reply.error_detail.map(|d| format!(": {d}")).unwrap_or_default()
        ));
    }
    Ok(stream)
}

#[cfg(not(unix))]
pub(crate) async fn dial_link(_socket: &Path, _host: &str) -> Result<BoxDuplex, String> {
    Err("the cmux link runs on Unix only".to_owned())
}

/// The next copy queued for the shadow; never, without one.
/// The probe's next dual-send check: `check`'s tick, or `doubt_at` (wall-clock ms) when that
/// comes first, which restarts `check` from then.
async fn doubt_or_check(check: &mut tokio::time::Interval, doubt_at: Option<u64>) {
    let Some(at) = doubt_at else {
        check.tick().await;
        return;
    };
    let wait = Duration::from_millis(at.saturating_sub(crate::store::now_ms()));
    tokio::select! {
        _ = check.tick() => {}
        () = tokio::time::sleep(wait) => check.reset(),
    }
}

async fn next_copy(shadow: &mut Option<super::dual::ShadowRun>) -> Option<String> {
    match shadow.as_mut() {
        Some(run) => run.rx.recv().await,
        None => std::future::pending().await,
    }
}

/// Send `texts` on a probe's WebSocket, each within [`PROBE_EVERY`]; false when one did not go.
async fn send_texts<S>(ws: &mut tokio_tungstenite::WebSocketStream<S>, texts: Vec<String>) -> bool
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    for text in texts {
        let sent = tokio::time::timeout(PROBE_EVERY, ws.send(Frame::Text(text.into()))).await;
        if !matches!(sent, Ok(Ok(()))) {
            return false;
        }
    }
    true
}

/// A ping's payload: when it went out, in microseconds since a process-wide origin, so its
/// pong measures the path's round trip.
pub(super) fn ping_stamp() -> Vec<u8> {
    micros_since_origin().to_le_bytes().to_vec()
}

/// The round trip a pong measured, if it answers a [`ping_stamp`].
pub(super) fn pong_rtt(payload: &[u8]) -> Option<Duration> {
    let sent = u64::from_le_bytes(<[u8; 8]>::try_from(payload).ok()?);
    let now = micros_since_origin();
    (sent <= now).then(|| Duration::from_micros(now - sent))
}

fn micros_since_origin() -> u64 {
    static ORIGIN: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    let origin = ORIGIN.get_or_init(std::time::Instant::now);
    u64::try_from(origin.elapsed().as_micros()).unwrap_or(u64::MAX)
}

impl Peer {
    /// The paired install the cmux link dials for this peer (`PeerConfig::link_host`, or the
    /// link's pairing with its key).
    pub(crate) fn set_link_host(&self, host: String) {
        if cmux_link::stamp::valid_id(&host) {
            let _ = self.link_host.set(host);
        }
    }

    /// The hub's last-known-good book (`peer_last_good.rs`).
    /// It keeps the remote tokens an `ssh://` peer reads there too, and starts with those it
    /// kept on an earlier run (`peer_kept_tokens.rs`) unless they disagree with a configured one.
    pub(crate) fn set_last_good(&self, book: Arc<crate::peer_last_good::LastGood>) {
        if self.ssh_parts().is_some() {
            self.read_tokens.back(book.clone(), &self.name, &self.url, |(token, peer)| {
                self.token.as_ref().is_none_or(|t| t == token)
                    && (self.peer_token.is_none() || self.peer_token == *peer)
            });
        }
        let _ = self.last_good.set(book);
    }

    /// Preparation may run concurrently; the registered peer owns token writes.
    /// This only sets an atomic generation, so registration does no file I/O.
    pub(crate) fn activate_read_tokens(&self) {
        self.read_tokens.activate();
    }

    pub(crate) fn persist_read_tokens(&self) {
        self.read_tokens.persist();
    }

    /// The paths this peer has, before any is dialed.
    pub(super) fn path_vias(&self) -> Vec<Via> {
        let mut vias: Vec<Via> =
            direct_via(self.wireguard.get().is_some(), self.link_host.get().is_some())
                .into_iter()
                .collect();
        vias.push(if self.ssh_parts().is_some() { Via::Ssh } else { Via::Url });
        if self.tailnet_route().is_some() {
            vias.push(Via::Tailnet);
        }
        #[cfg(feature = "hub-carrier")]
        if self.has_hub_path() {
            vias.push(Via::Hub);
        }
        vias
    }

    /// Run `f` on this peer's paths, made on first use with the path remembered from an
    /// earlier run.
    pub(super) fn with_paths<T>(&self, f: impl FnOnce(&mut Paths) -> T) -> T {
        let mut paths = self.paths.lock_or_recover();
        let paths = paths.get_or_insert_with(|| {
            let mut paths = Paths::new(&self.path_vias());
            let remembered = self.last_good.get().and_then(|book| book.get(&self.name));
            paths.remember(remembered.and_then(|entry| entry.via));
            paths
        });
        f(paths)
    }

    /// The path the live link runs on, while it is open.
    pub(crate) fn serving(&self) -> Option<Via> {
        *self.serving.lock_or_recover()
    }

    pub(super) fn set_serving(&self, via: Option<Via>) {
        *self.serving.lock_or_recover() = via;
        self.switch_wanted.store(false, Ordering::SeqCst);
        self.with_paths(|paths| paths.serving(via, crate::store::now_ms()));
    }

    /// When the link's path falls in doubt, while that is still ahead and the probe on `via`
    /// is not the link's own path: the moment its shadow may be wanted (`Paths::doubt_at`).
    pub(super) fn doubt_ahead(&self, via: Via) -> Option<u64> {
        let serving = self.serving().filter(|serving| *serving != via)?;
        let at = self.with_paths(|paths| paths.doubt_at(serving))?;
        (at > crate::store::now_ms()).then_some(at)
    }

    /// A pong on `via`.
    pub(super) fn path_pong(&self, via: Via, rtt: Duration) {
        let switch = self.with_paths(|paths| paths.pong(via, rtt, crate::store::now_ms()));
        self.after_switch(switch);
    }

    /// `via`'s connection failed or ended.
    pub(super) fn path_failed(&self, via: Via) {
        let switch = self.with_paths(|paths| paths.failed(via, crate::store::now_ms()));
        self.after_switch(switch);
    }

    /// The clock moved (a ping tick): paths whose trust ran out are dead.
    pub(super) fn paths_tick(&self) {
        let switch = self.with_paths(|paths| paths.tick(crate::store::now_ms()));
        self.after_switch(switch);
    }

    /// The selector moved the session to `to`: the live link moves there at its next quiet
    /// moment (`switch_due`).
    pub(super) fn after_switch(&self, switch: Option<Option<Via>>) {
        let Some(Some(to)) = switch else { return };
        let serving = self.serving();
        if serving.is_some_and(|via| via != to) && self.link().is_ready() {
            tracing::info!(peer = %self.name, from = ?serving, to = ?to, "a faster path is up; the link moves to it");
            self.switch_wanted.store(true, Ordering::SeqCst);
        }
    }

    /// Whether the live link should end now to move to the path the selector picked: one was
    /// picked, and no request is out on this link (its answer would be lost). Its chats'
    /// streams resume on the next link from their cursors (`afterSeq`).
    ///
    /// Requests the peer sent this daemon count too: a lent GitHub action (the only incoming
    /// request answered later; any other is refused at once in the serve loop) holds the link
    /// until its answer is queued, and a queued frame until it is written (`out` empty). An
    /// action past its own budget (`ACTION_BUDGET`) no longer holds it: the link moves, the
    /// action is revoked with the link (`link_ended`, its `gh` killed), and the peer's own
    /// request deadline fails it there.
    pub(super) fn switch_due(&self) -> bool {
        if !self.switch_wanted.load(Ordering::SeqCst)
            || !self.on_wire.lock_or_recover().is_empty()
            || self.answering.busy(tokio::time::Instant::now())
            || self.out.capacity() != self.out.max_capacity()
        {
            return false;
        }
        self.pending.try_lock().is_ok_and(|pending| pending.is_empty())
    }

    /// Whether a path other than `failed` answers now: the link that just ended moves there
    /// without the session noticing (no outage is counted).
    pub(super) fn another_path_alive(&self, failed: Via) -> bool {
        self.with_paths(|paths| paths.active().is_some_and(|via| via != failed))
    }

    /// The order a cold connect dials this peer's paths in (`Paths::dial_order`).
    #[cfg(test)]
    pub(super) fn dial_order(&self) -> Vec<Via> {
        self.with_paths(|paths| paths.dial_order(crate::store::now_ms()))
    }

    /// The token and peer token a direct path presents: the configured ones, else those read
    /// over ssh (`tokens`).
    fn direct_credentials(
        &self,
        ssh_tokens: Option<&(tokens::Tokens, bool)>,
    ) -> Option<(String, Option<String>)> {
        ssh_tokens.map(|((token, peer), _)| (token.clone(), peer.clone())).or_else(|| {
            self.token.clone().map(|token| (token, self.peer_token.clone())).or_else(|| {
                (self.token.is_none() || self.peer_token.is_none())
                    .then(|| self.read_tokens.get())
                    .flatten()
            })
        })
    }

    /// Dial this peer's paths (`dial_order`), each `STAGGER` after the one before it or at once
    /// when it failed, and keep the first that opens; the others are marked failed. Relay
    /// first (`Paths::relay_first`), the hub relay and the path after it start together at
    /// once. A token read over ssh, when one is needed, runs inside the dials that present
    /// tokens, never before the race: a dial with its tokens configured or kept starts at once.
    pub(super) async fn open_first(self: &Arc<Self>) -> Result<(Via, Opened), String> {
        use futures_util::FutureExt;
        // Opt-in tailnet path: read from memory only, never awaited (a first read runs behind).
        self.refresh_tailnet(None).await;
        let started = crate::store::now_ms();
        let (order, together) = self.with_paths(|paths| {
            let now = crate::store::now_ms();
            (paths.dial_order(now), paths.dial_together(now))
        });
        let read = Box::pin(self.direct_tokens(&order)).shared();
        // Whether a dial ran past its connect deadline: the link's end class (`link_timed_out`).
        let timed_out = Arc::new(AtomicBool::new(false));
        let dials: Vec<_> = order
            .iter()
            .map(|via| {
                let read = read.clone();
                let dial =
                    async move { self.open_via(*via, self.dial_tokens(*via, read).await).await };
                (*via, DIAL_TIMED_OUT.scope(timed_out.clone(), dial))
            })
            .collect();
        let mut stopped = self.stop_changed.subscribe();
        let raced = tokio::select! {
            biased;
            _ = stopped.wait_for(|stopped| *stopped) => return Err("peer stopped".to_owned()),
            raced = race_together(dials, together, STAGGER) => raced,
        };
        let (via, opened, failed) = match raced {
            Ok(won) => won,
            Err(failed) => {
                for (via, _) in &failed {
                    self.path_failed(*via);
                }
                if timed_out.load(Ordering::SeqCst) {
                    self.link_timed_out.store(true, Ordering::SeqCst);
                }
                // Every path failed: the route is down, for the most telling of their kinds.
                self.went_down(connect_fail(failed.iter().map(|(_, error)| error)));
                return Err(failures_line(&failed));
            }
        };
        self.with_paths(|paths| paths.record_opened(&order, via, started, crate::store::now_ms()));
        for (via, error) in &failed {
            tracing::debug!(peer = %self.name, via = via.as_str(), "path unavailable: {error}");
            self.path_failed(*via);
        }
        // The path that opened carries the link: alive before its first pong, so a probe of
        // another path that answers first does not move the link at once.
        self.with_paths(|paths| paths.opened(via, crate::store::now_ms()));
        if let Some(line) = backup_line(via, self.ssh_parts().is_some(), &failed) {
            tracing::info!(peer = %self.name, via = via.as_str(), carrier = via.carrier().as_str(), "{line}");
        }
        Ok((via, opened))
    }

    /// The tokens dial `via` of a cold connect starts with: none for a URL path (it presents
    /// the configured ones); for the rest, the shared read's (`direct_tokens`), awaited only by
    /// a dial that would present read tokens. A direct or hub dial with configured or kept
    /// tokens does not wait on ssh.
    async fn dial_tokens<F>(&self, via: Via, read: F) -> Option<(tokens::Tokens, bool)>
    where
        F: Future<Output = Option<(tokens::Tokens, bool)>>,
    {
        let configured = self.token.is_some() && self.peer_token.is_some();
        match via {
            Via::Url => None,
            Via::Wireguard | Via::Link | Via::Tailnet | Via::Hub if configured => None,
            // What the read would answer at once (`connect_tokens`), without waiting on it.
            Via::Wireguard | Via::Link | Via::Tailnet | Via::Hub
                if self.read_tokens.get().is_some() =>
            {
                self.read_tokens.get().map(|kept| (kept, true))
            }
            _ => read.await,
        }
    }

    /// The tokens a direct path presents, read over ssh first only when this peer has no
    /// configured pair: an ssh:// peer may source this launch's credentials there, and a
    /// direct path must not present older ones than its ssh path would. Configured tokens
    /// need no read, so a direct path never waits on ssh for them; and a read that fails
    /// (ssh down) leaves the direct path its kept tokens, never stops it.
    async fn direct_tokens(&self, order: &[Via]) -> Option<(tokens::Tokens, bool)> {
        let direct = order
            .iter()
            .any(|via| matches!(via, Via::Wireguard | Via::Link | Via::Tailnet | Via::Hub));
        let configured = self.token.is_some() && self.peer_token.is_some();
        if !direct || configured || self.ssh_parts().is_none() {
            return None;
        }
        match self.connect_tokens().await {
            Ok(tokens) => Some(tokens),
            Err(error) => {
                tracing::debug!(peer = %self.name, "no tokens over ssh before the direct path: {error}");
                None
            }
        }
    }

    /// The cmux link socket to dial, ahead of the link's registration (tests).
    // Only the Linux link tests in peer_carriers_tests.rs call it.
    #[cfg(all(test, target_os = "linux"))]
    pub(super) fn set_link_socket(&self, socket: PathBuf) {
        let _ = self.link_socket.set(socket);
    }

    /// A raw stream to the peer's listener on a direct path, and the URL its upgrade names.
    async fn direct_stream(&self, via: Via) -> Result<(BoxDuplex, String), DialError> {
        match via {
            Via::Wireguard => {
                let (transport, address) =
                    self.wireguard.get().ok_or_else(|| "no WireGuard route".to_owned())?;
                let stream = transport
                    .connect(*address)
                    .await
                    .map_err(|e| DialError::new(fail_of_chain(&e), e.to_string()))?;
                Ok((Box::new(stream), format!("ws://localhost:{}", address.port())))
            }
            Via::Link => {
                let host = self.link_host.get().ok_or_else(|| "not a paired install".to_owned())?;
                let socket = match self.link_socket.get() {
                    Some(socket) => Some(socket.clone()),
                    None => tokio::task::spawn_blocking(link_socket).await.ok().flatten(),
                }
                .ok_or_else(|| "cmux link is not running".to_owned())?;
                let stream = dial_link(&socket, host).await?;
                Ok((Box::new(stream), "ws://localhost/".to_owned()))
            }
            Via::Tailnet => self.tailnet_stream().await.map_err(DialError::from),
            #[cfg(feature = "hub-carrier")]
            Via::Hub => Ok((Box::new(self.hub_stream().await?), "ws://localhost/".to_owned())),
            other => Err(format!("{} is not a direct stream path", other.as_str()).into()),
        }
    }

    /// Open the peer's WebSocket on direct path `via`, for the link or for a probe (`For`).
    async fn open_direct(
        &self,
        via: Via,
        ssh_tokens: Option<&(tokens::Tokens, bool)>,
        dialer: For,
    ) -> Result<Opened, DialError> {
        let (token, peer_token) = self
            .direct_credentials(ssh_tokens)
            .ok_or_else(|| "no token for the peer yet".to_owned())?;
        let deadline = if self.linked_once.load(Ordering::SeqCst)
            && matches!(via, Via::Wireguard | Via::Link | Via::Tailnet)
        {
            self.timings.connect.min(DIRECT_REDIAL_CONNECT)
        } else {
            self.timings.connect
        };
        // The first request goes out with the upgrade (`Peer::early_initialize`); a peer whose
        // listener predates that refuses the upgrade ("junk after client request"), which is
        // remembered (`early_refused`) and dialed again without it. A probe sends none: its
        // socket is the observer `probe_hello`'s, never the link's (`For`).
        let mut use_early = dialer == For::Link && !self.early_refused.load(Ordering::SeqCst);
        loop {
            let heard = Heard::default();
            let early = use_early.then(|| self.early_initialize()).flatten();
            let early_id = early.as_ref().map(|(id, _)| *id);
            let opening = async {
                let (stream, url) = self.direct_stream(via).await.map_err(|e| (false, e))?;
                let req = self
                    .ws_request(&url, Some(&token), peer_token.as_deref())
                    .map_err(|e| (false, DialError::from(e)))?;
                tokio_tungstenite::client_async_with_config(
                    req,
                    match early {
                        Some((_, frame)) => heard.wrap_early(stream, frame),
                        None => heard.wrap(stream),
                    },
                    Some(crate::server::ws_config()),
                )
                .await
                // Only an answer that is not the token's refusal may be the early frame's.
                .map_err(|e| (!tokens::refused(&e), DialError::ws(&e)))
            };
            match tokio::time::timeout(deadline, opening).await {
                Ok(Ok((ws, _))) => {
                    return Ok(Opened {
                        ws: OpenedWs::Boxed(Box::new(ws)),
                        heard,
                        presented: peer_token,
                        ssh_errors: None,
                        early_id,
                    });
                }
                Ok(Err((maybe_early, _))) if maybe_early && early_id.is_some() => {
                    self.early_refused.store(true, Ordering::SeqCst);
                    tracing::debug!(peer = %self.name, "the peer refused an upgrade with a first request behind it; dialing without");
                    use_early = false;
                }
                Ok(Err((_, error))) => return Err(error),
                Err(_) => return Err(DialError::timeout(connect_timed_out(deadline))),
            }
        }
    }

    /// Open the peer's WebSocket on the configured `ws://`/`wss://` URL, for the link or for a
    /// probe (`For`).
    async fn open_url(&self, dialer: For) -> Result<Opened, DialError> {
        // The peer token never crosses a network in clear.
        let peer_token = match self.peer_token.as_deref() {
            Some(_) if !super::carries_peer_token(&self.url) => {
                if !self.withheld.swap(true, Ordering::SeqCst) {
                    tracing::warn!(peer = %self.name, "the peer runs as remote (Web): its transport is plain ws:// to a host that is not loopback, so the peer token is not sent; use ssh:// or wss://");
                }
                None
            }
            other => other,
        };
        // Whether an attempt sent the early `initialize` (a refusal then dials without it).
        let sent_early = AtomicBool::new(false);
        let token_said_no = AtomicBool::new(false);
        // One whole open, `connect_async`'s steps with the TCP stream's reads counted (`Heard`).
        let attempt = || async {
            let req = self.ws_request(&self.url, self.token.as_deref(), peer_token)?;
            let heard = Heard::default();
            // Over TLS the upgrade is written inside the stream this would wrap: no early frame. A
            // probe sends none either (`For`).
            let early = (dialer == For::Link
                && self.url.starts_with("ws://")
                && !self.early_refused.load(Ordering::SeqCst))
            .then(|| self.early_initialize())
            .flatten();
            let early_id = early.as_ref().map(|(id, _)| *id);
            if early_id.is_some() {
                sent_early.store(true, Ordering::SeqCst);
            }
            let host = req.uri().host().ok_or_else(|| "the peer URL has no host".to_owned())?;
            let host = host.trim_start_matches('[').trim_end_matches(']').to_owned();
            let tls = req.uri().scheme_str() == Some("wss");
            let port = req.uri().port_u16().unwrap_or(if tls { 443 } else { 80 });
            // A peer the person configured: a host they name.
            cmux_egress::allow_named(&host);
            let tcp =
                crate::happy_dial::connect_tcp(&host, port).await.map_err(|e| DialError::io(&e))?;
            // A peer forwards the pane's prompts and their images: the listener's limits.
            let (ws, _) = tokio_tungstenite::client_async_tls_with_config(
                req,
                match early {
                    Some((_, frame)) => heard.wrap_early(tcp, frame),
                    None => heard.wrap(tcp),
                },
                Some(crate::server::ws_config()),
                None,
            )
            .await
            .map_err(|e| {
                if tokens::refused(&e) {
                    token_said_no.store(true, Ordering::SeqCst);
                    self.token_refused();
                }
                DialError::ws(&e)
            })?;
            Ok::<_, DialError>((ws, heard, early_id))
        };
        // A URL that already carried this peer is opened again every `URL_REDIAL_AGAIN` while
        // no attempt has opened (`happy_dial::again`): an open sent into an outage otherwise
        // waits out its SYN and segment retransmissions after the network is back. A wake or a
        // network change starts a fresh attempt at once, not at the next tick.
        let connect = async {
            if !self.linked_once.load(Ordering::SeqCst) {
                return attempt().await;
            }
            let kick = || async {
                let mut slept = crate::peer_link::SleepWatch::now();
                tokio::select! {
                    () = self.network_changed() => {
                        tracing::info!(peer = %self.name, "network changed mid-dial; dialing again now");
                    }
                    () = async {
                        loop {
                            tokio::time::sleep(URL_REDIAL_AGAIN).await;
                            if slept.check().is_some() {
                                break;
                            }
                        }
                    } => {
                        tracing::info!(peer = %self.name, "this computer slept mid-dial; dialing again now");
                    }
                }
            };
            crate::happy_dial::again(
                URL_REDIAL_AGAIN,
                crate::happy_dial::AGAIN_AT_MOST,
                kick,
                attempt,
            )
            .await
        };
        let (ws, heard, early_id) = match tokio::time::timeout(self.timings.connect, connect).await
        {
            Ok(Ok(opened)) => opened,
            // A listener that predates the early request refuses the upgrade: dial without.
            Ok(Err(_))
                if sent_early.load(Ordering::SeqCst) && !token_said_no.load(Ordering::SeqCst) =>
            {
                self.early_refused.store(true, Ordering::SeqCst);
                return Box::pin(self.open_url(dialer)).await;
            }
            Ok(Err(error)) => return Err(error),
            Err(_) => return Err(DialError::timeout(connect_timed_out(self.timings.connect))),
        };
        Ok(Opened {
            ws: OpenedWs::Url(Box::new(ws)),
            heard,
            presented: None,
            ssh_errors: None,
            early_id,
        })
    }

    /// Open the peer's WebSocket over `ssh -W`, reading its tokens over ssh as needed.
    async fn open_ssh(
        &self,
        mut ssh_tokens: Option<(tokens::Tokens, bool)>,
    ) -> Result<Opened, DialError> {
        let mut restarted = false;
        loop {
            // A first connect with nothing read: the tunnel logs in first and the read rides its
            // master (`peer_ssh_master.rs`). A later one (a redial, a restarted remote that may not
            // listen yet) opens its tunnel after the read, as one with kept tokens has none.
            let reading = tokio::time::Instant::now();
            let mut early = if ssh_tokens.is_none()
                && self.read_tokens.get().is_none()
                && !self.linked_once.load(Ordering::SeqCst)
            {
                Some(self.open_tunnel().await?)
            } else {
                None
            };
            let read = match ssh_tokens.take() {
                Some(tokens) => Ok(tokens),
                None => self.connect_tokens().await,
            };
            let ((token, peer_token), kept) = match read {
                Ok(tokens) => tokens,
                Err(error) => {
                    self.end_tunnel().await;
                    return Err(error.into());
                }
            };
            // A read that waited for the remote's peer token (`TOKEN_REREADS`) outlasted the
            // remote's upgrade deadline (5 s, `server::WS_HANDSHAKE_TIMEOUT`): a new tunnel.
            if early.is_some() && reading.elapsed() > EARLY_TUNNEL_FOR {
                early = None;
                self.end_tunnel().await;
            }
            let attempt = tokio::time::Instant::now();
            let may_restart = !restarted && !self.waking();
            let (stream, remote_port, errors) = match early {
                Some(tunnel) => tunnel,
                None => self.open_tunnel().await?,
            };
            let heard = Heard::default();
            let mut refused = false;
            let mut restart = false;
            let upgraded = async {
                let req = self.ws_request(
                    &format!("ws://127.0.0.1:{remote_port}"),
                    Some(&token),
                    peer_token.as_deref(),
                )?;
                let stream: BoxDuplex = Box::new(stream);
                // A peer forwards the pane's prompts and their images: the listener's limits.
                let upgrade = tokio::time::timeout(
                    self.timings.connect,
                    tokio_tungstenite::client_async_with_config(
                        req,
                        heard.wrap(stream),
                        Some(crate::server::ws_config()),
                    ),
                );
                tokio::pin!(upgrade);
                let upgraded = tokio::select! {
                    upgraded = &mut upgrade => upgraded,
                    () = self.next_ask_after(attempt + RESTART_AFTER), if may_restart => {
                        restart = true;
                        return Err("a client asked while the attempt was still connecting".to_owned().into());
                    }
                };
                let (ws, _) = upgraded
                    .map_err(|_| DialError::timeout(connect_timed_out(self.timings.connect)))?
                    .map_err(|e| {
                        refused = tokens::refused(&e);
                        DialError::ws(&e)
                    })?;
                Ok::<_, DialError>(ws)
            }
            .await;
            let error = match upgraded {
                Ok(ws) => {
                    return Ok(Opened {
                        ws: OpenedWs::Boxed(Box::new(ws)),
                        heard,
                        presented: peer_token,
                        ssh_errors: Some(errors),
                        early_id: None,
                    });
                }
                Err(error) => error,
            };
            // End the owned SSH process now, including when its next attempt is an hour away.
            self.end_tunnel().await;
            // A client asked mid-connect (the network was down): one new attempt, same tokens, now.
            if restart && !self.stop.load(Ordering::SeqCst) {
                tracing::info!(peer = %self.name, "a client asked while the connect was pending; connecting again");
                self.with_silence(crate::peer_link::SilenceBudget::dial_struggled);
                restarted = true;
                ssh_tokens = Some(((token, peer_token), kept));
                continue;
            }
            if refused {
                self.token_refused();
                self.read_tokens.forget();
                // Kept tokens the remote no longer takes: read them again and retry once, now.
                if kept && !self.stop.load(Ordering::SeqCst) {
                    tracing::info!(peer = %self.name, "the remote refused the kept token; reading it again");
                    continue;
                }
            }
            let reason = errors.finish().await;
            // A WebSocket timeout can be specific to one remote daemon. OpenSSH's
            // transport keepalives retire a dead master without ending healthy siblings.
            self.note_ssh_failure(reason);
            // ssh's own failure class says more than the upgrade's error over its tunnel.
            let fail = ssh_errors::dial_fail(reason).or(error.fail);
            return Err(DialError::new(fail, ssh_errors::describe(error.text, reason)));
        }
    }

    /// Open the peer's WebSocket on `via` (the cold connect's dial of one path).
    pub(super) async fn open_via(
        &self,
        via: Via,
        ssh_tokens: Option<(tokens::Tokens, bool)>,
    ) -> Result<Opened, DialError> {
        let opened = match via {
            Via::Ssh => self.open_ssh(ssh_tokens).await,
            Via::Url => self.open_url(For::Link).await,
            Via::Wireguard | Via::Link | Via::Tailnet => {
                self.open_direct(via, ssh_tokens.as_ref(), For::Link).await
            }
            Via::Hub if via.streams() => {
                self.open_direct(via, ssh_tokens.as_ref(), For::Link).await
            }
            Via::Hub => Err("the hub relay carries no live link yet".to_owned().into()),
        }?;
        // Unproven until the daemon's `initialize` answer on this connection says it is the
        // peer principal (`dualPrincipal`, read by the handshake).
        self.note_token_path(via, false);
        Ok(opened)
    }

    /// Whether path `via`'s current connection is the daemon's peer principal, as that
    /// daemon's `initialize` answer on it said (`token_paths`); false until it answers.
    pub(super) fn note_token_path(&self, via: Via, principal: bool) {
        self.token_paths.lock_or_recover().insert(via, principal);
    }

    /// The `initialize` a probe sends on its own connection: only to learn whether the daemon
    /// takes it as the peer principal (`dualPrincipal`). It says it only observes, so it keeps
    /// no daemon running (`daemon/unused_exit.rs`).
    fn probe_hello(&self) -> (i64, String) {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let hello = serde_json::json!({"protocolVersion": 1, "clientCapabilities": {},
            "clientInfo": {"name": super::CLIENT_NAME, "version": crate::hub::VERSION},
            "_meta": {"acpmux": {"observer": true}}});
        let line =
            crate::rpc::Message::request(id, crate::rpc::method::INITIALIZE, hello).to_line();
        (id, line.trim_end_matches('\n').to_owned())
    }

    /// Keep every path of this peer that does not carry the link open and measured: once per
    /// peer, and only when it has more than one path (a single path is measured by the link's
    /// own pings). Each probe ends with the peer.
    pub(super) fn start_probes(self: &Arc<Self>) {
        let vias = self.with_paths(|paths| paths.stream_vias());
        if vias.len() < 2 || self.probing.swap(true, Ordering::SeqCst) {
            return;
        }
        for via in vias {
            tokio::spawn(self.clone().probe(via));
        }
    }

    /// The probe of path `via`: while the link does not run on it, a WebSocket of its own,
    /// pinged each [`PROBE_EVERY`]; a dead one is dialed again on its recovery backoff.
    pub(super) async fn probe(self: Arc<Self>, via: Via) {
        let mut stopped = self.stop_changed.subscribe();
        loop {
            if *stopped.borrow() {
                return;
            }
            if !self.with_paths(|paths| paths.has(via)) {
                return; // taken out of the live set (a tailnet path no longer offered)
            }
            let now = crate::store::now_ms();
            let serving = self.serving() == Some(via);
            if serving || !self.with_paths(|paths| paths.recovery_due(via, now)) {
                let wait = self
                    .with_paths(|paths| paths.recover_at(via))
                    .filter(|_| !serving)
                    .map_or(PROBE_EVERY, |at| Duration::from_millis(at.saturating_sub(now)))
                    .min(PROBE_EVERY);
                tokio::select! {
                    () = tokio::time::sleep(wait) => continue,
                    _ = stopped.changed() => return,
                }
            }
            crate::gauges::bump(&crate::gauges::links().probe_dials);
            let opened = tokio::select! {
                opened = tokio::time::timeout(PROBE_CONNECT, self.open_probe(via)) => opened,
                _ = stopped.changed() => return,
            };
            match opened {
                Ok(Ok((OpenedWs::Boxed(ws), tunnel))) => self.probe_link(via, *ws, tunnel).await,
                Ok(Ok((OpenedWs::Url(ws), tunnel))) => self.probe_link(via, *ws, tunnel).await,
                Ok(Err(error)) => {
                    tracing::debug!(peer = %self.name, via = via.as_str(), "path probe failed: {error}");
                    self.path_failed(via);
                }
                Err(_) => self.path_failed(via),
            }
        }
    }

    /// Ping `ws` on `via` until it fails, the link moves onto `via`, or the peer stops. While
    /// the link's path is in doubt and `via` is the best other path, `ws` is also the link's
    /// shadow (`peer_dual.rs`): it carries a copy of each frame, and its chat events and
    /// replies are taken once.
    pub(super) async fn probe_link<S>(
        &self,
        via: Via,
        mut ws: tokio_tungstenite::WebSocketStream<S>,
        _tunnel: Option<ProbeTunnel>,
    ) where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        // Held while this probe's connection is: `gauges.links.probesOpen`.
        let _open = crate::gauges::Held::on(&crate::gauges::links().probes_open);
        let mut stopped = self.stop_changed.subscribe();
        let mut ping = tokio::time::interval(PROBE_EVERY);
        ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut check = tokio::time::interval(super::dual::DOUBT_CHECK);
        // Whether the daemon takes this connection as the peer principal: only its answer on
        // this connection qualifies the path for dual send, read again on each probe.
        self.note_token_path(via, false);
        let (hello_id, hello) = self.probe_hello();
        let mut hello_id = Some(hello_id);
        if !send_texts(&mut ws, vec![hello]).await {
            self.path_failed(via);
            return;
        }
        check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut shadow: Option<super::dual::ShadowRun> = None;
        loop {
            // Without a shadow, the check also wakes the moment the link's path falls in doubt,
            // so dual send starts then and not up to a whole `DOUBT_CHECK` later.
            let doubt_at = if shadow.is_none() { self.doubt_ahead(via) } else { None };
            tokio::select! {
                _ = stopped.changed() => break,
                _ = ping.tick() => {
                    // The link took this path: its own pings measure it now.
                    if self.serving() == Some(via) && shadow.is_none() {
                        break;
                    }
                    self.paths_tick();
                    let sent = tokio::time::timeout(PROBE_EVERY, ws.send(Frame::Ping(ping_stamp().into()))).await;
                    if !matches!(sent, Ok(Ok(()))) {
                        self.path_failed(via);
                        break;
                    }
                }
                () = doubt_or_check(&mut check, doubt_at) => {
                    let done = shadow.as_mut().is_some_and(|run| self.shadow_done(run));
                    let frames = match shadow.take() {
                        None if self.dual_wanted(via) => {
                            let (run, frames) = self.shadow_start(via).await;
                            shadow = Some(run);
                            frames
                        }
                        Some(run) if done => self.shadow_end(run).await,
                        Some(mut run) => {
                            // A chat whose gap outlived its bound is attached again from its
                            // cursor.
                            let mut frames = Vec::new();
                            for sid in self.dual_gaps().await {
                                frames.extend(self.shadow_resubscribe(&mut run, &sid).await);
                            }
                            // A chat whose attach did not cover its stream, due again.
                            frames.extend(self.shadow_retries(&mut run).await);
                            shadow = Some(run);
                            frames
                        }
                        None => Vec::new(),
                    };
                    if !send_texts(&mut ws, frames).await {
                        self.path_failed(via);
                        break;
                    }
                }
                Some(copy) = next_copy(&mut shadow) => {
                    if !send_texts(&mut ws, vec![copy]).await {
                        self.path_failed(via);
                        break;
                    }
                }
                frame = ws.next() => match frame {
                    Some(Ok(Frame::Pong(payload))) => {
                        if let Some(rtt) = pong_rtt(&payload) {
                            self.path_pong(via, rtt);
                        }
                    }
                    Some(Ok(Frame::Text(text))) => {
                        if let Some(id) = hello_id
                            && let Some(principal) = hello_answer(text.as_str(), id)
                        {
                            hello_id = None;
                            self.note_token_path(via, principal);
                        } else if let Some(run) = shadow.as_mut() {
                            let frames = self.shadow_frame(run, text.as_str()).await;
                            if !send_texts(&mut ws, frames).await {
                                self.path_failed(via);
                                break;
                            }
                        } else {
                            self.probe_frame(text.as_str());
                        }
                    }
                    Some(Ok(Frame::Close(_)) | Err(_)) | None => {
                        self.path_failed(via);
                        break;
                    }
                    Some(Ok(_)) => {}
                },
            }
        }
        if let Some(run) = shadow.take() {
            let _ = self.shadow_end(run).await;
        }
        // timeout: a polite close on a link that is ending; a peer that never answers it is dropped.
        let _ = tokio::time::timeout(Duration::from_secs(1), ws.close(None)).await;
        // `_tunnel` (an ssh probe's own process) ends here.
    }

    /// A probe's own WebSocket on `via`, with the credentials already known (a probe never
    /// reads tokens over ssh: the link's connect did), and its ssh process for an ssh path.
    async fn open_probe(&self, via: Via) -> Result<(OpenedWs, Option<ProbeTunnel>), String> {
        match via {
            Via::Wireguard | Via::Link | Via::Tailnet => {
                let opened = self.open_direct(via, None, For::Probe).await?;
                self.note_token_path(via, false);
                Ok((opened.ws, None))
            }
            Via::Hub if via.streams() => {
                let opened = self.open_direct(via, None, For::Probe).await?;
                self.note_token_path(via, false);
                Ok((opened.ws, None))
            }
            Via::Url => {
                let ws = self.open_url(For::Probe).await?.ws;
                self.note_token_path(via, false);
                Ok((ws, None))
            }
            Via::Ssh => {
                let (token, peer_token) = self
                    .direct_credentials(None)
                    .ok_or_else(|| "no token for the peer yet".to_owned())?;
                let (child, stream, remote_port, errors) = self.spawn_tunnel().await?;
                let req = self.ws_request(
                    &format!("ws://127.0.0.1:{remote_port}"),
                    Some(&token),
                    peer_token.as_deref(),
                )?;
                let stream: BoxDuplex = Box::new(stream);
                let (ws, _) = tokio_tungstenite::client_async_with_config(
                    req,
                    Heard::default().wrap(stream),
                    Some(crate::server::ws_config()),
                )
                .await
                .map_err(|e| e.to_string())?;
                self.note_token_path(via, false);
                Ok((OpenedWs::Boxed(Box::new(ws)), Some((child, errors))))
            }
            Via::Hub => Err("the hub relay carries no live link yet".to_owned()),
        }
    }
}

/// Requests the peer sent this daemon that are still being answered, each with the deadline
/// past which it no longer holds the link on its path (`Peer::switch_due`).
#[derive(Default)]
pub(crate) struct Answering(Arc<StdMutex<AnsweringSet>>);

#[derive(Default)]
struct AnsweringSet {
    next: u64,
    until: std::collections::HashMap<u64, tokio::time::Instant>,
}

/// One request being answered; dropped once its answer is queued (or never will be).
pub(crate) struct AnsweringGuard {
    set: Arc<StdMutex<AnsweringSet>>,
    id: u64,
}

impl Answering {
    /// A request starts being answered, for at most `budget`.
    pub(crate) fn start(&self, budget: Duration) -> AnsweringGuard {
        let mut set = self.0.lock_or_recover();
        let id = set.next;
        set.next += 1;
        set.until.insert(id, tokio::time::Instant::now() + budget);
        AnsweringGuard { set: self.0.clone(), id }
    }

    /// Whether a request is being answered within its budget at `now`.
    pub(crate) fn busy(&self, now: tokio::time::Instant) -> bool {
        self.0.lock_or_recover().until.values().any(|until| *until > now)
    }
}

impl Drop for AnsweringGuard {
    fn drop(&mut self) {
        self.set.lock_or_recover().until.remove(&self.id);
    }
}

#[path = "peer_path_book.rs"]
mod book;

#[cfg(test)]
#[path = "peer_carriers_tests.rs"]
mod tests;

/// Whether `text` answers the probe's `initialize` `id`: Some with whether the daemon said this
/// connection is its peer principal (an error, or no word, says no).
fn hello_answer(text: &str, id: i64) -> Option<bool> {
    let msg: serde_json::Value = serde_json::from_str(text).ok()?;
    if msg.get("method").is_some() || msg.get("id").and_then(serde_json::Value::as_i64) != Some(id)
    {
        return None;
    }
    let principal = msg.pointer("/result/_meta/acpmux/dualPrincipal");
    Some(principal == Some(&serde_json::Value::Bool(true)))
}
