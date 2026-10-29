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

#[cfg(test)]
#[path = "peer_state_tests.rs"]
mod state_tests;

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

/// How a backoff wait between attempts ended (`Peer::wait_backoff`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BackoffWait {
    /// The delay passed.
    Done,
    /// This computer slept through it: the attempt goes now.
    Woke,
    /// The peer was stopped.
    Stopped,
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
    /// The peer lists `sessionAuth` (`hub/session_auth.rs`).
    session_auth: AtomicBool,
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
    /// Where each change of `state()` goes once the hub runs the peer (`report_states`).
    states: StdMutex<Option<Arc<crate::peer_states::PeerStates>>>,
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
            on_wire: Default::default(),
            connected: AtomicBool::new(false),
            open: AtomicBool::new(false),
            last_error: StdMutex::new(None),
            remote_version: StdMutex::new(None),
            served_as: StdMutex::new(None),
            person_instance: StdMutex::new(None),
            trust_gate: AtomicBool::new(false),
            vm_boundary: AtomicBool::new(false),
            github_broker: AtomicBool::new(false),
            github_slots: crate::github_broker::owner_slots(name),
            github_link: AtomicU64::new(0),
            github_revoked: tokio::sync::Notify::new(),
            file_put: AtomicBool::new(false),
            file_put_chunks: AtomicBool::new(false),
            media_read: AtomicBool::new(false),
            link_epoch: AtomicU64::new(0),
            subagent_transcript: AtomicBool::new(false),
            send_attach: AtomicBool::new(false),
            prompt_uploads: AtomicBool::new(false),
            upload_resume: AtomicBool::new(false),
            session_auth: AtomicBool::new(false),
            withheld: AtomicBool::new(false),
            presented: StdMutex::new(None),
            admitting: AtomicBool::new(false),
            attached: StdMutex::new(HashSet::new()),
            notices,
            stop: AtomicBool::new(false),
            stop_signal: Notify::new(),
            settled: tokio::sync::watch::channel(0).0,
            link: StdMutex::new(Link::default()),
            states: StdMutex::new(None),
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
            let reply = tokio::select! {
                reply = crate::github_broker::serve_owner(&me.name, params) => reply,
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
            if let Ok(line) = msg.bounded_line() {
                let frame = Outbound { epoch, key: None, line };
                let _ = tokio::time::timeout(me.timings.request, me.out.send(frame)).await;
            }
            drop(slot);
        });
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
        self.github_revoked.notify_waiters();
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

    /// Whether the peer said at its last handshake that it answers `_acpmux/session/auth`.
    pub fn supports_session_auth(&self) -> bool {
        self.session_auth.load(Ordering::SeqCst)
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

    /// Sends `m` on the link of epoch `epoch` (any link when None), with no check that the
    /// handshake finished: the handshake's own requests go out through here.
    async fn link_request_on(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
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
        if m == method::MUX_WATCH {
            *self.watch_key.lock_or_recover() = Some(key.clone());
        }
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
        while !self.stop.load(Ordering::SeqCst) {
            let outcome = self.connect_once(&mut out_rx).await;
            // Before the link goes down, so the state note of the drop names why.
            if let Err(e) = &outcome {
                *self.last_error.lock_or_recover() = Some(e.clone());
            }
            // The epoch moves first: a handshake that marks the link ready checks it after,
            // so `connected` never stays true for a link that is gone.
            self.link_ended();
            self.open.store(false, Ordering::SeqCst);
            self.connected.store(false, Ordering::SeqCst);
            // A link that held a while starts over; one that flaps (up, then
            // reset seconds later) keeps backing off, so a loaded host is
            // not hit with a reconnect every second.
            if self.with_link(|l| l.down(crate::store::now_ms(), self.timings.stable_after)) {
                backoff.reset();
            }
            if let Err(e) = outcome {
                let notice = PeerNotice::Disconnected(e);
                let _ = self.notices.send((self.name.clone(), self.generation, notice)).await;
            }
            self.fail_link_requests(&mut out_rx).await;
            if self.stop.load(Ordering::SeqCst) {
                break;
            }
            let delay = backoff.next(crate::peer_link::jitter());
            match self.wait_backoff(delay).await {
                BackoffWait::Done => {}
                // The network that failed before the sleep may take a moment to come back: the
                // next attempts are quick ones again.
                BackoffWait::Woke => backoff.reset(),
                BackoffWait::Stopped => break,
            }
        }
    }

    /// Waits out one backoff delay. A wait that this
    /// computer slept through ends at the wake, with the backoff started over: the delay ran on
    /// the monotonic clock, which stood still, so the attempt would otherwise come up to a
    /// minute after the wake, while the network that failed before the sleep is likely back.
    async fn wait_backoff(&self, delay: Duration) -> BackoffWait {
        let deadline = tokio::time::Instant::now() + delay;
        let mut watch = SleepWatch::now();
        loop {
            let check = (tokio::time::Instant::now() + SleepWatch::EVERY).min(deadline);
            tokio::select! {
                _ = tokio::time::sleep_until(check) => {
                    if let Some(slept) = watch.check() {
                        tracing::info!(peer = %self.name, "this computer slept {}s; reconnecting now", slept.as_secs());
                        return BackoffWait::Woke;
                    }
                    if tokio::time::Instant::now() >= deadline {
                        return BackoffWait::Done;
                    }
                }
                _ = self.stop_signal.notified() => return BackoffWait::Stopped,
            }
        }
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
        out_rx: &mut mpsc::Receiver<Outbound>,
    ) -> Result<(), String>
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
        self.with_link(|l| l.opened(crate::store::now_ms()));
        tracing::info!(peer = %self.name, "link open to {}; handshaking", self.url);

        // Handshake in a task so the read loop below can serve the responses.
        let me = self.clone();
        let (stale_tx, mut stale_rx) = oneshot::channel::<String>();
        let handshake = tokio::spawn(async move {
            let mut hello = json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": CLIENT_NAME, "version": crate::hub::VERSION}});
            // This Mac lends the peer its GitHub login (`hub/github_owner.rs` on the peer).
            if me.github_broker() {
                hello["_meta"] = json!({"acpmux": {"githubBroker": true}});
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
            let auth = lists(crate::hub::session_auth::FEATURE);
            me.session_auth.store(auth, Ordering::SeqCst);
            // The reader published the reply's list (`watch_key`), so Connected follows it.
            me.link_request_on(method::MUX_WATCH, json!({"enabled": true}), Some(link)).await?;
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
            tracing::info!(peer = %me.name, "connected to {}", me.url);
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
        let result = loop {
            if self.stop.load(Ordering::SeqCst) {
                break Ok(());
            }
            tokio::select! {
                _ = self.stop_signal.notified() => break Ok(()),
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
                    last_frame = tokio::time::Instant::now();
                    wake_probe = None;
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
                    let Some(Outbound { epoch, key, line }) = line else { break Ok(()) };
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
