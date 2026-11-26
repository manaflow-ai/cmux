//! The hub owns every session, its child agent, its event log, and the clients' fan-out channel.
//! Method groups live in sibling files: `peers` (remote daemons), `lifecycle` (spawn, resume,
//! fork), `permissions` (agent requests and policy), `turns` (prompt, cancel, config), `transfer`
//! (export, import), `views` (summaries), `handoff` (a reviewed first message to another harness),
//! `adoption` (resuming a harness's own session), `models_view` (the picker's model lists).
//!
//! The `mod` declarations stay together, sorted by name, each with its own comment and attributes
//! directly above it, so two branches that each add a module rarely touch the same lines
//! (`scripts/merge-insertions.py` merges a branch from before the sort into this order).

mod account_usage;
mod activity;
pub(crate) mod additional_dirs;
pub(crate) mod admission;
// A create with no room here starts on the peer placement picks.
pub(crate) mod admission_redirect;
#[cfg(test)]
mod admission_restore_tests;
// A create over the cap with nowhere to go asks the fleet for a machine.
pub(crate) mod admission_scale_up;
mod adopt_retry;
mod adopted_fences;
mod adoption;
pub(crate) mod agent_hold;
#[cfg(test)]
mod agent_messaging_tests;
mod agent_pairs;
pub(crate) mod agent_timer;
pub(crate) mod agent_vm;
mod app_exit;
mod append;
pub mod approvers;
mod aside;
pub(crate) mod ask_choices;
mod asks_below;
mod atomic_json;
mod audit_entries;
pub(crate) mod audit_log;
// A foreground shell still running after five minutes goes to the background (Claude Code).
mod auto_background;
// Idle chats leave this machine on their own while it stays over budget (`autoEvacuate`).
pub(crate) mod auto_evacuate;
// What Auto mode asks of a chat (`auto_session/`): its work, its record, its freeze.
mod auto_hold;
// A holder gives a chat the person moved: its turn stopped as a move by hand stops one.
mod auto_give;
pub(crate) use auto_give::TurnStop;
pub(crate) mod auto_resume;
mod away_recap;
mod background_cause;
pub mod background_turn;
#[cfg(test)]
mod background_turn_end_tests;
mod bg_folder;
#[cfg(all(test, unix))]
mod bg_folder_bench;
mod bg_notify;
mod bg_tasks;
pub(crate) mod book_tee;
mod bookmarks;
mod bounded;
mod bridge;
mod btw;
mod caller_registry;
pub(crate) mod cancel;
mod capacity_retry;
/// A chat waiting for capacity: the one calm state every client draws.
pub(crate) mod capacity_wait;
// A turn ends when its agent ends it; the steers it runs on with are the next turn's.
mod carried_turn;
mod catalog_reload;
pub mod chat_activity;
mod chat_index;
// A reply's checkable claims against the turn's runs (`claim_checks`).
mod claim_check;
pub(crate) mod clone_boot;
mod closed_rows;
#[cfg(unix)]
mod closed_tmp;
pub mod cmux_tools_answer;
mod cold_archive;
mod cold_segments;
// A wake onto a cold, large chat: one batch on an interval, compacted first.
pub(crate) mod cold_wake;
mod complete;
pub mod composers;
mod construct;
mod control_asks;
pub(crate) mod create_key;
pub mod created_by;
mod credentials;
mod cursor_ext;
pub(crate) mod dead_letters;
pub(crate) mod desktop_bridge;
mod digest;
pub(crate) mod dispatch;
mod drafts;
// RFD 0002 steps 1 and 2: nothing consumes the rung until step 3's row field.
#[cfg_attr(not(test), allow(dead_code))]
mod earned_access;
#[cfg_attr(not(test), allow(dead_code))]
mod earned_events;
mod elevation;
mod ephemeral;
mod event_reads;
pub(crate) mod evict;
mod exit_reason;
mod fallback_start;
pub(crate) mod file_uploads;
#[cfg(test)]
mod first_work_tests;
mod fork;
mod fork_at;
pub(crate) mod fork_before;
pub(crate) mod fork_cancel;
mod fork_replay;
mod fork_request;
#[cfg(test)]
mod fork_retarget_tests;
mod fork_start;
pub mod fork_subagent;
mod fork_transcript_auth;
mod former_names;
pub mod forum;
#[cfg(test)]
mod forum_held_turn_tests;
pub mod forum_hosted;
mod forward_wait;
pub(crate) mod full_access_bound;
pub(crate) mod full_access_children;
mod gemini_plan;
mod git_watch;
// The dynamic CPU class's controller (`cpu_class/pressure.rs`).
mod cpu_pressure;
mod github_owner;
mod goal_tools;
mod handoff;
mod harness_key;
mod harness_magic;
mod harness_sandbox;
mod harness_view;
mod harness_watch;
mod health_view;
// What appending a held tool output snapshot costs, small chat and god chat (manual, `--ignored`).
#[cfg(test)]
#[path = "held_append_bench.rs"]
mod held_append_bench;
mod held_asks;
mod held_lock;
pub mod here;
pub(crate) mod history_delete;
pub(crate) mod history_search;
mod history_timing;
mod host_level;
#[cfg(test)]
mod host_notice_tests;
mod hosts;
// Row 3b's first PR: the source, driven by tests. Its second PR (the tee at v1's append and the
// chat registry in the daemon's v2 handle) is its first caller in the daemon.
pub(crate) mod hub_health;
mod hunk_summary;
mod hybrid_hold;
pub(super) mod idle;
mod idle_census;
mod idle_governor;
pub(crate) mod image_size;
pub(crate) mod inactive_archive;
pub(crate) mod inbox;
pub(crate) mod inbox_subscription;
mod install;
pub mod journal_restore;
#[cfg(test)]
mod journal_restore_tests;
pub(crate) mod key_route;
mod key_store;
// The per-lane fan-out cap (`lane_fanout.rs`).
pub(crate) mod lane_fanout;
mod lane_report_reads;
mod lane_report_subagents;
mod lane_report_text;
mod lane_reports;
mod launch_backoff;
mod launch_roots;
mod launchers;
pub mod ledger;
#[cfg(test)]
mod ledger_hub_tests;
mod lifecycle;
pub mod lineage;
pub(crate) mod list_guard;
mod list_order;
pub(crate) mod list_tee;
mod live_ages;
#[cfg(test)]
mod live_ages_tests;
mod live_models;
mod live_name;
mod locate;
pub(crate) mod lock_bridge;
mod log_deferral;
mod log_load;
#[cfg(test)]
mod long_chat_tests;
mod loop_detector;
mod loop_goal;
#[cfg(test)]
mod loop_goal_tests;
pub mod mac_approvers;
mod machine_info;
mod mcp_connect;
pub(crate) mod mcp_probe;
pub mod media_handles;
pub mod media_read;
mod memory_inbox;
mod mesh_book;
mod mesh_rows;
mod message_events;
mod meta_save;
mod model_alias;
pub(crate) mod model_availability;
mod model_hint;
mod model_options;
mod model_probe;
mod models_view;
mod moved_forward;
mod moved_prompt_fence;
pub(crate) mod native_history;
mod native_history_chain;
pub(crate) mod native_messaging;
mod new_request;
pub mod no_session;
mod offer_results;
mod offers;
pub(crate) mod op_once;
pub(crate) mod open_delivery;
mod outage;
pub(crate) mod outbox;
#[cfg(test)]
mod outbox_open_tests;
#[cfg(test)]
pub(crate) mod outbox_oracle;
pub(crate) mod outbox_stats;
mod own_host;
#[cfg(test)]
mod owned_scope_bench_tests;
mod page_first;
pub(crate) mod page_replies;
mod paging;
pub(crate) mod pause;
/// Paused (acpmux continues it) or stranded (nothing will): a row's reading.
pub(crate) mod pause_state;
mod paused_fs;
mod peer_cache;
pub(crate) mod peer_cache_disk;
#[cfg(test)]
mod peer_cache_disk_tests;
mod peer_closed_bound;
#[cfg(all(test, target_os = "linux"))]
mod peer_flap_soak;
mod peer_grace;
#[cfg(test)]
mod peer_grace_tests;
mod peer_lease;
#[cfg(test)]
mod peer_notice_cost_tests;
mod peer_row;
pub(crate) mod peer_snapshot;
mod peer_table;
mod peers;
mod permission_groups;
pub(crate) mod permission_modes;
mod permissions;
pub mod person;
// The person's prompts to a held chat wait to go in together (`person_hold.rs`).
mod person_hold;
mod person_prompt_at;
mod personal_stats;
#[cfg(test)]
mod phone_floor_tests;
mod place_migrate;
pub mod plan_build;
mod policy_gate;
mod policy_mode;
mod policy_source;
mod pool;
pub(crate) mod pool_pressure;
// Files a prompt names, read into it as the turn starts (harness magic).
mod prefetch;
pub mod presence;
mod processes;
mod profile_respawn;
#[cfg(test)]
mod prompt_accept_tests;
// The account's rate limit holds every turn of a chat until its reset.
pub(crate) mod prompt_admission;
mod prompt_attribution;
mod prompt_coach;
pub(crate) mod prompt_images;
mod prompt_ledger;
mod prompt_line;
#[cfg(test)]
mod prompt_line_tests;
mod prompt_sender;
mod protected_hold;
pub(crate) mod pull_requests;
pub(crate) mod purge_tombstones;
mod question_replies;
mod queue;
mod queue_admission;
mod queue_edit;
pub(crate) mod queue_origin;
pub mod races;
pub(crate) mod rate_hold;
mod rediscover;
#[cfg(test)]
mod refused_append_tests;
pub(crate) mod register;
pub(crate) mod release_to_watch;
mod remote_cwd;
mod remote_floor;
mod remote_rows;
pub(crate) mod remote_sandbox;
mod remote_table;
#[cfg(test)]
mod remote_table_bench;
pub(crate) mod reply_fit;
#[cfg(test)]
mod reply_segment_tests;
mod repo_sync;
pub(crate) mod require_asking;
mod resolve;
mod resolve_here;
mod restore_point;
mod restore_writer;
pub(crate) mod restricted;
mod resume;
mod retention;
mod review_brief;
pub(crate) mod review_queue;
#[cfg(test)]
mod review_queue_tests;
mod route_switch;
pub(crate) mod row_log;
mod rows_source;
pub mod rules;
mod secrets;
mod seen;
#[cfg(test)]
mod sender_claim_tests;
mod session;
pub(crate) mod session_auth;
pub(crate) mod session_budget_watch;
pub(crate) mod session_hold;
mod session_index;
pub(crate) mod session_pages;
mod settings_watch;
pub(crate) mod settled_view;
#[cfg(test)]
mod shared_row_tests;
mod shutdown;
#[cfg(test)]
mod shutdown_scan_tests;
#[cfg(test)]
mod shutdown_tests;
mod silent_listing;
mod silent_turn;
#[cfg(feature = "sim")]
mod sim_startup;
mod spawn;
mod spoken_handles;
mod stale_host_respawn;
mod stalled_turn;
mod start_defaults;
mod start_gate;
pub(crate) mod start_mode;
mod start_mode_state;
mod start_retry;
mod start_watch;
mod startup;
#[cfg(test)]
mod startup_wait_tests;
mod status_write;
mod steer_end;
#[cfg(test)]
mod steer_on_start_tests;
pub(crate) mod stop_condition;
pub(crate) mod stop_if_idle;
#[cfg(test)]
mod stop_settles_tests;
mod store_load;
mod store_pressure;
mod stream;
mod subagent_expiry;
pub(crate) mod subagent_list;
pub(crate) mod subagent_resume;
pub(crate) mod subagent_retry;
pub(crate) mod subagent_transcript;
mod subsession_answer;
mod subsession_guard;
mod subsession_results;
mod subsession_resume;
mod subsession_runs;
mod subsession_send;
pub mod subsessions;
mod successors;
mod surge_triage;
// Mask old tool output instead of summarizing it (harness magic).
pub(crate) mod surgery;
pub mod synced;
mod tags;
mod tailnet_controller;
mod tap;
mod task_names;
pub(crate) mod tasks;
mod team_information;
mod team_sent;
mod terminal_input;
#[cfg(test)]
mod time_breakdown_restore_tests;
mod title_log;
#[cfg(test)]
mod title_log_tests;
mod titles;
mod tool_installs;
mod tool_output_cut;
mod tool_paths;
mod tool_read_images;
mod tool_shell;
mod tool_start;
mod tools;
mod touched;
mod transcript;
#[cfg(test)]
mod transcript_seq_tests;
mod transfer;
mod transfer_agent_files;
mod transfer_authority;
mod transfer_guard;
mod transfer_hub_precopy;
mod transfer_in;
mod transfer_out;
pub mod transfer_park;
pub mod transfer_pull;
mod transfer_watch;
#[cfg(test)]
mod translator_queue_tests;
#[cfg(all(test, unix))]
mod trigger_quiet_tests;
mod trust_wait;
mod turn_attestation;
pub(crate) mod turn_cap;
mod turn_cost;
pub(crate) mod turn_frames;
mod turn_git;
mod turn_retry;
mod turn_rules;
pub(crate) mod turn_shots;
mod turn_usage;
mod turns;
#[cfg(test)]
mod turns_copy_stop_tests;
pub(crate) mod unattended_presets;
mod unread_steer;
// What one small update costs at 100, 1,000 and 3,000 sessions (manual, `--ignored`).
#[cfg(test)]
#[path = "update_cost_bench.rs"]
mod update_cost_bench;
mod update_repeats;
mod usage_answer;
// Opt-in team usage sharing: one record per turn (`cmux-usage-share`).
mod usage_share;
mod usage_view;
pub(crate) mod usage_warnings;
#[cfg(test)]
mod usage_warnings_tests;
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) mod v1_source;
mod verify;
pub(crate) mod views;
pub mod vm_boundary;
pub mod vm_host;
#[cfg(test)]
mod wait_reason_tests;
mod warm;
mod watch;
mod watch_events;
pub(crate) mod watches;
mod web_control;
mod web_token;
mod wip_ref;
mod work_below;
#[cfg(test)]
mod worker_lock_tests;
mod workflow_activity;
pub(crate) mod workflow_ci;
pub(crate) mod workflow_index;
mod workflow_runs;
pub(crate) mod worktree_care;
mod wrap_up_offer;
mod xai;

pub use crate::build_info::{build, install_build, version_line};
pub(crate) use crate::turn_errors;
pub use agent_pairs::PairGuard;
pub use auto_background::AUTO_BACKGROUND_ENV;
pub(crate) use auto_hold::{AUTO_AWAY, AUTO_CLIENT};
pub use bg_tasks::{BgScope, bg_owner_words};
pub(crate) use cold_archive::COLD_CHANGED;
pub use file_uploads::FEATURE as FILE_PUT_FEATURE;
/// The windowed upload sender (`file_uploads/window.rs`), for the upload bench.
pub use file_uploads::window as file_put_window;
pub use fork::Retarget;
pub(crate) use fork::offers_fork;
pub use handoff::{HANDOFF_OPERATIONS, MAX_CAPSULE_BYTES};
pub(crate) use idle::SessionAtWork;
pub(crate) use idle_census::LaunchServers;
pub use idle_census::{Sidecar, StoredLaunch};
pub(crate) use lane_reports::TAG as REPORTS_TO_TAG;
pub use list_guard::{RequestHold, RequestStage};
pub(crate) use log_load::AdoptionReady;
#[cfg(debug_assertions)]
pub(crate) use log_load::test_hold;
#[cfg(test)]
pub(crate) use log_load::{NOTE_BEFORE_CATCH_UP_LOCK, NOTE_BEFORE_REPLAY_SCAN, NOTE_IN_CATCH_UP};
pub use media_read::FEATURE as MEDIA_READ_FEATURE;
pub use model_options::{
    current_effort, current_model, current_option, resolve_config_id, spawn_effort, web_url,
    web_url_for_session,
};
pub use native_history::FEATURE as NATIVE_HISTORY_FEATURE;
pub use peer_row::PeerRow;
pub use person_hold::PromptTriager;
pub(crate) use policy_mode::SetRequest;
pub(crate) use pool::SESSION_NEW_BUDGET;
pub use prompt_coach::CoachRewriter;
pub use retention::RetentionRequest;
pub(crate) use route_switch::is_chief;
pub use subagent_transcript::FEATURE as SUBAGENT_TRANSCRIPT_FEATURE;
pub use tool_start::{ToolStart, tool_start};
/// Whether a prompt block is acpmux's lead mark of who wrote it (`prompt_attribution.rs`).
pub fn prompt_attribution_lead(block: &Value) -> bool {
    prompt_attribution::is_lead(block)
}
/// Adds acpmux's marks of who wrote a prompt to `params` (`prompt_attribution.rs`), for tests
/// of the readers that pick its blocks.
#[cfg(test)]
pub(crate) fn prompt_attribution_mark(
    params: &mut Value,
    sender: Option<&str>,
    provenance: Option<&Value>,
) {
    prompt_attribution::mark(params, sender, provenance);
}
pub use digest::{MAX_FROM_AGENT_CHARS, declared_sender, on_peer_host};
pub use key_store::{CliKeyStore, KeepAsk, KeyStore};
pub use pool::{
    PrewarmRequest, PrewarmShape, RssProbe, parse_home_shapes, person_spare_shapes, tree_rss_bytes,
};
pub(crate) use queue::approved_prompts_error;
pub use queue::{Approver, QueuedPrompt, Withdrawn, supersede::key as supersede_key};
pub use route_switch::HarnessRestarts;
pub(crate) use route_switch::route_error;
pub(crate) use seen::{Look, reader_of};
pub use session::{Session, live_tags};
pub(crate) use transfer_out::TOOL_IN_FLIGHT;
pub(crate) use turn_errors::is_limit_error;

/// [`Hub::withdraws`]: each withdraw's answer once its notice is accepted or refused.
type WithdrawsInFlight =
    HashMap<(String, String), tokio::sync::watch::Receiver<Option<Result<Value, RpcError>>>>;
pub(crate) use crate::shell_readonly;
pub(crate) use crate::time_breakdown;
pub use new_request::{
    NewRequest, SUFFIX_TAKEN_NAME, declared_model_json, profile_takes_model_at_spawn,
    suffixed_name, terminal_harness_refusal,
};
pub use paging::{
    DEFAULT_PAGE_BYTES, EventFilter, EventPage, MAX_PAGE_BYTES, fit_reply, page_bytes,
};
pub use peer_lease::PeerLease;
pub(super) use session::{newest_first, prompt_text, short_text};
pub use shutdown::SHUTTING_DOWN;
pub(crate) use shutdown::{
    AGENT_END_BUDGET, CREATED as REFUSED_CREATED, shutting_down_before_create,
};
pub use spawn::expand_env_value;
/// Debug builds only: the next `n` reads of whether a copy of `peer` is ahead fail, as a timed
/// out or dead store would (`peer_snapshot/restore.rs`).
#[cfg(debug_assertions)]
#[doc(hidden)]
pub fn peer_snapshot_reads_fail(peer: &str, n: u32) {
    peer_snapshot::reads_fail(peer, n);
}

/// Debug builds only: each copy keeps at most `n` records from its next change on (0: the
/// bound as built), as a turn past the bound would leave it (`peer_snapshot.rs` `bound`).
#[cfg(debug_assertions)]
#[doc(hidden)]
pub fn peer_snapshot_bound(n: usize) {
    peer_snapshot::BOUND_EVENTS.store(n, std::sync::atomic::Ordering::SeqCst);
}
pub(crate) use crate::questions;
pub use moved_forward::{MAX_MOVES_FOLLOWED, MOVED_HOPS_FIELD};
pub(crate) use peers::{
    PEER_LAGGED, PEER_PERMISSION_PENDING, PEER_ROWS_CHANGED, PEER_SETTLE_BUDGET, is_permission_ask,
};
pub use permission_groups::PERMISSION_GROUP_OPERATIONS;
pub(crate) use permissions::drop_display_lines;
pub(crate) use start_gate::host_label;
pub use subsession_send::Delivery;
pub use vm_boundary::vm_boundary_peer_approves;

/// The longest `match` a durable watch takes (`_acpmux/watch_add`): a stubbed reply chunk keeps
/// that much of its text's end (`paging.rs` `stub_msg`), so a match across chunks is never lost.
pub const MAX_MATCH_BYTES: usize = 2 * 1024;

/// Every `match` a request brings (`_acpmux/events`, `_acpmux/watch_add`) passes here: one past
/// [`MAX_MATCH_BYTES`] would make each stub keep that much of both its text's ends, past any page's
/// bound.
pub fn validate_match(pattern: Option<&str>) -> Result<(), crate::rpc::RpcError> {
    match pattern {
        Some(p) if p.len() > MAX_MATCH_BYTES => Err(crate::rpc::RpcError::invalid_params(format!(
            "match is at most {MAX_MATCH_BYTES} bytes: a watch on a peer chat keeps that much of each long reply's end to find a match across replies"
        ))),
        _ => Ok(()),
    }
}

/// A `match` saved before the cap, cut to [`MAX_MATCH_BYTES`] at a char boundary. Returns whether
/// it was cut.
pub(crate) fn cap_match(pattern: &mut Option<String>) -> bool {
    let Some(p) = pattern else { return false };
    if p.len() <= MAX_MATCH_BYTES {
        return false;
    }
    let mut end = MAX_MATCH_BYTES;
    while !p.is_char_boundary(end) {
        end -= 1;
    }
    p.truncate(end);
    true
}

impl Hub {
    /// Run durable watches: the loop that reconciles them on hub events and the
    /// `REMOTE_WORKERS` that page peer chats. The daemon starts them once at startup; a test
    /// that needs real watch paging starts them on its own hub.
    pub fn start_watches(self: &Arc<Self>) {
        watches::Watches::start(self);
    }
}
pub use web_control::Control;
pub(crate) use web_control::ModeWrite;
pub use web_token::WebToken;

use crate::agent::{ChildAgent, Direction, Inbound};
use crate::config::{Config, HarnessProfile, PermissionPolicy};
use crate::mailbox::Mailbox;
use crate::rpc::{Id, Message, RpcError, method};
use crate::session_identity::{LOCAL_HOST_ID, SessionReceipt};
use crate::store::{
    EventRecord, META_SCHEMA, SessionMeta, SessionStatus, Store, WaitReason, now_ms,
};
use anyhow::Result;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

/// A status [`Hub::set_status`] writes: every [`SessionStatus`] but Waiting, which only
/// [`Hub::set_waiting`] writes, with its [`WaitReason`]. A type of its own, so a Waiting with no
/// reason does not compile (goal cloud-chat-waiting-always-explained).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NotWaiting {
    Idle,
    Ready,
    Running,
    Disconnected,
    Closed,
}

impl From<NotWaiting> for SessionStatus {
    fn from(s: NotWaiting) -> Self {
        match s {
            NotWaiting::Idle => Self::Idle,
            NotWaiting::Ready => Self::Ready,
            NotWaiting::Running => Self::Running,
            NotWaiting::Disconnected => Self::Disconnected,
            NotWaiting::Closed => Self::Closed,
        }
    }
}

impl NotWaiting {
    /// `status` as one [`Hub::set_status`] writes; None for Waiting.
    pub(crate) fn of(status: SessionStatus) -> Option<Self> {
        Some(match status {
            SessionStatus::Idle => Self::Idle,
            SessionStatus::Ready => Self::Ready,
            SessionStatus::Running => Self::Running,
            SessionStatus::Disconnected => Self::Disconnected,
            SessionStatus::Closed => Self::Closed,
            SessionStatus::Waiting => return None,
        })
    }
}

impl WaitReason {
    /// What a chat asked `request` (a permission request) waits for: a question when it carries
    /// one, else a permission.
    pub(crate) fn of_request(request: &Value) -> Self {
        if is_question(request) { Self::Question } else { Self::Permission }
    }
}

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

pub use crate::build_info::VERSION;

/// How long a session's harness may sit unused (no turn, nothing queued, no
/// question waiting, no activity) before it hibernates: it exits and the
/// session resumes on its next prompt (`idle.rs`).
pub const IDLE_CHILD: std::time::Duration = std::time::Duration::from_secs(2 * 60);

/// Events the hub's background readers missed because they fell behind its event ring
/// ([`Hub::lagged_reader`]), since the daemon started.
pub(crate) static READER_LAGS: AtomicU64 = AtomicU64::new(0);

/// Fan-out item: one appended record for one session, shared by every receiver, never copied.
/// `remote` carries the peer name and the peer's summary when the session lives elsewhere.
#[derive(Debug, Clone)]
pub struct HubEvent {
    pub session_id: String,
    pub record: Arc<EventRecord>,
    pub remote: Option<RemoteRef>,
    /// The record's `session/update` line as attached connections that read it raw get it (every
    /// origin but a peer daemon's), built by the first connection that sends it and shared by the
    /// rest (`server::deliver`). HOT PATH AUDIT area F, row A4: a streamed token is copied and
    /// encoded once, not once per attached connection.
    pub update_line: Arc<std::sync::OnceLock<Option<Arc<str>>>>,
    /// The session's row as a watcher's `_acpmux/session_changed` carries it, without and with
    /// its tools, built by the first watching connection that sends it and shared by the rest
    /// (`server::deliver`): one build per record, not one per watching connection. The ring
    /// keeps no row once its watchers sent it ([`SharedRow`]). Its fan-out clock rides in the
    /// same allocation (`gauges.fanout`).
    pub row: Arc<EventRow>,
    /// The list position its row change took (`row_log.rs`), stamped as it is sent; 0 for an
    /// event that changes no row.
    pub list_seq: u64,
    /// A row of one peer's burst, sent as a batch (`Events::send_remote_batch`): a watcher that
    /// asked for batches (`peerRowBatches`, `server::deliver`) hears the burst as one
    /// `_acpmux/peer_rows_changed` after its last row instead of each row's `session_changed`.
    pub peer_batch: bool,
}

/// A [`HubEvent`]'s cells its receivers share: its row without its tools, with them, and with
/// them but no time breakdown (a client that draws none: its `initialize`'s `omitTimeBreakdown`,
/// or an attach's, `SubOpts::omit_time_breakdown`), and the clock of its fan-out to the
/// connections (`gauges::FanoutClock`).
#[derive(Debug, Default)]
pub struct EventRow {
    pub cells: [SharedRow; 3],
    pub fanout: crate::gauges::FanoutClock,
}

/// One record's row, shared by the watchers sending it at the same time and held only while one
/// does. The event ring keeps its last 8,192 events (`Events::new`), so a row each event kept
/// stayed until 8,192 later records pushed it out: a full row carries up to 512 time spans,
/// the tools and the MCP servers as `Value`s, and huge-blue's daemon grew about 1.1 GB an hour
/// to 17 GB (cmuxterm-hq#14649); a lane VM's held 1.6 million spans in 6.4 GB after 6 hours.
#[derive(Debug, Default)]
pub struct SharedRow(std::sync::Mutex<std::sync::Weak<Value>>);

impl SharedRow {
    /// The row a watcher is still sending, else `build`'s, which the next one shares.
    pub(crate) fn get_or_build(&self, build: impl FnOnce() -> Option<Value>) -> Option<Arc<Value>> {
        let mut held = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(row) = held.upgrade() {
            return Some(row);
        }
        let row = Arc::new(build()?);
        *held = Arc::downgrade(&row);
        Some(row)
    }
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
    /// The peer's row, packed (`peer_row.rs`), sharing its text with the table's row. The hub's
    /// event ring holds up to 8,192 events, and an outage of a peer announces every row of it:
    /// as a parsed `Value` each held a tree several times the row's text, and a host with ~100
    /// sessions and peers that came and went grew about 55 MB a minute. A connection parses it
    /// as it sends it, and frees it then.
    pub summary: PeerRow,
}

impl RemoteRef {
    /// The id this daemon's list row names the peer's session `mux_id` by (its
    /// `qualifiedSessionId`, `Hub::remote_summary`): the one key a client matches the
    /// peer's notices of that session to its row and to what it found by that row.
    pub fn qualified_id(&self, mux_id: &str) -> String {
        SessionReceipt::new(self.peer.as_str(), mux_id, None, 0).qualified_id()
    }
}

/// A session that lives on a peer daemon.
#[derive(Debug, Clone)]
pub struct RemoteSession {
    pub peer: String,
    /// Its row, packed (`peer_row.rs`).
    pub summary: PeerRow,
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
    /// Admitted Cloud trigger provenance, never client supplied metadata.
    pub trigger: bool,
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
    /// Whether its prompt is accepted: its sender heard `prompt_accepted`, when it was queued or
    /// once every check that can refuse it has passed (`run_prompt`). Only from then on does a
    /// second copy of the prompt hear this turn (`turns.rs` `pending_turn`).
    pub accepted: bool,
    /// The paired device that sent this Web turn, while every Web prompt and steer in it came
    /// from that one device (`Hub::owner_phone_full_access` reads it again); None for a Local
    /// turn, one another client touched and one recovered after a restart. Set with the turn
    /// and narrowed beside `control`, under the turn lock (review of cmux#43251, P1-F1).
    pub device: Option<String>,
}

/// Options for `Hub::prompt_with`.
#[derive(Default)]
pub struct PromptOptions {
    /// Internal guard checked after asynchronous prompt setup and immediately before acceptance.
    /// Public only so callers outside the crate can build options with `..Default::default()`;
    /// it can only refuse a prompt, never admit one.
    #[doc(hidden)]
    pub race_guard: Option<Arc<dyn Fn() -> Result<(), RpcError> + Send + Sync>>,
    /// The prompt's admission, taken by the RPC layer before it resolves prompt uploads
    /// (`prompt_admission.rs`: bounded both ways).
    #[doc(hidden)]
    pub admission: Option<Arc<prompt_admission::Admission>>,
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
    /// A native Cloud mobile prompt: apply the phone's asking-mode policy,
    /// including to a prompt that waited in the queue.
    pub cloud_mobile: bool,
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
    /// With `steer_only`, also fences a steer to this exact turn; a completed target
    /// never redirects a workflow nudge into a person's next prompt.
    pub interrupt_turn: Option<String>,
    /// Who sent the prompt, when not the person (`prompt_provenance.rs`).
    pub provenance: Option<Value>,
    /// Connection proof that a person authored this prompt. A `person_message` kind alone is not
    /// enough: local clients may supply that shape without the authenticated person handshake.
    pub human_authenticated: bool,
    /// The owner's own terminal send (`server/requests.rs` `owner_terminal`): recorded as the
    /// person's prompt, yet no connection proved the person, so it lifts no protected hold
    /// (`protected_hold.rs`), as #37497 made it.
    pub unproven_owner: bool,
    /// The text of a prompt a connection proved the person's (`server/requests.rs`
    /// `person_admitted`), for the prompt coach (`prompt_coach.rs`): recorded by the prompt's
    /// id once it has one, so its own turn's end settles it.
    pub coach: Option<String>,
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
    /// A fired continuation's generation (`auto_resume.rs` `Pending::generation`): its turn
    /// starts only while no Stop came since its fire, even once its mark is gone.
    pub fired: Option<u64>,
    /// `_meta.acpmux.supersede` (`supersede.rs`): the same sender's prompts still queued under
    /// this key leave the queue, replaced by this one.
    pub supersede: Option<String>,
    /// Validated display-only metadata from the app's ordered composer. It is persisted in the
    /// mux record and never forwarded to the agent's ACP prompt.
    pub display_parts: Option<Value>,
    /// The paired machine that sent it (`server/remote_guard.rs` `sending_device`). It grants
    /// nothing by itself: each rule reads the pairing store again at dispatch, its Full-access
    /// setting (`Hub::full_access_hold`) and whether it is the owner's own phone (D13,
    /// `Hub::local_claude_refusal`).
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
    /// A plain send from another agent, on this host or forwarded by a peer daemon or the mesh
    /// relay (`session/prompt`, `inbox::plain_send`): the chat's inbox takes it. Every other path
    /// that prompts (reports, task cards, a paused pair's release) keeps the queue.
    pub inbox: bool,
    /// The sender waits for the reply (`_meta.acpmux.wakeOrFail`): a message the inbox would
    /// hold in an idle chat that it does not wake is refused at once (`inbox.rs`
    /// `not_woken`), never left waiting for a turn that does not come.
    pub wake_or_fail: bool,
    /// The sender waits for the reply and prints it (`readsReply`, `wakeOrFail`): its
    /// connection's end, `true` once it left. An inbox message keeps it, so a notice says
    /// "waiting" only while that caller is still there, and a question nobody waits for gets its
    /// reply sent back (`hub/question_replies.rs`).
    pub reply_reader: Option<tokio::sync::watch::Receiver<bool>>,
}

/// The outcome of one client prompt id, shared with a resend of it.
pub(super) type PromptOutcome = Arc<tokio::sync::watch::Sender<Option<Result<Value, RpcError>>>>;

/// What the agent's stream says about the current assistant message, used
/// to record `message_superseded` and to attach streamed error text to
/// `turn_result`.
#[derive(Debug, Default)]
pub(super) struct StreamState {
    capacity_retries: capacity_retry::Retries,
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
    /// The reply segment streaming now (`stream.rs` `reply_segment`): the id stamped on each of
    /// its `agent_message_chunk` records, until a new message or a prompt (a steer) ends it.
    pub(super) reply_segment: Option<String>,
    /// Reply segments started in this turn, which numbers the next one.
    pub(super) reply_segments: u32,
    /// Reply segments started outside any turn since the daemon started (`reply_segment_for`):
    /// never reset, so text between turns never reuses an earlier id.
    pub(super) loose_segments: u32,
    /// The turn `reply_segments` counts in, and the `messageId` of the segment streaming now.
    pub(super) segment_turn: Option<String>,
    pub(super) segment_message: Option<String>,
    /// This turn's agent thought or called a tool (`stream.rs`), and how much reply
    /// text it streamed (`after_agent_update`): what `unstored_turn_worked` reads.
    pub(super) agent_worked: bool,
    pub(super) reply_chars: usize,
}

/// An inline `/btw` side session's transcript owner: its family and the parent chat's env.
pub(super) type InlineBtwOwner = (String, std::collections::BTreeMap<String, String>);

pub struct Hub {
    pub(super) hub_ref: std::sync::OnceLock<std::sync::Weak<Hub>>,
    pub(crate) workflow_runs: crate::workflow_runs::Service,
    pub config: RwLock<Config>,
    pub(crate) wireguard: Option<Arc<crate::wireguard::Transport>>,
    /// The hub carrier once it starts (`hub_carrier.rs`); every peer holds this slot.
    #[cfg(feature = "hub-carrier")]
    pub hub_carrier: crate::hub_carrier::HubCarrierSlot,
    /// The carrier's registration the daemon's start made from the join config
    /// (`hub_carrier::start_kept`); a sign-out's leave drops it, which unregisters.
    #[cfg(feature = "hub-carrier")]
    pub(crate) hub_carrier_serve: std::sync::Mutex<Option<crate::hub_carrier::HubServe>>,
    /// The loopback WebSocket address the start gave the carrier, so an enroll that replaces the
    /// join starts it again on the new join (`server/machine_enroll.rs`).
    #[cfg(feature = "hub-carrier")]
    pub(crate) hub_carrier_websocket: std::sync::OnceLock<std::net::SocketAddr>,
    /// A local route to each of the person's other machines' cmux-tui session (`machine_routes.rs`).
    #[cfg(feature = "hub-carrier")]
    pub(crate) machine_routes: crate::machine_routes::Routes,
    /// Each peer's last-known-good path (`peer_last_good.rs`), beside the peer caches.
    pub(crate) peer_paths: Arc<crate::peer_last_good::LastGood>,
    /// The daemon's store, read through each fork's referenced history (`store/fork_view.rs`).
    pub(super) store: Box<dyn Store>,
    pub(super) mailbox: Mailbox,
    /// The forum log (`forum.rs`, `hub/forum.rs`).
    pub(super) forum: std::sync::OnceLock<crate::forum::Forum>,
    /// The team's hosted forum, set up from the env on first use (`hub/forum_hosted.rs`).
    pub(super) forum_hosted: std::sync::OnceLock<forum_hosted::Slot>,
    pub(super) sessions: StdMutex<HashMap<String, Arc<Session>>>,
    /// The chats that left memory, each a compact row (`evict.rs`).
    pub(crate) evicted: evict::Tier,
    spoken_handle_renames: StdMutex<()>,
    /// Session ids whose metadata is still live. Closed records remain in `sessions` and on
    /// disk for history, search, export and restore, but list/peer hot paths never walk them.
    pub(super) live_session_ids: StdMutex<std::collections::HashSet<String>>,
    /// Serialized summaries for closed sessions (`closed_rows.rs`). Metadata commits replace the
    /// row before the next list, so no list rebuilds closed-session projections, and a list
    /// page copies their bytes unparsed.
    pub(super) closed_summary_cache: StdMutex<closed_rows::ClosedRows>,
    /// The closed sessions' chat activity, built once for every chats reader (`chat_activity.rs`).
    pub(crate) chat_activity_cache: chat_activity::ActivityCache,
    /// v2's book tee (`book_tee.rs`), when the daemon writes books: with none, v1's append is
    /// as it was.
    pub(super) book_tee: std::sync::OnceLock<Arc<book_tee::BookTee>>,
    /// The transcript rows of the chats a client reads rows of (`rows/serve.rs`).
    pub(crate) rows: crate::rows::RowsCache,
    /// Closed rows built anew because their cached bytes were missing or stale (tests).
    #[cfg(test)]
    pub(super) closed_summary_builds: AtomicU64,
    /// Closed rows parsed back from their cached bytes (tests).
    #[cfg(test)]
    pub(super) closed_summary_parses: AtomicU64,
    /// Session summaries built, live or closed, with tools or without (tests).
    #[cfg(test)]
    pub(crate) summaries_built: AtomicU64,
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
    /// Every change watchers hear of, each a list position (`list_guard.rs`, `row_log.rs`).
    pub(super) events: list_guard::Events,
    /// The v2 list stream on peer links: the v2 handle when `peers` is on, and the counters
    /// (`link_v2.rs`).
    pub(crate) link_v2: Arc<crate::link_v2::Shared>,
    /// A test's hold on list requests (`list_guard.rs`).
    pub(crate) list_guard: list_guard::ListGuard,
    /// `_acpmux/archive` and `_acpmux/rename` run once per `opId` (`op_once.rs`).
    pub(crate) op_once: op_once::OpOnce,
    /// This daemon's rows in list order, kept as they change (`list_order.rs`).
    pub(super) list_order: list_order::ListOrder,
    /// Client requests every connection serves now, each holding its work slot
    /// (`server/in_flight.rs`, `Hub::requests_in_flight`).
    pub(crate) requests_in_flight: Arc<std::sync::atomic::AtomicUsize>,
    /// Each chat's spend and context as its harness recorded them (`usage_view.rs`).
    pub(crate) usage_stats: usage_view::UsageCache,
    /// `_acpmux/usage`'s last answer, kept by its list position (`usage_answer.rs`).
    pub(crate) usage_answers: usage_answer::UsageAnswers,
    /// What every turn here cost, indexed by day and session (`hub/ledger`, `_acpmux/ledger`).
    pub(crate) ledger: ledger::Ledger,
    /// `_acpmux/models` replies now asking peers for theirs
    /// (`server/models_fanout.rs`): a remote asker meanwhile gets this
    /// daemon's own catalog, so mutual peers cannot ping-pong.
    pub models_fanouts: std::sync::atomic::AtomicUsize,
    /// The sessions that may hold an ask, and those with pull requests (`review_queue.rs`).
    pub(crate) review_index: review_queue::Index,
    /// The approvals audit trail (`audit_log.rs`).
    pub(crate) audit: audit_log::AuditLog,
    pub shutdown: Notify,
    /// The owner of the hub's own tasks (`cmux_scope`). Every task that lives off the hub (the
    /// idle reaper, each chat's inbound loop, pool starts, carried turns, retries, message
    /// projections) is spawned here, never with a bare `tokio::spawn`: then the shutdown cancels
    /// them all and joins them within a deadline (`Hub::close_owned_tasks`, after the agents),
    /// naming any that did not end, instead of leaving them parked on a wake nobody sends with a
    /// handle that keeps the hub alive. A connection's scope is a child of this one. New hub
    /// code spawns through it; the spawn-owner ratchet counts the bare spawns left.
    pub(crate) scope: cmux_scope::Scope,
    /// Latched daemon restart and drain shared by TCP and embedded-tailnet listeners.
    pub(crate) ws_shutdown: crate::server::WsShutdown,
    /// Set only by an explicit daemon restart/update handoff. Ordinary stops
    /// close clients normally so they do not immediately reconnect to a dead daemon.
    pub(crate) restart_requested: std::sync::atomic::AtomicBool,
    /// Raised when a supervised task cannot go on: the daemon stops for a restart
    /// (`crate::supervise`).
    pub(crate) fatal: crate::supervise::Fatal,
    pub started_at: u64,
    /// The peer registry, published as a snapshot (`peer_table.rs`): a lookup takes no lock.
    pub(super) peers: peer_table::PeerTable,
    /// The peers' rows, published as a snapshot (`remote_table.rs`): a reader loads it with no
    /// lock and never holds up a writer; writers (peer notices, purges) take turns.
    pub(super) remote_sessions: remote_table::RemoteTable,
    /// The same person's machines and sessions the mesh hub lists (`mesh_book.rs`).
    pub(super) mesh_book: StdMutex<mesh_book::MeshBook>,
    /// The health of the machines only the mesh hub reaches, read through it (`hub_health.rs`).
    pub(crate) hub_health: Arc<StdMutex<hub_health::HubHealth>>,
    /// Read answers larger than one hub message, held for their asker (`mesh_read_parts.rs`).
    pub(crate) mesh_read_parts: crate::server::mesh_relay::read::parts::ReadParts,
    /// Hub-routed session reads shared by callers while the same network read is in flight.
    pub(crate) mesh_read_flights: crate::single_flight::SingleFlight<
        crate::server::mesh_relay::read::ReadKey,
        Result<Value, crate::rpc::RpcError>,
    >,
    /// Each parent's children by tag, for an approval card's label (`permissions/display.rs`).
    pub(super) child_tags: permissions::ChildTags,
    /// Leased peers by name, with the generation of the peer each lease
    /// started (`peer_lease.rs`); never saved. Look up a peer Arc briefly, then release this and
    /// the `peers` lock before taking `remote_sessions` or a per-peer writer gate.
    pub(super) peer_leases: StdMutex<HashMap<String, u64>>,
    /// Per-peer cache writers; held through the write so removal cannot be followed by an older
    /// snapshot landing on disk. Each holds what it last left on disk (`peer_cache_disk.rs`), so
    /// a save writes only what changed. Entries are removed with the peer.
    pub(super) peer_cache_writers:
        StdMutex<HashMap<String, Arc<StdMutex<peer_cache_disk::OnDisk>>>>,
    /// Bounds concurrent cache serialization/fsync work; notice application never waits on it.
    pub(super) cache_write_gate: Arc<StdMutex<()>>,
    #[cfg(test)]
    pub(super) cache_test_writes: AtomicU64,
    /// Peer rows `visit_remote_sessions` copied out (`peer_notice_cost_tests.rs`).
    #[cfg(test)]
    pub(super) remote_rows_copied: AtomicU64,
    /// Bytes the peer cache saves wrote, both files (`peer_cache_disk_tests.rs`).
    #[cfg(test)]
    pub(super) cache_test_bytes: AtomicU64,
    #[cfg(test)]
    pub(super) cache_test_write_delay_ms: AtomicU64,
    #[cfg(test)]
    pub(super) cache_test_write_started: AtomicBool,
    #[cfg(test)]
    pub(super) cache_test_delay_peer: StdMutex<Option<String>>,
    #[cfg(test)]
    pub(super) cache_test_flush_pause:
        StdMutex<Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>>,
    #[cfg(test)]
    pub(super) peer_notice_projection_hook: StdMutex<Option<Arc<peers::PeerNoticeProjectionHook>>>,
    /// Moves on with each `peer_add` (under the config lock): a reload whose file read began
    /// before one leaves the saved peers' boundaries and GitHub lending as that add left them.
    pub(super) peer_config_gen: std::sync::atomic::AtomicU64,
    /// The config's `usageWarnings` thresholds, set at start and on each reload
    /// (`catalog_reload.rs`): a summary reads them here, so a writer holding the config lock never
    /// swaps the configured rules for the defaults (`usage_warnings.rs`).
    pub(super) usage_limits: StdMutex<crate::config::UsageLimits>,
    /// The links of Macs that lend this machine their GitHub login (`github_owner.rs`).
    pub(super) github_owners: github_owner::Owners,
    /// Agent byte channels: listeners and open channels (`server/channels.rs`).
    pub(crate) channels: crate::server::channels::Channels,
    /// The cmux sign-in the app lends for App tokens (`github_app_token.rs`).
    pub(crate) github_app: Arc<crate::github_app_token::AppLease>,
    /// Auto mode's holder loop, once this daemon started one (`auto_session::spawn_holder`):
    /// what the Auto methods and a prompt to a chat another holder runs reach it through.
    pub(crate) auto_holder: std::sync::OnceLock<crate::auto_session::HolderHandle>,
    /// Whose turn it is to run git in an Auto chat's folder (`auto_session/turns.rs`).
    pub(crate) auto_turns: crate::auto_session::turns::Turns,
    /// Each peer session's events as this daemon saw them, kept on disk
    /// (`peer_snapshot.rs`): a paused or offline peer's chat paints from it.
    pub(super) peer_snapshots: peer_snapshot::PeerSnapshots,
    pub(super) peer_notices: mpsc::Sender<(String, u64, crate::peer::PeerNotice)>,
    /// `peerWake`'s argv (config `peerWake`), handed to every peer (`Peer::wake`); a config
    /// reload swaps it in place (`catalog_reload.rs`).
    pub(super) peer_wake: crate::peer::WakeHook,
    pub(super) peer_notices_rx:
        Mutex<Option<mpsc::Receiver<(String, u64, crate::peer::PeerNotice)>>>,
    pub(super) peer_notices_stop: tokio::sync::watch::Sender<bool>,
    pub(super) peer_notices_finished: AtomicBool,
    pub(super) peer_notices_done: Arc<Notify>,
    /// A peer cache save was put off (`save_peer_cache`): the notice loop arms its one cache
    /// deadline. With nothing put off it sets no timer (`peer_grace.rs`).
    pub(super) peer_cache_kick: Notify,
    /// `SAVE_EVERY_MS` in tests that wait for a put-off save (`peer_cache.rs`).
    #[cfg(test)]
    pub(super) cache_test_save_every_ms: AtomicU64,
    /// Models each agent has advertised, keyed by agent profile name. Filled
    /// whenever a session starts, so the picker can list a harness that has
    /// no live session.
    pub(super) known_models: StdMutex<HashMap<String, Vec<(String, String)>>>,
    /// The ACP lists kept on disk by earlier probes (`live_models::AcpCache`), read once at
    /// start: by harness, the profile key it was probed under and the list. Each fills
    /// `known_models` for a profile with the same key until its probe answers (`model_probe.rs`).
    pub(super) acp_cached: StdMutex<HashMap<String, (String, Vec<(String, String)>)>>,
    /// The harnesses whose `known_models` entry is that disk copy, not a report of this
    /// daemon's: the probe still runs for them.
    pub(super) acp_from_disk: StdMutex<std::collections::HashSet<String>>,
    /// What each ACP harness's startup probe's `session/new` answered about a new chat's choices,
    /// by profile name: its `modes` and `configOptions`, as sent. A `_acpmux/harnesses` row's
    /// `reported` falls back to it until a chat of the harness reports (`start_mode.rs`).
    pub(super) probed_choices: StdMutex<HashMap<String, (Option<Value>, Option<Value>)>>,
    /// Each agent's reasoning levels per model, from the level variants its model list names
    /// (`model_catalog::variant_efforts`): the `efforts` of its rows in `_acpmux/models`.
    pub(super) known_efforts: StdMutex<HashMap<String, HashMap<String, Vec<String>>>>,
    /// Model lists from Claude Code's and Codex's own CLIs, by profile name
    /// (`hub/live_models.rs`): richer than `known_models` (efforts, fast).
    pub(super) live_models: StdMutex<HashMap<String, Vec<crate::live_models::LiveModel>>>,
    /// The model ids Codex chats reported that each live list lacked, by profile name, each
    /// already probed again for once (`recheck_live_models`).
    pub(super) live_rechecks: StdMutex<HashMap<String, std::collections::HashSet<String>>>,
    /// When each live list's probe last started (`hub/live_ages.rs`): a read probes an old one again.
    pub(super) live_ages: StdMutex<live_ages::LiveAges>,
    /// (harness, model) pairs whose backend refused them, with its message (model_availability.rs).
    pub(super) refused_models: StdMutex<HashMap<(String, String), String>>,
    /// False while the daemon finishes startup work (login environment,
    /// launcher checks) in the background. Session creation and agent
    /// spawns wait for it; every other request is answered at once.
    pub(super) startup_ready: tokio::sync::watch::Sender<bool>,
    /// The first local client reached the daemon. Deferred peer dials wait for this so remote
    /// handshakes cannot consume the runtime while the app paints its first chat.
    pub(super) local_ready: tokio::sync::watch::Sender<bool>,
    /// Whether an agent may start: the login environment, the catalog, the launcher checks and
    /// the vault are ready (`startup.rs` `prepare_spawns`). Apart from `startup_ready`: a new chat
    /// or a chat's own start waits for this and for its own adoption only, never for every
    /// other chat's adoption or log (`daemon.rs`).
    pub(super) spawn_ready: tokio::sync::watch::Sender<bool>,
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
    /// This start is a copied machine's first: the machine it was copied from (`clone_boot.rs`).
    pub(super) clone_boot: std::sync::OnceLock<String>,
    /// A chat closed: wakes the log retention worker (`retention.rs`).
    pub(super) retention_wake: Arc<Notify>,
    /// Chats whose log the store brought back from its cold archive, whose preview is not dropped
    /// yet, and the wake of the worker that drops it (`cold_archive.rs`).
    pub(super) cold_rehydrated: Arc<StdMutex<std::collections::BTreeSet<String>>>,
    pub(super) cold_wake: Arc<Notify>,
    /// Chats whose log sealed a segment since the cold segments' worker last looked, and its wake
    /// (`cold_segments.rs`).
    pub(super) cold_sealed: Arc<StdMutex<std::collections::BTreeSet<String>>>,
    pub(super) cold_sealed_wake: Arc<Notify>,
    /// Chats whose log grew past another 4 MiB since the pack worker last looked, its wake, and
    /// the log stamp each chat's pack was last checked against (`pack_as_it_grows.rs`).
    pub(super) pack_grown: Arc<StdMutex<std::collections::BTreeSet<String>>>,
    pub(super) pack_grown_wake: Arc<Notify>,
    pub(super) pack_checked: StdMutex<HashMap<String, u64>>,
    /// Tests: the level the cold segments' worker moves at, in place of the settings file's.
    #[cfg(test)]
    pub(super) cold_segments_level: StdMutex<Option<Option<i32>>>,
    /// False from a deferred start with running agent hosts until adoption ends: prompts to
    /// those chats wait for it (`log_load.rs` `wait_adopted`).
    pub(crate) adoption_ready: tokio::sync::watch::Sender<bool>,
    /// One chat's adoption ended (`log_load.rs` `chat_adopted`): its waiting prompts look again.
    pub(crate) chat_adopted_wake: Notify,
    /// Startup has read the login environment: the catalog sees its PATH.
    pub(super) catalog_ready: tokio::sync::watch::Sender<bool>,
    /// Startup has served the model lists kept on disk: `_acpmux/models` waits for it.
    pub(super) model_caches_ready: tokio::sync::watch::Sender<bool>,
    pub(super) login_env_requested: AtomicBool,
    /// Session ids an `import` is writing right now.
    pub(super) importing: StdMutex<std::collections::HashSet<String>>,
    /// Forks being made under a caller's cancel token (`fork_cancel.rs`).
    pub(super) pending_forks: fork_cancel::PendingForks,
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
    /// How long a start that waits on its harness lets it do no work (`start_watch.rs`
    /// `START_HUNG`; tests shorten it).
    pub(super) start_hung: StdMutex<std::time::Duration>,
    /// The background-task runner's binary and spool segment a test set (`bg_tasks.rs`).
    pub(super) bg_runner: StdMutex<Option<(crate::self_command::SelfCommand, u64)>>,
    /// Background-task starts, one at a time (`bg_tasks.rs`).
    pub(super) bg_starts: tokio::sync::Mutex<()>,
    /// The chats' task folders at their last look (`bg_folder.rs`).
    pub(super) bg_folders: bg_folder::BgFolders,
    /// The harnesses the model probes may start (`ACPMUX_PROBE_HARNESSES`);
    /// None: every harness.
    pub(super) probe_only: StdMutex<Option<std::collections::BTreeSet<String>>>,
    pub(super) idle_wake: Arc<Notify>,
    /// Paces the host's background capacity continuations (`auto_resume/capacity_gate.rs`).
    pub(super) capacity_gate: auto_resume::CapacityGate,
    pub(super) idle_reaper: AtomicBool,
    /// The clocks at the last gap check, and how many gaps were seen (`resume.rs`).
    pub(super) resume_watch: Arc<resume::ResumeState>,
    pub(super) resumes: tokio::sync::watch::Sender<u64>,
    /// When a person last prompted a chat here, Unix ms, 0 for never (`person_prompt_at.rs`).
    pub(super) person_prompts: tokio::sync::watch::Sender<u64>,
    /// Paused machines' replicas and write journals, when `writeJournal.enabled` (`paused_fs.rs`).
    pub(super) paused_fs: Option<Arc<crate::write_journal::paused::PausedFs>>,
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
    /// The app's `agents.chats.sessionRecap` (`away_recap.rs`), from its last chat settings push.
    pub(super) session_recap: AtomicBool,
    /// The app's `agents.chats.terminalChatWritable` (`release_to_watch.rs`), from its last chat
    /// settings push: whether a chat handed to a cmux terminal stays writable.
    pub(super) terminal_chat_writable: AtomicBool,
    /// When each away chat's recap is asked for, in hub clock nanos (`away_recap.rs`).
    pub(super) recap_due: StdMutex<HashMap<String, u64>>,
    /// Chats whose host below the level moved, or will not, in this daemon's run (`host_level.rs`).
    pub(super) host_moved: StdMutex<HashSet<String>>,
    /// Wakes the recap loop when `recap_due` changes.
    pub(super) recap_wake: Arc<Notify>,
    /// What writes prompt coach rewrites instead of the small model (tests; `prompt_coach.rs`).
    pub(super) coach_rewriter: StdMutex<Option<prompt_coach::CoachRewriter>>,
    /// Chats with a surge triage pass due or running, and whether another is asked after it
    /// (`surge_triage.rs`).
    pub(super) surge_triage_due: StdMutex<HashMap<String, bool>>,
    /// What answers surge triage instead of the small model (tests; `surge_triage.rs`).
    pub(super) surge_triager: StdMutex<Option<surge_triage::SurgeTriager>>,
    /// Whether surge admission holds messages, set by tests; `None` reads Settings >
    /// Experimental > Labs > Show Preview Features (`inbox_surge.rs` `surge_inbox_on`).
    pub(super) surge_inbox: StdMutex<Option<bool>>,
    /// The fleet hold as its file last read (`session_hold.rs`).
    pub(crate) fleet_hold: StdMutex<session_hold::FleetHoldCache>,
    /// Each chat's surge triage state between passes (`surge_triage.rs` `Journal`).
    pub(super) surge_triage_journals: StdMutex<HashMap<String, surge_triage::Journal>>,
    /// The thread owners every chat subscribed itself to (`surge_triage.rs`).
    pub(super) surge_subscribers: StdMutex<surge_triage::Subscribers>,
    /// Each digest recipient's digest turn under way and its measured reply period
    /// (`surge_triage.rs` `DigestPace`): one entry per session a digest reached.
    pub(super) surge_digest_pace: StdMutex<HashMap<String, surge_triage::DigestPace>>,
    /// What triages held prompts instead of the small model (tests; `person_hold.rs`).
    pub(super) prompt_triager: StdMutex<Option<person_hold::PromptTriager>>,
    /// The forced start mode and the setting's change count (`start_mode_state.rs`).
    pub(super) start_mode_state: start_mode_state::StartModeCell,
    /// The caller tokens earlier daemon runs gave out, by session (`caller_registry.rs`).
    pub(super) caller_registry: caller_registry::CallerRegistry,
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
    /// Withdraws whose retraction notice is on its way, by session and prompt id: a second
    /// withdraw of the same message answers as the first (`withdraw.rs`).
    pub(super) withdraws: StdMutex<WithdrawsInFlight>,
    /// Tests only: a pause before a family message's write (`full_access_bound::WriteSeam`).
    #[cfg(test)]
    pub(super) family_write_seam: full_access_bound::WriteSeam,
    /// Tests only: a pause while a prompt's model-sized copies are made (`turns::agent_blocks`).
    #[cfg(test)]
    pub(super) copy_seam: full_access_bound::WriteSeam,
    /// Tests only: a pause after a fork read its parent's meta, before its cut (`fork.rs`).
    #[cfg(test)]
    pub(super) fork_seam: full_access_bound::WriteSeam,
    /// Tests only: pause an admitted prompt before its logical turn is installed.
    #[cfg(test)]
    pub(super) prompt_start_seam: full_access_bound::WriteSeam,
    /// Tests only: pause a prompt before it reaches queue admission.
    #[cfg(test)]
    pub(super) prompt_admission_seam: full_access_bound::WriteSeam,
    /// Tests only: pause a prompt whose turn shows, before its last check and its acceptance.
    #[cfg(test)]
    pub(super) turn_shown_seam: full_access_bound::WriteSeam,
    /// Tests only: pause a chat's first work once it holds it (`inbox.rs`), before its turn.
    #[cfg(test)]
    pub(super) first_work_seam: full_access_bound::WriteSeam,
    /// Tests only: pause a turn's end once its turn is taken (`finish_turn`), before it writes.
    #[cfg(test)]
    pub(super) finish_seam: full_access_bound::WriteSeam,
    /// Tests only: pause purge after store deletion, before ID-keyed cleanup.
    #[cfg(test)]
    pub(super) purge_seam: full_access_bound::WriteSeam,
    /// Tests only: the rules of an earlier head this hub replays (`journal_restore::AT_91B`).
    #[cfg(test)]
    pub(super) old_rules: std::sync::atomic::AtomicU8,
    /// Tests only: pause a retry's task before it sets its wait (`auto_resume.rs`).
    #[cfg(test)]
    pub(super) retry_seam: full_access_bound::WriteSeam,
    /// Tests only: pause an unstarted turn's end between its shutdown check and its write
    /// (`start_retry.rs` `fail_unless_shutdown_settles`); it blocks its thread.
    #[cfg(test)]
    pub(super) settle_seam: full_access_bound::WriteSeam,
    /// Tests only: pause a dispatch check's refusal between its shutdown check and its
    /// `prompt_refused` write (`web_control.rs` `check_dispatch`); it blocks its thread.
    #[cfg(test)]
    pub(super) refuse_seam: full_access_bound::WriteSeam,
    /// Tests only: delay a Stop before its notification reaches the child writer.
    #[cfg(test)]
    pub(super) cancel_write_seam: Arc<full_access_bound::WriteSeam>,
    /// Tests only: runs right before a queued prompt's `queued` record is logged (`enqueue`).
    #[cfg(test)]
    pub(super) queued_log_seam: StdMutex<Option<Box<dyn FnOnce() + Send>>>,
    /// Tests only: this daemon takes a bundle as a build without queue approval would
    /// (`transfer_in.rs` refuses one that carries approved prompts that still wait).
    #[cfg(test)]
    pub(super) queue_approval_off: AtomicBool,
    pub(super) harness_watch: harness_watch::HarnessWatchState,
    /// The one check of every watched transcript (`watch_tick.rs`).
    pub(super) watch_ticker: watch::WatchTicker,
    /// The settings file watched for start-mode changes (`settings_watch.rs`).
    pub(super) settings_watch: settings_watch::SettingsWatchState,
    /// Moves on each time the settings watch saw the settings file change (written, created,
    /// replaced): what waits for a setting with no timer subscribes (the desktop bridge while it
    /// is off, `desktop_bridge.rs`).
    pub(super) settings_changes: tokio::sync::watch::Sender<u64>,
    /// The HEAD of each attached session's folder, watched for a checkout (`git_watch.rs`).
    pub(super) git_watch: git_watch::GitWatchState,
    /// Whether `dynamic` sessions yield the CPU now (`cpu_pressure.rs`).
    pub(super) cpu_pressure: StdMutex<crate::cpu_class::pressure::Controller>,
    pub catalog: Arc<crate::catalog::CatalogService>,
    /// Sign in with ChatGPT: its attempts and per-account refresh locks (`crate::chatgpt`).
    pub chatgpt: Arc<crate::chatgpt::Service>,
    /// One-click Claude Code tokens (`claude setup-token` in the daemon's own pty).
    pub claude_token: Arc<crate::claude_token::Service>,
    /// Agent CLI health (`harness_health`, `hub/health_view.rs`).
    pub health: Arc<crate::harness_health::HealthService>,
    /// The token the web listener checks now (`web_token.rs`).
    pub web_token: WebToken,
    /// This launch's person key (`person.rs`): who may allow and grant.
    pub person: person::PersonGate,
    /// Who has each chat open and who types in it, in memory only (`presence.rs`).
    pub presence: presence::Presence,
    /// Who is on this machine now, across devices, in memory only (`here.rs`).
    pub here: here::HereTable,
    /// Chat titles and read marks as a sync replica, opened on first use (`synced.rs`).
    pub synced: std::sync::OnceLock<synced::Synced>,
    /// How long a move may go without its client (`transfer_watch.rs`).
    pub(super) transfer_lease: StdMutex<std::time::Duration>,
    /// The moves one watch ends, or whose begin still makes them (`transfer_watch.rs`).
    pub(super) watched_moves: StdMutex<HashSet<String>>,
    /// How a hub move reaches its source for the pages (`transfer_pull.rs`): the hub carrier's
    /// `TransferSource` circuit once it starts, or a test's in-process stand-in.
    pub(super) transfer_dial: StdMutex<Option<Arc<dyn transfer_pull::TransferDial>>>,
    /// The circuits a pre-copy's target parked for its move's control (`transfer_park.rs`).
    pub(super) parked_moves: StdMutex<transfer_park::Parked>,
    /// How long Ctrl-B waits for Claude Code's answer (`processes.rs`).
    pub(super) background_timeout: StdMutex<std::time::Duration>,
    /// How long a foreground shell runs before it goes to the background, None: never
    /// (`auto_background.rs`).
    pub(super) auto_background_after: StdMutex<Option<std::time::Duration>>,
    /// The `<session>/<tool call>` shells a timer of `auto_background.rs` watches.
    pub(super) auto_background_armed: StdMutex<std::collections::HashSet<String>>,
    /// How long a foreground call runs before the person's message waiting behind it moves it to
    /// the background, None: never (`auto_background.rs`).
    pub(super) message_background_after: StdMutex<Option<std::time::Duration>>,
    /// Chats agents offered the person, still open (`offers.rs`).
    pub(super) offers: offers::Offers,
    /// Which session each lane reports its turns to (`lane_reports.rs`).
    pub(super) lane_reports: lane_reports::LaneReports,
    /// Authenticated parents already receiving a lane result through wait/history.
    lane_report_reads: lane_report_reads::LaneReportReads,
    /// Open sub-sessions per parent and starts in flight (`subsessions.rs`).
    pub(super) subsessions: subsessions::Index,
    pub(super) races_running: StdMutex<std::collections::HashSet<String>>,
    /// Creates admitted and still starting (`admission.rs`).
    pub(super) admitting: admission::Admitting,
    /// Run slots of each session's sub-sessions (`subsession_runs.rs`).
    pub(super) subsession_runs: Arc<subsession_runs::Runs>,
    /// `_acpmux/wait` requests subscribed and not yet answered (`server/wait.rs`), shown
    /// as `_acpmux/status` `openWaits`.
    pub(crate) open_waits: std::sync::atomic::AtomicUsize,
    /// `session/update` lines built for attached connections since start (`server::deliver`): each
    /// copies, merges and encodes the record's params. HOT PATH AUDIT area F, row A4: once per record,
    /// not once per connection.
    pub(crate) session_update_encodes: std::sync::atomic::AtomicU64,
    /// `_acpmux/wait` row evaluations since start (`server/wait.rs`): each builds the summaries of
    /// the chats it waits on. A streamed token must cost none (HOT PATH AUDIT area F, row A1).
    pub(crate) wait_evaluations: std::sync::atomic::AtomicU64,
    /// Failed subagents waiting to be resumed, by chat (`subagent_retry.rs`).
    pub(super) subagent_retries: subagent_retry::Retries,
    /// Each chat's top-level subagents and their briefs, for a Resume (`subagent_resume.rs`).
    pub(super) subagent_resumes: subagent_resume::Resumes,
    /// Fired by `set_transfer_lease`: each move's watch reads the new lease now.
    pub(super) transfer_lease_changed: Notify,
    /// Secrets agents asked the person for, and their one-use refs (`secrets.rs`).
    pub(super) secrets: secrets::Secrets,
    pub(super) mcp_connects: mcp_connect::McpConnects,
    /// Sub-session starts waiting on a folder's trust card, and Not nows (`trust_wait.rs`).
    pub(super) trust_waits: trust_wait::Waits,
    /// Messages `send --no-wait` handed over, and forwarded prompts waiting for a peer's
    /// acceptance (`outbox.rs`).
    pub(crate) outbox: outbox::Outbox,
    /// Per host, how long no ssh carry goes to it after one was not taken
    /// (`server/ssh_carry.rs`): this daemon's alone, so two hubs (or two tests) never share it.
    pub(crate) ssh_carry_cooldown: std::sync::Mutex<crate::server::ssh_carry::Cooldown>,
    /// The team hub a send to a name nobody here resolves goes through, while a mesh relay
    /// runs (`server/mesh_relay.rs`); unset without one, or in a hub a test builds. A sign-out's
    /// leave clears it and a later enroll sets the new hub's (`server/machine_enroll.rs`).
    pub mesh: crate::mesh::MeshSlot,
    /// The running mesh relay's loops: the one the daemon started, or one a sign-in enroll
    /// started live (`server/machine_enroll.rs`). Stopped at shutdown.
    pub mesh_relay: tokio::sync::Mutex<Option<crate::server::mesh_relay::MeshRelay>>,
    /// Held across every change of this daemon's join (`server/machine_enroll.rs`): the daemon
    /// start's leave and relay start, a sign-in's enroll, a sign-out's leave, and shutdown. Each
    /// reads the join's state on disk once it holds it, so none acts on what another changed.
    pub join_transition: Arc<tokio::sync::Mutex<()>>,
    /// The daemon start's join task (a leave the last run did not finish, then the relay), while
    /// it may run: shutdown ends it before it stops the relay.
    pub join_start: std::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
    pub(crate) watches: watches::Watches,
    pub(crate) peer_accepts: outbox::PeerAccepts,
    /// A peer's live asks for sessions it has not listed yet (`held_asks.rs`).
    pub(crate) held_peer_asks: held_asks::HeldAsks,
    /// Agent message pairs and their runaway guard (`agent_pairs.rs`).
    pub(super) agent_pairs: agent_pairs::AgentPairs,
    /// Pairing tickets and paired machines (`crate::pairing`).
    pub pairing: Arc<crate::pairing::Pairing>,
    /// The optional embedded tailnet node. It is initialized lazily so the
    /// default daemon never starts or links a node without an explicit request.
    #[cfg(all(unix, feature = "tailnet"))]
    pub(crate) tailnet_controller: std::sync::OnceLock<Arc<crate::tailnet::embedded::Controller>>,
    /// Where each workspace runs now, for the stable tailnet node's front
    /// (`tailnet/stable_front.rs`), set by `_acpmux/tailnet/placement`.
    pub(crate) tailnet_placements: Arc<cmux_tailnet_front::PlacementTable>,
    /// Brief identities shared by dispatch, report and MCP clients.
    pub(crate) briefs: dispatch::Briefs,
    /// Every Claude workflow of this daemon's chats (`workflow_index.rs`).
    pub(crate) workflow_index: workflow_index::WorkflowIndex,
    /// Which predicted next prompts reach the person (`suggestion_gate.rs`): this daemon's own
    /// chats and the peers' chats it relays to its person.
    pub(crate) suggestion_gate: StdMutex<crate::suggestion_gate::Gate>,
    /// The last few `_acpmux/events` replies, kept while their chat's log is unchanged
    /// (`page_replies.rs`).
    pub(crate) page_replies: page_replies::PageReplies,
}

/// What a cached closed row was built after: every row's changes (`Events::summary_generation`),
/// its own session's (`Session::summary_gen`), and its open children's (`subsessions`). A change
/// of one session's row moves its own count only, so the other closed rows keep their bytes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct SummaryStamp {
    all: u64,
    own: u64,
    children: u64,
}

impl Hub {
    pub fn run_id(&self) -> String {
        self.person.instance().to_owned()
    }

    /// Drive lifecycle timers from `clock` (tests pass a `ManualClock`).
    pub fn set_clock(&self, clock: Arc<dyn crate::clock::Clock>) {
        *self.clock.lock().unwrap() = clock;
        self.idle_wake.notify_one();
    }

    /// How long a start that waits on its harness (the person's, or one with `waitStart`) lets
    /// the harness do no work before it ends the start (`start_watch.rs`; tests shorten it).
    pub fn set_start_hung(&self, hung: std::time::Duration) {
        *self.start_hung.lock().unwrap_or_else(|e| e.into_inner()) = hung;
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

    /// A background reader of [`Hub::subscribe`] fell `missed` events behind (rework stage 3,
    /// E4): counted, logged, and the chats it may have missed a turn's end of, the idle ones, to
    /// look at again.
    pub(super) fn lagged_reader(&self, reader: &'static str, missed: u64) -> Vec<Arc<Session>> {
        READER_LAGS.fetch_add(missed, Ordering::Relaxed);
        tracing::warn!(
            reader,
            missed,
            "a background event reader fell behind: it reads its chats again"
        );
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        sessions.values().filter(|s| s.turn().is_none()).cloned().collect()
    }

    /// Tests only: `session`'s record of `kind`, heard as the hub's own event.
    #[cfg(test)]
    pub(crate) fn emit_for_test(&self, session: &str, kind: &str, msg: Value) {
        let record = EventRecord {
            seq: 1,
            at: 0,
            dir: "mux".into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        };
        let _ = self.events.send(HubEvent {
            session_id: session.into(),
            record: Arc::new(record),
            remote: None,
            update_line: Default::default(),
            row: Default::default(),
            list_seq: 0,
            peer_batch: false,
        });
    }

    pub fn subscribe(&self) -> broadcast::Receiver<HubEvent> {
        self.events.subscribe()
    }

    /// Which connections each event wakes (`server/interest.rs`): a connection's fan-out reads
    /// its own inbox, not [`Hub::subscribe`].
    pub(crate) fn fanout_router(&self) -> &Arc<crate::server::interest::Router> {
        self.events.router()
    }

    pub fn mailbox(&self) -> &Mailbox {
        &self.mailbox
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
        // The line first, then the metadata (R-DURABILITY S3b, as `set_tags_answered`).
        self.append(session, "mux", "rules", json!({"rules": rules}));
        self.save_meta_answered(session)
    }

    /// Store the unsent composer text without adding it to the transcript.
    /// Whitespace-only input clears the draft while preserving whitespace in a
    /// non-empty draft exactly as typed.
    pub fn set_composer_draft(
        &self,
        session: &Session,
        text: &str,
    ) -> Result<Option<String>, RpcError> {
        if session.moving().is_some() {
            return Err(RpcError::invalid_params(queue::moving_error(session).message));
        }
        let draft = (!text.trim().is_empty()).then(|| text.to_owned());
        {
            let mut meta = session.meta.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            meta.composer_draft = draft.clone();
            meta.updated_at = now_ms();
        }
        // It dates the chat with no record: told before the next list read, and placed again in
        // the list's order (`list_order.rs`).
        self.events.row_changed(session);
        self.chat_activity_cache.note(
            &session.id,
            "composer_draft",
            session.status() == SessionStatus::Closed,
        );
        // Answered once the draft is saved: "the one durable shared draft". A kept change: saved
        // when written, synced with the next acked change or within a second (`meta_save.rs`).
        self.save_meta_kept(session)?;
        // One edit of the person's synced draft (`hub/synced.rs`); the value already there (a
        // remote winner applied through here) is none.
        self.synced_record(
            synced::draft_key(&session.id),
            draft.clone().map_or(serde_json::Value::Null, serde_json::Value::String),
        );
        Ok(draft)
    }

    /// Lists the temporary folders of sessions this daemon no longer has
    /// (`agent/session_tmp.rs`) and removes them on a thread of their own.
    /// The daemon calls it after metadata loads and before startup releases spawns.
    #[cfg(unix)]
    pub fn sweep_session_tmp(&self) {
        let mut metas: Vec<(String, SessionStatus)> = self
            .sessions()
            .iter()
            .map(|session| session.read_meta(|m| (m.id.clone(), m.status)))
            .collect();
        // An evicted chat keeps its folder as it did in memory (`evict.rs`).
        metas.extend(self.evicted.rows().iter().map(|row| (row.keys.id.clone(), row.keys.status)));
        let known: std::collections::HashSet<&str> =
            metas.iter().map(|(id, _)| id.as_str()).collect();
        let closed: std::collections::HashSet<&str> = metas
            .iter()
            .filter(|(_, status)| *status == SessionStatus::Closed)
            .map(|(id, _)| id.as_str())
            .collect();
        // A session whose record did not list still has its folder.
        let stored = |id: &str| {
            known.contains(id) || self.store.session_path(id).is_some_and(|d| d.exists())
        };
        let stale = crate::agent::session_tmp::stale_for_daemon(&stored, &|id| closed.contains(id));
        if stale.is_empty() {
            return;
        }
        tracing::info!(count = stale.len(), "removing temporary folders of forgotten sessions");
        std::thread::spawn(move || crate::agent::session_tmp::remove_all(&stale));
    }
}

pub(crate) use crate::protocol::merge_mux_meta;

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
