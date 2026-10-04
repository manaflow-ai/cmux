//! The hub owns every session, its child agent, its event log, and the
//! fan-out channel that attached clients subscribe to.
//!
//! Method groups live in sibling files: `peers` (remote daemons), `lifecycle`
//! (spawn, resume, fork), `permissions` (agent requests and policy), `turns`
//! (prompt, cancel, config), `transfer` (export, import), `views` (summaries),
//! `handoff` (a reviewed first message to a new session on another harness),
//! `adoption` (resuming a harness's own session on `session/new`).

mod adoption;
mod handoff;
mod idle;
mod launchers;
pub use handoff::{HANDOFF_OPERATIONS, MAX_CAPSULE_BYTES};
mod hosts;
mod lifecycle;
pub(crate) mod model_availability;
mod paging;
mod shutdown;
mod spawn;
mod stream;
mod tap;
#[cfg(test)]
mod tap_tests;
pub use lifecycle::{NewRequest, profile_takes_model_at_spawn};
pub use paging::{EventFilter, EventPage};
pub use spawn::expand_env_value;
mod peers;
mod permission_groups;
mod permissions;
pub use permission_groups::PERMISSION_GROUP_OPERATIONS;
pub mod rules;
mod transfer;
mod turns;
mod warm;
pub(crate) use turns::merge_mux_meta;
mod views;

use crate::agent::{ChildAgent, Direction, Inbound};
use crate::config::{Config, HarnessProfile, PermissionPolicy};
use crate::rpc::{Id, Message, RpcError, method};
use crate::store::{EventRecord, META_SCHEMA, SessionMeta, SessionStatus, Store, now_ms};
use anyhow::Result;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::sync::{Mutex, Notify, RwLock, broadcast, mpsc, oneshot};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// How long a session's harness may sit unused (no client, no turn, no
/// activity) before it exits; the session resumes on its next prompt.
pub const IDLE_CHILD: std::time::Duration = std::time::Duration::from_secs(5 * 60);
/// Git hash and date stamped at build time (see build.rs).
pub const BUILD: &str = env!("ACPMUX_BUILD");

/// Fan-out item: one appended record for one session. `remote` carries the
/// peer name and the peer's session summary when the session lives elsewhere.
#[derive(Debug, Clone)]
pub struct HubEvent {
    pub session_id: String,
    pub record: EventRecord,
    pub remote: Option<RemoteRef>,
}

#[derive(Debug, Clone)]
pub struct RemoteRef {
    pub peer: String,
    pub summary: Value,
}

/// A session that lives on a peer daemon.
#[derive(Debug, Clone)]
pub struct RemoteSession {
    pub peer: String,
    pub summary: Value,
}

#[derive(Debug)]
pub(super) struct PendingPermission {
    pub(super) request: Value,
    pub(super) reply: oneshot::Sender<Value>,
}

#[derive(Debug, Clone)]
pub struct TurnInfo {
    pub started_at: u64,
    pub client: String,
    pub prompt_preview: String,
    /// Stable turn identifier, assigned when the prompt is accepted and
    /// carried by `queued`, `user_message`, `turn_started` and `turn_result`.
    pub turn_id: String,
    /// The client's `_meta.acpmux.promptId`, or one acpmux generated.
    pub prompt_id: String,
    /// Sequence of this turn's `turn_started` record.
    pub turn_seq: u64,
}

/// A prompt waiting for the running turn to end.
#[derive(Debug, Clone)]
pub struct QueuedPrompt {
    pub prompt_id: String,
    pub turn_id: String,
    pub client: String,
    pub preview: String,
    pub queued_at: u64,
}

/// Options for `Hub::prompt_with`.
#[derive(Default)]
pub struct PromptOptions {
    /// Client-chosen id (`_meta.acpmux.promptId`); generated when absent.
    pub prompt_id: Option<String>,
    /// Called once, as soon as the prompt is recorded (queued or started),
    /// with `{sessionId, promptId, turnId, queued, position?, steer?}`, or
    /// `{sessionId, promptId, duplicate: true}` for a prompt id seen before.
    pub on_accepted: Option<Box<dyn FnOnce(Value) + Send>>,
    /// The client sends this prompt id again (`_meta.acpmux.resend`), for
    /// example after its daemon connection closed: also look in the
    /// session's log, which outlives a daemon restart.
    pub resend: bool,
}

/// The outcome of one client prompt id, shared with a resend of it.
pub(super) type PromptOutcome = Arc<tokio::sync::watch::Sender<Option<Result<Value, RpcError>>>>;

/// Client prompt ids remembered per session for deduplication.
pub(super) const PROMPT_LEDGER: usize = 64;

/// What the agent's stream says about the current assistant message, used
/// to record `message_superseded` and to attach streamed error text to
/// `turn_result`.
#[derive(Debug, Default)]
pub(super) struct StreamState {
    /// `messageId` of the assistant message streaming now.
    pub(super) open_message: Option<String>,
    /// Set by a harness retry signal while `open_message` was streaming:
    /// (abandoned messageId, the retry notice text).
    pub(super) retry_from: Option<(String, String)>,
    /// A terminal error the harness reported in-band during this turn.
    pub(super) harness_error: Option<Value>,
    /// Text and sequences of the trailing `agent_message_chunk` records of
    /// the current message; compared with the error text when a turn fails.
    pub(super) trailing_text: String,
    pub(super) trailing_seqs: Vec<u64>,
    pub(super) trailing_overflow: bool,
}

pub struct Session {
    pub id: String,
    pub(super) meta: StdMutex<SessionMeta>,
    pub(super) child: Mutex<Option<Arc<ChildAgent>>>,
    /// Held while a child is spawned and initialized, so concurrent
    /// requests for a stopped session start one agent, not several.
    pub(super) spawn_lock: Mutex<()>,
    pub(super) seq: AtomicU64,
    /// Held from sequence allocation until the record is stored and sent,
    /// so the log and fan-out always see sequences in order.
    pub(super) append_lock: StdMutex<()>,
    pub(super) loading: AtomicBool,
    pub(super) turn_lock: Mutex<()>,
    pub(super) turn: StdMutex<Option<TurnInfo>>,
    pub(super) queued: AtomicU64,
    pub(super) queue: StdMutex<Vec<QueuedPrompt>>,
    pub(super) stream: StdMutex<StreamState>,
    permissions: StdMutex<permission_groups::PermissionState>,
    /// Bumped (under the `permissions` lock) whenever pending
    /// permissions are cancelled; a request that started before the bump
    /// is answered `cancelled` instead of being registered.
    pub(super) permission_epoch: AtomicU64,
    pub(super) rehydrate: AtomicBool,
    pub(super) inbound_tx: mpsc::Sender<Inbound>,
    pub(super) inbound_rx: Mutex<Option<mpsc::Receiver<Inbound>>>,
    pub(super) steering: AtomicBool,
    /// Set on a freshly forked Claude session: the parent's agent session id
    /// to pass as `--resume <id> --fork-session` on first spawn.
    pub(super) fork_from: StdMutex<Option<String>>,
    /// Set once the session is purged, so late events do not recreate its
    /// files while the directory is being removed.
    pub(super) purged: AtomicBool,
    /// Bumps on every status, permission and turn change; waits gate on it.
    pub(super) state_seq: AtomicU64,
    /// Clients attached right now (TUI, web, CLI streams).
    pub(super) attached: std::sync::atomic::AtomicUsize,
    /// Last stderr lines of the current turn, quoted when the agent
    /// process dies without an answer ("Not logged in", a launcher error).
    pub(super) stderr_tail: StdMutex<std::collections::VecDeque<String>>,
    /// Recent client prompt ids and their outcomes, newest last: a prompt
    /// sent again with the same id never runs a second turn.
    pub(super) prompts: StdMutex<std::collections::VecDeque<(String, PromptOutcome)>>,
    /// Bumped when a record failed to reach the store; an agent host entry
    /// is acknowledged only when its record was stored.
    pub(super) append_errors: AtomicU64,
    /// The hub clock's time (`Hub::clock_now`) of the last record or
    /// attach change; the idle harness exit counts from it (`idle.rs`).
    pub(super) last_active: AtomicU64,
}

impl Session {
    pub fn meta(&self) -> SessionMeta {
        self.meta.lock().unwrap().clone()
    }
    pub fn turn(&self) -> Option<TurnInfo> {
        self.turn.lock().unwrap().clone()
    }
    pub fn queued(&self) -> u64 {
        self.queued.load(Ordering::SeqCst)
    }
    pub fn queue(&self) -> Vec<QueuedPrompt> {
        self.queue.lock().unwrap().clone()
    }
    pub fn pending_permissions(&self) -> Vec<(String, Value)> {
        self.permissions
            .lock()
            .unwrap()
            .pending
            .iter()
            .map(|(k, v)| (k.clone(), v.request.clone()))
            .collect()
    }
    pub(super) fn status(&self) -> SessionStatus {
        self.meta.lock().unwrap().status
    }
}

pub struct Hub {
    pub config: RwLock<Config>,
    pub(super) store: Box<dyn Store>,
    pub(super) sessions: StdMutex<HashMap<String, Arc<Session>>>,
    /// Where adopt looks for harness sessions.
    pub(super) harness_homes: StdMutex<crate::adopt::HarnessHomes>,
    pub(super) events: broadcast::Sender<HubEvent>,
    pub shutdown: Notify,
    pub started_at: u64,
    pub(super) peers: StdMutex<HashMap<String, Arc<crate::peer::Peer>>>,
    pub(super) remote_sessions: StdMutex<HashMap<String, RemoteSession>>,
    pub(super) peer_notices: mpsc::Sender<(String, u64, crate::peer::PeerNotice)>,
    pub(super) peer_notices_rx:
        Mutex<Option<mpsc::Receiver<(String, u64, crate::peer::PeerNotice)>>>,
    /// Models each agent has advertised, keyed by agent profile name. Filled
    /// whenever a session starts, so the picker can list a harness that has
    /// no live session.
    pub(super) known_models: StdMutex<HashMap<String, Vec<(String, String)>>>,
    /// (harness, model) pairs whose backend refused them, with its message (model_availability.rs).
    pub(super) refused_models: StdMutex<HashMap<(String, String), String>>,
    /// False while the daemon finishes startup work (login environment,
    /// launcher checks) in the background. Session creation and agent
    /// spawns wait for it; every other request is answered at once.
    pub(super) startup_ready: tokio::sync::watch::Sender<bool>,
    pub(super) login_env_requested: AtomicBool,
    /// Session ids an `import` is writing right now.
    pub(super) importing: StdMutex<std::collections::HashSet<String>>,
    pub(super) handoffs: handoff::Handoffs,
    /// New agents run under agent hosts (`enable_agent_hosts`).
    pub(super) agent_hosts: AtomicBool,
    /// `_acpmux/shutdown {endAgents: true}` (the app's Quit Everything):
    /// the coming shutdown ends hosted agents instead of detaching them.
    pub(super) end_agents_on_shutdown: AtomicBool,
    /// Sessions whose hosted agents a shutdown with `endAgents` still keeps
    /// (`keepSessions`: the app's Home Chief).
    pub(super) keep_on_shutdown: StdMutex<std::collections::HashSet<String>>,
    /// Turns a shutdown with `endAgents` settled as cancelled: their prompt
    /// futures must not write a second result when the agent ends.
    pub(super) settled_by_shutdown: StdMutex<std::collections::HashSet<String>>,
    /// `npx -y PACKAGE` launches resolved to their bin: (npx, package) to path.
    pub(super) launchers: StdMutex<HashMap<(String, String), String>>,
    /// Harnesses whose last model probe failed, with the reason; reported in
    /// `_acpmux/models` and `_acpmux/harnesses` (`probeError`).
    pub probe_errors: StdMutex<HashMap<String, String>>,
    /// Lifecycle timers (the idle harness exit) run on this clock.
    pub(super) clock: StdMutex<Arc<dyn crate::clock::Clock>>,
    /// A session harness unused for this long exits (`idle.rs`); None: never.
    pub(super) idle_child: StdMutex<Option<std::time::Duration>>,
    pub(super) idle_wake: Arc<Notify>,
    pub(super) idle_reaper: AtomicBool,
    /// Set when `shutdown_all` starts: the idle reaper stops for good.
    pub(super) stopping: AtomicBool,
    /// Held by one idle reaper pass; shutdown waits for it after `stopping`.
    pub(super) idle_pass: Mutex<()>,
}

/// Tags that have not expired, as a flat map.
pub fn live_tags(m: &SessionMeta) -> Value {
    let now = now_ms();
    let mut out = serde_json::Map::new();
    for (k, t) in &m.tags {
        if t.expires_at.map(|e| e > now).unwrap_or(true) {
            out.insert(k.clone(), Value::String(t.value.clone()));
        }
    }
    Value::Object(out)
}

pub(super) fn short_text(s: &str, max: usize) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() <= max {
        s
    } else {
        let mut out: String = s.chars().take(max).collect();
        out.push('…');
        out
    }
}

pub(super) fn prompt_text(blocks: &[Value]) -> String {
    blocks
        .iter()
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

impl Hub {
    pub fn new(config: Config, store: Box<dyn Store>) -> Arc<Self> {
        let (events, _) = broadcast::channel(8192);
        let (peer_notices, peer_notices_rx) = mpsc::channel(4096);
        let peers_cfg = config.peers.clone();
        let handoffs = handoff::Handoffs::open(store.handoff_dir());
        let hub = Arc::new(Self {
            config: RwLock::new(config),
            store,
            sessions: StdMutex::new(HashMap::new()),
            harness_homes: StdMutex::new(crate::adopt::HarnessHomes::from_env()),
            events,
            shutdown: Notify::new(),
            started_at: now_ms(),
            peers: StdMutex::new(HashMap::new()),
            remote_sessions: StdMutex::new(HashMap::new()),
            peer_notices,
            peer_notices_rx: Mutex::new(Some(peer_notices_rx)),
            known_models: StdMutex::new(HashMap::new()),
            refused_models: StdMutex::new(HashMap::new()),
            startup_ready: tokio::sync::watch::channel(true).0,
            login_env_requested: AtomicBool::new(false),
            importing: StdMutex::new(std::collections::HashSet::new()),
            handoffs,
            agent_hosts: AtomicBool::new(false),
            end_agents_on_shutdown: AtomicBool::new(false),
            keep_on_shutdown: StdMutex::new(Default::default()),
            settled_by_shutdown: StdMutex::new(Default::default()),
            launchers: StdMutex::new(HashMap::new()),
            probe_errors: StdMutex::new(HashMap::new()),
            clock: StdMutex::new(crate::clock::TokioClock::new()),
            idle_child: StdMutex::new(Some(IDLE_CHILD)),
            idle_wake: Arc::new(Notify::new()),
            idle_reaper: AtomicBool::new(false),
            stopping: AtomicBool::new(false),
            idle_pass: Mutex::new(()),
        });
        hub.load_from_store();
        if tokio::runtime::Handle::try_current().is_ok() {
            let h = hub.clone();
            tokio::spawn(async move { h.peer_notice_loop().await });
            for (name, pc) in peers_cfg {
                hub.start_peer(&name, &pc.url, pc.token.clone());
            }
        }
        hub
    }

    /// Drive lifecycle timers from `clock` (tests pass a `ManualClock`).
    pub fn set_clock(&self, clock: Arc<dyn crate::clock::Clock>) {
        *self.clock.lock().unwrap() = clock;
        self.idle_wake.notify_one();
    }

    /// How long an unused session harness lives; None keeps it forever.
    pub fn set_idle_child(&self, idle: Option<std::time::Duration>) {
        *self.idle_child.lock().unwrap() = idle;
        self.idle_wake.notify_one();
    }

    /// Points adopt at other harness stores (tests use fixture stores).
    pub fn set_harness_homes(&self, homes: crate::adopt::HarnessHomes) {
        *self.harness_homes.lock().unwrap() = homes;
    }

    pub fn subscribe(&self) -> broadcast::Receiver<HubEvent> {
        self.events.subscribe()
    }

    /// Hold session creation and agent spawns until `finish_startup`.
    pub fn begin_startup(&self, login_env: bool) {
        self.login_env_requested.store(login_env, Ordering::SeqCst);
        self.startup_ready.send_replace(false);
    }

    /// Background startup: import the login environment (when requested),
    /// reload the catalog so PATH discovery sees it, check launchers, then
    /// let spawns through and probe models.
    pub async fn finish_startup(self: &Arc<Self>) {
        let login_env = self.login_env_requested.load(Ordering::SeqCst);
        let mut reloaded = false;
        if login_env && crate::login_env::import().await {
            match self.reload_catalog().await {
                Ok(_) => reloaded = true,
                Err(e) => tracing::warn!("catalog reload after login env: {e}"),
            }
        }
        self.verify_launchers().await;
        self.startup_ready.send_replace(true);
        tracing::info!("startup complete; agents may spawn");
        // A catalog reload already started fresh probes.
        if !reloaded {
            self.probe_models().await;
        }
    }

    pub fn startup_complete(&self) -> bool {
        *self.startup_ready.borrow()
    }

    /// Wait until background startup has finished (immediate outside a daemon).
    pub(super) async fn wait_startup(&self) {
        let mut rx = self.startup_ready.subscribe();
        let _ = rx.wait_for(|ready| *ready).await;
    }

    /// Run `--version` on proxy launchers off the executor and mark the ones
    /// that fail unavailable (and drop fallbacks that point at them).
    async fn verify_launchers(&self) {
        let mut probe = self.config.read().await.clone();
        let before = probe.harnesses.clone();
        let Ok(probe) = tokio::task::spawn_blocking(move || {
            crate::config::verify_launchers(&mut probe);
            probe
        })
        .await
        else {
            return;
        };
        let mut cfg = self.config.write().await;
        // Launchers the probe rerouted (claude-sr through the subrouter server), unless a
        // reload changed them meanwhile.
        for (name, routed) in &probe.harnesses {
            let unchanged =
                cfg.harnesses.get(name).map(|p| &p.argv) == before.get(name).map(|p| &p.argv);
            if unchanged
                && before.get(name).map(|p| &p.argv) != Some(&routed.argv)
                && before.contains_key(name)
            {
                cfg.harnesses.insert(name.clone(), routed.clone());
            }
        }
        for (name, reason) in &probe.unavailable {
            let argv = |c: &Config| c.harnesses.get(name).map(|p| p.argv.clone());
            if argv(&cfg) != argv(&probe) || cfg.unavailable.contains_key(name) {
                continue;
            }
            for p in cfg.harnesses.values_mut() {
                if p.fallback.as_deref() == Some(name.as_str()) {
                    p.fallback = None;
                }
            }
            cfg.unavailable.insert(name.clone(), reason.clone());
        }
    }

    pub(super) fn load_from_store(self: &Arc<Self>) {
        let metas = match self.store.list() {
            Ok(m) => m,
            Err(e) => {
                tracing::warn!("store list failed: {e}");
                return;
            }
        };
        let mut sessions = self.sessions.lock().unwrap();
        for mut meta in metas {
            if meta.status != SessionStatus::Closed {
                meta.status = SessionStatus::Idle;
            }
            // Meta is saved less often than events; after a hard stop the
            // log can be ahead of it. Never hand out a sequence twice.
            if let Ok(extra) = self.store.events(&meta.id, meta.last_seq, 1_000_000)
                && let Some(last) = extra.last()
            {
                meta.event_count += extra.len() as u64;
                meta.last_seq = last.seq;
            }
            let session = self.make_session(meta);
            sessions.insert(session.id.clone(), session);
        }
        tracing::info!("loaded {} sessions from store", sessions.len());
        drop(sessions);
        // A turn whose agent host still runs is not lost: the host is adopted.
        self.mark_unknown_outcomes(&Self::live_host_sessions());
    }

    pub(super) fn make_session(&self, meta: SessionMeta) -> Arc<Session> {
        let (inbound_tx, inbound_rx) = mpsc::channel(1024);
        Arc::new(Session {
            id: meta.id.clone(),
            seq: AtomicU64::new(meta.last_seq),
            meta: StdMutex::new(meta),
            child: Mutex::new(None),
            spawn_lock: Mutex::new(()),
            append_lock: StdMutex::new(()),
            loading: AtomicBool::new(false),
            turn_lock: Mutex::new(()),
            turn: StdMutex::new(None),
            queued: AtomicU64::new(0),
            queue: StdMutex::new(Vec::new()),
            stream: StdMutex::new(StreamState::default()),
            permissions: StdMutex::new(permission_groups::PermissionState::default()),
            permission_epoch: AtomicU64::new(0),
            rehydrate: AtomicBool::new(false),
            inbound_tx,
            inbound_rx: Mutex::new(Some(inbound_rx)),
            steering: AtomicBool::new(false),
            fork_from: StdMutex::new(None),
            purged: AtomicBool::new(false),
            state_seq: AtomicU64::new(0),
            attached: std::sync::atomic::AtomicUsize::new(0),
            stderr_tail: StdMutex::new(std::collections::VecDeque::new()),
            prompts: StdMutex::new(std::collections::VecDeque::new()),
            append_errors: AtomicU64::new(0),
            last_active: AtomicU64::new(self.clock_now()),
        })
    }

    // ------------------------------------------------------------ lookup

    pub fn sessions(&self) -> Vec<Arc<Session>> {
        let mut v: Vec<_> = self.sessions.lock().unwrap().values().cloned().collect();
        v.sort_by_key(|s| std::cmp::Reverse(s.meta().updated_at));
        v
    }

    /// Resolve by id, exact name, or unique prefix of either.
    pub fn resolve(&self, key: &str) -> Result<Arc<Session>, RpcError> {
        let sessions = self.sessions.lock().unwrap();
        if let Some(s) = sessions.get(key) {
            return Ok(s.clone());
        }
        let mut by_name: Vec<_> =
            sessions.values().filter(|s| s.meta().name == key).cloned().collect();
        if by_name.len() == 1 {
            return Ok(by_name.remove(0));
        }
        let by_prefix: Vec<_> = sessions
            .values()
            .filter(|s| s.id.starts_with(key) || s.meta().name.starts_with(key))
            .cloned()
            .collect();
        match by_prefix.len() {
            1 => Ok(by_prefix.into_iter().next().unwrap()),
            0 => Err(RpcError::not_found(format!("no session matches {key:?}"))),
            n => Err(RpcError::invalid_params(format!("{key:?} matches {n} sessions; use the id"))),
        }
    }

    // ------------------------------------------------------------ logging

    pub(super) fn append(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
    ) -> EventRecord {
        self.append_with_host_seq(session, dir, kind, msg, None)
    }

    /// Append one record; `host_seq` names the agent host entry it logs.
    pub(super) fn append_with_host_seq(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
    ) -> EventRecord {
        let _order = session.append_lock.lock().unwrap();
        let seq = session.seq.fetch_add(1, Ordering::SeqCst) + 1;
        let record =
            EventRecord { seq, at: now_ms(), dir: dir.into(), kind: kind.into(), msg, host_seq };
        if session.purged.load(Ordering::SeqCst) {
            return record;
        }
        self.touch(session);
        if let Err(e) = self.store.append(&session.id, &record) {
            session.append_errors.fetch_add(1, Ordering::SeqCst);
            tracing::warn!(session = %session.id, "append failed: {e}");
        }
        {
            let mut m = session.meta.lock().unwrap();
            m.last_seq = seq;
            m.event_count += 1;
            m.updated_at = record.at;
        }
        if matches!(
            kind,
            "status"
                | "permission_request"
                | "permission_decision"
                | "permission_auto"
                | "permission_group"
                | "permission_chat_allowance"
                | "turn_started"
                | "turn_result"
                | "turn_end"
                | "turn_error"
                | "queued"
                | "dequeued"
                | "created"
                | "tags"
                | "rules"
        ) {
            session.state_seq.fetch_add(1, Ordering::SeqCst);
        }
        let _ = self.events.send(HubEvent {
            session_id: session.id.clone(),
            record: record.clone(),
            remote: None,
        });
        record
    }

    /// A client attached or detached. Attaching clears the unread bit.
    pub fn attach_count(&self, session: &Session, delta: i32) {
        // A client letting go starts the idle period; one arriving resets it.
        self.touch(session);
        use std::sync::atomic::AtomicUsize;
        let _ = AtomicUsize::new(0);
        if delta > 0 {
            session.attached.fetch_add(delta as usize, Ordering::SeqCst);
            let was_unread = {
                let mut m = session.meta.lock().unwrap();
                std::mem::replace(&mut m.unread, false)
            };
            if was_unread {
                self.save_meta(session);
                self.append(
                    session,
                    "mux",
                    "status",
                    json!({"status": session.status().to_string(), "read": true}),
                );
            }
        } else {
            let d = (-delta) as usize;
            let _ = session
                .attached
                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |v| Some(v.saturating_sub(d)));
        }
    }

    /// Orchestrator tags with optional expiry.
    pub fn set_tags(
        &self,
        session: &Session,
        set: Option<&serde_json::Map<String, Value>>,
        remove: &[String],
        ttl_seconds: Option<u64>,
    ) {
        {
            let mut m = session.meta.lock().unwrap();
            let expires_at = ttl_seconds.map(|t| now_ms().saturating_add(t.saturating_mul(1000)));
            if let Some(set) = set {
                for (k, v) in set {
                    let value = match v {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    };
                    m.tags.insert(k.clone(), crate::store::Tag { value, expires_at });
                }
            }
            for k in remove {
                m.tags.remove(k);
            }
        }
        self.save_meta(session);
        self.append(session, "mux", "tags", json!({"tags": live_tags(&session.meta())}));
    }

    pub fn set_rules(&self, session: &Session, rules: Option<Value>) {
        self.permission_policy_changed(session, |m| m.permission_rules = rules.clone());
        self.save_meta(session);
        self.append(session, "mux", "rules", json!({"rules": rules}));
    }

    /// Turn-by-turn summary from the event log.
    pub fn history(&self, session: &Session, limit: usize) -> Vec<Value> {
        let events = self.store.events(&session.id, 0, 500_000).unwrap_or_default();
        let mut turns: Vec<Value> = Vec::new();
        let mut cur: Option<serde_json::Map<String, Value>> = None;
        for e in events {
            match e.kind.as_str() {
                "user_message" if e.msg.get("steer").and_then(Value::as_bool) != Some(true) => {
                    if let Some(t) = cur.take() {
                        turns.push(Value::Object(t));
                    }
                    let mut t = serde_json::Map::new();
                    t.insert("seq".into(), json!(e.seq));
                    t.insert("startedAt".into(), json!(e.at));
                    t.insert(
                        "prompt".into(),
                        json!(short_text(
                            e.msg.get("text").and_then(Value::as_str).unwrap_or(""),
                            120
                        )),
                    );
                    t.insert("toolCalls".into(), json!(0));
                    t.insert("permissions".into(), json!(0));
                    t.insert("status".into(), json!("running"));
                    cur = Some(t);
                }
                "tool_call" => {
                    if let Some(t) = cur.as_mut() {
                        let n = t.get("toolCalls").and_then(Value::as_u64).unwrap_or(0);
                        t.insert("toolCalls".into(), json!(n + 1));
                    }
                }
                "permission_request" | "permission_auto" => {
                    if let Some(t) = cur.as_mut() {
                        let n = t.get("permissions").and_then(Value::as_u64).unwrap_or(0);
                        t.insert("permissions".into(), json!(n + 1));
                    }
                }
                "usage_update" => {
                    if let Some(t) = cur.as_mut()
                        && let Some(u) =
                            e.msg.pointer("/params/update/used").and_then(Value::as_u64)
                    {
                        t.insert("tokens".into(), json!(u));
                    }
                }
                "turn_result" => {
                    if let Some(t) = cur.as_mut() {
                        t.insert(
                            "status".into(),
                            e.msg.get("status").cloned().unwrap_or(json!("completed")),
                        );
                        t.insert(
                            "stopReason".into(),
                            e.msg.get("stopReason").cloned().unwrap_or(Value::Null),
                        );
                        t.insert("endedAt".into(), json!(e.at));
                        let started = t.get("startedAt").and_then(Value::as_u64).unwrap_or(e.at);
                        t.insert("wallMs".into(), json!(e.at.saturating_sub(started)));
                        if let Some(err) = e.msg.get("error") {
                            t.insert("error".into(), err.clone());
                        }
                    }
                }
                "turn_end" | "turn_error" => {
                    // Older logs without turn_result.
                    if let Some(t) = cur.as_mut()
                        && t.get("endedAt").is_none()
                    {
                        let failed = e.kind == "turn_error";
                        t.insert(
                            "status".into(),
                            json!(if failed { "failed" } else { "completed" }),
                        );
                        t.insert(
                            "stopReason".into(),
                            e.msg.get("stopReason").cloned().unwrap_or(Value::Null),
                        );
                        t.insert("endedAt".into(), json!(e.at));
                        let started = t.get("startedAt").and_then(Value::as_u64).unwrap_or(e.at);
                        t.insert("wallMs".into(), json!(e.at.saturating_sub(started)));
                    }
                }
                _ => {}
            }
        }
        if let Some(t) = cur.take() {
            turns.push(Value::Object(t));
        }
        let n = turns.len();
        turns.into_iter().skip(n.saturating_sub(limit)).collect()
    }

    /// After a restart: a turn that started but never settled gets a
    /// `turn_result failed outcome_unknown`, so nobody replays a prompt that
    /// may have run to completion.
    pub(super) fn mark_unknown_outcomes(&self, hosted: &std::collections::HashSet<String>) {
        for session in self.sessions() {
            if hosted.contains(&session.id) {
                continue;
            }
            // Scan the whole log: a long turn can stream far more records
            // than any fixed tail window after its `turn_started`.
            let mut open: Option<(u64, Value)> = None;
            let scanned = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
                match e.kind.as_str() {
                    "turn_started" => {
                        open = Some((e.seq, e.msg.get("turnId").cloned().unwrap_or(Value::Null)))
                    }
                    "turn_result" => open = None,
                    _ => {}
                }
                true
            });
            if scanned.is_err() {
                continue;
            }
            if let Some((seq, turn_id)) = open {
                let error = "the daemon restarted before this turn settled";
                self.append(&session, "mux", "turn_result", json!({"status": "failed", "detail": "outcome_unknown", "turnSeq": seq, "turnId": turn_id, "error": error, "errorText": error}));
                self.save_meta(&session);
            }
        }
    }

    pub(super) fn save_meta(&self, session: &Session) {
        let meta = session.meta();
        if let Err(e) = self.store.save(&meta) {
            tracing::warn!(session = %session.id, "save meta failed: {e}");
        }
    }

    pub(super) fn set_status(&self, session: &Session, status: SessionStatus) {
        let changed = {
            let mut m = session.meta.lock().unwrap();
            let changed = m.status != status;
            m.status = status;
            m.updated_at = now_ms();
            changed
        };
        if changed {
            self.append(session, "mux", "status", json!({"status": status.to_string()}));
            self.save_meta(session);
        }
    }

    pub fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.store.events(id, after, limit)
    }

    pub fn session_dir(&self, id: &str) -> Option<PathBuf> {
        self.store.session_dir(id)
    }
}

/// Browser URL for the dashboard, with the token in the query string.
pub fn web_url(w: &crate::config::WebSocketConfig) -> String {
    let host = w.listen.replace("0.0.0.0", "127.0.0.1").replace("[::]", "[::1]");
    match &w.token {
        Some(t) => format!("http://{host}/?token={t}"),
        None => format!("http://{host}/"),
    }
}

/// Current value of a select config option, by id.
pub fn current_option(m: &SessionMeta, id: &str) -> Option<String> {
    let opts = m.config_options.as_ref().and_then(Value::as_array)?;
    opts.iter()
        .find(|o| o.get("id").and_then(Value::as_str) == Some(id))
        .and_then(|o| o.get("currentValue").and_then(Value::as_str).map(str::to_owned))
}

/// The option id a harness uses for thinking effort, given the name a
/// client asked for. `effort` is the portable name; Codex calls it
/// `reasoning_effort`.
pub fn resolve_config_id(m: &SessionMeta, id: &str) -> String {
    let ids: Vec<String> = m
        .config_options
        .as_ref()
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|o| o.get("id").and_then(Value::as_str).map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();
    if ids.iter().any(|x| x == id) {
        return id.to_owned();
    }
    if matches!(id, "effort" | "thinking" | "reasoning" | "reasoning_effort") {
        for cand in ["effort", "reasoning_effort", "thinking", "reasoning", "thought_level"] {
            if ids.iter().any(|x| x == cand) {
                return cand.to_owned();
            }
        }
    }
    id.to_owned()
}

pub fn current_model(m: &SessionMeta) -> Option<String> {
    if let Some(r) = &m.model_request {
        return Some(r.clone());
    }
    if let Some(opts) = m.config_options.as_ref().and_then(Value::as_array) {
        for o in opts {
            if o.get("id").and_then(Value::as_str) == Some("model")
                && let Some(v) = o.get("currentValue").and_then(Value::as_str)
            {
                return Some(v.to_owned());
            }
        }
    }
    m.models
        .as_ref()
        .and_then(|x| x.get("currentModelId"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}
