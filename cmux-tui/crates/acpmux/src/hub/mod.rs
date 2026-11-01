//! The hub owns every session, its child agent, its event log, and the clients' fan-out channel.
//! Method groups live in sibling files: `peers` (remote daemons), `lifecycle` (spawn, resume,
//! fork), `permissions` (agent requests and policy), `turns` (prompt, cancel, config), `transfer`
//! (export, import), `views` (summaries), `handoff` (a reviewed first message to another harness),
//! `adoption` (resuming a harness's own session), `models_view` (the picker's model lists).

mod activity;
pub(crate) mod admission;
mod adopted_fences;
mod adoption;
mod agent_pairs;
mod message_events;
pub use agent_pairs::PairGuard;
mod aside;
mod atomic_json;
mod build;
pub use build::{build, install_build, version_line};
pub(crate) mod auto_resume;
mod bg_tasks;
mod bounded;
mod btw;
// A turn ends when its agent ends it; the steers it runs on with are the next turn's.
mod carried_turn;
mod exit_reason;
mod fallback_start;
pub(crate) mod session_auth;
pub(crate) mod subagent_retry;
pub(crate) mod turn_errors;
pub(crate) use btw::SIDE_TAG;
pub(crate) use policy_mode::SetRequest;
mod bookmarks;
pub(crate) mod cancel;
mod catalog_reload;
mod complete;
pub mod composers;
mod cursor_ext;
mod digest;
pub(crate) mod dispatch;
pub(crate) mod file_uploads;
pub use file_uploads::FEATURE as FILE_PUT_FEATURE;
#[cfg(test)]
mod first_work_tests;
mod fork;
#[cfg(test)]
mod prompt_accept_tests;
#[cfg(test)]
mod shutdown_tests;
pub(crate) use fork::offers_fork;
mod fork_at;
mod fork_transcript_auth;
pub mod forum;
pub(crate) mod full_access_bound;
mod handoff;
mod harness_view;
mod harness_watch;
mod health_view;
pub(super) mod idle;
mod idle_census;
pub(crate) use idle_census::LaunchServers;
pub use idle_census::Sidecar;
#[cfg(unix)]
pub(crate) use idle_census::host_census;
mod launch_roots;
mod launchers;
pub mod lineage;
pub(crate) mod list_guard;
mod live_models;
mod locate;
pub mod media_handles;
pub mod media_read;
mod mesh_rows;
pub(crate) mod native_history;
pub(crate) mod subagent_transcript;
mod team_information;
mod team_sent;
pub(crate) mod workflow_index;
pub use handoff::{HANDOFF_OPERATIONS, MAX_CAPSULE_BYTES};
pub use media_read::FEATURE as MEDIA_READ_FEATURE;
pub use native_history::FEATURE as NATIVE_HISTORY_FEATURE;
pub use subagent_transcript::FEATURE as SUBAGENT_TRANSCRIPT_FEATURE;
mod hosts;
mod lifecycle;
mod log_deferral;
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
#[cfg(test)]
mod prompt_line_tests;
mod prompt_sender;
mod protected_hold;
mod queue;
mod queue_admission;
mod queue_edit;
pub(crate) mod reply_fit;
pub use digest::{MAX_FROM_AGENT_CHARS, declared_sender};
pub use queue::{QueuedPrompt, Withdrawn, supersede::key as supersede_key};
mod profile_respawn;
mod resolve;
mod route_switch;
pub use pool::{PrewarmRequest, RssProbe, tree_rss_bytes};
pub use route_switch::HarnessRestarts;
pub(crate) use route_switch::route_error;
pub(crate) use turn_errors::is_limit_error;
mod git_watch;
mod github_owner;
mod lane_report_reads;
mod lane_report_text;
mod lane_reports;
mod meta_save;
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
pub(crate) mod inbox;
mod spawn;
mod start_defaults;
pub(crate) mod start_mode;
mod start_mode_state;
mod startup;
mod steer_end;
mod store_load;
mod stream;
mod tags;
mod tailnet_controller;
mod tap;
mod titles;
mod tool_paths;
mod tools;
pub(crate) mod turn_cap;
mod watch;
pub use new_request::{
    NewRequest, declared_model_json, profile_takes_model_at_spawn, terminal_harness_refusal,
};
pub use paging::{EventFilter, EventPage, MAX_PAGE_BYTES, fit_reply, page_bytes};
pub use spawn::expand_env_value;
pub mod approvers;
pub(crate) mod key_route;
pub mod mac_approvers;
mod own_host;
mod peer_cache;
#[cfg(all(test, target_os = "linux"))]
mod peer_flap_soak;
mod peer_grace;
#[cfg(test)]
mod peer_grace_tests;
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
pub(crate) mod stop_if_idle;
#[cfg(test)]
mod stop_settles_tests;
mod transcript;
mod transfer;
mod transfer_authority;
mod transfer_guard;
mod transfer_in;
mod transfer_out;
mod transfer_watch;
mod trust_wait;
mod turn_attestation;
mod turn_git;
mod turn_usage;
mod usage_view;
pub(crate) use usage_view::READ_WAIT as USAGE_READ_WAIT;
pub mod background_turn;
mod turns;
#[cfg(test)]
mod turns_copy_stop_tests;
pub(crate) mod usage_warnings;
#[cfg(test)]
mod usage_warnings_tests;
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
use cmux_json::JsonSet as _;
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
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::sync::{Mutex, Notify, RwLock, broadcast, mpsc, oneshot};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// How long a session's harness may sit unused (no turn, nothing queued, no
/// question waiting, no activity) before it hibernates: it exits and the
/// session resumes on its next prompt (`idle.rs`).
pub const IDLE_CHILD: std::time::Duration = std::time::Duration::from_secs(2 * 60);

/// Fan-out item: one appended record for one session, shared by every receiver, never copied.
/// `remote` carries the peer name and the peer's summary when the session lives elsewhere.
#[derive(Debug, Clone)]
pub struct HubEvent {
    pub session_id: String,
    pub record: Arc<EventRecord>,
    pub remote: Option<RemoteRef>,
}

/// One `_acpmux/message` copy in a journal: its message id, plus for a sender's copy the chat
/// that received it and the peer holding that chat.
fn message_key(id: &str, target: Option<&str>, peer: Option<&str>) -> String {
    match (target, peer) {
        (None, _) => id.to_owned(),
        (Some(target), None) => format!("{target}\0{id}"),
        (Some(target), Some(peer)) => format!("{peer}\u{1}{target}\0{id}"),
    }
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
    /// The line its prompt leaves on the session summary (`turn.prompt`: the sidebar's step, the
    /// hover card's task, the sub-session tools): another agent's message as "name: first line",
    /// never its envelope (`prompt_line.rs`), masked before its cut, so a secret across the cut
    /// leaves no head. `prompt_preview` stays the prompt as sent, for the turn's records.
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
    /// plan's step in progress, masked (`activity.rs`).
    pub doing: activity::TurnActivity,
    /// Its prompt is acpmux's own notice of other agents' messages (an inbox notice or a
    /// digest, `prompt_line::is_notice`), not words anyone typed: the summary's `turn.notice`.
    pub notice: bool,
    /// Whether the person's own prompt started it (`inbox.rs` [`inbox::persons_prompt`]): no
    /// inbox notice and no other agent's steer goes into it.
    pub persons: bool,
}

/// Options for `Hub::prompt_with`.
#[derive(Default)]
pub struct PromptOptions {
    /// Native-prepared Cloud turn capability; held in memory until claim/finish only.
    pub cloud_turn: Option<crate::cloud_rewind::CloudTurnEnvelope>,
    /// Client-chosen id (`_meta.acpmux.promptId`); generated when absent.
    pub prompt_id: Option<String>,
    /// The delivery id for a message sent through `_acpmux/send_queue`; direct prompts use the
    /// prompt id when no separate delivery id exists.
    pub message_id: Option<String>,
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
    /// Sender identity carried across a peer link. Provenance is intentionally removed at that
    /// boundary, but the additive message event still needs the sender's stable identity.
    pub message_sender: Option<Value>,
    /// Another agent's name when it sent the prompt with no provenance: the session a
    /// connection proved it runs in, or `_meta.acpmux.fromAgent` (`digest.rs`).
    pub agent: Option<String>,
    /// `_meta.acpmux.class` (`prompt_class.rs`): what another agent's message asks of this chat.
    /// Kept only on another agent's message, where none means `result`.
    pub class: Option<crate::prompt_class::PromptClass>,
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
    /// The queue took it already and it goes back in (a Send now or a steer whose turn ended
    /// first): its room is not checked again (`queue_admission.rs`), so a prompt it accepted is
    /// never refused for room.
    pub admitted: bool,
    /// A queued prompt sent now (`queue.rs` `steer_queued`): it steers in even past the running
    /// turn's cap (`turn_cap.rs`).
    pub send_now: bool,
    /// The thread another agent's message goes in (`inbox.rs` `explicit_thread`): `pr:N` or
    /// `topic:T`; `None` derives it.
    pub thread: Option<String>,
    /// A plain send from another agent on this host (`session/prompt`, `inbox::plain_send`): the
    /// chat's inbox takes it. Every other path that prompts (reports, task cards, a paused pair's
    /// release, a peer's or the mesh relay's forward) keeps the queue.
    pub inbox: bool,
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

/// An inline `/btw` side session's transcript owner: its family and the parent chat's env.
pub(super) type InlineBtwOwner = (String, std::collections::BTreeMap<String, String>);

pub struct Hub {
    pub config: RwLock<Config>,
    pub(crate) wireguard: Option<Arc<crate::wireguard::Transport>>,
    pub(super) store: Box<dyn Store>,
    pub(super) mailbox: Mailbox,
    /// The forum log (`forum.rs`, `hub/forum.rs`).
    pub(super) forum: std::sync::OnceLock<crate::forum::Forum>,
    pub(super) sessions: StdMutex<HashMap<String, Arc<Session>>>,
    /// Projection-only message repairs in flight, keyed by destination and delivery id. These
    /// retries never resend a prompt and are bounded in `message_events.rs`.
    pub(super) message_repairs: StdMutex<std::collections::HashSet<(String, String)>>,
    #[cfg(test)]
    pub(super) message_projection_failures: StdMutex<std::collections::HashSet<String>>,
    /// Where adopt looks for harness sessions.
    pub(super) harness_homes: StdMutex<crate::adopt::HarnessHomes>,
    /// Inline `/btw` side sessions being created, by their request-unique name: the family and
    /// parent env their transcript cleanup reads (`btw.rs` `InlineOwned`). A creation that fails
    /// and is discarded inside `new_session` or `fork` removes that harness transcript too.
    pub(super) inline_btw: StdMutex<HashMap<String, InlineBtwOwner>>,
    /// Every change watchers hear of, counted for the session list guard (`list_guard.rs`).
    pub(super) events: list_guard::Events,
    /// The shared, paced full session list (`list_guard.rs`).
    pub(crate) list_guard: list_guard::ListGuard,
    /// Each chat's spend and context as its harness recorded them (`usage_view.rs`).
    pub(crate) usage_stats: usage_view::UsageCache,
    /// `_acpmux/models` replies now asking peers for theirs
    /// (`server/models_fanout.rs`): a remote asker meanwhile gets this
    /// daemon's own catalog, so mutual peers cannot ping-pong.
    pub models_fanouts: std::sync::atomic::AtomicUsize,
    pub shutdown: Notify,
    /// Latched daemon restart and drain shared by TCP and embedded-tailnet listeners.
    pub(crate) ws_shutdown: crate::server::WsShutdown,
    /// Set only by an explicit daemon restart/update handoff. Ordinary stops
    /// close clients normally so they do not immediately reconnect to a dead daemon.
    pub(crate) restart_requested: std::sync::atomic::AtomicBool,
    pub started_at: u64,
    pub(super) peers: StdMutex<HashMap<String, Arc<crate::peer::Peer>>>,
    pub(super) remote_sessions: StdMutex<remote_rows::RemoteRows>,
    /// Each parent's children by tag, for an approval card's label (`permissions/display.rs`).
    pub(super) child_tags: permissions::ChildTags,
    /// Leased peers by name, with the generation of the peer each lease
    /// started (`peer_lease.rs`); never saved. Lock order: this, then
    /// `peers`; never `peers` first.
    pub(super) peer_leases: StdMutex<HashMap<String, u64>>,
    /// Moves on with each `peer_add` (under the config lock): a reload whose file read began
    /// before one leaves the saved peers' boundaries and GitHub lending as that add left them.
    pub(super) peer_config_gen: std::sync::atomic::AtomicU64,
    /// The config's `usageWarnings` thresholds, set at start and on each reload
    /// (`catalog_reload.rs`): a summary reads them here, so a writer holding the config lock never
    /// swaps the configured rules for the defaults (`usage_warnings.rs`).
    pub(super) usage_limits: StdMutex<crate::config::UsageLimits>,
    /// The links of Macs that lend this machine their GitHub login (`github_owner.rs`).
    pub(super) github_owners: github_owner::Owners,
    /// The cmux sign-in the app lends for App tokens (`github_app_token.rs`).
    pub(crate) github_app: Arc<crate::github_app_token::AppLease>,
    /// Each peer session's events as this daemon saw them, kept on disk
    /// (`peer_snapshot.rs`): a paused or offline peer's chat paints from it.
    pub(super) peer_snapshots: peer_snapshot::PeerSnapshots,
    pub(super) peer_notices: mpsc::Sender<(String, u64, crate::peer::PeerNotice)>,
    pub(super) peer_notices_rx:
        Mutex<Option<mpsc::Receiver<(String, u64, crate::peer::PeerNotice)>>>,
    pub(super) peer_notices_stop: tokio::sync::watch::Sender<bool>,
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
    /// False while the daemon's startup task runs (`daemon.rs`: logs, adoption,
    /// `finish_startup`, the chat index's start). `_acpmux/status` `loading.startupDone`.
    pub(super) startup_work_done: tokio::sync::watch::Sender<bool>,
    store_load: store_load::StoreLoad,
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
    /// Turns a shutdown settled as cancelled (`endAgents`) or handed to the next daemon: their
    /// prompt futures write no result of their own when the agent ends.
    pub(super) settled_by_shutdown: StdMutex<std::collections::HashSet<String>>,
    /// A turn's end under way (`Session::ending`) landed or went: a shutdown waiting for those
    /// ends looks again (`shutdown.rs` `settle_ends`).
    pub(super) ends_moved: Notify,
    /// `npx -y PACKAGE` launches resolved to their bin: (npx, package) to path.
    pub(super) launchers: StdMutex<HashMap<(String, String), String>>,
    /// Harnesses whose last model probe failed, with the reason; reported in
    /// `_acpmux/models` and `_acpmux/harnesses` (`probeError`).
    pub probe_errors: StdMutex<HashMap<String, String>>,
    /// Lifecycle timers (the idle harness exit) run on this clock.
    pub(super) clock: StdMutex<Arc<dyn crate::clock::Clock>>,
    /// A session harness unused for this long exits (`idle.rs`); None: never.
    pub(super) idle_child: StdMutex<Option<std::time::Duration>>,
    /// The background-task runner's binary and spool segment a test set (`bg_tasks.rs`).
    pub(super) bg_runner: StdMutex<Option<(crate::self_command::SelfCommand, u64)>>,
    /// Background-task starts, one at a time (`bg_tasks.rs`).
    pub(super) bg_starts: tokio::sync::Mutex<()>,
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
    /// Tests only: pause an admitted prompt before its logical turn is installed.
    #[cfg(test)]
    pub(super) prompt_start_seam: full_access_bound::WriteSeam,
    /// Tests only: pause a chat's first work once it holds it (`inbox.rs`), before its turn.
    #[cfg(test)]
    pub(super) first_work_seam: full_access_bound::WriteSeam,
    /// Tests only: pause a turn's end once its turn is taken (`finish_turn`), before it writes.
    #[cfg(test)]
    pub(super) finish_seam: full_access_bound::WriteSeam,
    /// Tests only: pause a retry's task before it sets its wait (`auto_resume.rs`).
    #[cfg(test)]
    pub(super) retry_seam: full_access_bound::WriteSeam,
    /// Tests only: delay a Stop before its notification reaches the child writer.
    #[cfg(test)]
    pub(super) cancel_write_seam: Arc<full_access_bound::WriteSeam>,
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
    /// Authenticated parents already receiving a lane result through wait/history.
    lane_report_reads: lane_report_reads::LaneReportReads,
    /// Open sub-sessions per parent and starts in flight (`subsessions.rs`).
    pub(super) subsessions: subsessions::Index,
    /// Creates admitted and still starting (`admission.rs`).
    pub(super) admitting: admission::Admitting,
    /// Run slots of each session's sub-sessions (`subsession_runs.rs`).
    pub(super) subsession_runs: Arc<subsession_runs::Runs>,
    /// `_acpmux/wait` requests subscribed and not yet answered (`server/wait.rs`), shown
    /// as `_acpmux/status` `openWaits`.
    pub(crate) open_waits: std::sync::atomic::AtomicUsize,
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
    /// The team hub a send to a name nobody here resolves goes through, once the mesh relay
    /// started (`server/mesh_relay.rs`); unset without one, or in a hub a test builds.
    pub mesh: std::sync::OnceLock<Arc<dyn crate::mesh::MeshHub>>,
    pub(crate) watches: watches::Watches,
    pub(crate) peer_accepts: outbox::PeerAccepts,
    /// Agent message pairs and their runaway guard (`agent_pairs.rs`).
    pub(super) agent_pairs: agent_pairs::AgentPairs,
    /// Pairing tickets and paired machines (`crate::pairing`).
    pub pairing: Arc<crate::pairing::Pairing>,
    /// The optional embedded tailnet node. It is initialized lazily so the
    /// default daemon never starts or links a node without an explicit request.
    #[cfg(all(unix, feature = "tailnet"))]
    pub(crate) tailnet_controller: std::sync::OnceLock<Arc<crate::tailnet::embedded::Controller>>,
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
        Self::build(config, store, mailbox, true, false, None)
    }

    pub fn new_with_mailbox(config: Config, store: Box<dyn Store>, mailbox: Mailbox) -> Arc<Self> {
        Self::build(config, store, mailbox, false, false, None)
    }

    /// A daemon serves immediately; metadata is read after its ready line.
    pub fn new_loading(config: Config, store: Box<dyn Store>, mailbox: Mailbox) -> Arc<Self> {
        Self::build(config, store, mailbox, true, true, None)
    }

    pub(crate) fn new_loading_with_wireguard(
        config: Config,
        store: Box<dyn Store>,
        mailbox: Mailbox,
        wireguard: Option<Arc<crate::wireguard::Transport>>,
    ) -> Arc<Self> {
        Self::build(config, store, mailbox, true, true, wireguard)
    }

    fn build(
        config: Config,
        store: Box<dyn Store>,
        mailbox: Mailbox,
        deferred: bool,
        loading: bool,
        wireguard: Option<Arc<crate::wireguard::Transport>>,
    ) -> Arc<Self> {
        let events = list_guard::Events::new(8192);
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
        let usage_limits = StdMutex::new(config.usage_warnings.limits());
        let hub = Arc::new(Self {
            config: RwLock::new(config),
            usage_limits,
            wireguard,
            store,
            mailbox,
            forum: std::sync::OnceLock::new(),
            sessions: StdMutex::new(HashMap::new()),
            message_repairs: StdMutex::new(std::collections::HashSet::new()),
            #[cfg(test)]
            message_projection_failures: StdMutex::new(std::collections::HashSet::new()),
            harness_homes: StdMutex::new(crate::adopt::HarnessHomes::from_env()),
            inline_btw: StdMutex::new(HashMap::new()),
            events,
            list_guard: Default::default(),
            usage_stats: Default::default(),
            models_fanouts: std::sync::atomic::AtomicUsize::new(0),
            shutdown: Notify::new(),
            ws_shutdown: Default::default(),
            restart_requested: std::sync::atomic::AtomicBool::new(false),
            started_at: now_ms(),
            peers: StdMutex::new(HashMap::new()),
            remote_sessions: Default::default(),
            child_tags: Default::default(),
            peer_leases: StdMutex::new(HashMap::new()),
            peer_config_gen: std::sync::atomic::AtomicU64::new(0),
            github_owners: Default::default(),
            github_app: Default::default(),
            peer_snapshots,
            peer_notices,
            peer_notices_rx: Mutex::new(Some(peer_notices_rx)),
            peer_notices_stop: tokio::sync::watch::channel(false).0,
            known_models: StdMutex::new(HashMap::new()),
            live_models: StdMutex::new(HashMap::new()),
            refused_models: StdMutex::new(HashMap::new()),
            startup_ready: tokio::sync::watch::channel(true).0,
            startup_work_done: tokio::sync::watch::channel(true).0,
            store_load: store_load::StoreLoad::new(loading),
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
            ends_moved: Notify::new(),
            launchers: StdMutex::new(HashMap::new()),
            probe_errors: StdMutex::new(HashMap::new()),
            clock: StdMutex::new(crate::clock::TokioClock::new()),
            idle_child: StdMutex::new(Some(IDLE_CHILD)),
            bg_runner: StdMutex::new(None),
            bg_starts: tokio::sync::Mutex::new(()),
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
            #[cfg(test)]
            cancel_write_seam: Arc::new(Default::default()),
            #[cfg(test)]
            prompt_start_seam: Default::default(),
            #[cfg(test)]
            first_work_seam: Default::default(),
            #[cfg(test)]
            finish_seam: Default::default(),
            #[cfg(test)]
            retry_seam: Default::default(),
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
            lane_report_reads: Default::default(),
            subsessions: Default::default(),
            admitting: Default::default(),
            subsession_runs: Default::default(),
            open_waits: Default::default(),
            subagent_retries: Default::default(),
            transfer_lease_changed: Notify::new(),
            secrets: Default::default(),
            trust_waits: Default::default(),
            outbox: Default::default(),
            mesh: Default::default(),
            watches: Default::default(),
            peer_accepts: Default::default(),
            agent_pairs: Default::default(),
            pairing: Default::default(),
            #[cfg(all(unix, feature = "tailnet"))]
            tailnet_controller: std::sync::OnceLock::new(),
            briefs,
        });
        if let Ok(c) = hub.config.try_read() {
            hub.refresh_web_modes(&c);
        }
        hub.recover_staged_replacements();
        if loading {
            hub.logs_ready.send_replace(false);
            hub.adoption_ready.send_replace(false);
        } else {
            hub.load_from_store(deferred);
        }
        if !deferred {
            hub.load_logs();
        }
        if tokio::runtime::Handle::try_current().is_ok() {
            let h = hub.clone();
            tokio::spawn(async move { h.peer_notice_loop().await });
            if !loading {
                hub.watch_transfers();
                hub.watch_orphans();
            }
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

    /// How many outbox deliveries are not settled yet (`outbox.rs`).
    pub fn outbox_unsettled(&self) -> usize {
        self.outbox.unsettled()
    }

    pub fn subscribe(&self) -> broadcast::Receiver<HubEvent> {
        self.events.subscribe()
    }

    pub fn mailbox(&self) -> &Mailbox {
        &self.mailbox
    }

    pub(super) fn load_from_store(self: &Arc<Self>, deferred: bool) {
        // A bounded debug seam for slow-filesystem startup tests; absent in release builds.
        #[cfg(debug_assertions)]
        if let Some(ms) = std::env::var("ACPMUX_TEST_DELAY_LOAD_STORE_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
        {
            std::thread::sleep(std::time::Duration::from_millis(ms.min(10_000)));
        }
        let Ok(mut metas) = self.store.list().inspect_err(|e| tracing::warn!("store list: {e}"))
        else {
            // Adoption still reaches every host this list hid: an off push waits for it
            // (`full_access_turned_off`).
            if deferred {
                self.adoption_ready.send_replace(false);
            }
            return;
        };
        // The small index the chat logs load by (`log_load.rs`): agent hosts still running.
        let read = Self::read_live_host_sessions();
        // Records that can not be read may hide a host whose lines adoption holds again: an off
        // push waits for adoption then too (`full_access_turned_off`).
        let unknown = read.is_none();
        let hosted = read.unwrap_or_default();
        let waiting =
            metas.iter().filter(|m| m.status == SessionStatus::Waiting).map(|m| m.id.clone());
        if deferred && (!hosted.is_empty() || unknown) {
            self.adoption_ready.send_replace(false);
        }
        {
            let mut plan = self.load_plan.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            plan.waiting.extend(waiting);
            plan.adopting.extend(hosted.iter().cloned());
            plan.hosted.extend(hosted.iter().cloned());
        }
        // An older daemon's approve-all that could be vmHost's asks now (`policy_source.rs`).
        self.settle_legacy_grants(&mut metas);
        self.store_load.total.store(metas.len(), Ordering::SeqCst);
        for meta in metas {
            let hosted = hosted.contains(&meta.id);
            self.install_stored_session(meta, deferred, hosted);
        }
        tracing::info!(
            "loaded {} sessions from store",
            self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner).len()
        );
        if deferred {
            self.logs_ready.send_replace(false);
        }
    }

    pub(super) fn install_stored_session(&self, meta: SessionMeta, deferred: bool, hosted: bool) {
        // An on-demand read may already have installed and updated this chat. Never replace it
        // with the snapshot the background list read earlier.
        let mut sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if sessions.contains_key(&meta.id) {
            return;
        }
        let mut meta = meta;
        // An agent whose host still runs keeps its saved status until adoption reaches it:
        // it works on meanwhile, never shown idle (claude-sr2, 2026-10-26).
        let kept = deferred
            && hosted
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
        // A live sub-session holds a slot of its parent (`subsessions.rs`). Idle-finished,
        // disconnected and closed children are retained in the store but do not use a slot.
        if let Some(link) = meta.subsession.as_ref() {
            self.subsessions.note_status(&link.started_by, &meta.id, meta.status);
        }
        let session = self.make_session(meta);
        session.caught_up.store(false, Ordering::SeqCst);
        *session.transfer_authority.lock().unwrap_or_else(|e| e.into_inner()) = None;
        // Its log is read after the ready line (`log_load.rs`).
        *session.log_load.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = false;
        session.log_loaded.store(false, Ordering::SeqCst);
        sessions.insert(session.id.clone(), session);
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
        let after =
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).harness_failures.through_seq;
        let mut results = Vec::new();
        let restored = self.store.scan_back(
            &session.id,
            after,
            u64::MAX,
            &|dir, kind| dir != b"mux" || kind != b"turn_result",
            &mut |record| {
                let success =
                    record.msg["status"] == "completed" && record.msg["stopReason"] != "cancelled";
                results.push(record);
                // A success settles everything before it; the bounded window settles the rest
                // (a streak older than it reads as starting at the window's oldest result).
                !success && results.len() < crate::session_liveness::RESTORE_RESULTS
            },
        );
        let rebuilt = restored.is_ok() && !results.is_empty();
        if rebuilt {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            for record in results.into_iter().rev() {
                meta.harness_failures.observe(&record.msg, record.seq, record.at);
            }
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
        // Kept, so the next start scans only past what this one read.
        if rebuilt {
            self.save_meta(session);
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
        // Hibernated before a restart: marked again, so it wakes on a click and draws no row.
        let hibernated_at = if meta.hibernated_ms != 0 { self.clock_now().max(1) } else { 0 };
        let (inbound_tx, inbound_rx) = mpsc::channel(1024);
        // A Claude chat saved without `steering` (an older build) still steers once adopted.
        meta.steering |= crate::claude_stdio::steers_by_info(meta.agent_info.as_ref());
        let steering = meta.steering;
        // Until it starts, an adopted chat goes by the agent it last ran (its saved `agentInfo`).
        let backgrounds_work = crate::claude_stdio::steers_by_info(meta.agent_info.as_ref());
        // A chat that moved away stays frozen after a restart: every prompt, queue, draft and
        // policy change refuses it as while it moved (`queue::moving_error`).
        let moving = meta.moved_to.as_ref().map(|_| transfer_out::MOVED_AWAY.to_owned());
        let session = Arc::new(Session {
            id: meta.id.clone(),
            seq: AtomicU64::new(meta.last_seq),
            meta: StdMutex::new(meta),
            child: Mutex::new(None),
            spawn_lock: Mutex::new(()),
            harness_use: RwLock::new(()),
            idle_refusal_logged: AtomicU64::new(0),
            append_lock: StdMutex::new(()),
            meta_writer: Default::default(),
            message_ids: StdMutex::new(None),
            log_deferral: StdMutex::new(Default::default()),
            loading: AtomicBool::new(false),
            replaying: StdMutex::new(Vec::new()),
            caught_up: AtomicBool::new(true),
            log_load: StdMutex::new(true),
            log_loaded: AtomicBool::new(true),
            auto_resume_restored: AtomicBool::new(false),
            protected_hold: AtomicBool::new(false),
            auto_resume: Default::default(),
            turn_lock: Mutex::new(()),
            turn_claimed: AtomicBool::new(false),
            admit: StdMutex::new(()),
            input_handoff: std::sync::Arc::new(Mutex::new(())),
            turn: StdMutex::new(None),
            queued: AtomicU64::new(0),
            queue: StdMutex::new(Vec::new()),
            prepared: StdMutex::new(std::collections::VecDeque::new()),
            prepared_done: StdMutex::new(std::collections::VecDeque::new()),
            cloud_generation: AtomicU64::new(
                std::env::var("CMUX_CLOUD_GENERATION")
                    .ok()
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0),
            ),
            team_information: Default::default(),
            queue_moved: Notify::new(),
            moving: StdMutex::new(moving),
            transfer_authority: StdMutex::new(Some((0, false))),
            restored: StdMutex::new(Vec::new()),
            inbox_digests: StdMutex::new(HashMap::new()),
            digest_bytes: AtomicU64::new(0),
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
            profile_respawn: AtomicBool::new(false),
            ending: StdMutex::new(None),
            detaching: AtomicBool::new(false),
            inbound_tx,
            inbound_rx: Mutex::new(Some(inbound_rx)),
            steering: AtomicBool::new(steering),
            backgrounds_work: AtomicBool::new(backgrounds_work),
            person: AtomicBool::new(false),
            steer_now: Default::default(),
            steer_end: tokio::sync::watch::channel(None).0,
            fork_from: StdMutex::new(None),
            applied: StdMutex::new(session::Applied::default()),
            purged: AtomicBool::new(false),
            replaced: AtomicBool::new(false),
            closing: AtomicBool::new(false),
            stops: AtomicU64::new(0),
            cancels: AtomicU64::new(0),
            cancel_forced_turn: StdMutex::new(None),
            cancel_forced_result_turn: StdMutex::new(None),
            stopping: StdMutex::new(None),
            stop_restart: StdMutex::new(None),
            stopped_agent: AtomicU64::new(0),
            stop_respawn: AtomicU64::new(0),
            taps: AtomicU64::new(0),
            muted_taps: AtomicU64::new(0),
            stop_hold: AtomicU64::new(0),
            turn_hold: AtomicU64::new(0),
            compacting: AtomicBool::new(false),
            compaction_metadata_fenced: AtomicBool::new(false),
            status_writes: AtomicU64::new(0),
            status_changes: AtomicU64::new(0),
            state_seq: AtomicU64::new(0),
            attached: std::sync::atomic::AtomicUsize::new(0),
            hidden: std::sync::atomic::AtomicUsize::new(0),
            stderr_tail: StdMutex::new(std::collections::VecDeque::new()),
            stderr_stream: StdMutex::new(session::SessionStderr::default()),
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
            turn_cap_timer: StdMutex::new(None),
            inbox: StdMutex::new(inbox::Inbox::default()),
            last_active: AtomicU64::new(self.clock_now()),
            hibernated_at: AtomicU64::new(hibernated_at),
            wake_cause: StdMutex::new(None),
            agent_requests: std::sync::atomic::AtomicUsize::new(0),
            web_control_ended: AtomicBool::new(false),
            floor: Default::default(),
            subagents: StdMutex::new(Default::default()),
            harness_turn: AtomicBool::new(false),
            background_turns: StdMutex::new(Default::default()),
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

    /// This daemon's own session `key` names: its id, its whole name, then a unique prefix of
    /// either. Only when none of those finds a session here and no peer lists one `key` names
    /// (by id, id prefix, whole name or `PEER/NAME`, `Hub::remote_strict_matches`), a bare key
    /// (no `/`) that is a sub-session's last name segment (`mac-ci-3` for `claude-sr2/mac-ci-3`,
    /// `session_name::ends_with_segments`) names it: so no key that found a session before
    /// short names, or was refused, finds another now. A short name only a peer's session has
    /// is the peer route's (`Hub::resolve_remote`); one several sessions share, here or on
    /// peers, is refused with their names. A miss is the plain `no session matches`
    /// (`Hub::unknown_session` adds the close names where a caller is told). A key with a `/`
    /// never matches by short name here: `HOST/NAME` stays a host's (`own_host.rs`).
    pub(super) fn resolve_here(&self, key: &str) -> Result<Arc<Session>, RpcError> {
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
        // (`acpmux session cancel NAME`) and every other call by name. One
        // pass sorts them into the tiers below.
        let bare = !key.contains('/');
        let (mut by_name, mut by_segment, mut by_prefix) = (Vec::new(), Vec::new(), Vec::new());
        for s in sessions.values() {
            let meta = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if meta.name == key {
                by_name.push(s.clone());
            }
            if bare && crate::session_name::ends_with_segments(&meta.name, key) {
                by_segment.push((s.clone(), meta.status == SessionStatus::Closed));
            }
            if s.id.starts_with(key) || meta.name.starts_with(key) {
                by_prefix.push(s.clone());
            }
        }
        drop(sessions);
        if by_name.len() == 1 {
            return Ok(by_name.remove(0));
        }
        let named = |matched: &[Arc<Session>]| -> Vec<String> {
            matched
                .iter()
                .map(|s| {
                    format!("{} ({})", s.meta.lock().unwrap_or_else(|e| e.into_inner()).name, s.id)
                })
                .collect()
        };
        let tied = |mut names: Vec<String>| {
            names.sort();
            names.dedup();
            crate::session_name::ambiguous(key, &names)
        };
        // A short name here, only where the rules above find nothing here and no peer lists a
        // session `key` names: then this answers as it did before short names matched. The
        // peers' rows are read only with a local candidate in hand (a plain miss, as for every
        // request a peer's session serves, reads none), with this daemon's sessions unlocked.
        // A short name only a peer's session has is `resolve_remote`'s.
        if by_name.is_empty()
            && by_prefix.is_empty()
            && !by_segment.is_empty()
            && self.remote_strict_matches(key) == 0
        {
            // Closed ones count only when no live one, here or on a peer, has the short name
            // (`hub/key_route.rs`), so this agrees with the route the unix socket takes.
            let remote = self.remote_segment_names(key);
            let live = by_segment.iter().any(|(_, closed)| !closed)
                || remote.iter().any(|(_, closed)| !closed);
            let here: Vec<Arc<Session>> = by_segment
                .into_iter()
                .filter(|(_, closed)| !live || !closed)
                .map(|(s, _)| s)
                .collect();
            let there: Vec<String> =
                remote.into_iter().filter(|(_, closed)| !live || !closed).map(|(n, _)| n).collect();
            match (here.as_slice(), there.len()) {
                ([one], 0) => return Ok(one.clone()),
                // The one a peer has is `resolve_remote`'s.
                ([], 1) => return Err(crate::session_name::not_found(key, &[])),
                // Several, here or on peers: a tie, refused with every name.
                _ => {
                    let mut names = named(&here);
                    names.extend(there);
                    return Err(tied(names));
                }
            }
        }
        match by_prefix.len() {
            1 => Ok(by_prefix.remove(0)),
            0 => Err(crate::session_name::not_found(key, &[])),
            _ => Err(tied(named(&by_prefix))),
        }
    }

    /// This daemon's own sessions `key` names: [by id, name or a prefix of either; by short name
    /// and live; by short name and closed]. A peer's short name gives way to the first two, and
    /// to the third only when it is closed too (`Hub::resolve_remote`).
    pub(super) fn local_match_counts(&self, key: &str) -> [usize; 3] {
        let bare = !key.contains('/');
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut counts = [0_usize; 3];
        for s in sessions.values() {
            let meta = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if s.id.starts_with(key) || meta.name.starts_with(key) {
                counts[0] = counts[0].saturating_add(1);
            } else if bare && crate::session_name::ends_with_segments(&meta.name, key) {
                let slot = if meta.status == SessionStatus::Closed { 2 } else { 1 };
                if let Some(count) = counts.get_mut(slot) {
                    *count = count.saturating_add(1);
                }
            }
        }
        counts
    }

    /// The one session here whose last name segment is the bare `key` (`HOST/SHORT` with this
    /// machine as `HOST`, `own_host.rs`): None when none is; refused when several are. Closed
    /// sessions count only when none is live, as in `key_route` and `resolve_here`.
    pub(super) fn resolve_short_here(&self, key: &str) -> Option<Result<Arc<Session>, RpcError>> {
        if key.contains('/') {
            return None;
        }
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let (live, closed): (Vec<_>, Vec<_>) = sessions
            .values()
            .filter_map(|s| {
                let meta = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                crate::session_name::ends_with_segments(&meta.name, key)
                    .then(|| (s.clone(), meta.name.clone(), meta.status == SessionStatus::Closed))
            })
            .partition(|(_, _, closed)| !closed);
        drop(sessions);
        let found = if live.is_empty() { closed } else { live };
        match found.as_slice() {
            [] => None,
            [(s, _, _)] => Some(Ok(s.clone())),
            many => Some(Err(crate::session_name::ambiguous(
                key,
                &many.iter().map(|(s, n, _)| format!("{n} ({})", s.id)).collect::<Vec<_>>(),
            ))),
        }
    }

    /// The refusal for a key no session here or on a peer names, with the names it nearly
    /// matched (`session_name::candidates`), so the caller can pick one instead of running
    /// `acpmux ls`. Reads every name: only where the refusal goes back to a caller.
    pub fn unknown_session(&self, key: &str) -> RpcError {
        let lower = key.to_ascii_lowercase();
        let mut names: Vec<String> = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .filter_map(|s| {
                let name = s.meta.lock().unwrap_or_else(|e| e.into_inner()).name.clone();
                name.to_ascii_lowercase().contains(&lower).then_some(name)
            })
            .collect();
        names.extend(self.remote_names_containing(&lower));
        let close = crate::session_name::candidates(names.iter().map(String::as_str), key);
        crate::session_name::not_found(key, &close)
    }

    // ------------------------------------------------------------ logging

    pub(crate) fn append(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
    ) -> EventRecord {
        self.append_with_host_seq(session, dir, kind, msg, None)
    }

    /// Persist one session-to-session message projection. The journal containing the copy is
    /// named by `session`; the payload keeps that id too so clients can route a replayed event.
    #[cfg(test)]
    pub(super) fn append_message_event(
        &self,
        session: &Session,
        sender: Value,
        text: String,
        message_id: String,
        at: u64,
    ) -> bool {
        self.append_message_event_scoped(session, sender, text, message_id, at, None, None)
    }

    /// `target_scope` names the receiving chat of a sender's copy, and `target_peer` the peer
    /// that holds it: a peer's chat may keep the raw id of one here (an export and import keeps
    /// ids), and a message to each is its own copy.
    #[allow(clippy::too_many_arguments)] // One copy's fields, each its own value.
    pub(super) fn append_message_event_scoped(
        &self,
        session: &Session,
        sender: Value,
        text: String,
        message_id: String,
        at: u64,
        target_scope: Option<&str>,
        target_peer: Option<&str>,
    ) -> bool {
        #[cfg(test)]
        if self
            .message_projection_failures
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&session.id)
        {
            return false;
        }
        let mut msg = json!({
            "sessionId": session.id.clone(),
            "sender": sender,
            "text": text,
            "at": at,
            "messageId": message_id,
        });
        if let Some(target) = target_scope {
            msg.set("_acpmuxTarget", json!(target));
            if let Some(peer) = target_peer {
                msg.set("_acpmuxTargetPeer", json!(peer));
            }
        }
        tool_paths::add_canonical_paths(session, "_acpmux/message", &mut msg);
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.catch_up_locked(session);
        // A forwarded delivery can be accepted more than once while a caller retries
        // the same id.  Keep one projection per delivery id in the durable journal,
        // including after a daemon restart. Load the id index once, not once per
        // message or recovered record. The append lock serializes check and append.
        let mut index = session.message_ids.lock().unwrap_or_else(|e| e.into_inner());
        if index.is_none() {
            let mut ids = std::collections::HashSet::new();
            if let Err(error) =
                self.store.scan_kinds(&session.id, &["_acpmux/message"], &mut |record| {
                    if let Some(id) = record.msg.get("messageId").and_then(Value::as_str) {
                        let target = record.msg.get("_acpmuxTarget").and_then(Value::as_str);
                        let peer = record.msg.get("_acpmuxTargetPeer").and_then(Value::as_str);
                        ids.insert(message_key(id, target, peer));
                    }
                    true
                })
            {
                tracing::warn!(session = %session.id, %error, "cannot read message projection ids");
                return false;
            }
            *index = Some(ids);
        }
        let Some(ids) = index.as_mut() else { return false };
        let key = message_key(&message_id, target_scope, target_peer);
        if ids.contains(&key) {
            return true;
        }
        // The payload retains the acceptance time; the journal records when this
        // copy was appended, so recovering an old message cannot regress activity.
        // Published only once stored: a failed copy is repaired later (`message_events.rs`),
        // and that repair's copy is the one clients and peers hear.
        if self.append_at_locked(session, "mux", "_acpmux/message", msg, None, None, true, true).1 {
            ids.insert(key);
            true
        } else {
            false
        }
    }

    /// Record the sender-side copy when a prompt is accepted by peer `target_peer`'s chat
    /// `target_session`.
    #[allow(clippy::too_many_arguments)] // One copy's fields, each its own value.
    pub(super) fn append_sender_message_event(
        &self,
        sender_session: &str,
        sender: Value,
        text: String,
        message_id: String,
        at: u64,
        target_peer: &str,
        target_session: &str,
    ) -> bool {
        if let Ok(session) = self.resolve(sender_session)
            && session.id == sender_session
        {
            self.append_message_event_scoped(
                &session,
                sender,
                text,
                message_id,
                at,
                Some(target_session),
                Some(target_peer),
            )
        } else {
            false
        }
    }

    pub(crate) fn append_stored(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
    ) -> bool {
        self.append_logged(session, dir, kind, msg, None).1
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

    /// Persist a record without broadcasting it. Callers use this for a durable marker whose
    /// in-memory state is installed immediately afterward; the following state event is the
    /// first watcher-visible record.
    pub(super) fn append_quiet(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
    ) -> EventRecord {
        let mut msg = msg;
        tool_paths::add_canonical_paths(session, kind, &mut msg);
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.catch_up_locked(session);
        self.append_at_locked(session, dir, kind, msg, None, None, false, false).0
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
        let mut msg = msg;
        // Off the append lock: it reads the disk.
        tool_paths::add_canonical_paths(session, kind, &mut msg);
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.catch_up_locked(session);
        self.append_at_locked(session, dir, kind, msg, host_seq, at, false, true)
    }

    /// [`Hub::append_at_locked`] of one record. `stored_only`: a record the store refused is
    /// neither counted nor published (its caller appends it again), so no client or peer hears a
    /// copy the journal does not hold. `kept`: what the log stores for it.
    #[allow(clippy::too_many_arguments)]
    fn append_record_locked(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
        at: Option<u64>,
        stored_only: bool,
        kept: log_deferral::Kept,
        notify: bool,
    ) -> (EventRecord, bool) {
        let seq = session.seq.fetch_add(1, Ordering::SeqCst) + 1;
        let at = at.unwrap_or_else(now_ms);
        // Record a harmless mux receipt instead of ambiguous completion metadata.
        // Hosted delivery must persist host_seq before acknowledging the entry; a
        // silent drop would lose its durable cursor and allow replay after reconnect.
        let fenced = dir == "in"
            && msg.pointer("/params/update").is_some_and(|u| session.fences_compaction_update(u));
        let record = if fenced {
            EventRecord {
                seq,
                at,
                dir: "mux".into(),
                kind: "compaction_metadata_fenced".into(),
                msg: json!({"sourceKind": kind}),
                host_seq,
            }
        } else {
            EventRecord { seq, at, dir: dir.into(), kind: kind.into(), msg, host_seq }
        };
        // The agent message runaway guard reads progress from here, not the store.
        if agent_pairs::progress_record(&record) {
            session.last_progress.store(seq, Ordering::SeqCst);
        }
        if session.purged.load(Ordering::SeqCst) {
            return (record, true);
        }
        // What its harness spent, read after a turn (`usage_view.rs`), is bookkeeping: it never
        // keeps the chat's agent awake.
        if !(dir == "mux" && kind == usage_view::RECORD_KIND) {
            self.touch(session);
        }
        let appended = match kept {
            // A fenced record keeps its receipt.
            log_deferral::Kept::Stub(msg) if !fenced => self.store.append(
                &session.id,
                &EventRecord { msg, dir: record.dir.clone(), kind: record.kind.clone(), ..record },
            ),
            _ => self.store.append(&session.id, &record),
        };
        let stored = match appended {
            Ok(()) => true,
            Err(e) => {
                session.append_errors.fetch_add(1, Ordering::SeqCst);
                tracing::warn!(session = %session.id, "append failed: {e}");
                false
            }
        };
        if stored {
            session.note_transfer_event(&record);
        }
        // A closed session's log is not held open: its last records (`status`,
        // then the agent's `stopped`) each close it again (`store.rs` Writers).
        if session.status() == SessionStatus::Closed {
            self.store.close_log(&session.id);
        }
        if stored_only && !stored {
            return (record, false);
        }
        {
            let mut m = session.meta.lock().unwrap();
            m.last_seq = seq;
            m.event_count += 1;
            m.updated_at = record.at;
            if record.dir == "mux" && record.kind == "turn_result" {
                m.harness_failures.observe(&record.msg, record.seq, record.at);
            }
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
                | "stopping"
                | "unstuck"
                | work_below::RECORD_KIND
                | "queued"
                | "dequeued"
                | "queue_removed"
                | "queue_order"
                | "queue_restored"
                | "queue_paused"
                | "queue_resumed"
                | "created"
                | "tags"
                | "rules"
                | profile_respawn::RECORD_KIND
        ) {
            session.state_seq.fetch_add(1, Ordering::SeqCst);
        }
        if notify {
            let _ = self.events.send(HubEvent {
                session_id: session.id.clone(),
                record: Arc::new(record.clone()),
                remote: None,
            });
        }
        (record, stored)
    }

    pub fn set_rules(&self, session: &Session, rules: Option<Value>) {
        // A failed save is logged there; no request waits for this one.
        let _ = self.set_rules_answered(session, rules);
    }

    /// [`Hub::set_rules`] for `_acpmux/set_rules`: answered only once the rules are saved
    /// (`meta_save.rs`).
    pub(crate) fn set_rules_answered(
        &self,
        session: &Session,
        rules: Option<Value>,
    ) -> Result<(), RpcError> {
        self.permission_policy_changed(session, |m| m.permission_rules = rules.clone());
        let saved = self.save_meta_answered(session);
        self.append(session, "mux", "rules", json!({"rules": rules}));
        saved
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
    ) -> Result<Option<String>, RpcError> {
        if text.chars().count() > Self::MAX_COMPOSER_DRAFT_CHARS {
            return Err(RpcError::invalid_params(format!(
                "composer draft exceeds {} characters",
                Self::MAX_COMPOSER_DRAFT_CHARS
            )));
        }
        if session.moving().is_some() {
            return Err(RpcError::invalid_params(queue::moving_error().message));
        }
        let draft = (!text.trim().is_empty()).then(|| text.to_owned());
        {
            let mut meta = session.meta.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            meta.composer_draft = draft.clone();
            meta.updated_at = now_ms();
        }
        // Answered only once the draft is in `session.json`: "the one durable shared draft".
        self.save_meta_answered(session)?;
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
                        if let Some(id) = e.msg.get("turnId") {
                            t.insert("turnId".into(), id.clone());
                        }
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

    /// Lists the temporary folders of sessions this daemon no longer has
    /// (`agent/session_tmp.rs`) and removes them on a thread of their own.
    /// The daemon calls it after metadata loads and before startup releases spawns.
    #[cfg(unix)]
    pub fn sweep_session_tmp(&self) {
        let metas: Vec<_> = self.sessions().iter().map(|session| session.meta()).collect();
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
            if was != status {
                session.status_changes.fetch_add(1, Ordering::SeqCst);
            }
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
                self.subsessions.note_status(&link.started_by, &session.id, status);
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
