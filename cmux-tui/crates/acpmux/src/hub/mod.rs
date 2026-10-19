//! The hub owns every session, its child agent, its event log, and the clients' fan-out channel.
//! Method groups live in sibling files: `peers` (remote daemons), `lifecycle` (spawn, resume,
//! fork), `permissions` (agent requests and policy), `turns` (prompt, cancel, config), `transfer`
//! (export, import), `views` (summaries), `handoff` (a reviewed first message to another harness),
//! `adoption` (resuming a harness's own session), `models_view` (the picker's model lists).

mod adoption;
mod aside;
pub(crate) mod auto_resume;
mod btw;
mod exit_reason;
mod turn_errors;
pub(crate) use btw::SIDE_TAG;
mod bookmarks;
mod cancel;
mod catalog_reload;
mod complete;
mod cursor_ext;
mod fork;
mod fork_at;
pub mod forum;
mod handoff;
mod harness_view;
mod harness_watch;
mod health_view;
mod idle;
mod launch_roots;
mod launchers;
mod live_models;
pub use handoff::{HANDOFF_OPERATIONS, MAX_CAPSULE_BYTES};
mod hosts;
mod lifecycle;
pub(crate) mod model_availability;
mod model_options;
mod new_request;
pub use model_options::{
    current_effort, current_model, current_option, resolve_config_id, web_url,
};
mod model_hint;
mod models_view;
mod paging;
mod personal_stats;
mod pool;
mod prompt_images;
mod queue;
mod queue_edit;
pub use queue::QueuedPrompt;
mod resolve;
mod route_switch;
pub use pool::{PrewarmRequest, RssProbe, tree_rss_bytes};
pub use route_switch::HarnessRestarts;
pub(crate) use route_switch::route_error;
pub(crate) use turn_errors::is_limit_error;
mod offer_results;
mod offers;
mod secrets;
mod seen;
mod session;
pub(crate) mod session_pages;
pub use session::{Session, live_tags};
pub(super) use session::{prompt_text, short_text};
mod shutdown;
mod spawn;
mod start_defaults;
pub(crate) mod start_mode;
mod startup;
mod steer_end;
mod stream;
mod tags;
mod tap;
mod titles;
mod tools;
pub use new_request::{
    NewRequest, declared_model_json, profile_takes_model_at_spawn, terminal_harness_refusal,
};
pub use paging::{EventFilter, EventPage};
pub use spawn::expand_env_value;
mod peers;
pub(crate) use peers::PEER_PERMISSION_PENDING;
mod permission_groups;
mod permissions;
pub mod person;
mod processes;
mod questions;
mod remote_floor;
mod remote_sandbox;
mod start_gate;
pub mod subsessions;
pub use permission_groups::PERMISSION_GROUP_OPERATIONS;
pub mod rules;
mod transcript;
mod transfer;
mod transfer_guard;
mod transfer_in;
mod transfer_out;
mod transfer_watch;
mod turn_usage;
mod turns;
pub(crate) mod views;
mod warm;
mod web_control;
mod web_token;
mod xai;
pub use web_control::Control;
pub(crate) use web_control::ModeWrite;
pub use web_token::WebToken;

use crate::agent::{ChildAgent, Direction, Inbound};
use crate::config::{Config, HarnessProfile, PermissionPolicy};
use crate::mailbox::Mailbox;
use crate::rpc::{Id, Message, RpcError, method};
use crate::session_identity::{LOCAL_HOST_ID, SessionReceipt};
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
    pub receipt: SessionReceipt,
}

#[derive(Debug)]
pub(super) struct PendingPermission {
    pub(super) request: Value,
    pub(super) reply: oneshot::Sender<Value>,
    /// The nonce a relayed allow's decision proof covers (`person.rs`,
    /// cx-0q7o): new for each prompt, valid only while it is pending.
    pub(super) decision_nonce: String,
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
    /// Who prompted (or steered) this turn. A Web turn never uses the chat
    /// allowance: each eligible permission in it still asks.
    pub control: Control,
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
    /// The rules the prompt runs under, checked again at dispatch.
    pub control: Control,
    /// Whether this prompt came from a gated app/Web path and must be checked
    /// again when a queued turn is dispatched.
    pub trust_gate: bool,
    /// A steer that must not become a queued prompt
    /// (`_meta.acpmux.steerOnly`): refused (`steer.unavailable`) when the
    /// session cannot steer now (no running turn, or an agent that does not
    /// steer).
    pub steer_only: bool,
    /// A steer (`_meta.acpmux.interrupt`) that an agent which cannot steer takes as "stop the
    /// running turn and run this next" instead of waiting behind the queue.
    pub interrupt: bool,
    /// Who sent the prompt, when not the person (`prompt_provenance.rs`).
    pub provenance: Option<Value>,
    /// An automatic continuation (`auto_resume.rs`): runs only while the chat still ends on
    /// this turn, checked again once it holds the turn lock, else refused unrecorded.
    pub after_turn: Option<String>,
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

pub struct Hub {
    pub config: RwLock<Config>,
    pub(super) store: Box<dyn Store>,
    pub(super) mailbox: Mailbox,
    /// The forum log (`forum.rs`, `hub/forum.rs`).
    pub(super) forum: std::sync::OnceLock<crate::forum::Forum>,
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
    /// Model lists from Claude Code's and Codex's own CLIs, by profile name
    /// (`hub/live_models.rs`): richer than `known_models` (efforts, fast).
    pub(super) live_models: StdMutex<HashMap<String, Vec<crate::live_models::LiveModel>>>,
    /// (harness, model) pairs whose backend refused them, with its message (model_availability.rs).
    pub(super) refused_models: StdMutex<HashMap<(String, String), String>>,
    /// False while the daemon finishes startup work (login environment,
    /// launcher checks) in the background. Session creation and agent
    /// spawns wait for it; every other request is answered at once.
    pub(super) startup_ready: tokio::sync::watch::Sender<bool>,
    /// Startup has read the login environment: the catalog sees its PATH.
    pub(super) catalog_ready: tokio::sync::watch::Sender<bool>,
    pub(super) login_env_requested: AtomicBool,
    /// Session ids an `import` is writing right now.
    pub(super) importing: StdMutex<std::collections::HashSet<String>>,
    pub(super) handoffs: handoff::Handoffs,
    /// New agents run under agent hosts (`enable_agent_hosts`).
    pub(super) agent_hosts: AtomicBool,
    /// What the coming shutdown does with hosted agents, decided once:
    /// `_acpmux/shutdown endAgents` sets it until the shutdown takes it.
    pub(super) shutdown_plan: StdMutex<shutdown::ShutdownPlan>,
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
    /// The harnesses the model probes may start (`ACPMUX_PROBE_HARNESSES`);
    /// None: every harness.
    pub(super) probe_only: StdMutex<Option<std::collections::BTreeSet<String>>>,
    pub(super) idle_wake: Arc<Notify>,
    pub(super) idle_reaper: AtomicBool,
    /// Set when `shutdown_all` starts: the idle reaper stops for good.
    pub(super) stopping: AtomicBool,
    /// Held by one idle reaper pass; shutdown waits for it after `stopping`.
    pub(super) idle_pass: Mutex<()>,
    /// Hidden pre-created sessions for instant harness switches (`pool/`).
    pub(super) pool: Arc<pool::PoolState>,
    /// The merged asking-mode table for Web connections (`web_control.rs`).
    pub(super) web_modes: StdMutex<web_control::WebModeCache>,
    /// Where the folder-trust gate reads (`server/trust_gate.rs`); None: no gate.
    pub(super) trust_gate: StdMutex<Option<crate::trust::Paths>>,
    /// The `sandbox-exec` remote chains run Claude Code under (`remote_sandbox.rs`).
    pub(super) remote_sandbox_exec: StdMutex<PathBuf>,
    /// The device-wide chat index, once started (`chats/`).
    pub(crate) chats: std::sync::OnceLock<Arc<crate::chats::ChatService>>,
    /// Work that waits for the chat index to start (`Hub::when_chats_ready`).
    pub(crate) chats_waiters: StdMutex<Vec<crate::chats::ChatsWaiter>>,
    pub(super) harness_watch: harness_watch::HarnessWatchState,
    pub catalog: Arc<crate::catalog::CatalogService>,
    /// Agent CLI health (`harness_health`, `hub/health_view.rs`).
    pub health: Arc<crate::harness_health::HealthService>,
    /// The token the web listener checks now (`web_token.rs`).
    pub web_token: WebToken,
    /// This launch's person key (`person.rs`): who may allow and grant.
    pub person: person::PersonGate,
    /// How long a move may go without its client (`transfer_watch.rs`).
    pub(super) transfer_lease: StdMutex<std::time::Duration>,
    /// Chats agents offered the person, still open (`offers.rs`).
    pub(super) offers: offers::Offers,
    /// Open sub-sessions per parent and starts in flight (`subsessions.rs`).
    pub(super) subsessions: subsessions::Index,
    /// Automatic continuations waiting to fire, by chat (`auto_resume.rs`).
    pub(super) auto_resumes: auto_resume::Pending,
    /// Fired by `set_transfer_lease`: each move's watch reads the new lease now.
    pub(super) transfer_lease_changed: Notify,
    /// Secrets agents asked the person for, and their one-use refs (`secrets.rs`).
    pub(super) secrets: secrets::Secrets,
}

impl Hub {
    pub fn new(config: Config, store: Box<dyn Store>) -> Arc<Self> {
        Self::new_with_mailbox(config, store, Mailbox::memory())
    }

    pub fn new_with_mailbox(config: Config, store: Box<dyn Store>, mailbox: Mailbox) -> Arc<Self> {
        let (events, _) = broadcast::channel(8192);
        let (peer_notices, peer_notices_rx) = mpsc::channel(4096);
        let peers_cfg = config.peers.clone();
        let handoffs = handoff::Handoffs::open(store.handoff_dir());
        let hub = Arc::new(Self {
            config: RwLock::new(config),
            store,
            mailbox,
            forum: std::sync::OnceLock::new(),
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
            live_models: StdMutex::new(HashMap::new()),
            refused_models: StdMutex::new(HashMap::new()),
            startup_ready: tokio::sync::watch::channel(true).0,
            catalog_ready: tokio::sync::watch::channel(true).0,
            login_env_requested: AtomicBool::new(false),
            importing: StdMutex::new(std::collections::HashSet::new()),
            handoffs,
            agent_hosts: AtomicBool::new(false),
            shutdown_plan: StdMutex::new(shutdown::ShutdownPlan::default()),
            settled_by_shutdown: StdMutex::new(Default::default()),
            launchers: StdMutex::new(HashMap::new()),
            probe_errors: StdMutex::new(HashMap::new()),
            clock: StdMutex::new(crate::clock::TokioClock::new()),
            idle_child: StdMutex::new(Some(IDLE_CHILD)),
            probe_only: StdMutex::new(None),
            idle_wake: Arc::new(Notify::new()),
            idle_reaper: AtomicBool::new(false),
            stopping: AtomicBool::new(false),
            idle_pass: Mutex::new(()),
            pool: Arc::new(pool::PoolState::new()),
            web_modes: StdMutex::new(Default::default()),
            trust_gate: StdMutex::new(None),
            remote_sandbox_exec: StdMutex::new(PathBuf::from(remote_sandbox::SANDBOX_EXEC)),
            chats: std::sync::OnceLock::new(),
            chats_waiters: StdMutex::new(Vec::new()),
            harness_watch: Default::default(),
            catalog: Arc::new(crate::catalog::CatalogService::new()),
            health: Arc::new(crate::harness_health::HealthService::new()),
            web_token: WebToken::new(String::new()),
            person: Default::default(),
            transfer_lease: StdMutex::new(transfer_watch::TRANSFER_LEASE),
            offers: Default::default(),
            subsessions: Default::default(),
            auto_resumes: Default::default(),
            transfer_lease_changed: Notify::new(),
            secrets: Default::default(),
        });
        if let Ok(c) = hub.config.try_read() {
            hub.refresh_web_modes(&c);
        }
        hub.load_from_store();
        if tokio::runtime::Handle::try_current().is_ok() {
            let h = hub.clone();
            tokio::spawn(async move { h.peer_notice_loop().await });
            hub.watch_transfers();
            hub.watch_titles();
            for (name, pc) in peers_cfg {
                hub.start_peer(&name, &pc);
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

    /// Limits the model probes to `names` (None: every harness), so a
    /// client that uses a few harnesses (the Chief) never starts the others'
    /// agents at daemon start. Set before `begin_startup`.
    pub fn set_probe_only(&self, names: Option<std::collections::BTreeSet<String>>) {
        *self.probe_only.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = names;
    }

    /// A client now uses `names` too (the Chief's engine set): they join the
    /// probe list and are probed now, in the background, so their model
    /// lists arrive without a daemon restart.
    pub async fn allow_probes(self: &Arc<Self>, names: std::collections::BTreeSet<String>) {
        if let Some(list) =
            self.probe_only.lock().unwrap_or_else(std::sync::PoisonError::into_inner).as_mut()
        {
            list.extend(names.iter().cloned());
        }
        let hub = self.clone();
        tokio::spawn(async move { hub.probe_models_with(false, false, Some(names)).await });
    }

    /// Whether the model probes may start harness `name`.
    pub(super) fn probes(&self, name: &str) -> bool {
        self.probe_only
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .is_none_or(|names| names.contains(name))
    }

    /// `ACPMUX_PROBE_HARNESSES`: comma-separated harness names; unset, every harness.
    pub fn probe_only_from_env(value: Option<&str>) -> Option<std::collections::BTreeSet<String>> {
        value.map(|v| {
            v.split(',').map(str::trim).filter(|n| !n.is_empty()).map(str::to_owned).collect()
        })
    }

    /// Turns on the folder-trust gate for the app's agent pane, reading the
    /// agents' files and acpmux's record at `paths` (the daemon passes the
    /// user's; tests pass fixtures). None turns it off.
    pub fn set_trust_gate(&self, paths: Option<crate::trust::Paths>) {
        *self.trust_gate.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = paths;
    }

    /// The gate's paths, while the gate is on.
    pub fn trust_gate(&self) -> Option<crate::trust::Paths> {
        self.trust_gate.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// Where adopt looks for harness sessions by default.
    pub fn harness_homes(&self) -> crate::adopt::HarnessHomes {
        self.harness_homes.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// Points adopt at other harness stores (tests use fixture stores).
    pub fn set_harness_homes(&self, homes: crate::adopt::HarnessHomes) {
        *self.harness_homes.lock().unwrap() = homes;
    }

    pub fn subscribe(&self) -> broadcast::Receiver<HubEvent> {
        self.events.subscribe()
    }

    pub fn mailbox(&self) -> &Mailbox {
        &self.mailbox
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
        let waiting: Vec<String> = metas
            .iter()
            .filter(|m| m.status == SessionStatus::Waiting)
            .map(|m| m.id.clone())
            .collect();
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
            // Every child's short name stays taken (`subsessions.rs`).
            if let Some(link) = &meta.subsession {
                self.subsessions.note_name(&link.started_by, &link.short_name);
            }
            // A sub-session that is not closed holds a slot of its parent (`subsessions.rs`).
            if let Some(link) =
                meta.subsession.as_ref().filter(|_| meta.status != SessionStatus::Closed)
            {
                self.subsessions.set_open(&link.started_by, &meta.id, true);
            }
            let session = self.make_session(meta);
            sessions.insert(session.id.clone(), session);
        }
        tracing::info!("loaded {} sessions from store", sessions.len());
        drop(sessions);
        // A turn whose agent host still runs is not lost: the host is adopted.
        let hosted = Self::live_host_sessions();
        self.mark_lost_waits(&waiting, &hosted);
        self.mark_unknown_outcomes(&hosted);
        self.restore_queues();
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
            queue_moved: Notify::new(),
            moving: StdMutex::new(None),
            restored: StdMutex::new(Vec::new()),
            stream: StdMutex::new(StreamState::default()),
            permissions: StdMutex::new(permission_groups::PermissionState::default()),
            permission_epoch: AtomicU64::new(0),
            input_since: AtomicU64::new(0),
            asks_in_flight: std::sync::atomic::AtomicUsize::new(0),
            asks_landed: Notify::new(),
            rehydrate: AtomicBool::new(false),
            forum_retell: AtomicBool::new(false),
            route_switch: AtomicBool::new(false),
            inbound_tx,
            inbound_rx: Mutex::new(Some(inbound_rx)),
            steering: AtomicBool::new(false),
            steer_end: tokio::sync::watch::channel(None).0,
            fork_from: StdMutex::new(None),
            applied: StdMutex::new(session::Applied::default()),
            purged: AtomicBool::new(false),
            state_seq: AtomicU64::new(0),
            attached: std::sync::atomic::AtomicUsize::new(0),
            hidden: std::sync::atomic::AtomicUsize::new(0),
            stderr_tail: StdMutex::new(std::collections::VecDeque::new()),
            prompts: StdMutex::new(std::collections::VecDeque::new()),
            append_errors: AtomicU64::new(0),
            last_active: AtomicU64::new(self.clock_now()),
            web_control_ended: AtomicBool::new(false),
            floor: Default::default(),
            subagents: StdMutex::new(Default::default()),
            processes: StdMutex::new(Default::default()),
        })
    }

    // ------------------------------------------------------------ lookup

    pub fn sessions(&self) -> Vec<Arc<Session>> {
        let v: Vec<_> = self.sessions.lock().unwrap().values().cloned().collect();
        newest_first(v)
    }

    /// Resolve by id, exact name, or unique prefix of either.
    pub fn resolve(&self, key: &str) -> Result<Arc<Session>, RpcError> {
        let sessions = self.sessions.lock().unwrap();
        // A qualified id is authoritative for new routing. The old bare id,
        // name and prefix forms below remain compatible.
        if let Some((host, mux_id)) = SessionReceipt::split_qualified_id(key)
            && host == LOCAL_HOST_ID
            && let Some(s) = sessions.get(mux_id)
        {
            return Ok(s.clone());
        }
        if let Some(s) = sessions.get(key) {
            return Ok(s.clone());
        }
        // Names are read under each session's meta lock, never cloned: a
        // clone of every meta took ~45 ms with 2,500 sessions, on each Stop
        // (`acpmux session cancel NAME`) and every other call by name.
        let named = |s: &Session, pick: &dyn Fn(&str) -> bool| {
            pick(&s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner).name)
        };
        let mut by_name: Vec<_> =
            sessions.values().filter(|s| named(s, &|n| n == key)).cloned().collect();
        if by_name.len() == 1 {
            return Ok(by_name.remove(0));
        }
        let by_prefix: Vec<_> = sessions
            .values()
            .filter(|s| s.id.starts_with(key) || named(s, &|n| n.starts_with(key)))
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
        self.append_logged(session, dir, kind, msg, host_seq).0
    }

    /// [`Hub::append_with_host_seq`], and whether THIS record is in the
    /// store (a purged session counts as stored: nothing is kept for it).
    /// The tap acknowledges a host entry on this result alone.
    pub(super) fn append_logged(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
    ) -> (EventRecord, bool) {
        self.append_at(session, dir, kind, msg, host_seq, None)
    }

    /// [`Hub::append_logged`] of a record that happened at `at` (Unix ms;
    /// None: now), as a fork's copy of its parent's turns did.
    pub(super) fn append_at(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
        at: Option<u64>,
    ) -> (EventRecord, bool) {
        let _order = session.append_lock.lock().unwrap();
        let seq = session.seq.fetch_add(1, Ordering::SeqCst) + 1;
        let at = at.unwrap_or_else(now_ms);
        let record = EventRecord { seq, at, dir: dir.into(), kind: kind.into(), msg, host_seq };
        if session.purged.load(Ordering::SeqCst) {
            return (record, true);
        }
        self.touch(session);
        let stored = match self.store.append(&session.id, &record) {
            Ok(()) => true,
            Err(e) => {
                session.append_errors.fetch_add(1, Ordering::SeqCst);
                tracing::warn!(session = %session.id, "append failed: {e}");
                false
            }
        };
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
                | "queue_removed"
                | "queue_order"
                | "queue_paused"
                | "queue_resumed"
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
        (record, stored)
    }

    pub fn set_rules(&self, session: &Session, rules: Option<Value>) {
        self.permission_policy_changed(session, |m| m.permission_rules = rules.clone());
        self.save_meta(session);
        self.append(session, "mux", "rules", json!({"rules": rules}));
    }

    /// The largest composer draft the daemon will persist for one session.
    pub const MAX_COMPOSER_DRAFT_CHARS: usize = 1_000_000;

    /// Store the unsent composer text without adding it to the transcript.
    /// Whitespace-only input clears the draft while preserving whitespace in a
    /// non-empty draft exactly as typed.
    pub fn set_composer_draft(
        &self,
        session: &Session,
        text: &str,
    ) -> Result<Option<String>, String> {
        if text.chars().count() > Self::MAX_COMPOSER_DRAFT_CHARS {
            return Err(format!(
                "composer draft exceeds {} characters",
                Self::MAX_COMPOSER_DRAFT_CHARS
            ));
        }
        if session.moving().is_some() {
            return Err(queue::moving_error().message);
        }
        let draft = (!text.trim().is_empty()).then(|| text.to_owned());
        {
            let mut meta = session.meta.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            meta.composer_draft = draft.clone();
            meta.updated_at = now_ms();
        }
        self.save_meta(session);
        Ok(draft)
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
                self.append_unknown_outcome(&session, json!({"status": "failed", "detail": "outcome_unknown", "turnSeq": seq, "turnId": turn_id, "error": error, "errorText": error}));
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
        let (was, link) = {
            let mut m = session.meta.lock().unwrap();
            let was = m.status;
            m.status = status;
            m.updated_at = now_ms();
            // The parent's slot follows the status under the same lock, so
            // concurrent status writes and the index never disagree (the
            // index is a leaf lock, `subsessions.rs`).
            if let Some(link) = &m.subsession {
                self.subsessions.set_open(
                    &link.started_by,
                    &session.id,
                    status != SessionStatus::Closed,
                );
            }
            (was, m.subsession.clone())
        };
        if was != status {
            if let Some(link) = &link {
                self.subsession_status(&session.id, link, was, status);
            }
            session.mark_waiting(status == SessionStatus::Waiting);
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

/// The unsent draft went out as `text`, from whichever client sent it: it is no longer the
/// chat's draft. Any other prompt leaves the draft as it is.
fn clear_sent_draft(meta: &mut SessionMeta, text: &str) {
    if meta.composer_draft.as_deref().is_some_and(|d| d.trim() == text.trim()) {
        meta.composer_draft = None;
    }
}

/// `sessions` newest first. Each session's `updated_at` is read once: other
/// tasks move it at any time (every logged event), and a key that is read
/// again on each comparison is not a total order, which makes Rust's sort
/// panic (the Chief daemon, 2026-10-14). Ties keep the session id order, so
/// the list is the same for the same values.
fn newest_first(sessions: Vec<Arc<Session>>) -> Vec<Arc<Session>> {
    let mut keyed: Vec<_> = sessions
        .into_iter()
        .map(|s| {
            let at = s.meta.lock().unwrap_or_else(|e| e.into_inner()).updated_at;
            (at, s)
        })
        .collect();
    keyed.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));
    keyed.into_iter().map(|(_, s)| s).collect()
}

/// Add `fields` under `_meta.acpmux` of an object, keeping any `_meta` the
/// agent sent.
pub(crate) fn merge_mux_meta(v: &mut Value, fields: Value) {
    let Some(obj) = v.as_object_mut() else { return };
    let meta = obj.entry("_meta").or_insert_with(|| json!({}));
    if !meta.is_object() {
        *meta = json!({});
    }
    let mux = meta.as_object_mut().unwrap().entry("acpmux").or_insert_with(|| json!({}));
    if !mux.is_object() {
        *mux = json!({});
    }
    if let (Some(dst), Some(src)) = (mux.as_object_mut(), fields.as_object()) {
        for (k, v) in src {
            dst.insert(k.clone(), v.clone());
        }
    }
}
