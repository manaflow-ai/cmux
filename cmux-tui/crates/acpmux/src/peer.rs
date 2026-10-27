//! A peer is a remote acpmux daemon. This daemon is an ACP client of it:
//! it watches the peer's sessions, forwards requests for them, and relays
//! the peer's notifications to local clients. Reconnects with backoff and
//! jitter, forever; a slow peer is `degraded`, a lost one `reconnecting`
//! (`peer_link.rs`).

use crate::no_panic::LockExt;
use crate::peer_link::{Backoff, Link, LinkTimings, PeerState};
use crate::rpc::{Message, RpcError, method};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::sync::{Mutex, Notify, mpsc, oneshot};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

#[path = "peer_health.rs"]
mod health;

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
    /// Outbound frames, each tagged with the link epoch it was admitted on:
    /// `serve` drops one whose link is gone, so it never goes out on the next.
    out: mpsc::Sender<(u64, String)>,
    out_rx: Mutex<Option<mpsc::Receiver<(u64, String)>>>,
    next_id: AtomicI64,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, RpcError>>>>>,
    pub connected: AtomicBool,
    pub last_error: StdMutex<Option<String>>,
    /// Version and build the peer reported at handshake.
    pub remote_version: StdMutex<Option<(String, String)>>,
    /// The origin the peer serves this daemon as (its initialize reply):
    /// `peer` when it accepted the peer token, `remote` (Web) otherwise.
    served_as: StdMutex<Option<String>>,
    /// The daemon run the peer named in its initialize reply
    /// (`personInstance`): the only run its pending prompts may carry
    /// (`hub/person.rs` (c)). A claim, not a proof.
    person_instance: StdMutex<Option<String>>,
    /// Whether the peer advertised the folder-trust gate in initialize.
    trust_gate: AtomicBool,
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
    /// Whether the peer saves a message's attachments (`attach.rs`).
    send_attach: AtomicBool,
    /// The peer lists `promptUploads` (`prompt_uploads.rs`).
    prompt_uploads: AtomicBool,
    /// The peer lists `uploadResume` (`hub/file_uploads.rs`).
    upload_resume: AtomicBool,
    /// The peer token was held back: the transport is plain `ws://` to a
    /// host that is not loopback (`carries_peer_token`). Logged once.
    withheld: AtomicBool,
    /// The peer token this connection presented (`stale_token`).
    presented: StdMutex<Option<String>>,
    /// From the WebSocket opening until `stale_token` cleared it: callers'
    /// requests and notifications are refused, so none goes out on a link
    /// that is dropped to reconnect as a peer, or waits to go out on the next.
    admitting: AtomicBool,
    attached: StdMutex<HashSet<String>>,
    notices: mpsc::Sender<(String, u64, PeerNotice)>,
    stop: AtomicBool,
    /// Wakes `serve` so `stop` closes the live connection.
    stop_signal: Notify,
    /// Counts connect attempts that settled (ready or failed), bumped by the
    /// hub once it applied the outcome, so a caller can await the next one.
    settled: tokio::sync::watch::Sender<u64>,
    /// Connected, degraded or reconnecting, and since when (`peer_link.rs`).
    link: StdMutex<Link>,
    timings: LinkTimings,
    /// When the hub last saved this peer's sessions (`hub/peer_cache.rs`).
    pub(crate) cache_saved_at: AtomicU64,
    /// The sessions this instance's link purged before its list (`hub/purge_tombstones.rs`).
    pub(crate) purge_tombstones: crate::hub::purge_tombstones::PurgeTombstones,
    /// The peer's last `_acpmux/host_health` and when it came (`peer_health.rs`).
    health: StdMutex<Option<(u64, Value)>>,
    /// An ask for it is out.
    health_asking: AtomicBool,
    /// The pending key of the handshake's `_acpmux/watch`. The reader publishes that reply's
    /// list itself, before it reads the next frame, so a `session_changed` the peer sent after
    /// the reply reaches the hub after the list, never before it.
    watch_key: StdMutex<Option<String>>,
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
            out,
            out_rx: Mutex::new(Some(out_rx)),
            next_id: AtomicI64::new(1),
            pending: Arc::new(Mutex::new(HashMap::new())),
            connected: AtomicBool::new(false),
            last_error: StdMutex::new(None),
            remote_version: StdMutex::new(None),
            served_as: StdMutex::new(None),
            person_instance: StdMutex::new(None),
            trust_gate: AtomicBool::new(false),
            file_put: AtomicBool::new(false),
            file_put_chunks: AtomicBool::new(false),
            media_read: AtomicBool::new(false),
            link_epoch: AtomicU64::new(0),
            subagent_transcript: AtomicBool::new(false),
            send_attach: AtomicBool::new(false),
            prompt_uploads: AtomicBool::new(false),
            upload_resume: AtomicBool::new(false),
            withheld: AtomicBool::new(false),
            presented: StdMutex::new(None),
            admitting: AtomicBool::new(false),
            attached: StdMutex::new(HashSet::new()),
            notices,
            stop: AtomicBool::new(false),
            stop_signal: Notify::new(),
            settled: tokio::sync::watch::channel(0).0,
            link: StdMutex::new(Link::default()),
            timings: LinkTimings::from_env(),
            cache_saved_at: AtomicU64::new(0),
            purge_tombstones: Default::default(),
            health: StdMutex::new(None),
            health_asking: AtomicBool::new(false),
            watch_key: StdMutex::new(None),
        })
    }

    pub fn link(&self) -> Link {
        self.link.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn with_link<T>(&self, f: impl FnOnce(&mut Link) -> T) -> T {
        f(&mut self.link.lock().unwrap_or_else(|e| e.into_inner()))
    }

    pub fn state(&self) -> PeerState {
        self.link().state()
    }

    /// Carry what an earlier instance (a replaced peer, or a saved list from
    /// an earlier run) knew of when the peer was last seen.
    pub fn seed_last_seen(&self, last_seen: Option<u64>) {
        self.with_link(|l| l.seed(last_seen));
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
        (tokio::io::Join<tokio::process::ChildStdout, tokio::process::ChildStdin>, u16),
        String,
    > {
        let (host, remote_port) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        let mut child = tokio::process::Command::new("ssh")
            .args(tunnel_argv(&host, remote_port))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("spawn ssh: {e}"))?;
        let stdout = child.stdout.take().ok_or_else(|| "ssh stdout".to_owned())?;
        let stdin = child.stdin.take().ok_or_else(|| "ssh stdin".to_owned())?;
        // Replacing the previous channel ends its ssh process.
        *self.tunnel.lock().await = Some(child);
        Ok((tokio::io::join(stdout, stdin), remote_port))
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
        let read = tokio::process::Command::new("ssh")
            .args(read_config_argv(&host))
            .kill_on_drop(true)
            .output();
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
            return Err(format!("ssh to {host} failed ({})", out.status));
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

    pub fn supports_trust_gate(&self) -> bool {
        self.trust_gate.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it takes `_acpmux/file_put`.
    pub fn supports_file_put(&self) -> bool {
        self.file_put.load(Ordering::SeqCst)
    }

    /// Whether the peer takes uploads in chunks (`file_put_begin`/`_chunk`/`_finish`/`_cancel`).
    pub fn supports_file_put_chunks(&self) -> bool {
        self.file_put_chunks.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it serves the media reader.
    pub fn supports_media_read(&self) -> bool {
        self.media_read.load(Ordering::SeqCst)
    }

    /// Which connection to the peer this is: it changes when a connection ends or the peer stops.
    pub fn link_epoch(&self) -> u64 {
        self.link_epoch.load(Ordering::SeqCst)
    }

    /// A connection to the peer ended: what the peer kept for it is gone.
    pub(crate) fn link_ended(&self) {
        self.link_epoch.fetch_add(1, Ordering::SeqCst);
    }

    /// Whether the peer said at its last handshake that it serves subagent transcripts.
    pub fn supports_subagent_transcript(&self) -> bool {
        self.subagent_transcript.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it saves a message's attachments.
    pub fn supports_send_attach(&self) -> bool {
        self.send_attach.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it reads uploaded files a message names.
    pub fn supports_prompt_uploads(&self) -> bool {
        self.prompt_uploads.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it answers upload status and checks a
    /// finish's `sha256` (`hub/file_uploads.rs`).
    pub fn supports_upload_resume(&self) -> bool {
        self.upload_resume.load(Ordering::SeqCst)
    }

    pub fn summary(&self) -> Value {
        let link = self.link();
        let (health, health_at) = self.health_summary();
        json!({
            "name": self.name,
            "url": self.url,
            "connected": self.connected.load(Ordering::SeqCst),
            "error": self.last_error.lock_or_recover().clone(),
            "remoteVersion": self.remote_version.lock_or_recover().as_ref().map(|(v, _)| v.clone()),
            "remoteBuild": self.remote_version.lock_or_recover().as_ref().map(|(_, b)| b.clone()),
            "localBuild": crate::hub::BUILD,
            "servedAs": self.served_as.lock().unwrap_or_else(|e| e.into_inner()).clone(),
            "peerTokenWithheld": self.withheld.load(Ordering::SeqCst),
            "canonicalEndpoint": canonical_endpoint(&self.url),
            "outdated": self.remote_version.lock_or_recover().as_ref().map(|(_, b)| b != crate::hub::BUILD).unwrap_or(false),
            "state": link.state().as_str(),
            "lastSeen": link.last_seen,
            "downSince": link.down_since,
            "attempts": link.attempts,
            "health": health,
            "healthAt": health_at,
        })
    }

    /// Remember that local clients want this session's stream, so it is
    /// re-attached after a reconnect.
    pub fn mark_attached(&self, session_id: &str) -> bool {
        self.attached.lock_or_recover().insert(session_id.to_owned())
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

    /// `request` with no admission check: the handshake's `initialize`.
    async fn link_request(&self, m: &str, params: Value) -> Result<Value, RpcError> {
        self.link_request_on(m, params, None).await
    }

    /// Sends `m` on the link of epoch `epoch` (any link when None).
    async fn link_request_on(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
    ) -> Result<Value, RpcError> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        let key = Value::from(id).to_string();
        self.pending.lock().await.insert(key.clone(), tx);
        if m == method::MUX_WATCH {
            *self.watch_key.lock_or_recover() = Some(key.clone());
        }
        // A request that times out, or whose caller stops waiting, takes its
        // entry with it rather than leaving it until the connection drops.
        let _forget = ForgetPending { pending: self.pending.clone(), key: Some(key) };
        // The link it was admitted on went down before it was registered: `run`
        // already failed what waited, and the next link drops its frame, so a
        // prompt (which has no deadline) would wait for good.
        if epoch.is_some_and(|e| e != self.link_epoch() || !self.connected.load(Ordering::SeqCst)) {
            return Err(self.unreachable_error());
        }
        // One frame larger than the peer reads with would drop the link and every chat on it.
        let line = Message::request(id, m, params).bounded_line().map_err(RpcError::too_large)?;
        let tag = epoch.unwrap_or_else(|| self.link_epoch());
        if self.out.send((tag, line)).await.is_err() {
            return Err(RpcError::internal(format!("peer {} connection closed", self.name)));
        }
        // A prompt or a wait answers when the peer's turn ends, however long that is; the
        // keepalive drops a link that stops answering, which fails it as `peer disconnected`,
        // and a forwarder whose client left drops it (`server/peer_forward.rs`).
        let answer = if waits_on_turn(m) {
            Ok(rx.await)
        } else {
            tokio::time::timeout(self.timings.request, rx).await
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
            Err(_) => Err(RpcError::internal(format!("peer {} timed out", self.name))),
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
        self.out
            .send((epoch, line))
            .await
            .map_err(|_| RpcError::internal(format!("peer {} connection closed", self.name)))
    }

    /// Run the connect loop until `stop`.
    pub async fn run(self: Arc<Self>) {
        let mut backoff = Backoff::default();
        let Some(mut out_rx) = self.out_rx.lock().await.take() else {
            // A second run: the first owns the outbound queue and the link.
            tracing::warn!(peer = %self.name, "peer link already running");
            return;
        };
        while !self.stop.load(Ordering::SeqCst) {
            let outcome = self.connect_once(&mut out_rx).await;
            self.connected.store(false, Ordering::SeqCst);
            self.link_ended();
            // A link that held a while starts over; one that flaps (up, then
            // reset seconds later) keeps backing off, so a loaded host is
            // not hit with a reconnect every second.
            if self.with_link(|l| l.down(crate::store::now_ms(), self.timings.stable_after)) {
                backoff.reset();
            }
            if let Err(e) = outcome {
                *self.last_error.lock_or_recover() = Some(e.clone());
                let notice = PeerNotice::Disconnected(e);
                let _ = self.notices.send((self.name.clone(), self.generation, notice)).await;
            }
            let mut p = self.pending.lock().await;
            for (_, tx) in p.drain() {
                let _ = tx.send(Err(RpcError::internal("peer disconnected")));
            }
            drop(p);
            if self.stop.load(Ordering::SeqCst) {
                break;
            }
            let delay = backoff.next(crate::peer_link::jitter());
            tokio::select! {
                _ = tokio::time::sleep(delay) => {}
                _ = self.stop_signal.notified() => break,
            }
        }
    }

    async fn connect_once(
        self: &Arc<Self>,
        out_rx: &mut mpsc::Receiver<(u64, String)>,
    ) -> Result<(), String> {
        if self.ssh_parts().is_some() {
            let (token, peer_token) = self.remote_tokens_settled().await?;
            *self.presented.lock().unwrap_or_else(|e| e.into_inner()) = peer_token.clone();
            let (stream, remote_port) = self.open_tunnel().await?;
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
            return self.serve(ws, out_rx).await;
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
        out_rx: &mut mpsc::Receiver<(u64, String)>,
    ) -> Result<(), String>
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        use tokio_tungstenite::tungstenite::Message as Frame;
        let (mut sink, mut source) = ws.split();
        self.admitting.store(true, Ordering::SeqCst);
        self.connected.store(true, Ordering::SeqCst);
        *self.last_error.lock_or_recover() = None;
        self.with_link(|l| l.opened(crate::store::now_ms()));
        tracing::info!(peer = %self.name, "connected to {}", self.url);

        // Handshake in a task so the read loop below can serve the responses.
        let me = self.clone();
        let (stale_tx, mut stale_rx) = oneshot::channel::<String>();
        let handshake = tokio::spawn(async move {
            let init = me
                .link_request(
                    method::INITIALIZE,
                    json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": CLIENT_NAME, "version": crate::hub::VERSION}}),
                )
                .await?;
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
            let advertised =
                init.pointer("/_meta/acpmux/features").and_then(Value::as_array).is_some_and(
                    |features| features.iter().any(|f| f.as_str() == Some("trustGate")),
                ) || init.pointer("/_meta/acpmux/trustGate").and_then(Value::as_bool) == Some(true);
            me.trust_gate.store(advertised, Ordering::SeqCst);
            let lists = |feature: &str| {
                init.pointer("/_meta/acpmux/features")
                    .and_then(Value::as_array)
                    .is_some_and(|features| features.iter().any(|f| f.as_str() == Some(feature)))
            };
            me.file_put.store(lists(crate::hub::FILE_PUT_FEATURE), Ordering::SeqCst);
            let chunks = lists(crate::hub::file_uploads::CHUNKS_FEATURE);
            me.file_put_chunks.store(chunks, Ordering::SeqCst);
            me.media_read.store(lists(crate::hub::MEDIA_READ_FEATURE), Ordering::SeqCst);
            me.subagent_transcript
                .store(lists(crate::hub::SUBAGENT_TRANSCRIPT_FEATURE), Ordering::SeqCst);
            me.send_attach.store(lists(crate::attach::FEATURE), Ordering::SeqCst);
            me.prompt_uploads.store(lists(crate::prompt_uploads::FEATURE), Ordering::SeqCst);
            let resume = lists(crate::hub::file_uploads::RESUME_FEATURE);
            me.upload_resume.store(resume, Ordering::SeqCst);
            // The reader published the reply's list (`watch_key`), so Connected follows it.
            me.request(method::MUX_WATCH, json!({"enabled": true})).await?;
            me.with_link(|l| l.ready(crate::store::now_ms()));
            let _ = me.notices.send((me.name.clone(), me.generation, PeerNotice::Connected)).await;
            let attached: Vec<String> = me.attached.lock_or_recover().iter().cloned().collect();
            for sid in attached {
                let _ = me.request(method::MUX_ATTACH, hidden_attach(&sid)).await;
            }
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
        let mut ticks: u64 = 0;
        let handshake_deadline = tokio::time::sleep(timings.handshake);
        tokio::pin!(handshake_deadline);
        let result = loop {
            if self.stop.load(Ordering::SeqCst) {
                break Ok(());
            }
            tokio::select! {
                _ = self.stop_signal.notified() => break Ok(()),
                // Once only: a finished oneshot is not polled again.
                stale = &mut stale_rx, if !stale_settled => {
                    stale_settled = true;
                    if let Ok(why) = stale {
                        break Err(why);
                    }
                }
                _ = &mut handshake_deadline, if !self.link().is_ready() => {
                    break Err(format!("handshake timed out after {}s", timings.handshake.as_secs()));
                }
                _ = ping.tick() => {
                    let silent = last_frame.elapsed();
                    if silent >= budget {
                        break Err(format!("peer stopped answering ({}s without a frame)", silent.as_secs()));
                    }
                    if silent >= timings.ping_every {
                        self.with_link(Link::overdue);
                    }
                    match tokio::time::timeout(budget, sink.send(Frame::Ping(Vec::new().into()))).await {
                        Ok(Ok(())) => {}
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(stopped_reading(budget)),
                    }
                    ticks += 1;
                    if ticks.is_multiple_of(health::HEALTH_EVERY) && self.link().is_ready() {
                        self.refresh_health();
                    }
                }
                frame = source.next() => {
                    let Some(frame) = frame else { break Err("peer closed the connection".to_owned()) };
                    let frame = match frame { Ok(f) => f, Err(e) => break Err(e.to_string()) };
                    last_frame = tokio::time::Instant::now();
                    self.with_link(|l| l.heard(crate::store::now_ms()));
                    let text = match frame {
                        tokio_tungstenite::tungstenite::Message::Text(t) => t.to_string(),
                        tokio_tungstenite::tungstenite::Message::Close(_) => break Err("peer closed the connection".to_owned()),
                        _ => continue,
                    };
                    let Ok(msg) = Message::parse(&text) else { continue };
                    match msg {
                        Message::Response { id, result, error } => {
                            let key = id.to_string();
                            // Not held while a notice waits for room: a caller registers under it.
                            let tx = self.pending.lock().await.remove(&key);
                            let Some(tx) = tx else { continue };
                            let reply = match error { Some(e) => Err(e), None => Ok(result.unwrap_or(Value::Null)) };
                            let watch = self.watch_key.lock_or_recover().take_if(|k| *k == key).is_some();
                            if let (true, Ok(list)) = (watch, &reply) {
                                let notice = PeerNotice::Sessions(watch_sessions(list));
                                if self.notices.send((self.name.clone(), self.generation, notice)).await.is_err() {
                                    break Ok(());
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
                            if self.notices.send((self.name.clone(), self.generation, notice)).await.is_err() {
                                break Ok(());
                            }
                        }
                        Message::Request { id, .. } => {
                            // acpmux does not send requests to clients today.
                            let _ = sink.send(tokio_tungstenite::tungstenite::Message::Text(
                                Message::err(id, RpcError::method_not_found("client-side request")).to_value().to_string().into(),
                            )).await;
                        }
                    }
                }
                line = out_rx.recv() => {
                    let Some((epoch, line)) = line else { break Ok(()) };
                    // Admitted on a link that went down: its caller was failed
                    // with that link, so it never goes out on this one.
                    if epoch != self.link_epoch() {
                        continue;
                    }
                    let text = line.trim_end_matches('\n').to_owned();
                    match tokio::time::timeout(budget, sink.send(Frame::Text(text.into()))).await {
                        Ok(Ok(())) => {}
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(stopped_reading(budget)),
                    }
                }
            }
        };
        handshake.abort();
        result
    }
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

/// The waits before each reread of a remote that has no peer token yet
/// (`Peer::remote_tokens_settled`, `Peer::stale_token`).
const TOKEN_REREADS: [Duration; 3] =
    [Duration::from_secs(1), Duration::from_secs(2), Duration::from_secs(4)];

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

/// Removes a request's pending entry when `Peer::request` returns or is
/// dropped; the reader has already removed it when the reply came.
struct ForgetPending {
    pending: PendingReplies,
    key: Option<String>,
}

impl Drop for ForgetPending {
    fn drop(&mut self) {
        let Some(key) = self.key.take() else { return };
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
        peer.out.send((stale, r#"{"jsonrpc":"2.0","method":"stale"}"#.to_owned())).await.unwrap();
        let live = peer.link_epoch();
        peer.out.send((live, r#"{"jsonrpc":"2.0","method":"live"}"#.to_owned())).await.unwrap();

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
