//! The hub owns every session, its child agent, its event log, and the clients' fan-out channel.
//! Method groups live in sibling files: `peers` (remote daemons), `lifecycle` (spawn, resume,
//! fork), `permissions` (agent requests and policy), `turns` (prompt, cancel, config), `transfer`
//! (export, import), `views` (summaries), `handoff` (a reviewed first message to another harness),
//! `adoption` (resuming a harness's own session), `models_view` (the picker's model lists).

mod activity;
pub(crate) mod admission;
mod adoption;
mod agent_pairs;
pub use agent_pairs::PairGuard;
mod aside;
pub(crate) mod auto_resume;
mod btw;
mod exit_reason;
pub(crate) mod subagent_retry;
mod turn_errors;
pub(crate) use btw::SIDE_TAG;
pub(crate) use policy_mode::SetRequest;
mod bookmarks;
mod cancel;
mod catalog_reload;
mod complete;
pub mod composers;
mod cursor_ext;
mod digest;
pub(crate) mod dispatch;
pub(crate) mod file_uploads;
pub use file_uploads::FEATURE as FILE_PUT_FEATURE;
mod fork;
mod fork_at;
pub mod forum;
pub(crate) mod full_access_bound;
mod handoff;
mod harness_view;
mod harness_watch;
mod health_view;
mod idle;
mod launch_roots;
mod launchers;
pub mod lineage;
mod live_models;
mod locate;
pub mod media_handles;
pub mod media_read;
pub(crate) mod subagent_transcript;
pub(crate) mod workflow_index;
pub use handoff::{HANDOFF_OPERATIONS, MAX_CAPSULE_BYTES};
pub use media_read::FEATURE as MEDIA_READ_FEATURE;
pub use subagent_transcript::FEATURE as SUBAGENT_TRANSCRIPT_FEATURE;
mod hosts;
mod lifecycle;
mod log_load;
mod retention;
pub use retention::RetentionRequest;
pub(crate) mod model_availability;
pub(crate) use log_load::AdoptionReady;
mod model_options;
mod new_request;
pub use model_options::{
    current_effort, current_model, current_option, resolve_config_id, web_url,
};
mod model_hint;
mod models_view;
mod paging;
mod personal_stats;
mod policy_mode;
mod policy_source;
mod pool;
pub(crate) mod prompt_images;
mod prompt_ledger;
mod prompt_line;
mod queue;
mod queue_edit;
pub use digest::{MAX_FROM_AGENT_CHARS, declared_sender};
pub use queue::{QueuedPrompt, supersede::key as supersede_key};
mod resolve;
mod route_switch;
pub use pool::{PrewarmRequest, RssProbe, tree_rss_bytes};
pub use route_switch::HarnessRestarts;
pub(crate) use route_switch::route_error;
pub(crate) use turn_errors::is_limit_error;
mod git_watch;
mod lane_reports;
mod offer_results;
mod offers;
mod secrets;
mod seen;
mod session;
pub(crate) mod session_pages;
mod settings_watch;
mod silent_turn;
mod stalled_turn;
pub(crate) mod tasks;
pub use session::{Session, live_tags};
pub(super) use session::{newest_first, prompt_text, short_text};
mod shell_readonly;
mod shutdown;
pub use shutdown::SHUTTING_DOWN;
mod spawn;
mod start_defaults;
pub(crate) mod start_mode;
mod start_mode_state;
mod startup;
mod steer_end;
mod stream;
mod tags;
mod tap;
mod titles;
mod tool_paths;
mod tools;
mod watch;
pub use new_request::{
    NewRequest, declared_model_json, profile_takes_model_at_spawn, terminal_harness_refusal,
};
pub use paging::{EventFilter, EventPage, MAX_PAGE_BYTES, page_bytes};
pub use spawn::expand_env_value;
pub mod approvers;
pub mod mac_approvers;
mod own_host;
mod peer_cache;
mod peer_lease;
pub(crate) mod peer_snapshot;
pub use peer_lease::PeerLease;
mod peers;
mod remote_rows;
pub(crate) use peers::{
    PEER_LAGGED, PEER_PERMISSION_PENDING, PEER_SETTLE_BUDGET, is_permission_ask,
};
mod permission_groups;
mod permissions;
pub(crate) use permissions::drop_display_lines;
pub mod person;
pub mod presence;
mod processes;
mod pull_requests;
pub(crate) mod purge_tombstones;
pub(crate) mod questions;
mod remote_floor;
pub(crate) mod remote_sandbox;
pub mod vm_boundary;
pub use vm_boundary::vm_boundary_peer_approves;
mod start_gate;
pub mod vm_host;
pub(crate) use start_gate::host_label;
mod subsession_answer;
mod subsession_guard;
mod subsession_results;
mod subsession_runs;
mod subsession_send;
pub mod subsessions;
pub use permission_groups::PERMISSION_GROUP_OPERATIONS;
pub use subsession_send::Delivery;
mod drafts;
pub(crate) mod outbox;
pub mod rules;
mod transcript;
mod transfer;
mod transfer_guard;
mod transfer_in;
mod transfer_out;
mod transfer_watch;
mod trust_wait;
mod turn_git;
mod turn_usage;
mod turns;
#[cfg(test)]
mod turns_copy_stop_tests;
pub(crate) mod views;
mod warm;
mod watch_events;
pub(crate) mod watches;
mod web_control;
mod web_token;
mod work_below;
pub(crate) mod worktree_care;
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

/// True when a permission request is an agent's question (`questions.rs`): what tells the
/// person about it says the agent asks, never that it needs a permission.
pub(crate) fn is_question(request: &Value) -> bool {
    questions::needs_person(request)
}

/// The first prompt of an agent's question: the normalized copy, else Claude Code's own input.
pub(crate) fn question_prompt(request: &Value) -> Option<&str> {
    questions::question(request)
        .and_then(|q| q.pointer("/items/0/prompt"))
        .or_else(|| request.pointer("/toolCall/rawInput/questions/0/question"))
        .and_then(Value::as_str)
        .filter(|p| !p.is_empty())
}
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

/// Fan-out item: one appended record for one session, shared by every receiver, never copied.
/// `remote` carries the peer name and the peer's summary when the session lives elsewhere.
#[derive(Debug, Clone)]
pub struct HubEvent {
    pub session_id: String,
    pub record: Arc<EventRecord>,
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
    /// A session above may answer it (`questions::ancestor_answerable`): fixed when it was asked.
    pub(super) ancestor_may_answer: bool,
    /// The session's status before this prompt made it Waiting (`settle_permission`).
    pub(super) prev_status: SessionStatus,
    /// The agent's JSON-RPC id for the request, when the agent asked. A
    /// matching `$/cancel_request` withdraws this prompt.
    pub(super) agent_request: Option<Id>,
    /// The hosted child generation that owns `agent_request`.
    pub(super) agent_host_incarnation: Option<String>,
}

#[derive(Debug, Clone)]
pub struct TurnInfo {
    pub started_at: u64,
    pub client: String,
    pub prompt_preview: String,
    /// `prompt_preview` masked before its cut, for the sub-session tools
    /// (`subsession_row`): a secret across the cut leaves no head there.
    pub masked_preview: String,
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
    /// What the turn does right now: its latest tool call's title and its
    /// plan's step in progress, raw and masked (`activity.rs`).
    pub doing: activity::TurnActivity,
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
    /// A steer read now (`_meta.acpmux.steerNow`): steered into the running turn, it stops the
    /// agent's current step at once, as Send now does for a waiting steer (`queue_edit.rs`
    /// `step_now`); the turn runs on. The Chief's tell (Lawrence, 2026-10-26: "interrupt by
    /// default"). A running subagent or background shell is never stopped for it
    /// (claude_stdio `steer_now_tests.rs`).
    pub steer_now: bool,
    /// With `interrupt`, the turn it was aimed at: only that turn stops. A send-now whose turn
    /// ended before the agent took it still goes next, but a turn that began meanwhile (another
    /// agent's message) runs on (Leo, 2026-10-21: "that might have accidentally swallowed up a
    /// queued message").
    pub interrupt_turn: Option<String>,
    /// Who sent the prompt, when not the person (`prompt_provenance.rs`).
    pub provenance: Option<Value>,
    /// Another agent's name when it sent the prompt with no provenance: the session a
    /// connection proved it runs in, or `_meta.acpmux.fromAgent` (`digest.rs`).
    pub agent: Option<String>,
    /// An automatic continuation (`auto_resume.rs`): runs only while the chat still ends on
    /// this turn, checked again once it holds the turn lock, else refused unrecorded.
    pub after_turn: Option<String>,
    /// `_meta.acpmux.supersede` (`supersede.rs`): the same sender's prompts still queued under
    /// this key leave the queue, replaced by this one.
    pub supersede: Option<String>,
    /// Validated display-only metadata from the app's ordered composer. It is persisted in the
    /// mux record and never forwarded to the agent's ACP prompt.
    pub display_parts: Option<Value>,
    /// The paired machine whose Full-access setting covered the request that sent it
    /// (`server/remote_guard.rs` `full_access_device`), read again at dispatch
    /// (`Hub::full_access_hold`).
    pub full_access_device: Option<String>,
    /// A person's subagent retry (`subagent_retry_manual.rs`): refused with `retry.busy` where it
    /// would wait (behind a turn, the queue, the turn lock or a run slot), never queued.
    pub no_queue: bool,
}

/// The outcome of one client prompt id, shared with a resend of it.
pub(super) type PromptOutcome = Arc<tokio::sync::watch::Sender<Option<Result<Value, RpcError>>>>;

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
    /// `_acpmux/models` replies now asking peers for theirs
    /// (`server/models_fanout.rs`): a remote asker meanwhile gets this
    /// daemon's own catalog, so mutual peers cannot ping-pong.
    pub models_fanouts: std::sync::atomic::AtomicUsize,
    pub shutdown: Notify,
    pub started_at: u64,
    pub(super) peers: StdMutex<HashMap<String, Arc<crate::peer::Peer>>>,
    pub(super) remote_sessions: StdMutex<remote_rows::RemoteRows>,
    /// Each parent's children by tag, for an approval card's label (`permissions/display.rs`).
    pub(super) child_tags: permissions::ChildTags,
    /// Leased peers by name, with the generation of the peer each lease
    /// started (`peer_lease.rs`); never saved. Lock order: this, then
    /// `peers`; never `peers` first.
    pub(super) peer_leases: StdMutex<HashMap<String, u64>>,
    /// Each peer session's events as this daemon saw them, kept on disk
    /// (`peer_snapshot.rs`): a paused or offline peer's chat paints from it.
    pub(super) peer_snapshots: peer_snapshot::PeerSnapshots,
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
    /// False from a deferred start (`Hub::new_deferred`) until `load_logs` read every
    /// chat log. A request for one chat waits for that chat's log only (`session_log`).
    pub(super) logs_ready: tokio::sync::watch::Sender<bool>,
    /// The chats whose agent host still ran and those left waiting for a permission when the
    /// last daemon stopped (`log_load.rs`).
    pub(super) load_plan: StdMutex<log_load::LoadPlan>,
    /// `resume_queues` ran: a chat whose log is read later resumes its own queue (`log_load.rs`).
    pub(super) queues_resumed: AtomicBool,
    /// A chat closed: wakes the log retention worker (`retention.rs`).
    pub(super) retention_wake: Arc<Notify>,
    /// False from a deferred start with running agent hosts until adoption ends: prompts to
    /// those chats wait for it (`log_load.rs` `wait_adopted`).
    pub(crate) adoption_ready: tokio::sync::watch::Sender<bool>,
    /// Startup has read the login environment: the catalog sees its PATH.
    pub(super) catalog_ready: tokio::sync::watch::Sender<bool>,
    pub(super) login_env_requested: AtomicBool,
    /// Session ids an `import` is writing right now.
    pub(super) importing: StdMutex<std::collections::HashSet<String>>,
    /// A log retention pass runs (`hub/retention.rs`): one at a time per hub.
    pub(super) retention_running: Arc<AtomicBool>,
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
    /// Fault injection for integration tests; never replaces the keeper's pinned bwrap.
    #[cfg(target_os = "linux")]
    pub(super) linux_bwrap_probe: StdMutex<Option<PathBuf>>,
    /// Where `vm_host.rs` reads the creation marker (`/`; a folder in tests).
    pub(super) vm_marker_root: StdMutex<PathBuf>,
    /// The device-wide chat index, once started (`chats/`).
    pub(crate) chats: std::sync::OnceLock<Arc<crate::chats::ChatService>>,
    /// Work that waits for the chat index to start (`Hub::when_chats_ready`).
    pub(crate) chats_waiters: StdMutex<Vec<crate::chats::ChatsWaiter>>,
    /// The forced start mode and the setting's change count (`start_mode_state.rs`).
    pub(super) start_mode_state: start_mode_state::StartModeCell,
    /// Held by each `sessions.allowFullAccess` push through its teardown (`apply_full_access_push`).
    pub(super) full_access_pushes: tokio::sync::Mutex<()>,
    /// Held (read) by a family message or an ancestor's answer from its last check until it is
    /// written to the agent; an MDM off push takes it (write) once the off is stored
    /// (`full_access_bound.rs` `family_gate`).
    pub(super) family_gate: Arc<tokio::sync::RwLock<()>>,
    /// Bumped by an off push that waited too long on the gate: its holders cut their message.
    pub(super) family_cut: tokio::sync::watch::Sender<u64>,
    /// The fence of an ancestor's answer, by permission id, for the write that delivers it
    /// (`subsession_answer.rs`).
    pub(super) answer_fences: StdMutex<HashMap<String, crate::agent::Fence>>,
    /// Tests only: a pause before a family message's write (`full_access_bound::WriteSeam`).
    #[cfg(test)]
    pub(super) family_write_seam: full_access_bound::WriteSeam,
    /// Tests only: a pause while a prompt's model-sized copies are made (`turns::agent_blocks`).
    #[cfg(test)]
    pub(super) copy_seam: full_access_bound::WriteSeam,
    pub(super) harness_watch: harness_watch::HarnessWatchState,
    /// The settings file watched for start-mode changes (`settings_watch.rs`).
    pub(super) settings_watch: settings_watch::SettingsWatchState,
    /// The HEAD of each attached session's folder, watched for a checkout (`git_watch.rs`).
    pub(super) git_watch: git_watch::GitWatchState,
    pub catalog: Arc<crate::catalog::CatalogService>,
    /// Agent CLI health (`harness_health`, `hub/health_view.rs`).
    pub health: Arc<crate::harness_health::HealthService>,
    /// The token the web listener checks now (`web_token.rs`).
    pub web_token: WebToken,
    /// This launch's person key (`person.rs`): who may allow and grant.
    pub person: person::PersonGate,
    /// Who has each chat open and who types in it, in memory only (`presence.rs`).
    pub presence: presence::Presence,
    /// How long a move may go without its client (`transfer_watch.rs`).
    pub(super) transfer_lease: StdMutex<std::time::Duration>,
    /// How long Ctrl-B waits for Claude Code's answer (`processes.rs`).
    pub(super) background_timeout: StdMutex<std::time::Duration>,
    /// Chats agents offered the person, still open (`offers.rs`).
    pub(super) offers: offers::Offers,
    /// Which session each lane reports its turns to (`lane_reports.rs`).
    pub(super) lane_reports: lane_reports::LaneReports,
    /// Open sub-sessions per parent and starts in flight (`subsessions.rs`).
    pub(super) subsessions: subsessions::Index,
    /// Creates admitted and still starting (`admission.rs`).
    pub(super) admitting: admission::Admitting,
    /// Run slots of each session's sub-sessions (`subsession_runs.rs`).
    pub(super) subsession_runs: Arc<subsession_runs::Runs>,
    /// `_acpmux/wait` requests subscribed and not yet answered (`server/wait.rs`), shown
    /// as `_acpmux/status` `openWaits`.
    pub(crate) open_waits: std::sync::atomic::AtomicUsize,
    /// Automatic continuations waiting to fire, by chat (`auto_resume.rs`).
    pub(super) auto_resumes: auto_resume::Pending,
    /// Failed subagents waiting to be resumed, by chat (`subagent_retry.rs`).
    pub(super) subagent_retries: subagent_retry::Retries,
    /// Fired by `set_transfer_lease`: each move's watch reads the new lease now.
    pub(super) transfer_lease_changed: Notify,
    /// Secrets agents asked the person for, and their one-use refs (`secrets.rs`).
    pub(super) secrets: secrets::Secrets,
    /// Sub-session starts waiting on a folder's trust card, and Not nows (`trust_wait.rs`).
    pub(super) trust_waits: trust_wait::Waits,
    /// Messages `send --no-wait` handed over, and forwarded prompts waiting for a peer's
    /// acceptance (`outbox.rs`).
    pub(crate) outbox: outbox::Outbox,
    pub(crate) watches: watches::Watches,
    pub(crate) peer_accepts: outbox::PeerAccepts,
    /// Agent message pairs and their runaway guard (`agent_pairs.rs`).
    pub(super) agent_pairs: agent_pairs::AgentPairs,
    /// Pairing tickets and paired machines (`crate::pairing`).
    pub pairing: Arc<crate::pairing::Pairing>,
    /// Brief identities shared by dispatch, report and MCP clients.
    pub(crate) briefs: dispatch::Briefs,
    /// Every Claude workflow of this daemon's chats (`workflow_index.rs`).
    pub(crate) workflow_index: workflow_index::WorkflowIndex,
}

impl Hub {
    pub fn new(config: Config, store: Box<dyn Store>) -> Arc<Self> {
        Self::new_with_mailbox(config, store, Mailbox::memory())
    }

    /// A daemon's hub: only the session list is read before it answers. The chat
    /// logs (their tails, queues and unsettled turns) load in `load_logs`, after
    /// the ready line (2026-10-20: reading 3.9 GB of logs first took 26.8 s).
    pub fn new_deferred(config: Config, store: Box<dyn Store>, mailbox: Mailbox) -> Arc<Self> {
        Self::build(config, store, mailbox, true)
    }

    pub fn new_with_mailbox(config: Config, store: Box<dyn Store>, mailbox: Mailbox) -> Arc<Self> {
        Self::build(config, store, mailbox, false)
    }

    fn build(config: Config, store: Box<dyn Store>, mailbox: Mailbox, deferred: bool) -> Arc<Self> {
        let (events, _) = broadcast::channel(8192);
        let (peer_notices, peer_notices_rx) = mpsc::channel(4096);
        let peers_cfg = config.peers.clone();
        let handoffs = handoff::Handoffs::open(store.handoff_dir());
        // Loaded now, so a forced `sessions.allowFullAccess` off holds from the first request
        // after a restart, before the app pushes again (`start_mode_state.rs`).
        let start_mode_state =
            start_mode_state::StartModeCell::load(start_mode_state::state_file(&config).as_deref());
        // Beside the peer caches, in the home they are in; a memory store keeps neither.
        let home = store.peer_cache_dir().and_then(|p| p.parent().map(Path::to_path_buf));
        let peer_snapshots = peer_snapshot::PeerSnapshots::open(home);
        let briefs = dispatch::Briefs::open(store.briefs_path());
        let hub = Arc::new(Self {
            config: RwLock::new(config),
            store,
            mailbox,
            forum: std::sync::OnceLock::new(),
            sessions: StdMutex::new(HashMap::new()),
            harness_homes: StdMutex::new(crate::adopt::HarnessHomes::from_env()),
            events,
            models_fanouts: std::sync::atomic::AtomicUsize::new(0),
            shutdown: Notify::new(),
            started_at: now_ms(),
            peers: StdMutex::new(HashMap::new()),
            remote_sessions: Default::default(),
            child_tags: Default::default(),
            peer_leases: StdMutex::new(HashMap::new()),
            peer_snapshots,
            peer_notices,
            peer_notices_rx: Mutex::new(Some(peer_notices_rx)),
            known_models: StdMutex::new(HashMap::new()),
            live_models: StdMutex::new(HashMap::new()),
            refused_models: StdMutex::new(HashMap::new()),
            startup_ready: tokio::sync::watch::channel(true).0,
            logs_ready: tokio::sync::watch::channel(true).0,
            load_plan: Default::default(),
            queues_resumed: AtomicBool::new(false),
            retention_wake: Arc::new(Notify::new()),
            adoption_ready: tokio::sync::watch::channel(true).0,
            catalog_ready: tokio::sync::watch::channel(true).0,
            login_env_requested: AtomicBool::new(false),
            importing: StdMutex::new(std::collections::HashSet::new()),
            retention_running: Arc::new(AtomicBool::new(false)),
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
            #[cfg(target_os = "linux")]
            linux_bwrap_probe: StdMutex::new(None),
            vm_marker_root: StdMutex::new(PathBuf::from("/")),
            chats: std::sync::OnceLock::new(),
            chats_waiters: StdMutex::new(Vec::new()),
            start_mode_state,
            full_access_pushes: tokio::sync::Mutex::new(()),
            family_gate: Arc::new(tokio::sync::RwLock::new(())),
            family_cut: tokio::sync::watch::channel(0).0,
            answer_fences: StdMutex::new(HashMap::new()),
            #[cfg(test)]
            family_write_seam: Default::default(),
            #[cfg(test)]
            copy_seam: Default::default(),
            harness_watch: Default::default(),
            settings_watch: Default::default(),
            git_watch: Default::default(),
            catalog: Arc::new(crate::catalog::CatalogService::new()),
            health: Arc::new(crate::harness_health::HealthService::new()),
            web_token: WebToken::new(String::new()),
            person: Default::default(),
            presence: Default::default(),
            workflow_index: Default::default(),
            transfer_lease: StdMutex::new(transfer_watch::TRANSFER_LEASE),
            background_timeout: StdMutex::new(processes::STOP_TIMEOUT),
            offers: Default::default(),
            lane_reports: Default::default(),
            subsessions: Default::default(),
            admitting: Default::default(),
            subsession_runs: Default::default(),
            open_waits: Default::default(),
            auto_resumes: Default::default(),
            subagent_retries: Default::default(),
            transfer_lease_changed: Notify::new(),
            secrets: Default::default(),
            trust_waits: Default::default(),
            outbox: Default::default(),
            watches: Default::default(),
            peer_accepts: Default::default(),
            agent_pairs: Default::default(),
            pairing: Default::default(),
            briefs,
        });
        if let Ok(c) = hub.config.try_read() {
            hub.refresh_web_modes(&c);
        }
        hub.recover_staged_replacements();
        hub.load_from_store(deferred);
        if !deferred {
            hub.load_logs();
        }
        if tokio::runtime::Handle::try_current().is_ok() {
            let h = hub.clone();
            tokio::spawn(async move { h.peer_notice_loop().await });
            hub.watch_transfers();
            hub.watch_titles();
            hub.watch_orphans();
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
        *self.harness_homes.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = homes;
    }

    pub fn subscribe(&self) -> broadcast::Receiver<HubEvent> {
        self.events.subscribe()
    }

    pub fn mailbox(&self) -> &Mailbox {
        &self.mailbox
    }

    pub(super) fn load_from_store(self: &Arc<Self>, deferred: bool) {
        let Ok(mut metas) = self.store.list().inspect_err(|e| tracing::warn!("store list: {e}"))
        else {
            return;
        };
        // The small index the chat logs load by (`log_load.rs`): agent hosts still running.
        let hosted = Self::live_host_sessions();
        let waiting =
            metas.iter().filter(|m| m.status == SessionStatus::Waiting).map(|m| m.id.clone());
        if deferred && !hosted.is_empty() {
            self.adoption_ready.send_replace(false);
        }
        *self.load_plan.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            log_load::LoadPlan {
                waiting: waiting.collect(),
                adopting: hosted.clone(),
                hosted: hosted.clone(),
            };
        // An older daemon's approve-all that could be vmHost's asks now (`policy_source.rs`).
        self.settle_legacy_grants(&mut metas);
        let mut sessions = self.sessions.lock().unwrap();
        for mut meta in metas {
            // An agent whose host still runs keeps its saved status until adoption reaches it:
            // it works on meanwhile, never shown idle (claude-sr2, 2026-10-26).
            let kept = deferred
                && hosted.contains(&meta.id)
                && matches!(
                    meta.status,
                    SessionStatus::Running | SessionStatus::Waiting | SessionStatus::Ready
                );
            if meta.status != SessionStatus::Closed && !kept {
                meta.status = SessionStatus::Idle;
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
            session.caught_up.store(false, Ordering::SeqCst);
            // Its log is read after the ready line (`log_load.rs`).
            *session.log_load.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = false;
            session.log_loaded.store(false, Ordering::SeqCst);
            sessions.insert(session.id.clone(), session);
        }
        tracing::info!("loaded {} sessions from store", sessions.len());
        drop(sessions);
        if deferred {
            self.logs_ready.send_replace(false);
        }
    }

    /// Wait until every chat log is read, or their load failed (immediate outside a deferred
    /// daemon start). A request for one chat waits for its own log instead (`session_log`).
    pub(crate) async fn wait_logs(&self) {
        let mut rx = self.logs_ready.subscribe();
        let _ = rx.wait_for(|ready| *ready).await;
    }

    /// Meta is saved less often than events; after a hard stop the log can be
    /// ahead of it. Counts the tail past `lastSeq` once, so no sequence is
    /// handed out twice; only that tail is read.
    pub(super) fn catch_up(&self, session: &Session) {
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.catch_up_locked(session);
    }

    fn catch_up_locked(&self, session: &Session) {
        if session.caught_up.swap(true, Ordering::SeqCst) {
            return;
        }
        let last_seq = session.meta.lock().unwrap().last_seq;
        if let Ok((extra, last)) = self.store.tail_after(&session.id, last_seq)
            && extra > 0
        {
            let mut meta = session.meta.lock().unwrap();
            meta.event_count += extra;
            meta.last_seq = last;
            // The log ran ahead of the saved session (a hard stop): a newer command list may be
            // in that tail, so a client reads the log for it instead of trusting the saved one.
            meta.available_commands = None;
            session.seq.fetch_max(last, Ordering::SeqCst);
        }
    }

    /// Runs `work` for each session on up to 8 threads (sessions are independent).
    pub(super) fn on_every_core(
        &self,
        sessions: &[Arc<Session>],
        work: impl Fn(&Arc<Session>) + Sync,
    ) {
        let workers = std::thread::available_parallelism().map_or(4, |n| n.get()).clamp(1, 8);
        let next = std::sync::atomic::AtomicUsize::new(0);
        std::thread::scope(|scope| {
            for _ in 0..workers.min(sessions.len()) {
                scope.spawn(|| {
                    while let Some(session) = sessions.get(next.fetch_add(1, Ordering::Relaxed)) {
                        work(session);
                    }
                });
            }
        });
    }

    pub(super) fn make_session(&self, mut meta: SessionMeta) -> Arc<Session> {
        let (inbound_tx, inbound_rx) = mpsc::channel(1024);
        // A Claude chat saved without `steering` (an older build) still steers once adopted.
        meta.steering |= crate::claude_stdio::steers_by_info(meta.agent_info.as_ref());
        let steering = meta.steering;
        // Until it starts, an adopted chat goes by the agent it last ran (its saved `agentInfo`).
        let backgrounds_work = crate::claude_stdio::steers_by_info(meta.agent_info.as_ref());
        let session = Arc::new(Session {
            id: meta.id.clone(),
            seq: AtomicU64::new(meta.last_seq),
            meta: StdMutex::new(meta),
            child: Mutex::new(None),
            spawn_lock: Mutex::new(()),
            append_lock: StdMutex::new(()),
            loading: AtomicBool::new(false),
            replaying: StdMutex::new(Vec::new()),
            caught_up: AtomicBool::new(true),
            log_load: StdMutex::new(true),
            log_loaded: AtomicBool::new(true),
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
            work_below_since: StdMutex::new(0),
            unread_after_work: AtomicBool::new(false),
            asks_in_flight: std::sync::atomic::AtomicUsize::new(0),
            asks_landed: Notify::new(),
            rehydrate: AtomicBool::new(false),
            forum_retell: AtomicBool::new(false),
            forum_retold: std::sync::Mutex::default(),
            forum_telling: std::sync::Mutex::default(),
            launched_with_tools: std::sync::atomic::AtomicU8::new(0),
            launch_env: StdMutex::new(None),
            route_switch: AtomicBool::new(false),
            inbound_tx,
            inbound_rx: Mutex::new(Some(inbound_rx)),
            steering: AtomicBool::new(steering),
            backgrounds_work: AtomicBool::new(backgrounds_work),
            steer_now: Default::default(),
            steer_end: tokio::sync::watch::channel(None).0,
            fork_from: StdMutex::new(None),
            applied: StdMutex::new(session::Applied::default()),
            purged: AtomicBool::new(false),
            replaced: AtomicBool::new(false),
            closing: AtomicBool::new(false),
            stops: AtomicU64::new(0),
            cancels: AtomicU64::new(0),
            status_writes: AtomicU64::new(0),
            state_seq: AtomicU64::new(0),
            attached: std::sync::atomic::AtomicUsize::new(0),
            hidden: std::sync::atomic::AtomicUsize::new(0),
            stderr_tail: StdMutex::new(std::collections::VecDeque::new()),
            prompts: StdMutex::new(std::collections::VecDeque::new()),
            append_errors: AtomicU64::new(0),
            last_progress: AtomicU64::new(0),
            heard: AtomicU64::new(0),
            heard_at: std::sync::atomic::AtomicI64::new(0),
            stalled_recheck: AtomicU64::new(0),
            open_tools: StdMutex::new(Default::default()),
            stalled_counted: StdMutex::new(None),
            stalled_gen: AtomicU64::new(0),
            last_model_at: AtomicU64::new(0),
            silent_turn: StdMutex::new(None),
            last_active: AtomicU64::new(self.clock_now()),
            web_control_ended: AtomicBool::new(false),
            floor: Default::default(),
            subagents: StdMutex::new(Default::default()),
            harness_turn: AtomicBool::new(false),
            processes: StdMutex::new(Default::default()),
            pr_creates: StdMutex::new(Default::default()),
            start_calls: StdMutex::new(Default::default()),
            composers: StdMutex::new(Default::default()),
        });
        // Found by its tags from now on (`permissions/display.rs`).
        self.child_tags.note(&session);
        session
    }

    // ------------------------------------------------------------ lookup

    pub fn sessions(&self) -> Vec<Arc<Session>> {
        let v: Vec<_> = self.sessions.lock().unwrap().values().cloned().collect();
        newest_first(v)
    }

    fn resolve_here(&self, key: &str) -> Result<Arc<Session>, RpcError> {
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
        mut msg: Value,
        host_seq: Option<u64>,
        at: Option<u64>,
    ) -> (EventRecord, bool) {
        // Off the append lock: it reads the disk.
        tool_paths::add_canonical_paths(session, kind, &mut msg);
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.catch_up_locked(session);
        let seq = session.seq.fetch_add(1, Ordering::SeqCst) + 1;
        let at = at.unwrap_or_else(now_ms);
        let record = EventRecord { seq, at, dir: dir.into(), kind: kind.into(), msg, host_seq };
        // The agent message runaway guard reads progress from here, not the store.
        if agent_pairs::progress_record(&record) {
            session.last_progress.store(seq, Ordering::SeqCst);
        }
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
        // A closed session's log is not held open: its last records (`status`,
        // then the agent's `stopped`) each close it again (`store.rs` Writers).
        if session.status() == SessionStatus::Closed {
            self.store.close_log(&session.id);
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
                | work_below::RECORD_KIND
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
            record: Arc::new(record.clone()),
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
        // Only the kinds a summary reads are parsed, one record at a time: the whole log
        // as records grew the daemon by 347 MB for a 70 MB Chief log (perf100, rbx).
        const KINDS: &[&str] = &[
            "user_message",
            "tool_call",
            "permission_request",
            "permission_auto",
            "usage_update",
            "turn_result",
            "turn_end",
            "turn_error",
        ];
        let mut turns: Vec<Value> = Vec::new();
        let mut cur: Option<serde_json::Map<String, Value>> = None;
        let _ = self.store.scan_kinds(&session.id, KINDS, &mut |e: EventRecord| {
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
            true
        });
        if let Some(t) = cur.take() {
            turns.push(Value::Object(t));
        }
        let n = turns.len();
        turns.into_iter().skip(n.saturating_sub(limit)).collect()
    }

    /// The seq of the log's last `turn_result`; only those records are parsed.
    pub(super) fn latest_turn_result(&self, id: &str) -> Result<Option<u64>, RpcError> {
        let mut latest = None;
        self.store
            .scan_kinds(id, &["turn_result"], &mut |e: EventRecord| {
                latest = latest.max(Some(e.seq));
                true
            })
            .map_err(|e| RpcError::internal(e.to_string()))?;
        Ok(latest)
    }

    /// Saves the session's record; never a purged session's. A late save (a generated title after
    /// the turn, a tag) would write its record back after the purge deleted it, and the next daemon
    /// start loaded it as a closed session: the Chief's compactor, which purges each node's session
    /// when the node is built, left about 450 of them in two hours (2026-10-20).
    pub(super) fn save_meta(&self, session: &Session) {
        if session.purged.load(Ordering::SeqCst) {
            return;
        }
        let meta = session.meta();
        if let Err(e) = self.store.save(&meta) {
            tracing::warn!(session = %session.id, "save meta failed: {e}");
        }
        // The purge ran between the check and the save: delete it again.
        if session.purged.load(Ordering::SeqCst)
            && let Err(e) = self.store.delete(&session.id)
        {
            tracing::warn!(session = %session.id, "delete of a purged session failed: {e}");
        }
    }

    /// Lists the temporary folders of sessions this daemon no longer has
    /// (`agent/session_tmp.rs`) and removes them on a thread of their own.
    /// The daemon calls it before its socket serves, so no session starts
    /// between the list and the store it is checked against.
    #[cfg(unix)]
    pub fn sweep_session_tmp(&self) {
        let metas = match self.store.list() {
            Ok(m) => m,
            Err(e) => {
                tracing::warn!("session tmp sweep skipped, the store did not list: {e}");
                return;
            }
        };
        let known: std::collections::HashSet<&str> = metas.iter().map(|m| m.id.as_str()).collect();
        let closed: std::collections::HashSet<&str> = metas
            .iter()
            .filter(|m| m.status == SessionStatus::Closed)
            .map(|m| m.id.as_str())
            .collect();
        // A session whose record did not list still has its folder.
        let stored =
            |id: &str| known.contains(id) || self.store.session_dir(id).is_some_and(|d| d.exists());
        let stale = crate::agent::session_tmp::stale_for_daemon(&stored, &|id| closed.contains(id));
        if stale.is_empty() {
            return;
        }
        tracing::info!(count = stale.len(), "removing temporary folders of forgotten sessions");
        std::thread::spawn(move || crate::agent::session_tmp::remove_all(&stale));
    }

    /// Sets `session`'s status. A stopped (closed) session stays closed: only a close writes
    /// Closed, and only [`Self::reopen`] leaves it. `acpmux session stop` cancels the turn and its
    /// asks and closes the session while that turn's task, its asks and an agent start are still
    /// ending; each of them read the session as open before it waited, and its write came after
    /// the close: a stopped session listed as ready again (ergo-walk2, 2026-10-25: "session stop
    /// says closed but acpmux ls still shows it ready"). The check and the write are one lock.
    pub(super) fn set_status(&self, session: &Session, status: SessionStatus) {
        self.write_status(session, status, None);
    }

    /// A stopped session starts again, for a request that came after its last stop: `stops` is
    /// [`Session::stops`] when the request came. Its status leaves Closed for Idle, logged
    /// `reopened`. False when it was not closed, or was stopped again since: it stays closed.
    pub(super) fn reopen(&self, session: &Session, stops: u64) -> bool {
        let reopened = self.write_status(session, SessionStatus::Idle, Some(stops));
        if reopened {
            self.append(session, "mux", "reopened", json!({}));
        }
        reopened
    }

    /// `reopen` is the stop count a reopen is for ([`Self::reopen`]), checked under the meta lock,
    /// which `kill`'s close takes after it counts the stop.
    fn write_status(&self, session: &Session, status: SessionStatus, reopen: Option<u64>) -> bool {
        // From before the status is set to after it is logged.
        session.status_writes.fetch_add(1, Ordering::SeqCst);
        struct Done<'a>(&'a AtomicU64);
        impl Drop for Done<'_> {
            fn drop(&mut self) {
                self.0.fetch_sub(1, Ordering::SeqCst);
            }
        }
        let _done = Done(&session.status_writes);
        let (was, link) = {
            let mut m = session.meta.lock().unwrap();
            let was = m.status;
            let reopens = reopen.is_some_and(|stops| session.stops.load(Ordering::SeqCst) == stops);
            if (was == SessionStatus::Closed && status != SessionStatus::Closed && !reopens)
                || (reopen.is_some() && was != SessionStatus::Closed)
            {
                return false;
            }
            m.status = status;
            // Only a change dates the chat: stopping a closed chat again logs nothing and leaves
            // it as old as it was, or a chat stopped every day would never be old enough for log
            // retention (`retention.rs`) and would move up the lists that sort by it.
            if was != status {
                m.updated_at = now_ms();
            }
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
            self.care_status(status);
            // A sub-session that starts or ends a turn, or closes, changes its parent's work.
            self.refresh_parent_work_below(session);
            if status == SessionStatus::Closed {
                self.retention_wake();
            }
        }
        true
    }

    pub fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.store.events(id, after, limit)
    }

    /// Visits the records past `after` in order, one at a time, until `visit` returns false.
    pub fn scan_events(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.store.scan(id, after, visit)
    }

    pub fn session_dir(&self, id: &str) -> Option<PathBuf> {
        self.store.session_dir(id)
    }
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

/// Ends the startup log load (`Hub::load_logs`) however it stops. A load that panicked
/// leaves the daemon on the session list and whatever the load finished before the panic
/// (the logs on disk are untouched; the next start reads them again), and says so in the
/// daemon log: an answer from that state beats `attach` and prompts that never answer.
struct LogsReady<'a>(&'a tokio::sync::watch::Sender<bool>);

impl Drop for LogsReady<'_> {
    fn drop(&mut self) {
        if std::thread::panicking() {
            tracing::error!(
                "reading the chat logs panicked; chats answer from the session list without \
                 the rest of the load (queues, cut-off turns, log tails)"
            );
        }
        self.0.send_replace(true);
    }
}
