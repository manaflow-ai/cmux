//! A peer is a remote acpmux daemon. This daemon is an ACP client of it:
//! it watches the peer's sessions, forwards requests for them, and relays
//! the peer's notifications to local clients. Reconnects with backoff and
//! jitter, forever; a slow peer is `degraded`, a lost one `reconnecting`
//! (`peer_link.rs`).

use crate::no_panic::LockExt;
use crate::peer_link::{
    Backoff, Link, LinkTimings, PeerState, SleepWatch, WAKE_PROBE, write_deadline,
};
use crate::rpc::{Message, RpcError, method};
use cmux_json::JsonSet as _;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::sync::{Mutex, Notify, mpsc, oneshot};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

#[path = "peer_features.rs"]
mod features;
#[path = "peer_health.rs"]
mod health;

#[path = "peer_ssh.rs"]
mod ssh_errors;
#[path = "peer_wanted.rs"]
mod wanted;
use wanted::BackoffWait;

#[cfg(test)]
#[path = "peer_features_tests.rs"]
mod features_tests;
#[cfg(test)]
#[path = "peer_state_tests.rs"]
mod state_tests;

#[cfg(test)]
#[path = "peer_restart_tests.rs"]
mod restart_tests;

#[cfg(test)]
#[path = "peer_handshake_tests.rs"]
mod handshake_tests;

/// Source of `Peer::generation`.
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

/// A peer watch includes the hub's remote sessions as well as its local ones.
/// A bidirectional pair must not import those already-mirrored rows, or each
/// reconnect/update would prefix the name with another peer hop.
fn is_mirrored_session(summary: &Value) -> bool {
    summary.get("peer").and_then(Value::as_str).is_some()
}

/// The `clientInfo.name` a peer link gives in `initialize`: the daemon it connects to keeps no
/// presence for it, whatever it serves the link as (`server/view.rs`).
pub const CLIENT_NAME: &str = "acpmux-peer";

/// The link's own `_acpmux/attach` of a peer's session `id`: it subscribes and reads no history,
/// and names its byte limit all the same, as `bound_page` does for a client's attach. A peer on an
/// older build reads `limit: 0` as no limit and has none of its own, so it answers with the whole
/// log in one frame, and one of 32.8 MB reset the link with its 29 chats (2026-10-21).
pub fn hidden_attach(id: &str) -> Value {
    json!({"sessionId": id, "limit": 0, "visible": false, "maxBytes": crate::hub::page_bytes(&json!({}))})
}

/// What the hub receives from a peer, tagged with the peer's name and
/// generation so notices from a replaced or removed peer can be dropped.
#[derive(Debug)]
pub enum PeerNotice {
    Connected,
    Disconnected(String),
    /// The remote daemon sent WebSocket Close 1012; its rows stay usable while it restarts.
    Restarting,
    /// Full session list from `_acpmux/watch` or a single `session_changed`.
    Sessions(Vec<Value>),
    SessionChanged {
        session: Value,
        kind: String,
        seq: u64,
    },
    Notification {
        method: String,
        params: Value,
        /// The link it came on (`Peer::link_epoch` when it was read).
        link: u64,
    },
}

/// A deliberate restart is not a transport failure and does not advance retry backoff.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LinkEnd {
    Stopped,
    Restarting,
}

pub struct Peer {
    pub name: String,
    /// Unique per `Peer` instance; a replacement under the same name gets a
    /// new one.
    pub generation: u64,
    pub url: String,
    token: Option<String>,
    /// The peer's peer token (`server/peer_auth.rs`), sent with `token`.
    peer_token: Option<String>,
    /// The `ssh -W` process carrying an `ssh://` peer's current connection.
    tunnel: Mutex<Option<tokio::process::Child>>,
    wireguard: std::sync::OnceLock<(Arc<crate::wireguard::Transport>, std::net::SocketAddr)>,
    /// Outbound frames, each tagged with the link epoch it was admitted on:
    /// `serve` drops one whose link is gone, so it never goes out on the next,
    /// and `fail_link_requests` fails the request it carries as not sent.
    out: mpsc::Sender<Outbound>,
    out_rx: Mutex<Option<mpsc::Receiver<Outbound>>>,
    next_id: AtomicI64,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, RpcError>>>>>,
    /// The pending keys whose frame `serve` wrote to the live link: when the link drops, only
    /// these may have run on the peer; every other request waiting fails as not sent.
    on_wire: OnWire,
    /// The handshake finished on the live link (`initialize` and `_acpmux/watch` answered, the
    /// sessions listed): what `connected` reports. False from the moment the link drops.
    pub connected: AtomicBool,
    /// The WebSocket is open, handshake or not: only the handshake's own requests go out
    /// while it is open and not `connected`.
    open: AtomicBool,
    pub last_error: StdMutex<Option<String>>,
    /// Version and build the peer reported at handshake.
    pub remote_version: StdMutex<Option<(String, String)>>,
    /// The build of this peer whose watch list the last handshake read in pages of rows
    /// (`Peer::watch_row_pages`): the next handshake to that build reads it so at once, without
    /// the two whole lists it would refuse (each a full build, 10-15 s on a busy peer).
    row_pages_for: StdMutex<Option<String>>,
    /// The origin the peer serves this daemon as (its initialize reply):
    /// `peer` when it accepted the peer token, `remote` (Web) otherwise.
    served_as: StdMutex<Option<String>>,
    /// The daemon run the peer named in its initialize reply
    /// (`personInstance`): the only run its pending prompts may carry
    /// (`hub/person.rs` (c)). A claim, not a proof.
    person_instance: StdMutex<Option<String>>,
    /// Whether the peer advertised the folder-trust gate in initialize.
    trust_gate: AtomicBool,
    /// This caller's own opt-out for its remote chains there (`PeerConfig`
    /// `vmBoundary`, `hub/vm_boundary.rs`): each `session/new` it forwards
    /// says `vmBoundary: true`.
    vm_boundary: AtomicBool,
    /// This Mac lends the peer its GitHub login (`PeerConfig` `githubBroker`,
    /// `github_broker.rs`), and how many of its actions may run at once: the slots of its name
    /// (`owner_slots`), which a reconnect's new peer shares with the old one.
    github_broker: AtomicBool,
    github_slots: Arc<tokio::sync::Semaphore>,
    /// The link (`link_epoch` + 1; 0 for none) whose handshake's watch was answered by the peer
    /// serving this daemon as a peer: the only link a GitHub action is taken on.
    github_link: AtomicU64,
    /// Wakes this peer's running GitHub actions when lending ends (`githubBroker` off, the link
    /// ended, the peer stopped), so they stop then rather than run on.
    github_revoked: tokio::sync::Notify,
    /// The cmux sign-in the app lent this daemon, for an App token when `gh` has no keyring
    /// login (`github_app_token.rs`); set once by the hub.
    github_app: std::sync::OnceLock<Arc<crate::github_app_token::AppLease>>,
    /// Whether the peer takes `_acpmux/file_put` (`hub/file_uploads.rs`).
    file_put: AtomicBool,
    /// It lists `filePutChunks` (`hub/file_uploads.rs`).
    file_put_chunks: AtomicBool,
    /// Whether the peer serves `_acpmux/media_open` and `_acpmux/media_range` (`hub/media_read.rs`).
    media_read: AtomicBool,
    /// Bumped each time a connection to the peer ends (and at `stop`): what the peer kept for
    /// the connection, like its media handles, went with it (`server/media_forward.rs`).
    link_epoch: AtomicU64,
    /// Whether the peer serves `_acpmux/subagent_transcript` (`hub/subagent_transcript.rs`).
    subagent_transcript: AtomicBool,
    /// Whether the peer serves `_acpmux/native_history` (`hub/native_history.rs`).
    native_history: AtomicBool,
    /// The peer lists `sessionAuth` (`hub/session_auth.rs`).
    session_auth: AtomicBool,
    /// The features the peer listed at its last handshake (`lists`).
    features: StdMutex<Vec<String>>,
    /// One more than the link epoch whose handshake listed `sessionResume`
    /// (`server/requests/session_open.rs`); 0 when the last handshake did not.
    session_resume_link: AtomicU64,
    /// The peer lists `session-messages-v1`: its prompt acceptances name the message they kept.
    session_messages: AtomicBool,
    /// The peer lists `personStop` (`server/requests/person_stop.rs`).
    pub(crate) person_stop: AtomicBool,
    /// The peer token was held back: the transport is plain `ws://` to a
    /// host that is not loopback (`carries_peer_token`). Logged once.
    withheld: AtomicBool,
    /// The peer token this connection presented (`stale_token`).
    presented: StdMutex<Option<String>>,
    /// From the WebSocket opening until `stale_token` cleared it: callers'
    /// requests and notifications are refused, so none goes out on a link
    /// that is dropped to reconnect as a peer, or waits to go out on the next.
    admitting: AtomicBool,
    /// The chats local clients want streamed, each with the ticket of its latest mark: a client
    /// that relies on a mark already there renews it, so an attach refused meanwhile does not
    /// take it away (`attach_hidden`).
    attached: StdMutex<HashMap<String, u64>>,
    marks: AtomicU64,
    notices: mpsc::Sender<(String, u64, PeerNotice)>,
    stop: AtomicBool,
    /// A replacement requested now attempts immediately, even if its cache is parked.
    retry_immediately: AtomicBool,
    /// Wakes `serve` so `stop` closes the live connection.
    stop_signal: Notify,
    /// A client waits on the peer: reconnects come within seconds (`peer_wanted.rs`).
    wanted: wanted::Wanted,
    /// Counts connect attempts that settled (ready or failed), bumped by the
    /// hub once it applied the outcome, so a caller can await the next one.
    settled: tokio::sync::watch::Sender<u64>,
    /// Connected, degraded or reconnecting, and since when (`peer_link.rs`).
    link: StdMutex<Link>,
    /// Where each change of `state()` goes once the hub runs the peer (`report_states`).
    states: StdMutex<Option<Arc<crate::peer_states::PeerStates>>>,
    timings: LinkTimings,
    /// When the hub last saved this peer's sessions (`hub/peer_cache.rs`).
    pub(crate) cache_saved_at: AtomicU64,
    /// The last successful cache write still records an outage that Connected must clear.
    pub(crate) cache_saved_outage: AtomicBool,
    /// This instance's outage outlived its grace and its rows went unreachable
    /// (`hub/peer_grace.rs`). Kept here, not in the notice loop, so it goes with the instance.
    pub(crate) outage_ended: AtomicBool,
    /// The sessions this instance's link purged before its list (`hub/purge_tombstones.rs`).
    pub(crate) purge_tombstones: crate::hub::purge_tombstones::PurgeTombstones,
    /// The peer's last `_acpmux/host_health` and when it came (`peer_health.rs`).
    health: StdMutex<Option<(u64, Value)>>,
    /// An ask for it is out.
    health_asking: AtomicBool,
    /// The pending key of the handshake's `_acpmux/watch`, or of a page of its list
    /// (`watch_request_on`). The reader publishes that reply's list itself, before it reads the
    /// next frame, so a `session_changed` the peer sent after the reply reaches the hub after
    /// the list, never before it. A list in pages is published once, whole, after its last.
    watch_key: StdMutex<Option<String>>,
    /// Whether the peer answers a watch's `known` with a delta, and the rows the last list read
    /// held (`watch_delta.rs`).
    watch_delta: AtomicBool,
    known: StdMutex<crate::watch_delta::Known>,
    /// Whether the list `known` holds was read with tools: a delta is asked for the same way.
    known_tools: AtomicBool,
    /// This link's messages from the peer so far: the bytes of their frames, and of their JSON
    /// text (more when the peer compresses them, `frame_compress.rs`).
    received: ReceivedBytes,
}

/// What a link received: frame bytes and JSON text bytes, from its open.
#[derive(Debug, Default)]
pub struct ReceivedBytes {
    frames: AtomicU64,
    text: AtomicU64,
}

impl ReceivedBytes {
    fn reset(&self) {
        self.frames.store(0, Ordering::SeqCst);
        self.text.store(0, Ordering::SeqCst);
    }

    fn add(&self, frame: usize, text: usize) {
        let n = |b: usize| u64::try_from(b).unwrap_or(u64::MAX);
        self.frames.fetch_add(n(frame), Ordering::SeqCst);
        self.text.fetch_add(n(text), Ordering::SeqCst);
    }

    /// (frame bytes, text bytes) since the link opened.
    pub fn read(&self) -> (u64, u64) {
        (self.frames.load(Ordering::SeqCst), self.text.load(Ordering::SeqCst))
    }
}

impl Peer {
    pub fn new(
        name: &str,
        url: &str,
        token: Option<String>,
        peer_token: Option<String>,
        notices: mpsc::Sender<(String, u64, PeerNotice)>,
    ) -> Arc<Self> {
        let (out, out_rx) = mpsc::channel(1024);
        Arc::new(Self {
            name: name.to_owned(),
            generation: NEXT_GENERATION.fetch_add(1, Ordering::SeqCst),
            url: url.to_owned(),
            token,
            peer_token,
            tunnel: Mutex::new(None),
            wireguard: std::sync::OnceLock::new(),
            out,
            out_rx: Mutex::new(Some(out_rx)),
            next_id: AtomicI64::new(1),
            pending: Arc::new(Mutex::new(HashMap::new())),
            on_wire: Default::default(),
            connected: AtomicBool::new(false),
            open: AtomicBool::new(false),
            last_error: StdMutex::new(None),
            remote_version: StdMutex::new(None),
            row_pages_for: StdMutex::new(None),
            served_as: StdMutex::new(None),
            person_instance: StdMutex::new(None),
            trust_gate: AtomicBool::new(false),
            vm_boundary: AtomicBool::new(false),
            github_broker: AtomicBool::new(false),
            github_slots: crate::github_broker::owner_slots(name),
            github_link: AtomicU64::new(0),
            github_revoked: tokio::sync::Notify::new(),
            github_app: std::sync::OnceLock::new(),
            file_put: AtomicBool::new(false),
            file_put_chunks: AtomicBool::new(false),
            media_read: AtomicBool::new(false),
            link_epoch: AtomicU64::new(0),
            subagent_transcript: AtomicBool::new(false),
            native_history: AtomicBool::new(false),
            session_auth: AtomicBool::new(false),
            features: StdMutex::new(Vec::new()),
            session_resume_link: AtomicU64::new(0),
            session_messages: AtomicBool::new(false),
            person_stop: AtomicBool::new(false),
            withheld: AtomicBool::new(false),
            presented: StdMutex::new(None),
            admitting: AtomicBool::new(false),
            attached: StdMutex::new(HashMap::new()),
            marks: AtomicU64::new(0),
            notices,
            stop: AtomicBool::new(false),
            retry_immediately: AtomicBool::new(false),
            stop_signal: Notify::new(),
            wanted: Default::default(),
            settled: tokio::sync::watch::channel(0).0,
            link: StdMutex::new(Link::default()),
            states: StdMutex::new(None),
            timings: LinkTimings::from_env(),
            cache_saved_at: AtomicU64::new(0),
            cache_saved_outage: AtomicBool::new(false),
            outage_ended: AtomicBool::new(false),
            purge_tombstones: Default::default(),
            health: StdMutex::new(None),
            health_asking: AtomicBool::new(false),
            watch_key: StdMutex::new(None),
            watch_delta: AtomicBool::new(false),
            known: StdMutex::new(crate::watch_delta::Known::default()),
            known_tools: AtomicBool::new(false),
            received: ReceivedBytes::default(),
        })
    }

    pub(crate) fn set_wireguard(
        &self,
        transport: Arc<crate::wireguard::Transport>,
        address: std::net::SocketAddr,
    ) {
        let _ = self.wireguard.set((transport, address));
    }

    /// What the current (or last) link received (`ReceivedBytes`).
    pub fn received(&self) -> &ReceivedBytes {
        &self.received
    }

    pub fn link(&self) -> Link {
        self.link.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Every change of the link's state goes through here, so each one sends its note
    /// (`report_states`) from the code that made it: no timer, no polling, no repeats.
    fn with_link<T>(&self, f: impl FnOnce(&mut Link) -> T) -> T {
        let mut link = self.link.lock().unwrap_or_else(|e| e.into_inner());
        let out = f(&mut link);
        self.note_state(&link);
        out
    }

    /// This instance speaks for its name in `states` (the hub's, `Hub::spawn_peer`) from now
    /// on: its state now, then each change (`_acpmux/peer_state_changed`). Once it is replaced
    /// or removed, `states` drops what it says.
    pub fn report_states(&self, states: Arc<crate::peer_states::PeerStates>) {
        let link = self.link.lock().unwrap_or_else(|e| e.into_inner());
        states.register(&self.name, self.generation, self.observed(&link));
        *self.states.lock_or_recover() = Some(states);
    }

    /// Called with `link` locked, so the notes go out in the order of the changes.
    fn note_state(&self, link: &Link) {
        // A stopped instance's link going down is not news: its replacement or its removal
        // speaks for the name next.
        if self.stop.load(Ordering::SeqCst) {
            return;
        }
        let Some(states) = self.states.lock_or_recover().clone() else { return };
        states.changed(&self.name, self.generation, self.observed(link));
    }

    fn observed(&self, link: &Link) -> crate::peer_states::Observed {
        crate::peer_states::Observed {
            state: link.state().wire(),
            last_seen: link.last_seen,
            error: self.last_error.lock_or_recover().clone(),
        }
    }

    pub fn state(&self) -> PeerState {
        self.link().state()
    }

    /// Carry the live instance being replaced. Replacing a peer is an explicit retry,
    /// including when that instance never reached it; automatic boot uses the cache path.
    pub fn seed_last_seen(&self, last_seen: Option<u64>) {
        self.retry_immediately.store(true, Ordering::SeqCst);
        self.with_link(|l| l.seed(last_seen));
    }

    /// What its last handshake would have said of attachments: a test's peer that never ran.
    #[cfg(test)]
    pub(crate) fn seed_send_attach(&self, takes: bool) {
        let mut features = self.features.lock_or_recover();
        features.retain(|f| f != crate::attach::FEATURE);
        if takes {
            features.push(crate::attach::FEATURE.to_owned());
        }
    }

    /// What its last handshake listed (`lists`): a test's peer that never ran.
    #[cfg(test)]
    pub(crate) fn seed_features(&self, features: &[&str]) {
        *self.features.lock_or_recover() = features.iter().map(|f| (*f).to_owned()).collect();
    }

    pub(crate) fn seed_cached_link(
        &self,
        last_seen: Option<u64>,
        down_since: Option<u64>,
        next_retry_at: Option<u64>,
    ) {
        self.with_link(|l| {
            l.seed(last_seen);
            l.seed_outage(down_since);
            if l.attempts == 0 && !l.is_ready() {
                l.next_retry_at = next_retry_at;
            }
        });
    }

    /// Restore explicit outage age independently of a possibly old session-cache lastSeen.
    #[cfg(test)]
    pub(crate) fn seed_outage(&self, down_since: Option<u64>) {
        self.with_link(|l| l.seed_outage(down_since));
    }

    /// One failed connect attempt, counted as `finish_link` counts it.
    #[cfg(test)]
    pub(crate) fn count_failed_attempt(&self) {
        self.with_link(|l| l.down(crate::store::now_ms(), self.timings.stable_after));
    }

    /// The refusal for a request while the link is down (`peer_link.rs`).
    pub fn unreachable_error(&self) -> RpcError {
        let error = self.last_error.lock().unwrap_or_else(|e| e.into_inner()).clone();
        crate::peer_link::unreachable_error(
            &self.name,
            &self.link(),
            error.as_deref(),
            crate::store::now_ms(),
        )
    }

    /// Receives every later settled connect attempt.
    pub fn settled(&self) -> tokio::sync::watch::Receiver<u64> {
        self.settled.subscribe()
    }

    /// The hub applied a connect outcome (sessions listed, or the error).
    pub fn mark_settled(&self) {
        self.settled.send_modify(|count| *count += 1);
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        self.link_ended();
        // Stores a permit when `serve` is not waiting yet.
        self.stop_signal.notify_one();
        if let Ok(mut t) = self.tunnel.try_lock() {
            if let Some(child) = t.as_mut() {
                let _ = child.start_kill();
            }
            *t = None;
        }
    }

    /// `ssh://user@host[:port]` -> (ssh destination, remote port); None for
    /// any other scheme and for an ssh URL `ssh_target` refuses.
    fn ssh_parts(&self) -> Option<(String, u16)> {
        let t = ssh_target(&self.url).ok()?;
        Some((t.destination, t.port))
    }

    /// Open an `ssh -W` stdio channel to the peer's WebSocket port. The
    /// connection runs over ssh's stdin and stdout, so there is no local port
    /// to wait for: the WebSocket handshake itself says whether it works.
    async fn open_tunnel(
        &self,
    ) -> Result<
        (
            tokio::io::Join<tokio::process::ChildStdout, tokio::process::ChildStdin>,
            u16,
            ssh_errors::Capture,
        ),
        String,
    > {
        let (host, remote_port) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        let mut child = tokio::process::Command::new("ssh")
            .args(tunnel_argv(&host, remote_port))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("spawn ssh: {e}"))?;
        let errors = ssh_errors::Capture::start(child.stderr.take());
        let stdout = child.stdout.take().ok_or_else(|| "ssh stdout".to_owned())?;
        let stdin = child.stdin.take().ok_or_else(|| "ssh stdin".to_owned())?;
        // Replacing the previous channel ends its ssh process.
        *self.tunnel.lock().await = Some(child);
        Ok((tokio::io::join(stdout, stdin), remote_port, errors))
    }

    /// The dashboard token (configured, else the remote daemon's own) and
    /// the remote daemon's peer token of this launch (configured, else none
    /// when the remote has none: an older daemon serves this one as Web),
    /// read over the same ssh access at each connect.
    async fn remote_tokens(&self) -> Result<(String, Option<String>), String> {
        let (host, _) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        if let (Some(t), Some(p)) = (&self.token, &self.peer_token) {
            return Ok((t.clone(), Some(p.clone())));
        }
        let mut child = tokio::process::Command::new("ssh")
            .args(read_config_argv(&host))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("read remote config: {e}"))?;
        let errors = ssh_errors::Capture::start(child.stderr.take());
        let read = child.wait_with_output();
        let out = tokio::time::timeout(self.timings.connect, read)
            .await
            .map_err(|_| {
                format!(
                    "reading the remote config timed out after {}s",
                    self.timings.connect.as_secs()
                )
            })?
            .map_err(|e| format!("read remote config: {e}"))?;
        // The read ends with the token `cat`, which fails when there is no
        // token: only an empty answer is a failed ssh.
        if out.stdout.is_empty() && !out.status.success() {
            return Err(ssh_errors::describe(
                format!("ssh to {host} failed ({})", out.status),
                errors.finish().await,
            ));
        }
        let (config, peer) = split_remote_read(&out.stdout);
        let peer = self.peer_token.clone().or(peer);
        if let Some(t) = &self.token {
            return Ok((t.clone(), peer));
        }
        let remote = remote_daemon_config(config).map_err(|why| match why {
            RemoteConfigError::Unreadable => {
                format!("remote {host} has no readable ~/.acpmux/config.json")
            }
            RemoteConfigError::NoToken => format!("remote {host} config has no websocket token"),
        })?;
        Ok((remote.token, peer))
    }

    /// `remote_tokens`, read again (`TOKEN_REREADS`) while the remote has
    /// no peer token: a daemon that is starting listens a few seconds before
    /// it writes `run/peer.token`, and the one that stopped removed its own.
    /// A connect inside that window would be served as Web, holding every
    /// prompt to the Web's rules until the link next drops. A remote too old
    /// to make a token has none after the rereads and is served as Web.
    async fn remote_tokens_settled(&self) -> Result<(String, Option<String>), String> {
        const STOPPED: &str = "peer stopped";
        if self.stop.load(Ordering::SeqCst) {
            return Err(STOPPED.to_owned());
        }
        let mut tokens = self.remote_tokens().await?;
        for wait in TOKEN_REREADS {
            if tokens.1.is_some() {
                break;
            }
            if !self.reread_wait(wait).await {
                return Err(STOPPED.to_owned());
            }
            tokens = self.remote_tokens().await?;
        }
        Ok(tokens)
    }

    /// Sleeps `wait` before a token reread; false, at once, when the peer
    /// stops (before or during it), so no further ssh read is made.
    async fn reread_wait(&self, wait: Duration) -> bool {
        if self.stop.load(Ordering::SeqCst) {
            return false;
        }
        tokio::select! {
            _ = tokio::time::sleep(wait) => {}
            _ = self.stop_signal.notified() => {
                // Put the permit back for `run` and `serve`, which wait on it too.
                self.stop_signal.notify_one();
            }
        }
        !self.stop.load(Ordering::SeqCst)
    }

    /// Why an `ssh://` connection the remote served as Web should connect
    /// again: the remote has a peer token now that this connection did not
    /// present (it restarted between the token read and the handshake, or
    /// had not written its token yet). One read per such connection, and
    /// rereads (`TOKEN_REREADS`) while the remote has no token (it is
    /// restarting, or wrote it after this connection's last read), all
    /// before the link is admitted, so a live link is never torn down for a
    /// late token; None when it was served as a peer, when a read fails, on
    /// stop, or when the remote still has no token or the same one (it
    /// serves this daemon as Web for another reason, and reconnecting would
    /// not change that).
    async fn stale_token(&self) -> Option<String> {
        self.ssh_parts()?;
        let served_as_web =
            self.served_as.lock().unwrap_or_else(|e| e.into_inner()).as_deref() == Some("remote");
        if !served_as_web {
            return None;
        }
        let presented = self.presented.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if self.stop.load(Ordering::SeqCst) {
            return None;
        }
        let (_, mut now) = self.remote_tokens().await.ok()?;
        for wait in TOKEN_REREADS {
            if now.is_some() {
                break;
            }
            if !self.reread_wait(wait).await {
                return None;
            }
            now = self.remote_tokens().await.ok()?.1;
        }
        (now.is_some() && now != presented).then(|| {
            "the peer served this daemon as remote, and it has a new peer token; reconnecting"
                .to_owned()
        })
    }

    /// How the peer said at its last handshake that it serves this daemon: `peer`, `remote`
    /// (as a Web client), or None from a peer too old to say.
    pub fn served_as(&self) -> Option<String> {
        self.served_as.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn remote_build(&self) -> Option<String> {
        self.remote_version.lock_or_recover().as_ref().map(|(_, b)| b.clone())
    }

    /// The daemon run the peer named at its last handshake.
    pub fn person_instance(&self) -> Option<String> {
        self.person_instance.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Set before the peer runs (`Hub::spawn_peer`), from its config or lease.
    pub fn set_vm_boundary(&self, on: bool) {
        self.vm_boundary.store(on, Ordering::SeqCst);
    }

    /// Whether this caller opts its remote chains on the peer out of the sandbox.
    pub fn vm_boundary(&self) -> bool {
        self.vm_boundary.load(Ordering::SeqCst)
    }

    /// From its config (`Hub::spawn_peer`, a reload): whether this Mac lends the peer its
    /// GitHub login. Read again for each action, so turning it off holds at once.
    pub fn set_github_broker(&self, on: bool) {
        self.github_broker.store(on, Ordering::SeqCst);
        if !on {
            self.github_revoked.notify_waiters();
        }
    }

    /// Whether this Mac lends the peer GitHub now: its config says so, and the link is one an
    /// on-path machine cannot pose as (`lends_over`).
    pub fn github_broker(&self) -> bool {
        self.github_broker.load(Ordering::SeqCst) && lends_over(&self.url)
    }

    /// The hub's lent cmux sign-in (`github_app_token.rs`).
    pub fn set_github_app(&self, app: Arc<crate::github_app_token::AppLease>) {
        let _ = self.github_app.set(app);
    }

    /// Whether the link `link` (the epoch it was read on) takes a GitHub action now: lent, the
    /// peer not stopped, `link` still the live one, and its handshake finished with the peer
    /// serving this daemon as a peer (not Web), so nothing sent before or around it is.
    fn github_ready(&self, link: u64) -> bool {
        self.github_broker()
            && !self.stop.load(Ordering::SeqCst)
            && self.link_epoch() == link
            && self.github_link.load(Ordering::SeqCst) == link + 1
    }

    /// The peer's daemon asked for a GitHub action (`github_broker.rs`) and `admit_owner` let it
    /// in on `link` (the epoch it was read on): run it, and answer on that link, never on a
    /// later one.
    fn serve_github_action(
        self: &Arc<Self>,
        id: Value,
        params: Value,
        slot: tokio::sync::OwnedSemaphorePermit,
        link: u64,
    ) {
        let me = self.clone();
        let epoch = link;
        // The slot is held until the answer is queued, within the request budget: at most
        // `OWNER_SLOTS` of these tasks exist per peer name, across reconnects, even when the link
        // stops reading.
        tokio::spawn(async move {
            // Lending that ends while it runs (`githubBroker` off, the peer removed, the link
            // ended) stops it: its `gh` is killed (`kill_on_drop`), and a link still up is told.
            let revoked = me.github_revoked.notified();
            tokio::pin!(revoked);
            revoked.as_mut().enable();
            // Lending that ended between the admission and here (the link ended, the peer was
            // stopped or removed, `githubBroker` off) starts nothing.
            if !me.github_ready(epoch) {
                return;
            }
            let app = me.github_app.get().map(Arc::as_ref);
            let reply = tokio::select! {
                reply = crate::github_broker::serve_owner(&me.name, params, app) => reply,
                () = &mut revoked => {
                    let Err(e) = crate::github_broker::admit_owner(&me.name, false, &me.github_slots) else {
                        return;
                    };
                    Err(e)
                }
            };
            let msg = match reply {
                Ok(v) => Message::ok(id, v),
                Err(e) => Message::err(id, e),
            };
            let reply_to = Some(crate::rpc::method::MUX_GITHUB_ACTION);
            if let Ok(line) = msg.bounded_line_replying(reply_to) {
                let frame = Outbound { epoch, key: None, line };
                let _ = tokio::time::timeout(me.timings.request, me.out.send(frame)).await;
            }
            drop(slot);
        });
    }

    /// Which connection to the peer this is: it changes when a connection ends or the peer stops.
    pub fn link_epoch(&self) -> u64 {
        self.link_epoch.load(Ordering::SeqCst)
    }

    /// A connection to the peer ended: what the peer kept for it is gone.
    pub(crate) fn link_ended(&self) {
        self.features.lock_or_recover().clear();
        self.link_epoch.fetch_add(1, Ordering::SeqCst);
        self.github_revoked.notify_waiters();
    }

    /// The WebSocket is open and the handshake has not finished.
    pub fn handshaking(&self) -> bool {
        self.open.load(Ordering::SeqCst) && !self.connected.load(Ordering::SeqCst)
    }

    pub fn summary(&self) -> Value {
        let link = self.link();
        let (health, health_at) = self.health_summary();
        json!({
            "name": self.name,
            "url": self.url,
            "connected": self.connected.load(Ordering::SeqCst),
            "handshaking": self.handshaking(),
            "error": self.last_error.lock_or_recover().clone(),
            "remoteVersion": self.remote_version.lock_or_recover().as_ref().map(|(v, _)| v.clone()),
            "remoteBuild": self.remote_version.lock_or_recover().as_ref().map(|(_, b)| b.clone()),
            "localBuild": crate::hub::build(),
            "servedAs": self.served_as.lock().unwrap_or_else(|e| e.into_inner()).clone(),
            "peerTokenWithheld": self.withheld.load(Ordering::SeqCst),
            "canonicalEndpoint": canonical_endpoint(&self.url),
            "outdated": self.remote_version.lock_or_recover().as_ref().map(|(_, b)| b != crate::hub::build()).unwrap_or(false),
            "state": link.state().as_str(),
            "lastSeen": link.last_seen,
            "downSince": link.down_since,
            "attempts": link.attempts,
            "health": health,
            "healthAt": health_at,
        })
    }

    /// Remember that local clients want this session's stream, so it is
    /// re-attached after a reconnect. True when it was not marked yet; a mark already there is
    /// renewed, since this caller now relies on it.
    pub fn mark_attached(&self, session_id: &str) -> bool {
        // The ticket is taken under the lock, so a later mark always holds a newer one.
        let mut marks = self.attached.lock_or_recover();
        let ticket = self.marks.fetch_add(1, Ordering::SeqCst) + 1;
        marks.insert(session_id.to_owned(), ticket).is_none()
    }

    /// The link's own attach of the peer's chat `id` ([`hidden_attach`]), marked already. Its
    /// error goes to the log at warn: a chat whose attach failed got no stream, and said
    /// nothing of why. One the peer refused ([`refuses_attach`]: the chat is gone there, or the
    /// peer takes no such attach) is no longer marked, so no reconnect asks for it again and the
    /// next prompt attaches it anew, unless a client marked it again while this attach was out:
    /// that client relies on the mark. Any other failure (the link dropped, a timeout, a full
    /// queue) keeps the mark, and the next link's handshake attaches it again.
    pub async fn attach_hidden(&self, id: &str) -> Result<Value, RpcError> {
        let ticket = self.attached.lock_or_recover().get(id).copied();
        let attached = self.request(method::MUX_ATTACH, hidden_attach(id)).await;
        if let Err(e) = &attached {
            let refused = refuses_attach(e);
            if refused {
                let mut marks = self.attached.lock_or_recover();
                if marks.get(id).copied() == ticket {
                    marks.remove(id);
                }
            }
            tracing::warn!(peer = %self.name, session = %id, refused, "the peer's chat was not attached, so it streams nothing until it is again: {}", e.message);
        }
        attached
    }

    /// How many requests wait for the peer's answer now.
    pub async fn pending_requests(&self) -> usize {
        self.pending.lock().await.len()
    }

    pub async fn request(&self, m: &str, params: Value) -> Result<Value, RpcError> {
        self.request_on(m, params, None).await
    }

    /// `request` on the link of epoch `epoch` only, when the caller read it before (it labels
    /// what the answer holds with it, `hub/peer_snapshot.rs`): unreachable once that link ended.
    pub async fn request_on(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
    ) -> Result<Value, RpcError> {
        // Read before the check: `run` moves the epoch on before it fails what
        // waits, so a request that is registered after that sees the change.
        let epoch = epoch.unwrap_or_else(|| self.link_epoch());
        if !self.connected.load(Ordering::SeqCst) || self.admitting.load(Ordering::SeqCst) {
            return Err(self.unreachable_error());
        }
        self.link_request_on(m, params, Some(epoch)).await
    }

    /// Sends `m` on the link of epoch `epoch` (any link when None), with no check that the
    /// handshake finished: the handshake's own requests go out through here.
    async fn link_request_on(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
    ) -> Result<Value, RpcError> {
        self.send_request(m, params, epoch, false).await
    }

    /// [`Self::link_request_on`] for the handshake's watch list on link `link`, its
    /// `_acpmux/watch` or a page after it: the reader takes the reply's rows (`watch_key`).
    async fn watch_request_on(&self, m: &str, params: Value, link: u64) -> Result<Value, RpcError> {
        self.send_request(m, params, Some(link), true).await
    }

    async fn send_request(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
        watch: bool,
    ) -> Result<Value, RpcError> {
        // One deadline from here: a request that waits for room in the queue (a stalled link,
        // or a full queue ahead of it) times out on the schedule of one the peer is slow to
        // answer, never later.
        let started = tokio::time::Instant::now();
        let deadline = started + self.timings.request;
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        let key = Value::from(id).to_string();
        self.pending.lock().await.insert(key.clone(), tx);
        // A request that times out, or whose caller stops waiting, takes its
        // entry with it rather than leaving it until the connection drops.
        let _forget = ForgetPending {
            pending: self.pending.clone(),
            on_wire: self.on_wire.clone(),
            key: Some(key.clone()),
        };
        // The link it was admitted on went down before it was registered: `run`
        // already failed what waited, and the next link drops its frame, so a
        // prompt (which has no deadline) would wait for good.
        if epoch.is_some_and(|e| e != self.link_epoch() || !self.open.load(Ordering::SeqCst)) {
            return Err(self.unreachable_error());
        }
        // Only on its own link, checked again under the lock: a request of a link gone down
        // (whose task may still run after its abort) never takes the key of the next link's
        // list. The next handshake sets its key after the epoch moved on, under the same lock.
        if watch {
            let mut held = self.watch_key.lock_or_recover();
            if epoch.is_some_and(|e| e != self.link_epoch()) {
                return Err(self.unreachable_error());
            }
            *held = Some(key.clone());
        }
        // One frame larger than the peer reads with would drop the link and every chat on it.
        let line = Message::request(id, m, params).bounded_line().map_err(RpcError::too_large)?;
        let tag = epoch.unwrap_or_else(|| self.link_epoch());
        let frame = Outbound { epoch: tag, key: Some(key), line };
        match tokio::time::timeout_at(deadline, self.out.send(frame)).await {
            Ok(Ok(())) => {}
            Ok(Err(_)) => {
                return Err(RpcError::internal(format!("peer {} connection closed", self.name)));
            }
            Err(_) => return Err(queue_timed_out(&self.name, started.elapsed())),
        }
        // A prompt or a wait answers when the peer's turn ends, however long that is; the
        // keepalive drops a link that stops answering, which fails it as `peer disconnected`,
        // and a forwarder whose client left drops it (`server/peer_forward.rs`).
        let answer = if waits_on_turn(m) {
            Ok(rx.await)
        } else {
            tokio::time::timeout_at(deadline, rx).await
        };
        match answer {
            // A full disk the peer reports is the peer's, not this machine's (`recovery.rs`).
            // No display line of the peer's own reaches this daemon's clients, on any route that
            // returns a peer's reply or its error's data (`hub::drop_display_lines`).
            Ok(Ok(r)) => r
                .map(|mut result| {
                    crate::hub::drop_display_lines(&mut result);
                    result
                })
                .map_err(|mut e| {
                    crate::recovery::annotate_peer(&mut e, &self.name);
                    if let Some(data) = e.data.as_mut() {
                        crate::hub::drop_display_lines(data);
                    }
                    e
                }),
            Ok(Err(_)) => {
                Err(RpcError::internal(format!("peer {} dropped the request", self.name)))
            }
            Err(_) => Err(RpcError::internal(format!(
                "peer {} timed out after {}s",
                self.name,
                started.elapsed().as_secs()
            ))),
        }
    }

    pub async fn notify(&self, m: &str, params: Value) -> Result<(), RpcError> {
        // Read before the check, as in `request`: a frame tagged with a link
        // that went down is dropped by `serve`, never sent on the next one.
        let epoch = self.link_epoch();
        if !self.connected.load(Ordering::SeqCst) || self.admitting.load(Ordering::SeqCst) {
            return Err(self.unreachable_error());
        }
        let line = Message::notification(m, params).bounded_line().map_err(RpcError::too_large)?;
        let started = tokio::time::Instant::now();
        let frame = Outbound { epoch, key: None, line };
        match tokio::time::timeout(self.timings.request, self.out.send(frame)).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(_)) => Err(RpcError::internal(format!("peer {} connection closed", self.name))),
            Err(_) => Err(queue_timed_out(&self.name, started.elapsed())),
        }
    }

    /// Run the connect loop until `stop`.
    pub async fn run(self: Arc<Self>) {
        let mut backoff = Backoff::default();
        let Some(mut out_rx) = self.out_rx.lock().await.take() else {
            // A second run: the first owns the outbound queue and the link.
            tracing::warn!(peer = %self.name, "peer link already running");
            return;
        };
        if !self.retry_immediately.load(Ordering::SeqCst)
            && let Some(wait) = self.link().parked_retry_wait(crate::store::now_ms())
        {
            let reason = format!("peer unavailable; next automatic retry in {}s", wait.as_secs());
            *self.last_error.lock_or_recover() = Some(reason.clone());
            self.with_link(|_| ());
            // Settle startup watchers now; no SSH is spawned just because this daemon updated.
            let _ = self
                .notices
                .send((self.name.clone(), self.generation, PeerNotice::Disconnected(reason)))
                .await;
            // Sleep-aware, like the reconnect backoff: a wake past the saved deadline tries now.
            if matches!(self.wait_backoff(wait).await, BackoffWait::Stopped) {
                return;
            }
        }
        while !self.stop.load(Ordering::SeqCst) {
            let outcome = self.connect_once(&mut out_rx).await;
            let restarting = matches!(&outcome, Ok(LinkEnd::Restarting));
            let notice = self.finish_link(outcome, &mut backoff);
            // A peer down for a day or more is parked on an hourly retry (`PeerLink::retry_delay`).
            // Scheduled before the notice goes out: the hub saves `next_retry_at` to the peer
            // cache while handling it, so a daemon restart mid-wait keeps the parked deadline.
            let delay = (!restarting).then(|| {
                self.with_link(|l| {
                    l.schedule_retry(
                        &mut backoff,
                        crate::store::now_ms(),
                        crate::peer_link::jitter(),
                    )
                })
            });
            if let Some(notice) = notice {
                let _ = self.notices.send((self.name.clone(), self.generation, notice)).await;
            }
            self.fail_link_requests(&mut out_rx).await;
            if self.stop.load(Ordering::SeqCst) {
                break;
            }
            // One immediate attempt for this Close 1012. If that attempt fails, it follows
            // the unchanged real-failure backoff; restarting is not a persistent retry mode.
            let Some(delay) = delay else {
                continue;
            };
            match self.wait_backoff(delay).await {
                BackoffWait::Done => {}
                // The network that failed before the sleep may take a moment to come back: the
                // next attempts are quick ones again.
                BackoffWait::Woke => backoff.reset(),
                BackoffWait::Stopped => break,
            }
        }
    }

    /// Publish the link ending before settling requests. Restart neither increments failed
    /// attempts nor draws from backoff; it starts backoff over when the previous link was stable.
    fn finish_link(
        &self,
        outcome: Result<LinkEnd, String>,
        backoff: &mut Backoff,
    ) -> Option<PeerNotice> {
        *self.last_error.lock_or_recover() = outcome.as_ref().err().cloned();
        self.link_ending(matches!(&outcome, Ok(LinkEnd::Restarting)));
        // The epoch moves first: a finishing handshake cannot leave a dead link ready.
        self.link_ended();
        self.open.store(false, Ordering::SeqCst);
        self.connected.store(false, Ordering::SeqCst);
        if matches!(&outcome, Ok(LinkEnd::Restarting)) {
            // The peer's daemon restarts (an update): a stable link's backoff starts over, as at
            // its drop, or each restart's failures add up and the next waits out a minute.
            let now = crate::store::now_ms();
            if self.link().ready_for(now).is_some_and(|up| up >= self.timings.stable_after) {
                backoff.reset();
            }
            self.with_link(|l| l.restarting(now));
            return Some(PeerNotice::Restarting);
        }
        // A genuinely stable link starts failure backoff over; a flapping one does not.
        if self.with_link(|l| l.down(crate::store::now_ms(), self.timings.stable_after)) {
            backoff.reset();
        }
        outcome.err().map(PeerNotice::Disconnected)
    }

    /// The link ended. A request that never went out on it (still queued, or waiting for room
    /// in the queue) fails as not sent (`peer_unreachable`, retryable), and its frame is dropped,
    /// never sent on the next link. One that went out fails as `peer_disconnected`: the peer
    /// may have run it.
    async fn fail_link_requests(&self, out_rx: &mut mpsc::Receiver<Outbound>) {
        let mut pending = self.pending.lock().await;
        while out_rx.try_recv().is_ok() {}
        let on_wire = std::mem::take(&mut *self.on_wire.lock_or_recover());
        for (key, tx) in pending.drain() {
            let _ = tx.send(Err(if on_wire.contains(&key) {
                RpcError::internal("peer disconnected").with_data(json!({
                    "reason": "peer_disconnected",
                    "detail": "the request went out before the link dropped; the peer may have run it",
                    "peer": self.name,
                }))
            } else {
                self.unreachable_error()
            }));
        }
    }

    async fn connect_once(
        self: &Arc<Self>,
        out_rx: &mut mpsc::Receiver<Outbound>,
    ) -> Result<LinkEnd, String> {
        // An SSH peer may source this launch's application credentials over
        // SSH. Resolve them before WG too, or a remote-origin handshake can
        // reread a newer peer token and reconnect forever with the old one.
        let ssh_tokens = if self.wireguard.get().is_some() && self.ssh_parts().is_some() {
            Some(self.remote_tokens_settled().await?)
        } else {
            None
        };
        let credentials = ssh_tokens
            .as_ref()
            .map(|(token, peer)| (token.as_str(), peer.as_deref()))
            .or_else(|| self.token.as_deref().map(|token| (token, self.peer_token.as_deref())));
        if let Some((transport, address)) = self.wireguard.get()
            && let Some((token, peer_token)) = credentials
        {
            let req = self.ws_request(
                &format!("ws://localhost:{}", address.port()),
                Some(token),
                peer_token,
            )?;
            let opening = async {
                let stream = transport.connect(*address).await.map_err(|e| e.to_string())?;
                tokio_tungstenite::client_async_with_config(
                    req,
                    stream,
                    Some(crate::server::ws_config()),
                )
                .await
                .map_err(|e| e.to_string())
            };
            let opened = tokio::select! {
                biased;
                _ = self.stop_signal.notified() => return Err("peer stopped".to_owned()),
                result = tokio::time::timeout(self.timings.connect, opening) => result,
            };
            if let Ok(Ok((ws, _))) = opened {
                *self.presented.lock().unwrap_or_else(|e| e.into_inner()) =
                    peer_token.map(str::to_owned);
                return self.serve(ws, out_rx).await;
            }
            tracing::debug!(peer = %self.name, "WireGuard unavailable; trying the configured peer route");
        }
        if self.ssh_parts().is_some() {
            let (token, peer_token) = match ssh_tokens {
                Some(tokens) => tokens,
                None => self.remote_tokens_settled().await?,
            };
            *self.presented.lock().unwrap_or_else(|e| e.into_inner()) = peer_token.clone();
            let (stream, remote_port, errors) = self.open_tunnel().await?;
            let outcome = async {
                let req = self.ws_request(
                    &format!("ws://127.0.0.1:{remote_port}"),
                    Some(&token),
                    peer_token.as_deref(),
                )?;
                // A peer forwards the pane's prompts and their images: the listener's limits.
                let (ws, _) = tokio::time::timeout(
                    self.timings.connect,
                    tokio_tungstenite::client_async_with_config(
                        req,
                        stream,
                        Some(crate::server::ws_config()),
                    ),
                )
                .await
                .map_err(|_| connect_timed_out(self.timings.connect))?
                .map_err(|e| e.to_string())?;
                self.serve(ws, out_rx).await
            }
            .await;
            // End the owned SSH process now, including when its next attempt is an hour away.
            if let Some(mut child) = self.tunnel.lock().await.take() {
                let _ = child.start_kill();
            }
            return match outcome {
                Ok(end) => Ok(end),
                Err(error) => Err(ssh_errors::describe(error, errors.finish().await)),
            };
        }
        *self.presented.lock().unwrap_or_else(|e| e.into_inner()) = None;
        // The peer token never crosses a network in clear.
        let peer_token = match self.peer_token.as_deref() {
            Some(_) if !carries_peer_token(&self.url) => {
                if !self.withheld.swap(true, Ordering::SeqCst) {
                    tracing::warn!(peer = %self.name, "the peer runs as remote (Web): its transport is plain ws:// to a host that is not loopback, so the peer token is not sent; use ssh:// or wss://");
                }
                None
            }
            other => other,
        };
        let req = self.ws_request(&self.url, self.token.as_deref(), peer_token)?;
        // A peer forwards the pane's prompts and their images: the listener's limits.
        let connect = tokio_tungstenite::connect_async_with_config(
            req,
            Some(crate::server::ws_config()),
            false,
        );
        let (ws, _) = tokio::time::timeout(self.timings.connect, connect)
            .await
            .map_err(|_| connect_timed_out(self.timings.connect))?
            .map_err(|e| e.to_string())?;
        self.serve(ws, out_rx).await
    }

    fn ws_request(
        &self,
        url: &str,
        token: Option<&str>,
        peer_token: Option<&str>,
    ) -> Result<tokio_tungstenite::tungstenite::handshake::client::Request, String> {
        let mut req = url.into_client_request().map_err(|e| e.to_string())?;
        if let Some(t) = token {
            req.headers_mut().insert(
                "authorization",
                format!("Bearer {t}").parse().map_err(|_| "bad token".to_owned())?,
            );
        }
        if let Some(p) = peer_token {
            req.headers_mut().insert(
                crate::server::peer_auth::HEADER,
                p.parse().map_err(|_| "bad peer token".to_owned())?,
            );
        }
        Ok(req)
    }

    /// Run one connected WebSocket until it closes.
    async fn serve<S>(
        self: &Arc<Self>,
        ws: tokio_tungstenite::WebSocketStream<S>,
        out_rx: &mut mpsc::Receiver<Outbound>,
    ) -> Result<LinkEnd, String>
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        use tokio_tungstenite::tungstenite::Message as Frame;
        let (mut sink, mut source) = ws.split();
        // Open, not connected: callers' requests are refused until the handshake finished
        // (`connected`), and only the handshake's own go out on this link (`link`).
        let link = self.link_epoch();
        self.admitting.store(true, Ordering::SeqCst);
        self.open.store(true, Ordering::SeqCst);
        *self.last_error.lock_or_recover() = None;
        self.received.reset();
        self.with_link(|l| l.opened(crate::store::now_ms()));
        tracing::info!(peer = %self.name, "link open to {}; handshaking", self.url);

        // Handshake in a task so the read loop below can serve the responses.
        let me = self.clone();
        let (stale_tx, mut stale_rx) = oneshot::channel::<String>();
        let mut handshake = tokio::spawn(async move {
            let mut hello = json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": CLIENT_NAME, "version": crate::hub::VERSION},
                // Large replies (the session list) may come compressed (`frame_compress.rs`).
                "_meta": {"acpmux": {"compression": crate::frame_compress::offer()}}});
            // This Mac lends the peer its GitHub login (`hub/github_owner.rs` on the peer).
            if me.github_broker() {
                hello.set_path(&["_meta", "acpmux", "githubBroker"], json!(true));
            }
            let init = me.link_request_on(method::INITIALIZE, hello, Some(link)).await?;
            let v = init
                .pointer("/_meta/acpmux/version")
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_owned();
            let b = init
                .pointer("/_meta/acpmux/build")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_owned();
            let build = (b != "unknown").then(|| b.clone());
            *me.remote_version.lock_or_recover() = Some((v, b));
            *me.served_as.lock().unwrap_or_else(|e| e.into_inner()) =
                init.pointer("/_meta/acpmux/origin").and_then(Value::as_str).map(str::to_owned);
            // Before any session is watched or attached on this link.
            if let Some(why) = me.stale_token().await {
                let _ = stale_tx.send(why);
                return Ok(());
            }
            me.admitting.store(false, Ordering::SeqCst);
            *me.person_instance.lock().unwrap_or_else(|e| e.into_inner()) = init
                .pointer("/_meta/acpmux/personInstance")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let lists = |feature: &str| {
                init.pointer("/_meta/acpmux/features")
                    .and_then(Value::as_array)
                    .is_some_and(|features| features.iter().any(|f| f.as_str() == Some(feature)))
            };
            let advertised = lists("trustGate")
                || init.pointer("/_meta/acpmux/trustGate").and_then(Value::as_bool) == Some(true);
            me.trust_gate.store(advertised, Ordering::SeqCst);
            let set =
                |flag: &AtomicBool, feature: &str| flag.store(lists(feature), Ordering::SeqCst);
            set(&me.file_put, crate::hub::FILE_PUT_FEATURE);
            set(&me.file_put_chunks, crate::hub::file_uploads::CHUNKS_FEATURE);
            set(&me.media_read, crate::hub::MEDIA_READ_FEATURE);
            set(&me.subagent_transcript, crate::hub::SUBAGENT_TRANSCRIPT_FEATURE);
            set(&me.native_history, crate::hub::NATIVE_HISTORY_FEATURE);
            set(&me.session_auth, crate::hub::session_auth::FEATURE);
            set(&me.person_stop, crate::hub::cancel::PERSON_STOP_FEATURE);
            set(&me.watch_delta, crate::watch_delta::FEATURE);
            // The rest are read from the list (`lists`): attachments, uploads, upload status,
            // and holding a prompt for the owner.
            let listed = init.pointer("/_meta/acpmux/features").and_then(Value::as_array);
            let listed = listed.into_iter().flatten().filter_map(Value::as_str);
            *me.features.lock_or_recover() = listed.map(str::to_owned).collect();
            let resumes = lists(crate::server::SESSION_RESUME_FEATURE);
            me.session_resume_link.store(if resumes { link + 1 } else { 0 }, Ordering::SeqCst);
            let messages = init
                .pointer("/_meta/acpmux/capabilities")
                .and_then(Value::as_array)
                .is_some_and(|ids| {
                    ids.iter().any(|id| id.as_str() == Some(crate::capabilities::SESSION_MESSAGES))
                });
            me.session_messages.store(messages, Ordering::SeqCst);
            // The reader published the reply's list (`watch_key`), so Connected follows it.
            // Without tools: an inventory is read per session, on an attachment (whose
            // `session_changed` notices carry it) or `_acpmux/info`, never in the list. With
            // them one host's list was 23 MB for 3,700 rows (2026-10-31), past the message
            // limit, and every link to it built and was refused one list before reading it
            // again without them; without them 16.6 MB. A delta is asked for as the list it
            // patches was read (`known_tools`).
            let watch = |tools: bool| json!({"enabled": true, "withTools": tools});
            let row_pages = build.is_some() && *me.row_pages_for.lock_or_recover() == build;
            // A link that read the list before reads only what changed since (`watch_delta.rs`),
            // with or without tools as that list was: a daemon serving it as a peer answers
            // with a delta. One too large to send is read as the whole list is.
            let delta =
                me.watch_delta.load(Ordering::SeqCst) && me.served_as().as_deref() == Some("peer");
            let known = delta.then(|| me.known.lock_or_recover().to_param());
            let known = known.filter(|k| k.as_object().is_some_and(|k| !k.is_empty()));
            let mut answered = None;
            if let Some(known) = known {
                let tools = me.known_tools.load(Ordering::SeqCst);
                let mut asked = watch(tools);
                asked.set("known", known);
                match me.watch_paced(method::MUX_WATCH, asked, link).await {
                    Err(e) if too_large(&e) => {
                        tracing::warn!(peer = %me.name, "the watch delta is too large ({}); reading the whole list", e.message);
                    }
                    answer => answered = Some((answer?, tools)),
                }
            }
            let first = if answered.is_some() {
                answered
            } else if row_pages {
                tracing::info!(peer = %me.name, "the watch list needed pages of rows last time; reading it so");
                me.watch_row_pages(link).await?;
                None
            } else {
                match me.watch_paced(method::MUX_WATCH, watch(false), link).await {
                    // A peer from before #28182 sends a whole list in one message or not at
                    // all (cosmic-gray's NIGHTLY, 16.4 MB without tools, on 2026-10-30): it is
                    // read in pages of a count of rows, which such a peer serves.
                    Err(e) if too_large(&e) => {
                        tracing::warn!(peer = %me.name, "the watch list is too large ({}); reading it in pages", e.message);
                        me.watch_row_pages(link).await?;
                        *me.row_pages_for.lock_or_recover() = build.clone();
                        None
                    }
                    answer => Some((answer?, false)),
                }
            };
            // A list too large for one message comes in pages (a peer served as Web, over
            // plain ws://, gets the whole list): every page is read before the link connects,
            // and the reader publishes the list once, whole, after the last.
            let tools = first.as_ref().is_some_and(|(_, tools)| *tools);
            if let Some((first, tools)) = first {
                me.watch_pages(first, tools, link).await?;
            }
            // Read whole (its last page too, or the delta): the next delta is asked for as this
            // list was read (`watch_delta.rs`).
            me.known_tools.store(tools, Ordering::SeqCst);
            // Connected only now, and ready with it, so its state note follows `connected`.
            // `run` moves the epoch on before it clears `connected` and takes the link down, so
            // a link that dropped meanwhile is seen here: it is not made ready again, and never
            // left reading connected.
            let live = me.with_link(|l| {
                let live = me.link_epoch() == link;
                if live {
                    me.connected.store(true, Ordering::SeqCst);
                    l.ready(crate::store::now_ms());
                }
                live
            });
            if !live || me.link_epoch() != link {
                me.connected.store(false, Ordering::SeqCst);
                return Ok(());
            }
            let (frames, text) = me.received.read();
            tracing::info!(peer = %me.name, frame_bytes = frames, text_bytes = text, "connected to {}", me.url);
            let _ = me.notices.send((me.name.clone(), me.generation, PeerNotice::Connected)).await;
            // Several at once: a chat the peer is slow on holds up no other's stream, and a
            // link with many chats does not fill its send queue with them.
            let attached: Vec<String> = me.attached.lock_or_recover().keys().cloned().collect();
            let link = &me;
            futures::stream::iter(attached.iter())
                .for_each_concurrent(REATTACHES_AT_ONCE, |sid| async move {
                    let _ = link.attach_hidden(sid).await;
                })
                .await;
            me.refresh_health();
            Ok::<(), RpcError>(())
        });

        // Keepalive: a ping each interval; any frame is an answer. A peer
        // silent for the whole budget, or one that stops reading so a send
        // cannot go out, is dropped and reconnected; one interval of silence
        // only marks it degraded.
        let timings = self.timings;
        let budget = timings.silence_budget();
        let mut ping = tokio::time::interval_at(
            tokio::time::Instant::now() + timings.ping_every,
            timings.ping_every,
        );
        ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut last_frame = tokio::time::Instant::now();
        let mut stale_settled = false;
        let mut handshake_ended = false;
        let mut ticks: u64 = 0;
        // Moved on by each page of a watch list read in pages, up to `HANDSHAKE_MOST` in all: a
        // peer that paces its lists still links, one that stops answering does not hold it.
        let handshake_started = tokio::time::Instant::now();
        let handshake_deadline = tokio::time::sleep(timings.handshake);
        tokio::pin!(handshake_deadline);
        // After this computer slept, the link's monotonic timers say its last frame came moments
        // ago, while its ssh tunnel has often died: a ping goes out at once, and the link is
        // dropped (and redialed) when nothing answers within `WAKE_PROBE`, rather than after the
        // ssh keepalive or the whole silence budget. Stops with the link.
        let mut wake_watch = SleepWatch::now();
        let mut wake_check = tokio::time::interval_at(
            tokio::time::Instant::now() + SleepWatch::EVERY,
            SleepWatch::EVERY,
        );
        wake_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut wake_probe: Option<tokio::time::Instant> = None;
        // The clocks are read before every write too, not only on `wake_check`'s tick: after a wake
        // the regular ping's tick may be served first, and its write must be held to the probe's
        // deadline, never the whole send budget.
        macro_rules! check_wake {
            () => {
                if let Some(slept) = wake_watch.check() {
                    tracing::info!(peer = %self.name, "this computer slept {}s; checking the link", slept.as_secs());
                    // One deadline for the ping to go out and its answer to come back.
                    let deadline = tokio::time::Instant::now() + WAKE_PROBE;
                    match tokio::time::timeout_at(deadline, sink.send(Frame::Ping(Vec::new().into()))).await {
                        Ok(Ok(())) => wake_probe = Some(deadline),
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(stopped_reading(WAKE_PROBE)),
                    }
                }
            };
        }
        // The rows of a watch list read in pages so far, and the changes the peer sent
        // meanwhile: published once the last page is in, the list first. A link that drops
        // before then publishes neither, so the hub keeps its last whole list.
        let mut paged: Option<(Vec<Value>, Vec<PeerNotice>)> = None;
        let result = loop {
            if self.stop.load(Ordering::SeqCst) {
                break Ok(LinkEnd::Stopped);
            }
            tokio::select! {
                _ = self.stop_signal.notified() => break Ok(LinkEnd::Stopped),
                _ = wake_check.tick() => check_wake!(),
                _ = tokio::time::sleep_until(wake_probe.unwrap_or_else(tokio::time::Instant::now)), if wake_probe.is_some() => {
                    break Err(format!("no answer {}s after this computer woke", WAKE_PROBE.as_secs()));
                }
                // Once only: a finished oneshot is not polled again.
                stale = &mut stale_rx, if !stale_settled => {
                    stale_settled = true;
                    if let Ok(why) = stale {
                        break Err(why);
                    }
                }
                // A handshake that ended without making the link ready ends the link now, with
                // why: a step the peer refused (or that failed on this link), a stale token, a
                // link that dropped meanwhile, or a task that panicked. The deadline below would
                // only say the handshake timed out.
                ended = &mut handshake, if !handshake_ended => {
                    handshake_ended = true;
                    match ended {
                        Ok(Err(e)) => break Err(format!("handshake failed: {}", e.message)),
                        Err(e) => break Err(format!("handshake failed: {e}")),
                        Ok(Ok(())) if !self.link().is_ready() => {
                            // The stale-token path sends its reason before it returns.
                            if !stale_settled && let Ok(why) = stale_rx.try_recv() {
                                break Err(why);
                            }
                            break Err("handshake ended before the link was ready".to_owned());
                        }
                        Ok(Ok(())) => {}
                    }
                }
                _ = &mut handshake_deadline, if !self.link().is_ready() => {
                    break Err(timed_out(handshake_started));
                }
                _ = ping.tick() => {
                    let silent = last_frame.elapsed();
                    if silent >= budget {
                        break Err(format!("peer stopped answering ({}s without a frame)", silent.as_secs()));
                    }
                    if silent >= timings.ping_every {
                        self.with_link(Link::overdue);
                    }
                    check_wake!();
                    let until = write_deadline(tokio::time::Instant::now(), budget, wake_probe);
                    match tokio::time::timeout_at(until, sink.send(Frame::Ping(Vec::new().into()))).await {
                        Ok(Ok(())) => {}
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(write_late(budget, wake_probe)),
                    }
                    ticks += 1;
                    if ticks.is_multiple_of(health::HEALTH_EVERY) && self.link().is_ready() {
                        self.refresh_health();
                    }
                }
                frame = source.next() => {
                    let Some(frame) = frame else { break Err("peer closed the connection".to_owned()) };
                    let frame = match frame { Ok(f) => f, Err(e) => break Err(e.to_string()) };
                    // `select!` is unbiased: a frame read as the deadline passes may not finish
                    // the handshake (or move the deadline on past its cap).
                    if !self.link().is_ready() && handshake_deadline.is_elapsed() {
                        break Err(timed_out(handshake_started));
                    }
                    last_frame = tokio::time::Instant::now();
                    wake_probe = None;
                    self.with_link(|l| l.heard(crate::store::now_ms()));
                    let (text, compressed) = match frame {
                        tokio_tungstenite::tungstenite::Message::Text(t) => {
                            self.received.add(t.len(), t.len());
                            (t.to_string(), false)
                        }
                        // Asked for in `initialize` (`frame_compress.rs`). One that does not
                        // inflate would lose a reply its caller waits on: the link starts over.
                        Frame::Binary(b) => match crate::frame_compress::inflate(&b, crate::server::WS_MAX_MESSAGE_BYTES) {
                            Ok(text) => {
                                self.received.add(b.len(), text.len());
                                (text, true)
                            }
                            Err(e) => break Err(e),
                        },
                        Frame::Close(Some(close)) if close.code == tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode::Restart => {
                            break Ok(LinkEnd::Restarting);
                        }
                        Frame::Close(_) => break Err("peer closed the connection".to_owned()),
                        _ => continue,
                    };
                    let msg = match Message::parse(&text) {
                        Ok(msg) => msg,
                        // Only large messages are compressed, and a reply among them would be
                        // lost while its caller waits: the link starts over, as for a frame
                        // that does not inflate.
                        Err(e) if compressed => break Err(format!("a compressed frame is not a JSON-RPC message: {e}")),
                        Err(_) => continue,
                    };
                    match msg {
                        Message::Response { id, result, error } => {
                            let key = id.to_string();
                            // Not held while a notice waits for room: a caller registers under it.
                            let tx = self.pending.lock().await.remove(&key);
                            self.on_wire.lock_or_recover().remove(&key);
                            let Some(tx) = tx else { continue };
                            let reply = match error { Some(e) => Err(e), None => Ok(result.unwrap_or(Value::Null)) };
                            let watch = self.watch_key.lock_or_recover().take_if(|k| *k == key).is_some();
                            // The handshake's last step answered on this link, as a peer serving
                            // this daemon: GitHub actions are taken from here on, and the
                            // added machine asks only after sending this answer
                            // (`hub/github_owner.rs`).
                            if watch && reply.is_ok() && self.served_as().as_deref() == Some("peer") {
                                self.github_link.store(link + 1, Ordering::SeqCst);
                            }
                            if let (true, Ok(list)) = (watch, &reply) {
                                let (mut rows, held) = paged.take().unwrap_or_default();
                                rows.extend(watch_sessions(list));
                                // The whole list a delta stands for; the rows of a whole list,
                                // kept for the next link's delta (`watch_delta.rs`).
                                let delta = crate::watch_delta::read_delta(list).map(|(_, removed)| removed);
                                let last = matches!(page_cursor(list), Ok(None));
                                match delta {
                                    Some(removed) => rows = self.known.lock_or_recover().patched(std::mem::take(&mut rows), &removed),
                                    None if last => self.known.lock_or_recover().listed(&rows),
                                    None => {}
                                }
                                match page_cursor(list) {
                                    // More pages: the handshake asks for them.
                                    Ok(Some(_)) => {
                                        paged = Some((rows, held));
                                        let until = (tokio::time::Instant::now() + timings.handshake)
                                            .min(handshake_started + HANDSHAKE_MOST.max(timings.handshake));
                                        handshake_deadline.as_mut().reset(until);
                                    }
                                    // A bad cursor: the handshake fails and the link drops.
                                    Err(_) => {}
                                    Ok(None) => {
                                        let mut stopped = false;
                                        for notice in std::iter::once(PeerNotice::Sessions(rows)).chain(held) {
                                            if self.notices.send((self.name.clone(), self.generation, notice)).await.is_err() {
                                                stopped = true;
                                                break;
                                            }
                                        }
                                        if stopped {
                                            break Ok(LinkEnd::Stopped);
                                        }
                                    }
                                }
                            }
                            let _ = tx.send(reply);
                        }
                        Message::Notification { method: m, params } => {
                            let p = params.unwrap_or(Value::Null);
                            let notice = if m == method::MUX_SESSION_CHANGED {
                                let session = p.get("session").cloned().unwrap_or(Value::Null);
                                // Remote session_changed notifications carry the
                                // peer name at the top level; older summaries
                                // also carry it inside `session`.
                                if p.get("peer").and_then(Value::as_str).is_some()
                                    || is_mirrored_session(&session)
                                {
                                    continue;
                                }
                                PeerNotice::SessionChanged {
                                    session,
                                    kind: p.get("kind").and_then(Value::as_str).unwrap_or("").to_owned(),
                                    seq: p.get("seq").and_then(Value::as_u64).unwrap_or(0),
                                }
                            } else {
                                PeerNotice::Notification { method: m, params: p, link: self.link_epoch() }
                            };
                            // A change during a paged watch list goes after that list.
                            if let (Some((_, held)), PeerNotice::SessionChanged { .. }) = (paged.as_mut(), &notice) {
                                held.push(notice);
                                continue;
                            }
                            if self.notices.send((self.name.clone(), self.generation, notice)).await.is_err() {
                                break Ok(LinkEnd::Stopped);
                            }
                        }
                        Message::Request { id, method: m, params } if m == method::MUX_GITHUB_ACTION => {
                            // Refused here, before anything is spawned, unless this Mac lends the
                            // peer GitHub, the handshake on this link finished, and a slot is free.
                            let admitted = crate::github_broker::admit_owner(&self.name, self.github_ready(link), &self.github_slots);
                            match admitted {
                                Ok(slot) => self.serve_github_action(id, params.unwrap_or(Value::Null), slot, link),
                                Err(e) => {
                                    // Bounded like any frame: a peer that asks and never reads
                                    // cannot hold this loop.
                                    let refusal = Frame::Text(Message::err(id, e).to_value().to_string().into());
                                    match tokio::time::timeout(budget, sink.send(refusal)).await {
                                        Ok(Ok(())) => {}
                                        Ok(Err(e)) => break Err(e.to_string()),
                                        Err(_) => break Err(stopped_reading(budget)),
                                    }
                                }
                            }
                        }
                        Message::Request { id, .. } => {
                            // Any other request from the peer: the broker's is the only one.
                            let refusal = Frame::Text(
                                Message::err(id, RpcError::method_not_found("client-side request")).to_value().to_string().into(),
                            );
                            match tokio::time::timeout(budget, sink.send(refusal)).await {
                                Ok(Ok(())) => {}
                                Ok(Err(e)) => break Err(e.to_string()),
                                Err(_) => break Err(stopped_reading(budget)),
                            }
                        }
                    }
                }
                line = out_rx.recv() => {
                    let Some(Outbound { epoch, key, line }) = line else { break Ok(LinkEnd::Stopped) };
                    // Admitted on a link that went down: its caller was failed
                    // with that link, so it never goes out on this one.
                    if epoch != self.link_epoch() {
                        continue;
                    }
                    // Before the frame is marked: a link a wake check drops never had it.
                    check_wake!();
                    // Marked before the write: a frame that is partly written may still run.
                    if let Some(key) = key {
                        self.on_wire.lock_or_recover().insert(key);
                    }
                    let text = line.trim_end_matches('\n').to_owned();
                    let until = write_deadline(tokio::time::Instant::now(), budget, wake_probe);
                    match tokio::time::timeout_at(until, sink.send(Frame::Text(text.into()))).await {
                        Ok(Ok(())) => {}
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(write_late(budget, wake_probe)),
                    }
                }
            }
        };
        handshake.abort();
        result
    }
}

/// Whether GitHub may be lent over a link to `url`: ssh (what Add Machine saves) or TLS, or a
/// plain WebSocket only on this machine's loopback. Over plain `ws://` to another host the
/// handshake that makes a link a peer could come from anything on the path.
fn lends_over(url: &str) -> bool {
    let Ok(u) = reqwest::Url::parse(url) else { return false };
    let host = u.host_str().unwrap_or("").trim_start_matches('[').trim_end_matches(']');
    match u.scheme() {
        "ssh" => ssh_target(url).is_ok(),
        "wss" => true,
        "ws" => {
            host == "localhost" || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
        }
        _ => false,
    }
}

/// How many of a link's chats its handshake attaches again at once after a reconnect.
const REATTACHES_AT_ONCE: usize = 16;

/// Whether the peer itself refused an attach (`Peer::attach_hidden`): the chat is not there, or
/// the peer takes no such request. The link's own failures (dropped, timed out, too large, a
/// full queue) are internal errors or carry `peer_unreachable` / `peer_disconnected`, never
/// these codes.
fn refuses_attach(e: &RpcError) -> bool {
    matches!(e.code, -32002 | -32601 | -32602)
}

/// The sessions an `_acpmux/watch` reply lists, without the rows the peer itself mirrors.
fn watch_sessions(reply: &Value) -> Vec<Value> {
    reply
        .get("sessions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|session| !is_mirrored_session(session))
        .cloned()
        .collect()
}

impl Peer {
    /// Reads every page after the watch reply `first` with `_acpmux/sessions {cursor}` on link
    /// `link`; the reader gathers their rows (`watch_key`). A cursor given twice, or one that is
    /// not a string, is an error that ends the handshake, never a loop or a short list.
    async fn watch_pages(&self, first: Value, tools: bool, link: u64) -> Result<(), RpcError> {
        let (mut seen, mut next) = (HashSet::new(), page_cursor(&first)?);
        while let Some(cursor) = next {
            if !seen.insert(cursor.clone()) {
                let why = format!("the peer gave the watch page cursor {cursor:?} twice");
                return Err(RpcError::internal(why));
            }
            let params = json!({"withTools": tools, "cursor": cursor});
            let page = self.watch_request_on(method::MUX_SESSIONS, params, link).await?;
            next = page_cursor(&page)?;
        }
        Ok(())
    }
}

impl Peer {
    /// Reads the watch list on link `link` in pages of a count of rows, without tools:
    /// `_acpmux/watch {limit}`, then `_acpmux/sessions {limit, cursor}` (the keyset pages every
    /// peer serves, those from before #28182 too). The reader gathers their rows (`watch_key`).
    /// Each page after the first is sized from the one before to about [`WATCH_PAGE_BYTES`], so
    /// a list over the limit takes a few pages: such a peer builds its list again for most
    /// pages while its sessions change, four back to back and then one per pace window (up to
    /// 15 s), and many small pages would outlast the handshake. A page refused as too large is
    /// asked for again with half the rows. A cursor given twice, or one that is not a string,
    /// ends the handshake.
    async fn watch_row_pages(&self, link: u64) -> Result<(), RpcError> {
        let (mut rows, mut cursor, mut seen) = (WATCH_FIRST_ROWS, None::<String>, HashSet::new());
        loop {
            let (m, params) = match &cursor {
                None => {
                    (method::MUX_WATCH, json!({"enabled": true, "withTools": false, "limit": rows}))
                }
                Some(after) => (
                    method::MUX_SESSIONS,
                    json!({"withTools": false, "limit": rows, "cursor": after}),
                ),
            };
            let page = match self.watch_paced(m, params, link).await {
                Err(e) if too_large(&e) && rows > 1 => {
                    rows /= 2;
                    continue;
                }
                page => page?,
            };
            let Some(next) = page_cursor(&page)? else { return Ok(()) };
            if !seen.insert(next.clone()) {
                let why = format!("the peer gave the watch page cursor {next:?} twice");
                return Err(RpcError::internal(why));
            }
            cursor = Some(next);
            rows = next_page_rows(&page).unwrap_or(rows);
        }
    }

    /// [`Self::watch_request_on`], asked again after the wait a peer's `list.paced` refusal
    /// names (a pre-#28182 peer refuses a list it would make wait more than 30 s). The
    /// handshake's deadline bounds the retries.
    async fn watch_paced(&self, m: &str, params: Value, link: u64) -> Result<Value, RpcError> {
        loop {
            match self.watch_request_on(m, params.clone(), link).await {
                Err(e) if paced(&e).is_some() => {
                    tokio::time::sleep(paced(&e).unwrap_or_default()).await;
                }
                answer => return answer,
            }
        }
    }
}

/// The longest a handshake reading its watch list in pages may take in all: each page moves its
/// deadline on by the handshake's own (`LinkTimings::handshake`), never past this.
const HANDSHAKE_MOST: Duration = Duration::from_secs(300);

/// The rows of the first watch page read by count (`Peer::watch_row_pages`): about 5 MB
/// without tools at the incident's row sizes (2.3 KB).
const WATCH_FIRST_ROWS: u64 = 2048;

/// The bytes a later watch page read by count is sized to: about half the message limit, so a
/// page whose rows grow meanwhile still fits.
const WATCH_PAGE_BYTES: u64 = 8 << 20;

/// The most rows a watch page read by count asks for.
const WATCH_MAX_ROWS: u64 = 1 << 16;

/// Why a handshake that ran out of time failed.
fn timed_out(started: tokio::time::Instant) -> String {
    format!("handshake timed out after {}s", started.elapsed().as_secs())
}

/// The rows of the next page, from `page`'s: as many as fit in [`WATCH_PAGE_BYTES`] at its
/// mean row size. None for a page with no rows.
fn next_page_rows(page: &Value) -> Option<u64> {
    let rows = u64::try_from(page.get("sessions")?.as_array()?.len()).ok().filter(|n| *n > 0)?;
    let bytes = u64::try_from(serde_json::to_vec(page).ok()?.len()).ok()?;
    let fit = rows.saturating_mul(WATCH_PAGE_BYTES).checked_div(bytes)?;
    Some(fit.clamp(1, WATCH_MAX_ROWS))
}

/// The longest wait a peer's `list.paced` reply may ask of a watch request before it is asked again.
const WATCH_PACED_MAX: Duration = Duration::from_secs(30);

/// How long to wait before asking again, when `e` is a peer's `list.paced` refusal.
fn paced(e: &RpcError) -> Option<Duration> {
    let data = e.data.as_ref()?;
    (data.get("reason").and_then(Value::as_str) == Some("list.paced")).then(|| {
        let ms = data.get("retryAfterMs").and_then(Value::as_u64).unwrap_or(1_000);
        Duration::from_millis(ms).min(WATCH_PACED_MAX)
    })
}

/// A watch or page reply's `nextCursor`: none when absent or null, an error when not a string.
fn page_cursor(reply: &Value) -> Result<Option<String>, RpcError> {
    match reply.get("nextCursor") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(cursor)) => Ok(Some(cursor.clone())),
        Some(other) => Err(RpcError::internal(format!("the peer gave the page cursor {other}"))),
    }
}

/// Whether `e` is a reply too large to send (`RpcError::too_large`).
fn too_large(e: &RpcError) -> bool {
    e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str)
        == Some("message.too_large")
}

/// The waits before each reread of a remote that has no peer token yet
/// (`Peer::remote_tokens_settled`, `Peer::stale_token`).
const TOKEN_REREADS: [Duration; 3] =
    [Duration::from_secs(1), Duration::from_secs(2), Duration::from_secs(4)];

/// One frame queued for the link: the link epoch it was admitted on, and the pending key of
/// the request it carries (None for a notification).
struct Outbound {
    epoch: u64,
    key: Option<String>,
    line: String,
}

/// A request or notification that found no room in the queue before its deadline: the link
/// is stalled. It was not sent, so retrying it never runs it twice.
fn queue_timed_out(name: &str, waited: Duration) -> RpcError {
    RpcError::internal(format!(
        "peer_unreachable: the link to {name} took no new request for {}s; the request was not sent; run `acpmux host ls` and retry",
        waited.as_secs()
    ))
    .with_data(json!({
        "reason": "peer_unreachable",
        "retryable": true,
        "try": "acpmux host ls",
        "detail": "the request was not sent",
        "peer": name,
        "queuedMs": u64::try_from(waited.as_millis()).unwrap_or(u64::MAX),
    }))
}

/// The requests whose answer waits on the agent's turn, never on the link alone.
pub(crate) fn waits_on_turn(m: &str) -> bool {
    matches!(m, method::SESSION_PROMPT | method::MUX_WAIT)
}

fn connect_timed_out(after: Duration) -> String {
    format!("connect timed out after {}s", after.as_secs())
}

fn stopped_reading(budget: Duration) -> String {
    format!("peer stopped reading (a send waited {}s)", budget.as_secs())
}

/// Why a write that timed out (`write_deadline`) dropped the link: a wake probe whose deadline
/// passed, else the send budget.
fn write_late(budget: Duration, wake_probe: Option<tokio::time::Instant>) -> String {
    match wake_probe {
        Some(probe) if probe <= tokio::time::Instant::now() => {
            format!("no answer {}s after this computer woke", WAKE_PROBE.as_secs())
        }
        _ => stopped_reading(budget),
    }
}

/// The default WebSocket port of an `ssh://` peer.
pub const SSH_PEER_PORT: u16 = 47811;

/// An `ssh://` peer's ssh destination (`[user@]host`) and remote port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshTarget {
    pub destination: String,
    pub port: u16,
}

/// Parse and check `ssh://[user@]host[:port]`. Every part reaches an ssh or
/// scp argv, and a peer URL can come from any WebSocket token holder
/// (`_acpmux/peer_add`), so a part that ssh could read as an option or that
/// carries anything but a name is refused: an empty user or host, one that
/// starts with `-` (`-oProxyCommand=...`, `-F...`), whitespace or a control
/// character, an `@` in the host, and a port that is not a plain number in
/// 1..=65535. The reason never quotes the value (it may hold a secret).
pub fn ssh_target(url: &str) -> Result<SshTarget, &'static str> {
    let rest = url.strip_prefix("ssh://").ok_or("not an ssh:// url")?;
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    let (user, hostport) = match rest.split_once('@') {
        Some((user, hostport)) => (Some(user), hostport),
        None => (None, rest),
    };
    let bracketed = hostport.starts_with('[') && hostport.ends_with(']');
    let (host, port) = match hostport.rsplit_once(':') {
        Some((host, port)) if !bracketed => {
            let plain = !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit());
            let port = port.parse::<u16>().ok().filter(|p| plain && *p > 0);
            (host, port.ok_or("the port is not a plain number")?)
        }
        _ => (hostport, SSH_PEER_PORT),
    };
    check_ssh_part(host, "host")?;
    if host.contains('@') {
        return Err("the host has an @");
    }
    let destination = match user {
        Some(user) => {
            check_ssh_part(user, "user")?;
            format!("{user}@{host}")
        }
        None => host.to_owned(),
    };
    Ok(SshTarget { destination, port })
}

/// A peer's canonical endpoint (hq plans/cmux-next/acpmux-one-daemon.md):
/// `ssh://HOST`, the ssh config's user and the machine's one daemon on
/// [`SSH_PEER_PORT`]. Some(it) when `url` is an `ssh://` URL that names a user
/// or another port, so a listing can say where it should point; None when it
/// already is canonical or is not an `ssh://` peer. It never re-points one.
pub fn canonical_endpoint(url: &str) -> Option<String> {
    let t = ssh_target(url).ok()?;
    let host = t.destination.rsplit_once('@').map_or(t.destination.as_str(), |(_, h)| h);
    (t.destination != host || t.port != SSH_PEER_PORT).then(|| format!("ssh://{host}"))
}

fn check_ssh_part(part: &str, what: &'static str) -> Result<(), &'static str> {
    let host = what == "host";
    if part.is_empty() {
        return Err(if host { "the host is empty" } else { "the user is empty" });
    }
    if part.starts_with('-') {
        return Err(if host {
            "the host starts with - (an ssh option)"
        } else {
            "the user starts with - (an ssh option)"
        });
    }
    // Names only: a user's ssh_config may put %h or %r into a shell command
    // (ProxyCommand, Match exec), and scp reads `/` and `:` itself.
    let name = |b: u8| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-');
    let plain = if let Some(inner) = part.strip_prefix('[').and_then(|p| p.strip_suffix(']')) {
        // A bracketed IPv6 address (scp strips the brackets).
        host && !inner.is_empty()
            && inner.bytes().all(|b| b.is_ascii_hexdigit() || matches!(b, b':' | b'.' | b'%'))
    } else {
        part.bytes().all(name)
    };
    if !plain {
        return Err(if host {
            "the host is not a plain name or [IPv6] address"
        } else {
            "the user is not a plain name"
        });
    }
    Ok(())
}

/// `ssh ... -W 127.0.0.1:PORT -- DESTINATION`: the `--` ends ssh's options,
/// so the destination is never read as one.
pub fn tunnel_argv(destination: &str, port: u16) -> Vec<String> {
    let mut argv: Vec<String> = [
        "-o",
        "BatchMode=yes",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=3",
        "-o",
        "ConnectTimeout=20",
        "-W",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    argv.push(format!("127.0.0.1:{port}"));
    argv.push("--".into());
    argv.push(destination.to_owned());
    argv
}

/// `ssh ... -- DESTINATION '<fixed command>'`: the remote config, a NUL,
/// then the remote daemon's peer token of this launch, if it has one.
pub fn read_config_argv(destination: &str) -> Vec<String> {
    [
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=20",
        "--",
        destination,
        "cat ~/.acpmux/config.json; printf '\\0'; cat ~/.acpmux/run/peer.token 2>/dev/null",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

/// Whether a direct (not ssh) peer URL may carry the peer token: `wss://`,
/// or `ws://` to a loopback host. Over plain `ws://` to any other host the
/// token would cross a network in clear, and the peer serves it as Web
/// anyway (`server/peer_auth.rs`). An `ssh://` peer connects through a
/// tunnel to the remote's loopback, so it always may.
pub fn carries_peer_token(url: &str) -> bool {
    let Ok(uri) = url.parse::<tokio_tungstenite::tungstenite::http::Uri>() else { return false };
    let host = uri.host().unwrap_or_default().trim_start_matches('[').trim_end_matches(']');
    match uri.scheme_str() {
        Some("wss") => true,
        Some("ws") => {
            host.eq_ignore_ascii_case("localhost")
                || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.to_canonical().is_loopback())
        }
        _ => false,
    }
}

/// The output of `read_config_argv`: the config bytes and the peer token
/// (None when absent or not a 64-digit hex token).
pub fn split_remote_read(out: &[u8]) -> (&[u8], Option<String>) {
    let Some(at) = out.iter().position(|b| *b == 0) else { return (out, None) };
    let (config, rest) = out.split_at_checked(at).unwrap_or((out, &[]));
    (config, peer_token_text(rest.get(1..).unwrap_or_default()))
}

/// A daemon's `run/peer.token` file: the token, trimmed, when it is 64 hex
/// digits; None for anything else.
pub fn peer_token_text(bytes: &[u8]) -> Option<String> {
    let token = std::str::from_utf8(bytes).ok().map(str::trim);
    token.filter(|t| t.len() == 64 && t.bytes().all(|b| b.is_ascii_hexdigit())).map(str::to_owned)
}

/// What a peer reads from another daemon's `~/.acpmux/config.json`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteDaemonConfig {
    /// The dashboard token (`websocket.token`).
    pub token: String,
    /// The WebSocket listen address (`websocket.listen`), when set.
    pub listen: Option<String>,
}

/// Why [`remote_daemon_config`] found no token. The reason never quotes
/// the file (it holds a secret).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteConfigError {
    /// Not JSON.
    Unreadable,
    /// JSON without a `websocket.token` string.
    NoToken,
}

/// Parse another daemon's `config.json` bytes, as an `ssh://` peer reads
/// them at each connect and the Cloud link's peer bridge reads them over
/// the remote tunnel.
pub fn remote_daemon_config(config: &[u8]) -> Result<RemoteDaemonConfig, RemoteConfigError> {
    let cfg: Value = serde_json::from_slice(config).map_err(|_| RemoteConfigError::Unreadable)?;
    let token = cfg
        .pointer("/websocket/token")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
        .ok_or(RemoteConfigError::NoToken)?
        .to_owned();
    let listen = cfg.pointer("/websocket/listen").and_then(Value::as_str).map(str::to_owned);
    Ok(RemoteDaemonConfig { token, listen })
}

type PendingReplies = Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, RpcError>>>>>;

/// `Peer::on_wire`.
type OnWire = Arc<StdMutex<HashSet<String>>>;

/// Removes a request's pending entry when `Peer::request` returns or is
/// dropped; the reader has already removed it when the reply came.
struct ForgetPending {
    pending: PendingReplies,
    on_wire: OnWire,
    key: Option<String>,
}

impl Drop for ForgetPending {
    fn drop(&mut self) {
        let Some(key) = self.key.take() else { return };
        self.on_wire.lock_or_recover().remove(&key);
        if let Ok(mut map) = self.pending.try_lock() {
            map.remove(&key);
        } else if let Ok(rt) = tokio::runtime::Handle::try_current() {
            let pending = self.pending.clone();
            rt.spawn(async move {
                pending.lock().await.remove(&key);
            });
        }
    }
}

#[cfg(test)]
#[path = "peer_attach_tests.rs"]
mod attach_tests;

#[cfg(test)]
mod remote_config_tests {
    use super::*;

    #[test]
    fn the_links_own_attach_names_its_byte_limit() {
        let attach = hidden_attach("s");
        assert_eq!(attach["sessionId"], "s");
        assert_eq!(attach["limit"], 0);
        assert_eq!(attach["visible"], false);
        assert_eq!(attach["maxBytes"], crate::hub::page_bytes(&json!({})));
    }

    #[test]
    fn a_remote_config_gives_its_token_and_listen_address() {
        let cfg = br#"{"websocket": {"listen": "127.0.0.1:47811", "token": "abc"}}"#;
        let parsed = remote_daemon_config(cfg).unwrap();
        assert_eq!(parsed.token, "abc");
        assert_eq!(parsed.listen.as_deref(), Some("127.0.0.1:47811"));
        let no_listen = remote_daemon_config(br#"{"websocket": {"token": "abc"}}"#).unwrap();
        assert_eq!(no_listen.listen, None);
    }

    #[test]
    fn a_remote_config_without_a_token_is_refused_without_quoting_it() {
        assert_eq!(remote_daemon_config(b"not json"), Err(RemoteConfigError::Unreadable));
        for cfg in [
            &br#"{}"#[..],
            br#"{"websocket": {"listen": "x"}}"#,
            br#"{"websocket": {"token": ""}}"#,
        ] {
            assert_eq!(remote_daemon_config(cfg), Err(RemoteConfigError::NoToken));
        }
    }

    #[test]
    fn a_peer_token_is_64_hex_digits() {
        let good = "a".repeat(64);
        assert_eq!(peer_token_text(format!("{good}\n").as_bytes()), Some(good.clone()));
        assert_eq!(peer_token_text(b""), None);
        assert_eq!(peer_token_text("g".repeat(64).as_bytes()), None);
        assert_eq!(peer_token_text("a".repeat(63).as_bytes()), None);
        let read = [br#"{"websocket":{"token":"t"}}"#.as_slice(), b"\0", good.as_bytes()].concat();
        assert_eq!(split_remote_read(&read).1, Some(good));
    }
}

#[cfg(test)]
#[path = "peer_briefs_tests.rs"]
mod briefs_tests;

#[cfg(test)]
mod link_epoch_tests {
    use super::*;

    /// A prompt admitted on a link that went down before it was registered fails at once: the
    /// next link drops its frame, and a prompt has no deadline, so it would wait for good.
    #[tokio::test]
    async fn a_prompt_admitted_on_a_link_that_went_down_fails_instead_of_waiting() {
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
        peer.connected.store(true, Ordering::SeqCst);
        let admitted_on = peer.link_epoch();
        // The link drops and the next one is up again before the request registers.
        peer.link_ended();
        let answer = tokio::time::timeout(
            Duration::from_secs(5),
            peer.link_request_on(method::SESSION_PROMPT, json!({}), Some(admitted_on)),
        )
        .await
        .expect("a prompt on a dead link must not wait");
        assert!(answer.is_err());
        assert_eq!(peer.pending_requests().await, 0, "no entry left behind");
    }

    /// Review of #24797 at 45ab6b1: lending was on for a plain `ws://` peer on another host, so
    /// anything on the path could answer the handshake as that peer and ask as it.
    #[test]
    fn github_is_lent_only_over_ssh_tls_or_loopback() {
        let (tx, _rx) = mpsc::channel(8);
        for (url, lends) in [
            ("ws://10.0.0.5:7777", false),
            ("ws://box.example:7777", false),
            ("ws://127.0.0.1:7777", true),
            ("ws://localhost:7777", true),
            ("ws://[::1]:7777", true),
            ("ws://127.0.0.2:7777", true),
            ("ws://[::2]:7777", false),
            ("wss://box.example", true),
            ("ssh://leo@box.example", true),
        ] {
            let peer = Peer::new("p", url, None, None, tx.clone());
            peer.set_github_broker(true);
            assert_eq!(peer.github_broker(), lends, "{url}");
        }
    }

    /// Review of #24797 at ee07ea5: an action admitted just before the peer stopped took the
    /// epoch after the stop as its own, so it still ran.
    #[tokio::test]
    async fn an_action_admitted_before_a_stop_never_runs() {
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new("stopped-mid-admit", "ws://127.0.0.1:9", None, None, tx);
        peer.set_github_broker(true);
        let link = peer.link_epoch();
        peer.github_link.store(link + 1, Ordering::SeqCst);
        let slot = crate::github_broker::admit_owner(
            &peer.name,
            peer.github_ready(link),
            &peer.github_slots,
        )
        .unwrap();
        peer.stop();
        let mut out = peer.out_rx.lock().await.take().unwrap();
        peer.serve_github_action(json!(1), json!({"action": "read", "repo": "o/r"}), slot, link);
        let sent = tokio::time::timeout(Duration::from_secs(1), out.recv()).await;
        assert!(
            sent.is_err(),
            "nothing ran or answered: {:?}",
            sent.ok().flatten().map(|f| f.line)
        );
        assert_eq!(peer.github_slots.available_permits(), crate::github_broker::OWNER_SLOTS);
    }

    /// Review of #24797 at 30e24d1: each reconnect's new peer had slots of its own while the
    /// old one's GitHub actions still ran, so reconnects started more than `OWNER_SLOTS` `gh`s.
    #[tokio::test]
    async fn a_reconnect_shares_its_github_slots_with_the_actions_still_running() {
        let (tx, _rx) = mpsc::channel(8);
        let old = Peer::new("slots-across-reconnects", "ws://127.0.0.1:9", None, None, tx.clone());
        let running: Vec<_> = (0..crate::github_broker::OWNER_SLOTS)
            .map(|_| crate::github_broker::admit_owner(&old.name, true, &old.github_slots).unwrap())
            .collect();
        old.stop();
        let new = Peer::new("slots-across-reconnects", "ws://127.0.0.1:9", None, None, tx);
        let e = crate::github_broker::admit_owner(&new.name, true, &new.github_slots).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "github.busy");
        drop(running);
        assert!(crate::github_broker::admit_owner(&new.name, true, &new.github_slots).is_ok());
    }
}

#[cfg(test)]
mod frame_epoch_tests {
    use super::*;
    use tokio_tungstenite::WebSocketStream;
    use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

    /// A frame admitted on a link that went down is dropped when `serve` dequeues it, even
    /// when its sender woke only after the next link opened; one admitted on the live link
    /// goes out.
    #[tokio::test]
    async fn a_frame_tagged_with_an_ended_link_never_goes_out_on_the_next() {
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
        let stale = peer.link_epoch();
        peer.link_ended();
        let frame = |epoch, line: &str| Outbound { epoch, key: None, line: line.to_owned() };
        peer.out.send(frame(stale, r#"{"jsonrpc":"2.0","method":"stale"}"#)).await.unwrap();
        let live = peer.link_epoch();
        peer.out.send(frame(live, r#"{"jsonrpc":"2.0","method":"live"}"#)).await.unwrap();

        let (ours, theirs) = tokio::io::duplex(1 << 16);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let mut out_rx = peer.out_rx.lock().await.take().unwrap();
        let link = peer.clone();
        let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });

        let mut seen = Vec::new();
        while !seen.iter().any(|t: &String| t.contains("\"live\"")) {
            let frame = tokio::time::timeout(Duration::from_secs(5), server.next())
                .await
                .expect("the live frame goes out")
                .expect("the link stays open")
                .unwrap();
            if let Frame::Text(text) = frame {
                seen.push(text.to_string());
            }
        }
        assert!(!seen.iter().any(|t| t.contains("\"stale\"")), "a stale frame went out: {seen:?}");
        serving.abort();
    }

    /// Review of #24797 at f2e68a4: a peer's request was refused with a send that had no time
    /// limit, so a peer that asks and never reads held the link's loop, pings and all, for good.
    #[tokio::test]
    async fn a_peer_that_asks_and_never_reads_loses_the_link() {
        let (tx, _rx) = mpsc::channel(8);
        let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
        let timings = &mut Arc::get_mut(&mut peer).expect("only this test holds it").timings;
        timings.ping_every = Duration::from_millis(200);
        timings.ping_misses = 2;
        let (ours, theirs) = tokio::io::duplex(1024);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let mut out_rx = peer.out_rx.lock().await.take().unwrap();
        let link = peer.clone();
        let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
        let asking = tokio::spawn(async move {
            for i in 0u64.. {
                let ask =
                    Message::request(json!(i), method::MUX_GITHUB_ACTION, json!({})).to_line();
                if server.send(Frame::Text(ask.trim_end().to_owned().into())).await.is_err() {
                    break;
                }
            }
        });
        let ended = tokio::time::timeout(Duration::from_secs(10), serving)
            .await
            .expect("the link ends instead of hanging");
        assert!(ended.unwrap().is_err());
        asking.abort();
    }
}

#[cfg(test)]
mod watch_order_tests {
    use super::*;
    use tokio_tungstenite::WebSocketStream;
    use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

    /// A `session_changed` the peer sends right after its `_acpmux/watch` reply is newer than
    /// the reply's list, so it reaches the hub after the list: a purge of a listed session
    /// leaves no row behind, where a list that came second put the purged row back.
    #[tokio::test]
    async fn a_purge_sent_right_after_the_watch_reply_lands_after_its_list() {
        let dir = cmux_unix_socket::short_test_dir("acpmux-po");
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Local;
        let store = crate::store::open(&cfg.store, dir.path()).unwrap();
        let hub = crate::hub::Hub::new(cfg, store);
        let (tx, mut rx) = mpsc::channel(64);
        let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert("box".to_owned(), peer.clone());

        let (ours, theirs) = tokio::io::duplex(1 << 16);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let mut out_rx = peer.out_rx.lock().await.take().unwrap();
        let link = peer.clone();
        let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
        // The peer answers every request; its watch reply lists m1, and the purge of m1
        // follows it in the same write.
        let fake = tokio::spawn(async move {
            let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "updatedAt": 5});
            while let Some(Ok(frame)) = server.next().await {
                let Frame::Text(text) = frame else { continue };
                let msg: Value = serde_json::from_str(&text).unwrap();
                let Some(id) = msg.get("id").cloned() else { continue };
                let watch = msg["method"] == method::MUX_WATCH;
                let result = if watch { json!({"sessions": [row]}) } else { json!({}) };
                let reply = json!({"jsonrpc": "2.0", "id": id, "result": result});
                if !watch {
                    server.send(Frame::Text(reply.to_string().into())).await.unwrap();
                    continue;
                }
                let purge = json!({"jsonrpc": "2.0", "method": method::MUX_SESSION_CHANGED,
                    "params": {"kind": "purged", "seq": 2, "session": {"sessionId": "m1"}}});
                server.feed(Frame::Text(reply.to_string().into())).await.unwrap();
                server.send(Frame::Text(purge.to_string().into())).await.unwrap();
            }
        });

        let mut seen = Vec::new();
        let (mut connected, mut purged) = (false, false);
        while !(connected && purged) {
            let (_, _, notice) = tokio::time::timeout(Duration::from_secs(5), rx.recv())
                .await
                .expect("the handshake settles and the purge comes")
                .expect("the link stays open");
            connected |= matches!(notice, PeerNotice::Connected);
            purged |=
                matches!(&notice, PeerNotice::SessionChanged { kind, .. } if kind == "purged");
            seen.push(notice);
        }
        let at = |want: fn(&PeerNotice) -> bool| seen.iter().position(want).unwrap();
        let list = at(|n| matches!(n, PeerNotice::Sessions(_)));
        let purge = at(|n| matches!(n, PeerNotice::SessionChanged { .. }));
        let ready = at(|n| matches!(n, PeerNotice::Connected));
        assert!(list < purge, "the list came after a newer purge: {seen:?}");
        assert!(list < ready, "connected before the list: {seen:?}");

        // The hub applies them in the order the link gave them; a second Connected is a
        // barrier: once it settled, every notice before it was applied.
        let mut settled = peer.settled();
        for notice in seen.into_iter().chain([PeerNotice::Connected]) {
            hub.peer_notices.send(("box".to_owned(), peer.generation, notice)).await.unwrap();
        }
        tokio::time::timeout(Duration::from_secs(5), settled.wait_for(|n| *n >= 2))
            .await
            .expect("the hub applies the notices")
            .unwrap();
        let rows = hub.remote_sessions();
        assert!(rows.is_empty(), "the purged row came back: {rows:?}");
        serving.abort();
        fake.abort();
    }
}
