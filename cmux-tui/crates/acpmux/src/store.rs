//! Persistence tiers for session metadata and the event log.
//!
//! `Local` writes `sessions/<id>/session.json` and append-only
//! `events/NNNNNN.ndjson` segments. `Memory` keeps the same data in RAM.
//! Both expose the same API so the hub does not care which is active.

use crate::config::{StoreConfig, StoreMode, write_atomic};
use crate::goal::GoalState;
use crate::no_panic::LockExt;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

mod compact;
pub use compact::{CompactMode, Compaction, Staged};
mod deferred;
pub use deferred::{Deferral, HeldBack, Keep, held_file};
mod cold;
pub(crate) mod cold_segments;
pub use cold::{COLD_FILE, ColdStats, RehydrateHook, StagedCold};
pub use cold_segments::{ColdMoved, ColdWarmed, SealHook, StagedColdSegments};
mod superseded;
pub use superseded::{Superseded, starts_prompt};
mod kind_heads;
mod kind_index;
mod sealed_segments;
mod segment_starts;
#[cfg(test)]
pub(crate) use kind_heads::KEYED_KINDS;
mod segment_table;
pub use kind_heads::KindHead;
pub use kind_index::{DIR as KIND_INDEX_DIR, INDEXED_KINDS, carry_copy as carry_kind_index};
use segment_table::SegmentList;
mod fork_view;
pub use fork_view::{
    ForkView, HISTORY_KINDS, HistoryFence, HistoryRef, HistoryWriter, fence_history,
    folder_to_replace,
};
mod log_bytes;
pub use log_bytes::{
    LogChunk, LogFilter, LogMark, LogMarks, LogPart, STAMP as LOG_STAMP, line_seq as log_line_seq,
};
mod meta_parts;
pub use meta_parts::PARTS_FILE;
pub(crate) use meta_parts::to_writer_without_parts;
mod shared_value;
mod text_index;
pub use shared_value::{SharedRows, SharedText, SharedValue};

/// The plan the person last approved in a chat (`hub/plan_build.rs` `approved_plan`): Claude
/// Code's ExitPlanMode, or a Grok, Cursor or Gemini plan approval, answered with an allow. The
/// pane keeps it in sight while the agent builds it (Leo's feature map, 2026-11-23: "plan pane
/// that stays during the build"); a newer approval replaces it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ApprovedPlan {
    /// The plan as approved, Markdown: the person's edit when they made one.
    pub markdown: String,
    /// The person edited the plan before approving it.
    pub edited: bool,
    /// The plan approval it answered.
    pub permission_id: String,
    /// The chat's turn count when it was approved.
    pub turn: u64,
    /// When it was approved, Unix ms.
    pub at: u64,
}

/// One line in the session event log.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct EventRecord {
    pub seq: u64,
    /// Unix milliseconds.
    pub at: u64,
    /// `in` = agent to acpmux, `out` = acpmux to agent, `mux` = acpmux internal.
    pub dir: String,
    /// JSON-RPC method, `sessionUpdate` value, or an acpmux kind such as `status`.
    pub kind: String,
    /// Raw JSON-RPC message, or the acpmux payload.
    pub msg: Value,
    /// The agent host entry this record logs (`hostSeq`), so a controller
    /// that adopts the host resumes after it (agent hosts, durable sessions).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_seq: Option<u64>,
}

/// Where a read of a log's newest records starts ([`Store::newest_window`]).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NewestWindow {
    /// The seq after which the newest records lie: 0 when the log holds no more than asked for,
    /// else the seq of the newest record left out, so records `1..=after` are the older ones.
    pub after: u64,
    /// The newest record's seq (0 for an empty log): the count of records the chat has logged.
    pub newest: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Copy)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    /// No child process. Prompts respawn and load the agent session.
    Idle,
    /// Child alive, no turn running.
    Ready,
    /// A prompt turn is running.
    Running,
    /// Waiting for a permission answer.
    Waiting,
    /// Child process died unexpectedly.
    Disconnected,
    /// Closed by the user. Log kept.
    Closed,
}

impl SessionStatus {
    /// The status as a session list's `status` says it (its `Display`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Ready => "ready",
            Self::Running => "running",
            Self::Waiting => "waiting",
            Self::Disconnected => "disconnected",
            Self::Closed => "closed",
        }
    }
}

impl std::fmt::Display for SessionStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Why a chat waits on the person: every [`SessionStatus::Waiting`] has one, written with it
/// (`Hub::set_waiting`, the only way into Waiting), so a client always says what it waits for (the
/// summary's `waitingOn`). Never a bare Waiting (goal cloud-chat-waiting-always-explained).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaitReason {
    /// An agent's question (AskUserQuestion, Codex user input), carried as a permission request.
    Question,
    /// A tool's permission: only the person allows it (`hub/person.rs`).
    Permission,
    /// A card asking to connect an MCP server (`hub/mcp_connect.rs`).
    McpConnect,
    /// A private card asking for a secret's value (`hub/secrets.rs`).
    Secret,
    /// A private card asking for the password to run one command as root (`hub/elevation.rs`).
    Elevation,
}

impl WaitReason {
    /// The summary's `waitingOn` for it.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Question => "question",
            Self::Permission => "permission",
            Self::McpConnect => "mcp_connect",
            Self::Secret => "secret",
            Self::Elevation => "elevation",
        }
    }
}

/// What a watched chat follows (`hub/watch.rs`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Watching {
    /// `claude` or `codex`.
    pub family: String,
    /// The harness's transcript, found in its own store (`adopt.rs`).
    pub file: PathBuf,
    /// How far into `file` acpmux has read, in bytes.
    #[serde(default)]
    pub offset: u64,
    /// The rollout is a current Codex one, whose message items are its turns (`adopt_replay.rs`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub codex_items: bool,
    /// The turn shown as open: the last prompt, until the transcript ends it, the next prompt
    /// comes, or Take Over settles it. Kept so a daemon restart goes on with it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open: Option<WatchedTurn>,
    /// The terminal the chat handed its conversation to (`acpmux resume-here`,
    /// `hub/release_to_watch.rs`): the chat's prompts go into that terminal's harness
    /// (`hub/bridge.rs`) while it runs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal: Option<TerminalDriver>,
    /// Prompts the terminal took while a turn ran (Claude Code's `queue-operation` enqueue), shown
    /// at once, oldest first, so the line that runs each later does not show it again (`watch.rs`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub queued: Vec<String>,
    /// Prompts the terminal took while a turn ran that did not show at once (past the cap, or
    /// text a delivery may have): one shows as typed when the turn takes it in (`watch.rs`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unshown: Vec<String>,
}

/// The process a chat handed its conversation to (`Watching::terminal`): `acpmux resume-here`,
/// which becomes the harness (`exec`, same pid).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalDriver {
    pub pid: u32,
    /// When `pid` started (ms since the epoch), so a later process under a reused pid is not it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started: Option<u64>,
    /// The harness's store the conversation is in (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
    pub store: PathBuf,
    /// The cmux terminal that process runs in, as the environment its exec was given names it
    /// (read from the kernel, `hub/terminal_input.rs` `of_process`): the chat's Stop,
    /// and its prompts while the harness has no inbox, reach the harness as keys typed there
    /// (`hub/terminal_input.rs`). None outside a cmux terminal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<TerminalInput>,
}

/// A cmux terminal's input (`TerminalDriver::input`): its session daemon's socket
/// (`CMUX_TUI_SOCKET`) and the terminal's id there (`CMUX_TUI_TERMINAL_ID`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalInput {
    pub socket: PathBuf,
    pub terminal_id: String,
}

/// A watched chat's open turn (`Watching::open`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchedTurn {
    pub turn_id: String,
    pub prompt_id: String,
    pub turn_seq: u64,
    /// An answer was shown, so the next piece is set apart from it.
    #[serde(default)]
    pub answered: bool,
}

/// Daemon-validated edit boundary and durable fork request identity.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ForkBefore {
    pub prompt_id: String,
    pub request_id: String,
    pub prompt_seq: u64,
    pub through_seq: Option<u64>,
    pub ready: bool,
}

/// Reserved before creating a child; retained even if the child is purged. A plain fork's
/// (`session/fork` with a `requestId` and no boundary, `hub/fork_request.rs`) has no `prompt_id`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ForkRequest {
    #[serde(default)]
    pub prompt_id: String,
    pub child_id: String,
}

/// How a fork's agent gets its chat's conversation at its first start, kept until that start (or
/// its first prompt) took it, so a daemon restart in between resumes it (`hub/fork_start.rs`):
/// it was in memory only, and a fork restarted before its agent started began a fresh
/// conversation under the copied turns (cmux#50096).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ForkStart {
    /// The fork is whole: its history and `forked` record are in. A fork a restart cut off
    /// before then is closed at the next start, never shown as a copy.
    #[serde(default)]
    pub made: bool,
    /// Claude's `--resume <this> --fork-session`: the chat's agent session it forks from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_from: Option<String>,
    /// Its first prompt carries the chat's transcript (a fork onto another harness, or one its
    /// agent could not fork mid-turn), under `note` when set.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub rehydrate: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

impl ForkStart {
    /// Nothing left to keep: a whole fork whose agent took its conversation.
    pub fn settled(&self) -> bool {
        self.made && self.resume_from.is_none() && !self.rehydrate
    }
}

/// A person's return to a chat that kept working (`hub/seen.rs`): the log seq they had seen when
/// they left, and how many turns ended while nobody showed it.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, schemars::JsonSchema)]
pub struct LastReturn {
    pub since: u64,
    pub turns: u64,
}

/// The chat's current away recap (`hub/away_recap.rs`): the record that shows it, the facts it
/// names, the turn count it covers and whether the person dismissed it.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AwayRecap {
    /// Seq of its `recap` record.
    pub seq: u64,
    /// Hash of `facts`, sent on the record so a client can tell one recap's facts from another's.
    pub digest: String,
    /// What it names (`away_recap::facts`): a recap whose facts are all here says nothing new.
    pub facts: Vec<String>,
    /// The turn count it covers; the next recap waits `TURNS_BETWEEN` more.
    pub turns: u64,
    /// The person pressed its ×: a recap with no new fact stays unwritten.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub dismissed: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ClaudeTokenRecovery {
    MachineLogin,
    // A saved setup-token rejection, including metadata written before chat-scoped recovery.
    #[serde(rename = "rejected")]
    LegacyRejected,
}

/// A chat's model switch for a sustained overload (`SessionMeta::capacity_fallback`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CapacityFallback {
    /// The chat's own model, as it named it.
    pub from: String,
    /// The smaller model it runs meanwhile.
    pub to: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionMeta {
    pub schema: String,
    pub id: String,
    pub name: String,
    /// Explicit spoken handle. Older and unnamed sessions derive one from the same stable id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<String>,
    /// The icon it set for itself or a person gave it (`session_icon.rs`): what every surface
    /// draws for it in place of its harness mark. None draws the harness mark.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<crate::session_icon::SessionIcon>,
    /// Someone gave `name` (at the start, a fork's or a rename), not the daemon's `HARNESS-N`
    /// default (`hub/new_request.rs` `unique_name_among`). False in a log from before it was kept.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub name_given: bool,
    /// The names it had before its renames, oldest first (`hub/former_names.rs`): each still
    /// names it wherever no session has it as its current name, so a message sent to an old
    /// name still arrives. At most `former_names::KEPT`; no other session keeps the same one.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub former_names: Vec<String>,
    /// The sessions it took over (`acpmux succeed`), as `HOST/NAME` (or a bare NAME on this
    /// host), each with the former names its predecessor listed. They go out in its heartbeat
    /// row's `formerNames`, so the hub sends a message for a dead predecessor here
    /// (plans/cmux-next/message-delivery-successors.md).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub succeeds: Vec<String>,
    /// The role addresses (`goal:SLUG`, `area:NAME`, `topic:NAME`) it claimed (`acpmux role
    /// claim`): a send to the address reaches it, here and through the hub.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub roles: Vec<crate::mesh::RoleClaim>,
    /// `agent` in a chat stored before the agent-to-harness rename (e857185a58).
    #[serde(alias = "agent")]
    pub harness: String,
    /// `agentArgv` (or `agent_argv`) in a chat stored before that rename.
    #[serde(default, alias = "agentArgv", alias = "agent_argv")]
    pub harness_argv: Vec<String>,
    /// The argv its agent last started with: a config or preset reload since creation can change
    /// it (`harness_argv` is the creation's). None before any start (#23322, review 36).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spawn_argv: Option<Vec<String>>,
    /// The owner's selected Cloud model connection ID. The credential stays in memory.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential_connection: Option<String>,
    /// The owner withdrew the delivered credential. Until redelivery, no new turn may use it,
    /// even if an adopted host still carries it while existing work finishes.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) credential_withdrawn: bool,
    /// Model selected at launch with the delivered connection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) claude_token_recovery: Option<ClaudeTokenRecovery>,
    /// Whether a host still needs to restart on the machine login. Older recovery records
    /// omit this field, so a recovered chat keeps the restart pending until a fresh launch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) claude_login_restart_pending: Option<bool>,
    /// `HarnessProfile::launch_digest` of the profile its agent last started from: a profile
    /// reload that changes it respawns the agent at its turn end, on the same conversation
    /// (`hub/profile_respawn.rs`). Kept on disk, so an agent host the next daemon adopts is
    /// judged too. None before any start, or for a start by an older build.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch_digest: Option<String>,
    /// Model family of the profile at creation (`claude`, `codex`, ...).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
    /// Preset the session was created from (`-p NAME`); its env is re-applied on every respawn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preset: Option<String>,
    /// Model requested for a harness whose argv or env carries `${model}`:
    /// applied at spawn, not through set_model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_request: Option<String>,
    /// The effort a new Claude Code chat starts on, given at spawn as `--effort` instead of a
    /// `session/set_config_option` after `initialize` (`hub/lifecycle.rs`). A start before the
    /// harness reported its options reads it (`model_options::spawn_effort`); its reported
    /// effort wins after that.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort_request: Option<String>,
    /// The chat runs a smaller model because its own stayed overloaded
    /// (`hub/auto_resume/capacity_failover.rs`): `from` comes back once a turn on `to` ends well.
    /// Saved with the meta, so a daemon restart still puts it back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capacity_fallback: Option<CapacityFallback>,
    pub cwd: PathBuf,
    /// Folders the chat sees beside `cwd` (ACP `session/new` `additionalDirectories`, its
    /// Sources): every start of its harness gets them (`hub/additional_dirs.rs`). Absolute,
    /// canonical, each once, never `cwd` itself.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub additional_directories: Vec<PathBuf>,
    /// When the chat's agent may stop (`_meta.acpmux.stopCondition`, `hub/stop_condition.rs`):
    /// every start of its Claude Code gets it as a prompt Stop hook, so a would-be stop is
    /// checked against it and the agent goes on until it holds; a Codex (codex-acp) chat gets it
    /// once as Codex's own goal. Kept only for those two; None for none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_condition: Option<String>,
    /// A Codex chat's stop condition was written to Codex as its goal (`stop_condition.rs`):
    /// Codex keeps the goal in its thread, so it is set once.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub stop_condition_sent: bool,
    /// Read-only work in a folder the person chose not to trust (`_meta.acpmux.restricted`,
    /// `hub/restricted.rs`): every start of its Claude Code skips the folder's settings and MCP
    /// servers, and it keeps the review policy.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub restricted: bool,
    #[serde(default)]
    pub agent_session_id: Option<String>,
    /// Claude Code can replace its native session id when a chat is forked. Keep ids this
    /// daemon previously recorded for the same chat so transcript reads can follow that history
    /// without scanning another session's store. This is daemon-owned state; it is never inferred
    /// from transcript contents.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub previous_agent_session_ids: Vec<String>,
    /// Every native id this chat had before the current one, whatever its family, oldest first
    /// and bounded (`RETIRED_AGENT_SESSION_IDS`). Not transcript authority: a Codex chat's
    /// earlier native roots, which its older records still name, so a client folding them
    /// (and the tap's `SubagentTree`) never reads an earlier root as one of its subagents.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub retired_agent_session_ids: Vec<String>,
    /// Proven family of the current native id. Older/imported metadata is unknown and cannot
    /// authorize historical Claude reads when that id is retired.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_session_family: Option<String>,
    pub status: SessionStatus,
    pub created_at: u64,
    pub updated_at: u64,
    #[serde(default)]
    pub last_seq: u64,
    /// The seq of the newest record `hub/paging.rs` `is_transcript` keeps (the summary's
    /// `transcriptSeq`). 0 from an older daemon's `session.json`: no client compares across
    /// that, since one bump past the value it read is all a client asks of it.
    #[serde(default)]
    pub transcript_seq: u64,
    /// Where the records this machine's own recovery wrote at the end of the journal begin (the
    /// seq before the first of them, `hub/restore_writer.rs` `is_recovery`), while they end it:
    /// any other record appended after them clears it, as does a restore that takes them back.
    /// The summary's `recoveredAfter`, so the owner restores from there a copy that ends at or
    /// before `last_seq` (review of #37284 at 8b5f3063, F2). Saved with the meta, so a machine
    /// that restarts again before its owner reconnects still says it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovered_after: Option<u64>,
    #[serde(default)]
    pub parent_id: Option<String>,
    #[serde(default)]
    pub fork_seq: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_before: Option<ForkBefore>,
    /// A fork's history, read from the chat it came from until written into its own log
    /// (`store/fork_view.rs`). None: its log holds all it shows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history_from: Option<HistoryRef>,
    /// The seq through which this log holds a chat's history under that chat's own seqs, so it
    /// skips seqs there: a fork by reference whose history was written into it
    /// (`store/fork_view.rs` `materialize`, `transfer.rs` `export`). Edit and resend's proof of
    /// the log allows those skips (`hub/fork_before.rs`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history_kept_through: Option<u64>,
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub fork_requests: std::collections::BTreeMap<String, ForkRequest>,
    /// A fork whose agent has not taken the chat's conversation yet ([`ForkStart`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_start: Option<ForkStart>,
    /// Whether this daemon verified the local parent link when the fork was made. Imported
    /// metadata is explicitly unverified, even when an old bundle happened to carry parent ids.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_parent_verified: Option<bool>,
    #[serde(default)]
    pub agent_info: Option<Value>,
    #[serde(default)]
    pub agent_capabilities: Option<Value>,
    /// The agent took prompts mid-turn at its last start (`_meta.steering.supported`). Kept so a
    /// session the daemon adopts after a restart (`hub/hosts.rs`), which never initializes its
    /// agent again, still steers instead of stopping the turn for every prompt sent now.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub steering: bool,
    /// Its agent was launched to write question previews as HTML (`hub/questions.rs`
    /// `PreviewFormat`), kept for the same reason: an adopted agent keeps its launch's format.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub html_previews: bool,
    #[serde(default)]
    pub modes: Option<Value>,
    /// The mode cmux itself last asked the harness for (its start default, the person's pick, a
    /// policy's mode), never one the harness reported on its own: a chat in full access lends its
    /// folder's trust only by this (`hub/trust_wait.rs`), so a harness that claims a mode gets none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode_set_by_cmux: Option<String>,
    #[serde(default)]
    pub config_options: Option<SharedValue>,
    #[serde(default)]
    pub models: Option<Value>,
    #[serde(default)]
    pub permission_policy: Option<String>,
    /// Who set `permission_policy` (`hub/policy_source.rs`); None from an older daemon.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_source: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    /// Who set `title` (`hub/titles.rs`): `prompt` (its first prompt's line),
    /// `harness` (its own `session_info_update`), `asked` (a generated title
    /// is on its way or came back empty; a later turn asks again, `hub/titles.rs`), `generated`,
    /// `adopted`, `named` (renamed before a title settled: none is generated) or `launched`
    /// (started under a name, not yet prompted).
    /// None: a chat titled before acpmux generated titles; kept as is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title_source: Option<String>,
    /// The first prompt a `prompt` title came from, until a title is asked for.
    #[serde(skip)]
    pub title_prompt: Option<String>,
    /// A title request is running (`hub/titles.rs`); this daemon run only.
    #[serde(skip)]
    pub title_asking: bool,
    /// Title requests that came back with no title in this daemon run (`hub/titles.rs`).
    #[serde(skip)]
    pub title_failures: u8,
    /// The first prompt was too thin to title reliably; permit one refresh after its turn.
    /// Ephemeral so this does not change the stored session format.
    #[serde(skip)]
    pub title_thin: bool,
    #[serde(default)]
    pub last_prompt: Option<String>,
    #[serde(default)]
    pub preview: Option<String>,
    #[serde(default)]
    pub event_count: u64,
    #[serde(default)]
    pub turn_count: u64,
    #[serde(default)]
    pub usage: Option<Value>,
    /// Claude Code's newest /context breakdown (`claude_stdio::context_breakdown`),
    /// sent after each turn; none from any other harness.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_breakdown: Option<Value>,
    /// Cmux-owned additions captured when this chat was created. Older chats have none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cmux_context: Option<Vec<crate::context_inventory::ContextPart>>,
    /// A preset override selected at creation; later setting edits affect only new chats.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cmux_preset_prompt: Option<String>,
    /// True only after a harness writer accepts the captured first-turn context.
    #[serde(default)]
    pub cmux_context_delivered: bool,
    /// True once cmux's rules on a system-level channel went into the transcript instead,
    /// because a start did not carry them (`context_inventory::append_owed_rules`): once.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cmux_rules_in_transcript: bool,
    /// The seq of the turn whose message carried them (`turn_started`): a fork cut before it
    /// keeps a transcript without them (`context_inventory::fork_keeps_rules`). None for rules
    /// recorded before this was kept.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cmux_rules_seq: Option<u64>,
    /// The account's plan usage limits (`claude_stdio::usage_limits`), newest per window, from
    /// Claude Code's `rate_limit_event`; none from any other harness.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage_limits: Option<Value>,
    /// The agent's newest `available_commands_update` (its slash commands), so
    /// opening a chat names them without reading its log back to the start,
    /// where an agent lists them once (perf100). Kept in `session.parts.json`, not
    /// `session.json` (`store/meta_parts.rs`): every other metadata save leaves it unwritten.
    #[serde(default, skip_serializing_if = "meta_parts::skip_commands")]
    pub available_commands: Option<SharedValue>,
    /// Last goal reported by the harness. Codex owns its persistence and continuation.
    #[serde(
        default,
        deserialize_with = "crate::goal::deserialize_option",
        skip_serializing_if = "Option::is_none"
    )]
    pub goal: Option<GoalState>,
    /// Per-session permission rules layered above the policy (see hub/rules.rs).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_rules: Option<Value>,
    /// Orchestrator labels: key -> (value, expiry unix ms).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub tags: BTreeMap<String, Tag>,
    /// A turn ended while no client was attached.
    #[serde(default)]
    pub unread: bool,
    /// The log seq the person had seen when they last stopped showing the chat (`hub/seen.rs`):
    /// where "New since you looked" goes when they come back. Set once per hide, never per
    /// record; None until a person has shown and left it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen_seq: Option<u64>,
    /// Turns that ended unseen since the person last showed the chat (the sidebar's count).
    #[serde(default, skip_serializing_if = "is_zero")]
    pub unread_turns: u64,
    /// The person's return to the chat after turns ended unseen, kept while they stay on it: a
    /// client that opens it then draws "New since you looked" at `since`, however its attach and
    /// its list read race. Cleared when the last client showing it stops.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_return: Option<LastReturn>,
    /// The chat's one "While you were away" recap (`hub/away_recap.rs`): a newer recap replaces it,
    /// one that says nothing new is never written, and its dismissal stays across restarts.
    /// None until the first recap.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub away_recap: Option<AwayRecap>,
    /// The plan the person last approved (`hub/plan_build.rs` `approved_plan`); None until one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_plan: Option<ApprovedPlan>,
    /// Each person's seen cursor (`hub/seen.rs` `read_through`): the newest log seq they had on
    /// screen while they attended the chat, keyed by person id (`_meta.acpmux.author` id,
    /// [`crate::hub::seen::OWNER_READER`] for the owner). Only `_acpmux/seen` moves it forward; a
    /// restart, update, reconnect, attach or `_acpmux/view` never does. Rows after it by an agent
    /// or another person are the person's unseen rows (the pane's Jump up).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub read_through: BTreeMap<String, u64>,
    /// The Claude conversation acpmux started with a fresh id has not
    /// finished a turn, so Claude may never have stored it (a launcher that
    /// died before the prompt reached Claude stores nothing). A respawn (a
    /// fallback profile, a dead process, a daemon restart) then starts a
    /// fresh conversation instead of `--resume`, which would fail the turn
    /// with "No conversation found with session ID".
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub claude_unstored: bool,
    /// The agent of the unstored conversation (`claude_unstored`) did work in a turn that did
    /// not end Ok: it said something, thought or called a tool (`Hub::unstored_turn_worked`). Only
    /// such a conversation is kept awake (`idle.rs`) and refused by `stop --if-idle`; one whose
    /// turns only ever got agent errors (a 503, an exhausted account) wakes as the same fresh
    /// conversation with its transcript restored either way (cmux#48917).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub claude_unstored_work: bool,
    /// Its creator asked every start of its agent to wait on the harness rather than a wall
    /// clock (`_meta.acpmux.waitStart`, `Session::wait_start`; the Chief's own sessions). Kept on
    /// disk, so a wake after hibernation or a daemon restart waits as its first start did: on
    /// 2026-11-04 a kept Chief session that woke after a restart died at the 90 s deadline again.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub wait_start: bool,
    /// Its creator purges it right after its work (`_meta.acpmux.throwaway`, the Chief
    /// compactor's nodes): its prompts'
    /// `user_message` keeps no long body (`hub/ephemeral.rs`), and a retry or restart never runs
    /// such a prompt again. Kept on disk with the rest of its meta.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub throwaway: bool,
    /// The key its creator sent with its `session/new` (`_meta.acpmux.createKey`,
    /// `hub/create_key.rs`): a create sent again with that key, after a daemon restart closed
    /// the connection before the reply, answers with this session instead of making another.
    /// Kept on disk, so the next daemon finds it too.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub create_key: Option<String>,
    /// The journal seq the agent's own session ends at, when the journal went past it without
    /// the agent: records its owner kept went back in (`hub/journal_restore.rs`, a session moved
    /// to a fresh machine from an older disk). The agent resumes its own older session, so its
    /// next prompt carries the turns after this seq (`hub/transcript.rs` `missed_turns`), and the
    /// mark goes. Saved with the meta: the agent's file and this mark are on one disk.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_behind_seq: Option<u64>,
    /// When (Unix ms) the idle exit hibernated its agent, 0 when no start woke it since
    /// (`hub/idle.rs`): after a restart, opening it wakes it and its wake draws no row, as
    /// before the restart, and the wake's log says how long it slept.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub hibernated_ms: u64,
    /// Who closed the chat last, why, and whether its work was done (`close_why.rs`): kept on
    /// every close, so a closed row (`close`) says what closed it after its log is compacted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub close: Option<crate::close_why::CloseRecord>,
    /// What the idle census knew of its hosted harness's MCP servers, for the next daemon that
    /// adopts that host (`hub/idle_census.rs`, `StoredLaunch`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_launch: Option<crate::sidecar_census::StoredLaunch>,
    /// The level (`agent_host::HOST_LEVEL`) at which this daemon's build started the chat's live
    /// host, by that host's incarnation (`hub/host_level.rs` `note_start_level`): what the start
    /// asked of the agent (whether it suggests next prompts) is decided there, by the daemon, not
    /// by the host's binary. None: an older daemon started it, or none yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_level: Option<StartLevel>,
    /// Where the chat went when it moved to another daemon (`hub/transfer_out.rs` commit:
    /// `{host?, sessionId, cwd?, branch?, commit?, socket?}`). Set once, never cleared here: a
    /// moved chat takes no prompt and never starts its agent on this daemon again (one writer),
    /// and `resolve` follows it there (`hub/locate.rs`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub moved_to: Option<Value>,
    /// The profile whose Claude store (its CLAUDE_CONFIG_DIR) holds the current Claude
    /// conversation: the one that started or forked it. A respawn on another profile (a failover)
    /// resumes only when that profile's store has the conversation, else starts fresh (E1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_profile: Option<String>,
    /// Outcome of the last turn: {turnId, promptId, status, stopReason?,
    /// errorText?, errorSource?, endedAt}.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_turn: Option<Value>,
    /// An explicit login replaced this account's credentials after this turn. Kept separately
    /// from history so replay and daemon upgrades do not revive an obsolete auth refusal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth_change: Option<AuthChange>,
    /// Classified harness attempts, projected from turn results; old stores default empty.
    #[serde(default)]
    pub harness_failures: crate::session_liveness::HarnessFailures,
    /// Its harness's own command sandbox: first refusal and whether it refuses now
    /// (`hub/harness_sandbox.rs`); old stores default to none.
    #[serde(default, skip_serializing_if = "crate::session_liveness::HarnessSandbox::is_none")]
    pub harness_sandbox: crate::session_liveness::HarnessSandbox,
    /// Created over a remote-origin connection (the WebSocket listener):
    /// its harness never spawns with a preset's args or system prompt.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub remote_origin: bool,
    /// A remote-origin session whose caller asked for the VM boundary
    /// (`hub/vm_boundary.rs`): its Claude Code runs without the platform
    /// sandbox while this machine takes the boundary. A fork or sub-session
    /// keeps it, as it keeps `remote_origin`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub vm_boundary: bool,
    /// Per-session env (`session_env.rs`): allowlisted keys set by the unix
    /// socket on session/new or session/fork, applied over the preset env at
    /// every spawn. Never copied to a fork or a handoff.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub session_env: BTreeMap<String, String>,
    /// The cmux workspace this session works in, as the client named it
    /// (`_meta.acpmux.workspaceId` on session/new or session/fork; a fork
    /// keeps its parent's). It picks the computer use display in
    /// per-workspace display mode (`agent_displays.rs`). Lowercase UUID.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// The harness store of an adopted chat that no profile's store holds
    /// (a subrouter account home, a root the person added; cx-vx54). acpmux
    /// found it in its own chat index, never in a request; every spawn runs
    /// the harness on it (``SessionMeta::apply_chat_store``).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chat_store: Option<PathBuf>,
    /// The adopted conversation's recorded cwd when it was gone here (a chat
    /// moved from another machine) and the session runs in a remapped folder
    /// instead (`hub/adoption.rs` `remapped_cwd`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adopted_cwd: Option<PathBuf>,
    /// Chat store roots the harness's launch env named at its last spawn
    /// (ALL-CHATS-ON-DEVICE C3): absolute, existing folders only.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub harness_roots: Vec<HarnessRoot>,
    /// A Claude Code or Codex conversation this chat shows without running it (`hub/watch.rs`):
    /// cleared when a client takes it over.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watching: Option<Watching>,
    /// Unsent composer text owned by this acpmux session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer_draft: Option<String>,
    /// A person pinned the chat to the top of their list (`_acpmux/pin`), synced to their other
    /// replicas as `pin/<id>` (`hub/synced.rs`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub pinned: bool,
    /// The session took its mode from the person's approval of its preset
    /// (`hub/person.rs` (b)): the approved contents' digest. A spawn from
    /// other contents leaves that mode (`hub/start_gate/preset_bind.rs`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preset_mode_approval: Option<String>,
    /// The seqs of this chat's `user_message` records the person bookmarked (the pane's thread
    /// minimap; `hub/bookmarks.rs`). A fork renumbers its copies; a move keeps the log's seqs.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub bookmarks: BTreeSet<u64>,
    /// The tools the chat has (`hub/tools.rs`). Its rows are kept in `session.parts.json`, as
    /// `available_commands` is (`store/meta_parts.rs`).
    #[serde(
        default,
        skip_serializing_if = "meta_parts::skip_tools",
        serialize_with = "meta_parts::tools_without_rows"
    )]
    pub tools: ToolInventory,
    /// Initial branch (session/new or fork; git_state.rs), never updated: it joins the
    /// session to its PR (hq#1920). None outside a repository or on detached HEAD.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<String>,
    /// Initial git commit and linked-worktree recovery record.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_head: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<crate::git_state::WorktreeOrigin>,
    /// The sum of what this session's turns reported (`hub/turn_usage.rs`).
    /// `None` until a harness reports any; a fork starts its own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub totals: Option<TurnUsage>,
    /// The harness's own running cost after the last turn (Claude Code's
    /// `total_cost_usd`), which the next turn's cost is measured from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness_cost_usd: Option<f64>,
    /// What this session's tasks cost so far, model and compute (`hub/turn_cost.rs`): the
    /// `sessionCostUsd` its last priced turn carried. A fork starts its own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_cost_usd: Option<f64>,
    /// The pull requests this session's `gh pr create` calls printed (`hub/pull_requests.rs`),
    /// once each, oldest first. A fork starts with none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pull_requests: Vec<String>,
    /// When each of `pull_requests` was opened (Unix ms), by URL: the review queue's window
    /// counts from it (`hub/review_queue.rs`). One without a time (a meta written before this
    /// field) counts from the session's creation. A fork starts with none.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub pull_request_times: BTreeMap<String, u64>,
    /// The pull requests this session's `gh pr merge` and `gh pr close` calls merged or closed,
    /// by URL (`hub/pull_requests.rs`), whoever's session opened them: none
    /// waits on the person any more (`hub/review_queue.rs`). At most
    /// `pull_requests::MAX_PULL_REQUESTS`, the oldest dropped first. A fork starts with none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub closed_pull_requests: Vec<String>,
    /// The files this session's tool calls read and edited, by repository and path there
    /// (`touched_files.rs`, `hub/touched.rs`): at most `touched_files::MAX_FILES`, the least
    /// recently touched dropped first. A fork starts with none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub touched_files: Vec<crate::touched_files::TouchedFile>,
    /// The session whose agent started this one with its `start_session`
    /// tool (`hub/subsessions.rs`), with its short name and depth. `None`
    /// for a session a person or client started. Never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subsession: Option<SubsessionLink>,
    /// This session's own sub-session limits, set at runtime by the person
    /// or by an ancestor within its budget; unset fields inherit.
    #[serde(default, skip_serializing_if = "SubsessionLimits::is_empty")]
    pub subsession_limits: SubsessionLimits,
    /// Model races owned by this parent. Shared so per-token metadata copies stay constant-time.
    #[serde(default)]
    pub races: std::sync::Arc<Vec<crate::race_records::Race>>,
    /// The plan builds started from this chat's plan approvals (`hub/plan_build.rs`): set by
    /// acpmux alone, never from a request. Shared as `races` is.
    #[serde(default, skip_serializing_if = "crate::plan_build_records::no_records")]
    pub plan_builds: std::sync::Arc<Vec<crate::plan_build_records::PlanBuildRecord>>,
    /// The session whose agent started this one, recorded once at creation from
    /// the proven caller (`hub/lineage.rs`): `acpmux new` run in an agent's
    /// shell, or its `start_session` tool. `None` for a session a person or
    /// the app started (a root), and for one saved before lineage existed.
    /// Never copied to a fork or a moved-in session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lineage: Option<Lineage>,
    /// Who created it (`hub/created_by.rs`): the person, an agent session or a script,
    /// decided by the daemon at creation from the connection, never from a request
    /// value. `None` for a fork, a moved-in session, and one saved before this existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_by: Option<CreatedBy>,
    /// The log holds a subagent entry with a retry waiting or in flight that no later entry
    /// cleared yet (`hub/subagent_retry.rs`): the next load clears it, as the restart dropped
    /// that retry. Never copied to a fork.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub subagent_retry_open: bool,
    /// The session's own turn cap in ms (`hub/turn_cap.rs`): past it, other agents' messages
    /// wait for the next turn. 0 turns it off; `None` takes the default its settings give
    /// (`turn_cap::default_turn_cap_ms`). Set by the person only; never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_cap_ms: Option<u64>,
    /// The turn the turn cap's notice went into (`hub/turn_cap.rs`), kept so a turn a restart
    /// adopts gets no second one. Never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_cap_noticed: Option<String>,
    /// The session that first gave this chat work (`hub/inbox.rs`): the sender of the first
    /// message to it before it ran a turn. Its actions wake the idle chat, as its lineage
    /// parent's do. Never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delegator: Option<String>,
    /// The chat's log is in its cold archive (`hub/cold_archive.rs`, `store/cold.rs`): what the
    /// chat list shows of it without opening the archive. Cleared when the log comes back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cold: Option<ColdPreview>,
    /// The chat's Auto mode (`auto_session/record.rs`): whether it is on, whether this machine
    /// held the chat last, and changes kept aside. Never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_session: Option<crate::auto_session::record::AutoRecord>,
    /// The subagent of chat `parent_id` this fork holds the conversation of, not the chat's own
    /// (`hub/fork_subagent.rs`). The info view's `forkOf`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_of_subagent: Option<SubagentForkOf>,
    /// The chat's place mode as the place menu set it (`place_mode.rs`): its pin. It is part of
    /// the chat's metadata, so it moves with the chat. None: never picked, which reads as Auto
    /// once this machine's one-time migration pinned every older chat to it (`place_pin.rs`,
    /// `hub/place_migrate.rs`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub place_mode: Option<crate::place_mode::PlaceMode>,
}

/// A fork of a chat's subagent: the chat, and the subagent as its `_meta.acpmux.subagents`
/// names it (`SessionMeta::fork_of_subagent`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SubagentForkOf {
    pub session_id: String,
    pub subagent_id: String,
    /// Claude's agent id (its sidechain's), or the Codex child's thread id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// A cold-archived chat's preview, kept in `session.json` (`SessionMeta::cold`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ColdPreview {
    /// Unix milliseconds.
    pub archived_at: u64,
    /// The prompts and replies its log held.
    pub messages: u64,
    /// The log's bytes on the disk before, and the archive's.
    pub bytes_before: u64,
    pub bytes_after: u64,
    /// Its last few messages, oldest first, each cut short.
    #[serde(default)]
    pub last: Vec<PreviewMessage>,
}

/// One message of a [`ColdPreview`].
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PreviewMessage {
    /// `user`, `assistant` or `tool`.
    pub role: String,
    pub text: String,
    /// Unix milliseconds.
    pub at: u64,
}

/// The turn whose auth evidence a credential replacement made obsolete. It proves a change,
/// not that the new credential works; the next turn supplies that evidence.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuthChange {
    pub at: u64,
    pub turn_id: Option<String>,
    pub ended_at: Option<u64>,
}

/// Where a session sits in the tree of sessions that started each other
/// (`hub/lineage.rs`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Lineage {
    /// The session whose agent started it.
    pub parent: String,
    /// The root of its tree: the first ancestor no agent started.
    pub root: String,
    /// 1 for a child of a root, 2 for a grandchild, and so on.
    pub depth: u32,
    /// The parent's tool call that started it, when acpmux could tell.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

/// `SessionMeta::start_level`: the level a daemon started host `incarnation` at.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct StartLevel {
    pub incarnation: String,
    pub level: u32,
}

/// Who created a session (`hub/created_by.rs`), the shape cmux-tui's
/// `workspace.create {created_by}` takes.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, schemars::JsonSchema)]
pub struct CreatedBy {
    pub kind: CreatorKind,
    /// The cmux workspace it was created from (lowercase UUID): the agent session's
    /// workspace for an agent, else the one the create named.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    /// The acpmux session whose agent created it; only for `agent`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum CreatorKind {
    /// This host's app, or a connection that proved it is the person.
    Person,
    /// An agent session: its shell's `acpmux new` (a proven caller token) or its
    /// `start_session` tool.
    Agent,
    /// Any other client: a script or the CLI outside a chat.
    Script,
}

/// A sub-session's place in its family (`hub/subsessions.rs`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SubsessionLink {
    /// The parent session's id.
    pub started_by: String,
    /// Its name among its parent's children (unique there), e.g. `tests`.
    pub short_name: String,
    /// 1 for a child of a root session, 2 for a grandchild, and so on.
    pub depth: u32,
    /// The person started it from its parent's suggested task
    /// (`hub/offers.rs`), in a mode they chose: the parent's agent reads
    /// it but does not prompt, stop or close it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub offered: bool,
}

/// Limit overrides of one session; `None` inherits its parent's, then the
/// settings, then the defaults (`hub/subsessions.rs`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SubsessionLimits {
    /// Most children this session may have open at once (not closed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_children: Option<u32>,
    /// The deepest level a session under this one may be started at.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_depth: Option<u32>,
    /// Most children running a turn at once (`hub/subsession_runs.rs`); more wait their turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_running: Option<u32>,
}

impl SubsessionLimits {
    pub fn is_empty(&self) -> bool {
        self.max_children.is_none() && self.max_depth.is_none() && self.max_running.is_none()
    }
}

/// What one turn, or a session's turns together, cost (`hub/turn_usage.rs`).
/// A field the harness never reported stays absent rather than 0.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TurnUsage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write_tokens: Option<u64>,
    /// Of `cache_write_tokens`, the hour-long writes (Claude Code's
    /// `cache_creation.ephemeral_1h_input_tokens`), which bill at twice the input price where a
    /// 5-minute write bills at 1.25 times. Absent in older records and for harnesses that do not
    /// say: their writes price at the 5-minute rate.
    #[serde(default, rename = "cacheWrite1hTokens", skip_serializing_if = "Option::is_none")]
    pub cache_write_1h_tokens: Option<u64>,
}

impl TurnUsage {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    /// Adds `turn` in, field by field; a field neither reported stays absent.
    pub fn add(&mut self, turn: &TurnUsage) {
        fn sum(a: Option<u64>, b: Option<u64>) -> Option<u64> {
            a.zip(b).map(|(a, b)| a.saturating_add(b)).or(a).or(b)
        }
        self.cost_usd = self
            .cost_usd
            .zip(turn.cost_usd)
            .map(|(a, b)| a + b)
            .or(self.cost_usd)
            .or(turn.cost_usd);
        self.input_tokens = sum(self.input_tokens, turn.input_tokens);
        self.output_tokens = sum(self.output_tokens, turn.output_tokens);
        self.cache_read_tokens = sum(self.cache_read_tokens, turn.cache_read_tokens);
        self.cache_write_tokens = sum(self.cache_write_tokens, turn.cache_write_tokens);
        self.cache_write_1h_tokens = sum(self.cache_write_1h_tokens, turn.cache_write_1h_tokens);
    }
}

/// The tools a chat has (`hub/tools.rs`): cmux's own, recorded at each
/// spawn, then what Claude Code's system/init reports.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ToolInventory {
    #[serde(default)]
    pub rows: SharedRows,
    /// The chat can turn MCP servers off (Claude Code, through
    /// `--disallowedTools` at each start); ACP harnesses take their tools at
    /// session start only.
    #[serde(default)]
    pub mutable: bool,
    /// The rows (`mcp:<server>`) this chat turned off. Every start of its
    /// Claude Code disallows their tools; a fork keeps them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub off: Vec<String>,
}

impl ToolInventory {
    pub fn is_empty(&self) -> bool {
        self.rows.is_empty() && !self.mutable && self.off.is_empty()
    }
}

/// One row of a chat's tool list (the summary's `tools`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub struct ToolRow {
    /// `mcp:<server>`, `skill:<name>` or `plugin:<name>`, unique in the chat.
    pub id: String,
    pub name: String,
    /// `mcp`, `skill`, `plugin`, or `cmux` for cmux's own tools.
    pub kind: String,
    /// What gives it: `cmux`, or the harness that reported it (`claude`).
    pub source: String,
    pub enabled: bool,
    /// `_acpmux/set_tools` can turn it on or off in this chat.
    pub can_toggle: bool,
    /// An MCP server's status in the harness's own word (Claude Code's
    /// `connected`, `failed`, `pending`, `needs-auth`, `disabled`), as its
    /// last report gave it; none for a server no harness reported.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
}

/// How many earlier native ids a chat keeps (`SessionMeta::retired_agent_session_ids`).
pub const RETIRED_AGENT_SESSION_IDS: usize = 32;

impl SessionMeta {
    pub(crate) fn spoken_handle(&self) -> std::borrow::Cow<'_, str> {
        crate::session_handle::display(self.handle.as_deref(), &self.id)
    }

    /// Whether its harness counts a turn's input apart from the prompt cache, as Anthropic's
    /// usage does, told from what this record knows of how the chat ran (a daemon that has its
    /// config asks the profile's kind first, `Hub::input_excludes_cache`):
    /// - Claude Code over its stream (claude-stdio, whatever its profile is named: the `cmux`
    ///   model router's too), which starts a Claude conversation (`claude_profile`, a Claude
    ///   `agent_session_family`);
    /// - the Claude ACP adapter (`@agentclientprotocol/claude-agent-acp`, formerly
    ///   `claude-code-acp`), which sums `usage.input_tokens` into its ACP `inputTokens`, the
    ///   cache's reads and writes apart, `totalTokens` all four.
    ///
    /// Another ACP harness's input (Codex's, Gemini's) counts the cache's reads in it. A record
    /// that never started its agent says nothing of either, and is read by its names: a harness
    /// named `claude…`, a Claude leaf family (`claude-sr2`), or the `cmux` router's profile
    /// (family `claude`). Plain family `claude` alone is not one, as opencode on a Claude model
    /// is filed under it with its own usage.
    pub fn input_excludes_cache(&self) -> bool {
        if self.claude_profile.is_some()
            || self.agent_session_family.as_deref().is_some_and(|f| f.starts_with("claude"))
        {
            return true;
        }
        let argv = self.spawn_argv.as_ref().unwrap_or(&self.harness_argv);
        if argv
            .iter()
            .any(|arg| arg.contains("claude-agent-acp") || arg.contains("claude-code-acp"))
        {
            return true;
        }
        let harness = self.harness.trim().to_ascii_lowercase();
        let family = self.family.as_deref().unwrap_or("").trim().to_ascii_lowercase();
        harness.starts_with("claude")
            || family.starts_with("claude-")
            || (harness == "cmux" && family == "claude")
    }

    /// Replace the native id, retaining only prior Claude ids as transcript authority.
    /// Explicit provenance prevents a non-Claude id entering history after a profile switch.
    pub fn set_agent_session_id(&mut self, next: Option<String>, family: &str) {
        if let Some(next) = next.as_ref() {
            self.retired_agent_session_ids.retain(|id| id != next);
        }
        if let Some(previous) = self.agent_session_id.clone()
            && next.as_ref() != Some(&previous)
        {
            self.retire_root(previous);
        }
        if let Some(next) = next.as_ref().filter(|_| family == "claude") {
            self.previous_agent_session_ids.retain(|id| id != next);
        }
        let previous_family = self.agent_session_family.as_deref();
        if let Some(previous) = self.agent_session_id.take()
            && previous_family == Some("claude")
            && !(family == "claude" && Some(&previous) == next.as_ref())
            && !self.previous_agent_session_ids.contains(&previous)
        {
            self.previous_agent_session_ids.push(previous);
        }
        self.agent_session_id = next;
        self.agent_session_family = self.agent_session_id.as_ref().map(|_| family.to_owned());
    }

    /// Drop the native id without making it transcript authority: a chat that starts its agent
    /// fresh (a guarded move with no agent file, `transfer_guard.rs`) keeps the old root only in
    /// `retired_agent_session_ids`, since its acpmux history still names it. Never into
    /// `previous_agent_session_ids`, which would let a Claude transcript read follow a file that
    /// did not come with the chat.
    pub fn retire_agent_session_id(&mut self) {
        if let Some(previous) = self.agent_session_id.take() {
            self.retire_root(previous);
        }
        self.agent_session_family = None;
    }

    /// Record an earlier root in `retired_agent_session_ids`: once, newest last, bounded.
    fn retire_root(&mut self, previous: String) {
        if self.retired_agent_session_ids.contains(&previous) {
            return;
        }
        if self.retired_agent_session_ids.len() >= RETIRED_AGENT_SESSION_IDS {
            self.retired_agent_session_ids.remove(0);
        }
        self.retired_agent_session_ids.push(previous);
    }

    /// Claude ids recorded for this chat: current first, then history from newest to oldest.
    /// The caller must separately authorize each ancestor before reading its ids.
    pub fn claude_session_ids(&self) -> impl Iterator<Item = &str> {
        self.agent_session_id
            .iter()
            .filter(|_| self.agent_session_family.as_deref().is_none_or(|f| f == "claude"))
            .chain(self.previous_agent_session_ids.iter().rev())
            .map(String::as_str)
    }

    /// `chat_store` as the harness's store variable (`CLAUDE_CONFIG_DIR` or
    /// `CODEX_HOME`) over `env` (a spawn's, or the env a store is read
    /// with). The harness's default home (`~/.claude`, `~/.codex`) removes
    /// the variable instead: setting `CLAUDE_CONFIG_DIR=~/.claude` moves
    /// Claude's own config file, and with it the person's login. OpenCode's
    /// store `<data>/opencode` is `XDG_DATA_HOME=<data>`.
    pub fn apply_chat_store(&self, env: &mut BTreeMap<String, String>) {
        let Some(dir) = &self.chat_store else { return };
        let (var, default, dir) = match self.family.as_deref() {
            Some("claude") => ("CLAUDE_CONFIG_DIR", ".claude", dir.as_path()),
            Some("codex") => ("CODEX_HOME", ".codex", dir.as_path()),
            Some("opencode") => match dir.parent() {
                Some(data) if dir.file_name().is_some_and(|name| name == "opencode") => {
                    ("XDG_DATA_HOME", ".local/share", data)
                }
                _ => return,
            },
            _ => return,
        };
        let real = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        let default = dirs::home_dir().map(|home| real(&home.join(default)));
        if default.is_some_and(|default| default == real(dir)) {
            env.remove(var);
        } else {
            env.insert(var.to_owned(), dir.to_string_lossy().into_owned());
        }
    }

    /// The Claude store this session's harness reads when it spawns on a
    /// profile with `env`.
    /// A Claude chat whose conversation is not stored (`claude_unstored`) and whose agent did
    /// work in it (`claude_unstored_work`): hibernating or stopping it would lose that work's
    /// context, so `idle.rs` keeps it awake and `stop --if-idle` refuses it (`unstored`).
    pub fn keeps_unstored_awake(&self) -> bool {
        self.claude_unstored && self.claude_unstored_work && self.turn_count > 0
    }

    pub fn claude_store(&self, env: &BTreeMap<String, String>) -> PathBuf {
        let mut env = env.clone();
        self.apply_chat_store(&mut env);
        crate::adopt::HarnessHomes::from_env().with_env(&[&env]).claude
    }
}

/// One chat store root a spawn's env named: `harness` is a chat index
/// adapter id (`claude-code`, `codex`, ...) or, for a profile's own `sessions`
/// roots, the profile id. Never carries other env values.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HarnessRoot {
    pub harness: String,
    pub path: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Tag {
    pub value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<u64>,
}

pub const META_SCHEMA: &str = "acpmux.session.v1";

pub fn now_ms() -> u64 {
    #[cfg(test)]
    if let Some(now) = test_clock::followed_now_ms() {
        return now;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    #[cfg(test)]
    let now = now + test_clock::ahead_ms();
    now
}

/// Compressed time for tests (`stress/`): this thread's [`now_ms`] runs ahead of the wall clock
/// by what it was moved, so a day of timestamps passes in a loop. Other threads see wall time.
/// Followed (`follow_tokio`), it is the wall time at the follow plus tokio's ticked time, never
/// the real time since.
#[cfg(test)]
pub(crate) mod test_clock {
    use std::cell::Cell;

    thread_local!(static AHEAD_MS: Cell<u64> = const { Cell::new(0) });
    // Followed: tokio's instant and the real wall time (ms) at the follow.
    thread_local!(static FOLLOW: Cell<Option<(tokio::time::Instant, u64)>> = const { Cell::new(None) });

    pub(crate) fn ahead_ms() -> u64 {
        AHEAD_MS.with(Cell::get)
    }

    /// This thread's wall clock while it follows tokio: the wall time at the follow, the ticked
    /// time since and what it was moved. None when it does not follow.
    pub(crate) fn followed_now_ms() -> Option<u64> {
        let (origin, wall) = FOLLOW.with(Cell::get)?;
        let ticked = u64::try_from(origin.elapsed().as_millis()).unwrap_or(u64::MAX);
        Some(wall.saturating_add(ticked).saturating_add(ahead_ms()))
    }

    /// Moves this thread's clock `ms` ahead. With `follow_tokio` on, this is the computer
    /// sleeping: the wall clock runs ahead of the monotonic one (`peer_link::SleepWatch`).
    pub(crate) fn advance(ms: u64) {
        AHEAD_MS.with(|a| a.set(a.get() + ms));
    }

    /// From now on this thread's wall clock moves with tokio's, so a test under
    /// `start_paused` runs a day of wall-clock rules (a peer parked after a day down) in
    /// milliseconds, with the wall and monotonic clocks in step as on an awake computer.
    pub(crate) fn follow_tokio() {
        let wall = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX));
        FOLLOW.with(|f| f.set(Some((tokio::time::Instant::now(), wall))));
    }

    /// Back to the real wall clock.
    pub(crate) fn reset() {
        AHEAD_MS.with(|a| a.set(0));
        FOLLOW.with(|f| f.set(None));
    }

    /// A followed clock is ticked time only: the real milliseconds a run takes, more on a loaded
    /// host, never move it, so the wall-clock rules a test drives (a peer parked after a day
    /// down) fall on the same tick in every run (`stress::reconnect`, "a seed replays its
    /// schedule exactly", failed at 9dc6d10f under load 22-60).
    #[tokio::test(start_paused = true)]
    async fn a_followed_clock_moves_with_ticked_time_only() {
        follow_tokio();
        let before = super::now_ms();
        // Real time passes, as when a loaded host deschedules the test; tokio's paused clock
        // does not (no await, so it cannot auto-advance).
        let real = std::time::Instant::now();
        while real.elapsed() < std::time::Duration::from_millis(20) {
            std::hint::spin_loop();
        }
        let after_real = super::now_ms();
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        let after_tick = super::now_ms();
        advance(5_000);
        let after_sleep = super::now_ms();
        reset();
        assert_eq!(after_real, before, "20 ms of real time moved the followed clock");
        assert_eq!(after_tick, before + 1_000, "1 s of ticked time");
        assert_eq!(after_sleep, before + 6_000, "a computer sleep still runs the wall clock ahead");
    }
}

pub trait Store: Send + Sync {
    fn list(&self) -> Result<Vec<SessionMeta>>;
    /// The chats whose metadata the last `list` found and could not read, so left out. A caller
    /// that must know every chat (a delete that writes each fork's history in first) reads these
    /// again. None for a store that leaves none out.
    fn unlisted(&self) -> Vec<String> {
        Vec::new()
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>>;
    /// One startup entry, with the same visibility rules as `list`. Raw `load` may still
    /// return a purged chat's late metadata save for recovery/maintenance callers.
    fn load_startup(&self, id: &str) -> Result<Option<SessionMeta>> {
        self.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()>;
    /// `save` of a kept change ([`ShowAfter::Written`]: a draft, a name): with the event journal, a
    /// line that shows it waits only for its record's write, not its sync. Without the journal
    /// there is no gate, and this is `save`.
    fn save_kept(&self, meta: &SessionMeta) -> Result<()> {
        self.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()>;
    /// Flush one session's event log and metadata to stable storage.
    ///
    /// The default is sufficient for memory stores and older implementations; local stores
    /// override it to sync the segment and its containing directories.
    fn flush_session(&self, _id: &str) -> Result<()> {
        self.flush()
    }
    /// v2's raw source (`hub/v1_source.rs`, `store/log_bytes.rs`): chat `id`'s lines from seq
    /// `from` that `filter` keeps, whole and as written, at most one chunk of them (or one line
    /// when a line is larger), into `out`, read under count `stamp` with `marks`. A store that
    /// holds parsed records writes each as its line.
    fn read_log(
        &self,
        id: &str,
        from: u64,
        filter: LogFilter<'_>,
        _stamp: u64,
        marks: &mut LogMarks,
        out: &mut Vec<u8>,
    ) -> Result<LogChunk> {
        use acpmux_core::chat::source::CHUNK_BYTES;
        out.clear();
        marks.clear();
        let mut chunk = LogChunk { next: from, at_end: true, read: 0 };
        let mut failed = None;
        self.scan(id, from.saturating_sub(1), &mut |record| {
            if record.seq < from {
                return true;
            }
            if record.seq > filter.through {
                return false;
            }
            if filter.kinds.is_some_and(|kinds| !kinds.contains(&record.kind.as_str())) {
                return true;
            }
            let line = match serde_json::to_vec(&record) {
                Ok(line) => line,
                Err(e) => {
                    failed = Some(e);
                    return false;
                }
            };
            if !out.is_empty() && out.len() + line.len() + 1 > CHUNK_BYTES {
                chunk.at_end = false;
                return false;
            }
            out.extend_from_slice(&line);
            out.push(b'\n');
            chunk.next = record.seq.saturating_add(1);
            true
        })?;
        if let Some(e) = failed {
            return Err(e.into());
        }
        chunk.read = out.len() as u64;
        Ok(chunk)
    }
    /// v2's `RawSource::read_at`: at most `max` bytes of chat `id`'s line at seq `seq`, from
    /// `offset` in it, into `out`, read under count `stamp` with `marks`; and whether the line
    /// ends there. A store whose lines are files reads that part alone; this default reads the
    /// line whole through `read_log`.
    #[allow(clippy::too_many_arguments)]
    fn read_log_part(
        &self,
        id: &str,
        seq: u64,
        offset: u64,
        max: usize,
        stamp: u64,
        marks: &mut LogMarks,
        out: &mut Vec<u8>,
    ) -> Result<LogPart> {
        let chunk = self.read_log(id, seq, LogFilter::ALL, stamp, marks, out)?;
        let line = out.iter().position(|b| *b == b'\n').unwrap_or(out.len());
        out.truncate(line);
        if log_line_seq(out) != Some(seq) {
            anyhow::bail!("chat {id} holds no line at seq {seq}");
        }
        let start = usize::try_from(offset).unwrap_or(usize::MAX).min(line);
        let end = start.saturating_add(max).min(line);
        out.copy_within(start..end, 0);
        out.truncate(end - start);
        Ok(LogPart { ends: end == line, read: chunk.read })
    }
    /// Chat `id`'s count of changes to lines already written (`store/log_bytes.rs`): 0 for a
    /// store whose lines never change.
    fn log_stamp(&self, _id: &str) -> Result<u64> {
        Ok(0)
    }
    /// Adds `by` to chat `id`'s count: its lines read differently from now.
    fn bump_log_stamp(&self, _id: &str, _by: u64) -> Result<()> {
        Ok(())
    }
    /// Chat `id`'s log durable through `seq`: v2's book is never ahead of its raw.
    fn sync_log_through(&self, id: &str, _seq: u64) -> Result<()> {
        self.flush_session(id)
    }
    /// Events with `seq > after`, at most `limit`.
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>>;
    /// Visit records with `seq > after` in order until `visit` returns false.
    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        for rec in self.events(id, after, usize::MAX)? {
            if !visit(rec) {
                break;
            }
        }
        Ok(())
    }
    /// `scan` for a reader that wants only some records: a line `may_match` is false for holds
    /// none of them, and a file store passes it without parsing it (a store that holds parsed
    /// records may ignore it; `visit` still decides on the rest). A subagent pane's read of an
    /// old subagent passed a long chat's every later line through a parse, on each of its pages.
    fn scan_matching(
        &self,
        id: &str,
        after: u64,
        _may_match: &dyn Fn(&[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan(id, after, visit)
    }
    /// `scan`, but a record that cannot be read (a torn or malformed line) is an error instead of
    /// being skipped: a reader that must see every record (the full-access bound's readback of a
    /// left host, #23322) learns that it did not. A memory store holds only whole records.
    fn scan_strict(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan(id, after, visit)
    }
    /// [`Store::scan_back`] for a read whose `skip` passes only kinds in [`INDEXED_KINDS`] (a
    /// page of prompts, the queue, turn results): a file store reads a segment's copy of those
    /// kinds where the copy is good (`store/kind_index.rs`), and the segment itself back from its
    /// end where it is not, so the read never costs more than `scan_back`'s and stops where it
    /// does. Every other store reads as `scan_back`.
    fn scan_back_indexed(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_back(id, after, before, skip, visit)
    }
    /// Visit records with `after < seq < before` newest first until `visit`
    /// returns false: the reverse of `scan`, for pages taken from the end.
    /// `skip(dir, kind)` true says a record is surely not wanted: a file store
    /// passes such a line without parsing it (a store that holds parsed
    /// records may ignore it; `visit` still decides on the rest).
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        let mut found = Vec::new();
        self.scan(id, after, &mut |rec| {
            if rec.seq >= before {
                return false;
            }
            if !skip(rec.dir.as_bytes(), rec.kind.as_bytes()) {
                found.push(rec);
            }
            true
        })?;
        for rec in found.into_iter().rev() {
            if !visit(rec) {
                break;
            }
        }
        Ok(())
    }
    /// How many records follow `after`, and the last one's `seq` (`after` when none): the
    /// catch-up of a log that ran ahead of its saved meta. A file store reads only the tail
    /// past `after`, never the whole log (daemon start, 2026-10-20).
    fn tail_after(&self, id: &str, after: u64) -> Result<(u64, u64)> {
        let mut count = 0;
        let mut last = after;
        self.scan(id, after, &mut |rec| {
            count += 1;
            last = last.max(rec.seq);
            true
        })?;
        Ok((count, last))
    }
    /// Where the newest `n` records before seq `before` start ([`NewestWindow`]): a replay that
    /// may send only `n` records sends the newest ones (`session/load`), not the oldest. A file
    /// store reads the lines' seqs back from the end and parses none, so the answer costs `n`
    /// lines however long the log is.
    fn newest_window(&self, id: &str, before: u64, n: u64) -> Result<NewestWindow> {
        newest_window_by_scan(self, id, before, n)
    }
    /// `scan` from the start, visiting only records whose `kind` is in `kinds`. A file store
    /// parses no other line (the queue restore at daemon start reads its few kinds out of
    /// logs that are mostly agent output).
    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan(id, 0, &mut |rec| {
            if kinds.contains(&rec.kind.as_str()) { visit(rec) } else { true }
        })
    }
    /// `scan_kinds`, but strict as `scan_strict` is: a record that cannot be read is an error. A
    /// file store reads a segment's copy of its kinds (`store/kind_index.rs`) only when every line
    /// the copy covers read whole.
    fn scan_kinds_strict(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_strict(id, 0, &mut |rec| {
            if kinds.contains(&rec.kind.as_str()) { visit(rec) } else { true }
        })
    }
    /// `scan_kinds` of the records past `after` only: a log load that begins at a restore point
    /// (`hub/restore_point.rs`). A file store reads from the segment that holds `after + 1`.
    fn scan_kinds_after(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        if after == 0 {
            return self.scan_kinds(id, kinds, visit);
        }
        self.scan(id, after, &mut |rec| {
            if kinds.contains(&rec.kind.as_str()) { visit(rec) } else { true }
        })
    }
    /// `scan_kinds_after`, strict as `scan_kinds_strict` is.
    fn scan_kinds_after_strict(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        if after == 0 {
            return self.scan_kinds_strict(id, kinds, visit);
        }
        self.scan_strict(id, after, &mut |rec| {
            if kinds.contains(&rec.kind.as_str()) { visit(rec) } else { true }
        })
    }
    /// `scan_kinds`, visiting only the records whose head (`store/kind_heads.rs`) `keep` keeps,
    /// shown in order: a caller that wants one prompt's few records out of a chat's many says so,
    /// and a file store reads and parses no other once it knows the chat's heads. `keep` may
    /// keep more than the caller needs (an unread head, a list of prompts), never fewer, and may
    /// be shown a head more than once (a fork's join, a segment read again whole).
    fn scan_kinds_keyed(
        &self,
        id: &str,
        kinds: &[&str],
        keep: &mut dyn FnMut(&KindHead<'_>) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds(id, kinds, &mut |rec| {
            let kept = keep(&KindHead::of(&rec));
            !kept || visit(rec)
        })
    }
    /// The restore point `id`'s last log load saved (`hub/restore_point.rs`), as saved. None in a
    /// store that keeps none.
    fn restore_point(&self, _id: &str) -> Option<Vec<u8>> {
        None
    }
    /// Saves `bytes` as `id`'s restore point, whole or not at all. A store that keeps none
    /// drops it.
    fn save_restore_point(&self, _id: &str, _bytes: &[u8]) -> Result<()> {
        Ok(())
    }
    /// Records used by the whole-store search, including an archive without thawing it.
    fn search_records(&self, id: &str, visit: &mut dyn FnMut(EventRecord)) -> Result<()> {
        self.scan_kinds(id, crate::session_search::KINDS, &mut |rec| {
            visit(rec);
            true
        })
    }

    /// Use the warm text index, or stream the messages out of an archived log.
    fn conversation_entries(
        &self,
        id: &str,
        visit: &mut dyn FnMut(crate::session_search::Entry),
    ) -> Result<()> {
        if self.is_cold(id) {
            crate::session_search::project_records(|feed| self.search_records(id, feed), visit)
        } else {
            self.text_entries(id, visit)
        }
    }

    /// `scan` from the start, passing each record's head ([`RecordHead`]) until `visit` returns
    /// false; the reader parses only the records it needs (`RecordHead::record`). A file store
    /// reads a head without parsing its line: adopting a host after a restart reads its whole
    /// log four times, and parsing every line held big-red's daemon at a full core for minutes.
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        self.scan(id, 0, &mut |rec| visit(&RecordHead::parsed(&rec)))
    }
    /// `scan_heads` of the records from `from` on, each with where its line is ([`LinePos`]) in
    /// a store that knows: an adoption that resumes from its checkpoint
    /// (`hub/hosts/checkpoint.rs`). `hint` is where the line of `from` was; a file store reads
    /// from there, when that line still holds `from`, and from the segment that holds `from`
    /// otherwise. Never more records than `scan_heads`, never fewer past `from`.
    fn scan_heads_from(
        &self,
        id: &str,
        from: u64,
        _hint: Option<LinePos>,
        visit: &mut dyn FnMut(&RecordHead<'_>, Option<LinePos>) -> bool,
    ) -> Result<()> {
        self.scan_heads(id, &mut |head| head.seq < from || visit(head, None))
    }
    /// The adoption checkpoint of `id` (`hub/hosts/checkpoint.rs`), as saved. None in a store
    /// that keeps none.
    fn adoption_checkpoint(&self, _id: &str) -> Option<Vec<u8>> {
        None
    }
    /// Saves `bytes` as `id`'s adoption checkpoint, whole or not at all. A store that keeps none
    /// drops it.
    fn save_adoption_checkpoint(&self, _id: &str, _bytes: &[u8]) -> Result<()> {
        Ok(())
    }
    /// The log's messages (`session_search.rs`), oldest first. A file store reads each segment's
    /// text copy (`store/text_index.rs`) and only the bytes appended past it.
    fn text_entries(
        &self,
        id: &str,
        visit: &mut dyn FnMut(crate::session_search::Entry),
    ) -> Result<()> {
        let mut projector = crate::session_search::Projector::default();
        self.scan_kinds(id, crate::session_search::KINDS, &mut |rec| {
            projector.feed(&rec);
            true
        })?;
        projector.entries.into_iter().for_each(visit);
        Ok(())
    }
    /// Make every appended record durable (called on shutdown).
    fn flush(&self) -> Result<()> {
        Ok(())
    }
    /// Waits up to `timeout` until every record appended so far is durable; false when the time
    /// ran out. For tests and tools: a request never blocks on the disk. The Local and Memory
    /// stores do not sync an append, so they return true at once (their appends are as durable
    /// as they will be until `flush`).
    fn wait_durable(&self, timeout: std::time::Duration) -> Result<bool> {
        let _ = timeout;
        Ok(true)
    }
    /// How durable its appends are (`server/durable_gate.rs`). None: appends are not journaled,
    /// and no connection waits for them.
    fn durability(&self) -> Option<Durability> {
        None
    }
    /// Why the store asks the daemon to stop with a restart, as it changes: `Some(reason)` once
    /// the store cannot go on safely (the journal store's frozen checkpoint, whose logs only a
    /// restart's replay writes again). None: a store that never asks.
    fn stop_reason(&self) -> Option<tokio::sync::watch::Receiver<Option<String>>> {
        None
    }
    /// The daemon's shutdown is done: from now on every write is refused. It lets go of
    /// `daemon.lock` before its process exits, so the next daemon may already read this store;
    /// what it reads is the old daemon's last word (`Hub::shutdown_all`). Waits for writes under
    /// way.
    fn seal(&self) {}
    /// Close the session's log until it is next written (a closed session's).
    fn close_log(&self, _id: &str) {}
    /// Retention (`store/compact.rs`): the log's last `seq` when it was last compacted.
    fn compacted_seq(&self, _id: &str) -> Option<u64> {
        None
    }
    /// Retention: when the log was last written, in ms, from its newest segment. None: the store
    /// keeps no log on disk, or the chat has none.
    fn log_written_at(&self, _id: &str) -> Option<u64> {
        None
    }
    /// Reads the log and, unless a dry run, writes its compacted segments beside it. None: the
    /// store keeps no log on disk, or the chat has none.
    fn stage_compaction(&self, _id: &str, _mode: CompactMode) -> Result<Option<Staged>> {
        Ok(None)
    }
    /// Puts a staged compaction in place unless the log changed since (false). The caller holds
    /// the chat's append lock.
    fn commit_compaction(&self, _id: &str, _staged: Staged) -> Result<bool> {
        Ok(false)
    }
    /// Leaves out every record of chat `id` past `after`, in place (`CompactMode::Truncate`):
    /// false when the log changed meanwhile, or the store cannot. Its caller holds the chat's
    /// append lock. A journal restore's only (`hub/journal_restore.rs`).
    fn truncate_after(&self, id: &str, after: u64) -> Result<bool> {
        match self.stage_compaction(id, CompactMode::Truncate { after })? {
            Some(staged) => self.commit_compaction(id, staged),
            None => Ok(false),
        }
    }
    /// Keeps `kept`, the records chat `id` keeps while a journal restore holds it
    /// (`hub/restore_writer.rs`), whole and durably beside its log, in place of what it kept
    /// before; None removes them. They take no seq: the restore needs the seqs past the log's
    /// end. Done only when it answers Ok. A store that keeps nothing across a restart keeps
    /// nothing here.
    fn keep_parked(&self, _id: &str, _kept: Option<&[u8]>) -> Result<()> {
        Ok(())
    }
    /// What [`Store::keep_parked`] last kept for chat `id`.
    fn kept_parked(&self, _id: &str) -> Result<Option<Vec<u8>>> {
        Ok(None)
    }
    /// Keeps `held`, the body of a tool output snapshot or turn diff chat `id` holds back from
    /// its log (`store/deferred.rs`), as slot `slot` (lowercase hex, `Deferral::slot`) beside the
    /// log, in place of what the slot kept; None removes it, and a slot with nothing is Ok. The
    /// body is kept before its stub is logged, so the next start stores what a killed daemon held
    /// (`Hub::take_back_held`). Not synced: a kill keeps it, a power cut may not. Never makes a
    /// chat's folder that is gone. A store that keeps nothing across a restart keeps nothing here.
    fn keep_held(&self, _id: &str, _slot: &str, _held: Option<&[u8]>) -> Result<()> {
        Ok(())
    }
    /// What [`Store::keep_held`] keeps for chat `id`: each slot and its bytes, in no order.
    fn kept_held(&self, _id: &str) -> Result<Vec<(String, Vec<u8>)>> {
        Ok(Vec::new())
    }
    /// Writes a cold archive of `id`'s log beside it and checks it (`store/cold.rs`); None
    /// without a log to archive, or for a store that keeps none.
    fn stage_cold(&self, _id: &str) -> Result<Option<StagedCold>> {
        Ok(None)
    }
    /// Puts `staged` in place of the log, unless the log changed since (false). The caller holds
    /// the chat's append lock.
    fn commit_cold(&self, _id: &str, _staged: StagedCold) -> Result<bool> {
        Ok(false)
    }
    /// Puts a cold-archived chat's log back; false when it was not archived. Any read of the log
    /// does this on its own; the hub calls it to open a chat on purpose.
    fn rehydrate(&self, _id: &str) -> Result<bool> {
        Ok(false)
    }
    /// The chat's log is in its cold archive. A few `lstat`s, no read.
    fn is_cold(&self, _id: &str) -> bool {
        false
    }
    /// Moves a cold-archived chat's archive to the person's cloud history store (opt-in,
    /// `cmux-session-cloud`), leaving a stub; its next read fetches it back. The bytes freed, or
    /// None when the chat is not archived here, cloud history is off, or the archive changed.
    fn offload_cold(&self, _id: &str) -> Result<Option<u64>> {
        Ok(None)
    }
    /// Registers this machine's cloud history GC root: one tree naming the blob of every chat
    /// offloaded here, so the store keeps them (roots expire unless registered again within 90
    /// days). Call it after a batch of offloads, not per chat. The blobs named, or None when cloud
    /// history is off.
    fn register_cloud_root(&self) -> Result<Option<usize>> {
        Ok(None)
    }
    /// Called with a chat's id each time its log comes back from its cold archive, on any path
    /// (a read, an append, a fork's history): the hub drops the chat's preview
    /// (`hub/cold_archive.rs`). Called inside the store's own locks: it must take none of its
    /// own that a store caller may hold. Set once.
    fn on_rehydrate(&self, _hook: RehydrateHook) {}
    /// Writes and checks the archives of at most `max` of `id`'s sealed segments still hot, at
    /// zstd `level`, beside them (`store/cold_segments.rs`). None: nothing to move, or a store
    /// that keeps no segments.
    fn stage_cold_segments(
        &self,
        _id: &str,
        _max: usize,
        _level: i32,
    ) -> Result<Option<StagedColdSegments>> {
        Ok(None)
    }
    /// Readies the store for a cold segments' commit, with no lock of the chat held: the journal
    /// store's checkpoint must cover every line of them. False: not now.
    fn prepare_cold_segments(&self, _id: &str, _staged: &StagedColdSegments) -> Result<bool> {
        Ok(true)
    }
    /// Puts staged archives in place of their segments, each unless it changed since. The caller
    /// holds the chat's append lock. What it moved.
    fn commit_cold_segments(&self, _id: &str, _staged: StagedColdSegments) -> Result<ColdMoved> {
        Ok(ColdMoved::default())
    }
    /// Finishes what a crash left of a move of `id`'s segments (`store/cold_segments.rs`).
    fn settle_cold_segments(&self, _id: &str) -> Result<()> {
        Ok(())
    }
    /// Brings every cold segment of `id` back to a plain `.ndjson`, each checked against its
    /// index's SHA-256 before it goes in place (`store/cold_segments.rs`, `cmux chats warm`).
    fn warm_cold_segments(&self, _id: &str) -> Result<ColdWarmed> {
        Ok(ColdWarmed::default())
    }
    /// Called with a chat's id when its log seals a segment (rolls over to the next), under the
    /// store's writers' lock: it may only note the id and wake a worker. Set once.
    fn on_segment_sealed(&self, _hook: SealHook) {}
    /// Called with a chat's id each time its log grows past another [`GROWN_EVERY`] bytes
    /// (`hub/pack_as_it_grows.rs`), on the appending thread after the write, outside the store's
    /// writers' and segment's locks (the caller's append lock may be held): it may only note the
    /// id and wake a worker. Set once.
    fn on_log_grown(&self, _hook: SealHook) {}
    fn delete(&self, id: &str) -> Result<()>;
    fn session_dir(&self, _id: &str) -> Option<PathBuf> {
        None
    }
    /// The chat's folder path only, for a caller that needs the path or its parent and reads or
    /// moves none of the chat's own files: no lock, no wait, no write. `session_dir` is for code
    /// that reads or moves them (the journal store writes the chat's metadata first).
    fn session_path(&self, id: &str) -> Option<PathBuf> {
        self.session_dir(id)
    }
    /// Where handoff records live: `handoffs/` beside `sessions/`, or none
    /// (in memory) for the memory store.
    fn handoff_dir(&self) -> Option<PathBuf> {
        None
    }
    /// Where each peer's last-known sessions are saved: `peers/` beside
    /// `sessions/`, or none (in memory) for the memory store.
    fn peer_cache_dir(&self) -> Option<PathBuf> {
        None
    }
    /// Where the brief and task ledger is saved (`hub/dispatch.rs`): `briefs.json` beside
    /// `sessions/`, or none (in memory) for the memory store, so a hub's tasks always name
    /// sessions of its own store.
    fn briefs_path(&self) -> Option<PathBuf> {
        None
    }
    /// Whether [`Store::history_writer`] can write a fork's history into its log
    /// (`store/fork_view.rs`). False: forks copy their history as records.
    fn writes_history(&self) -> bool {
        false
    }
    /// Names `fork` a fork of `reference` before its meta is saved, so a delete or compaction of
    /// the chat from now on writes the history into it first (`store/fork_view.rs`). An error:
    /// the chat is gone.
    fn reserve_reference(&self, _fork: &str, _reference: &HistoryRef) -> Result<()> {
        Ok(())
    }
    /// Takes back a [`Store::reserve_reference`] of a fork that was not made.
    fn forget_reference(&self, _fork: &str) {}
    /// Before `id`'s folder is replaced whole (a chat moved back here) or removed: every fork that
    /// references its history holds that history itself first, and no new fork references it
    /// until [`Store::end_release`] (review of #37020). Use [`fence_history`].
    fn release_history(&self, _id: &str) -> Result<()> {
        Ok(())
    }
    /// Ends one [`Store::release_history`].
    fn end_release(&self, _id: &str) {}
    /// A writer of the history a fork referenced, as its log's first segment. None: this store
    /// writes none ([`Store::writes_history`]).
    fn history_writer(&self, _id: &str) -> Result<Option<Box<dyn HistoryWriter + '_>>> {
        Ok(None)
    }
    /// Where the approvals audit trail is kept (`hub/audit_log.rs`): `audit/` beside
    /// `sessions/`, or none (in memory) for the memory store.
    fn audit_dir(&self) -> Option<PathBuf> {
        None
    }
}

/// [`Store::newest_window`] by `scan_back`, for a store with no cheaper read of its seqs.
pub(crate) fn newest_window_by_scan<S: Store + ?Sized>(
    store: &S,
    id: &str,
    before: u64,
    n: u64,
) -> Result<NewestWindow> {
    let mut window = NewestWindow::default();
    let mut seen = 0u64;
    store.scan_back(id, 0, before, &|_, _| false, &mut |rec| {
        window.newest = window.newest.max(rec.seq);
        seen += 1;
        if seen > n {
            window.after = rec.seq;
            return false;
        }
        true
    })?;
    Ok(window)
}

mod log_line;
pub use log_line::RecordHead;

/// Where a log line is: its segment's number and the byte offset its line starts at
/// (`Store::scan_heads_from`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinePos {
    pub segment: u32,
    pub offset: u64,
}

#[cfg(test)]
pub(crate) use log_line::PARSED_LINES;

use log_line::{
    first_seq, for_each_line_rev, for_each_line_rev_between, for_each_line_rev_from, offset_of_seq,
    parse_record, record_dir, record_kind, record_seq,
};

pub fn open(config: &StoreConfig, root: &Path) -> Result<Box<dyn Store>> {
    Ok(match config.mode {
        StoreMode::Memory => Box::new(MemoryStore::default()),
        StoreMode::Local => Box::new(journal_store::JournalStore::open(
            config,
            root,
            std::sync::Arc::new(journal_store::FencedStorage::daemon()),
            cmux_journal::Config::default(),
        )?),
    })
}

/// Writes the event journal a run left in `home`, if any, into that home's logs and
/// `session.json` files, checkpoints it and retires its records: afterwards the home's `sessions/`
/// hold every acknowledged change on their own. For code that moves or merges a home's chat
/// folders without a daemon (the build adoption, `cmux-tui`'s `build_adopt`): a daemon that
/// stopped without a shutdown leaves changes only its journal holds (a new chat's `session.json`
/// is written by a checkpoint). Nothing to do without a journal. No daemon may run in `home`: the
/// caller holds its `daemon.lock`.
pub fn catch_up_journal(config: &StoreConfig, home: &Path) -> Result<()> {
    journal_store::catch_up(config, home)
}

mod durability;
pub use durability::{Durability, FULL_WAIT, ShowAfter};
pub(crate) use durability::{RecordClass, record_class, streamed};
mod journal_store;
#[cfg(test)]
pub(crate) use journal_store::open_with_journal;
#[cfg(test)]
pub(crate) use journal_store::{DISK_RESERVE, set_test_free};
mod log_sync;
mod segment_writer;
pub use segment_writer::GROWN_EVERY;
use segment_writer::SegmentWriter;
pub mod open_logs;
#[cfg(test)]
pub(crate) use journal_store::{
    hold_next_read_fence_on_this_thread, pause_next_log_write_on_this_thread,
};
pub(crate) use log_sync::SyncFailed;
#[cfg(all(test, unix))]
mod sync_model;

mod memory;
pub use memory::MemoryStore;
#[cfg(test)]
pub(crate) use memory::{COPY_FORKS, REFUSE_APPENDS};

// ----------------------------------------------------------------- local

/// A chat's restore point, beside its `session.json` (`hub/restore_point.rs`).
const RESTORE_POINT: &str = "restore-point.json";
/// A chat's adoption checkpoint, beside its `session.json` (`hub/hosts/checkpoint.rs`).
const ADOPTION_CHECKPOINT: &str = "adoption-checkpoint.json";

/// `path`'s bytes, read in the held home (`None` when it is missing or unreadable).
fn held_file_bytes(path: &Path) -> Option<Vec<u8>> {
    let mut bytes = Vec::new();
    crate::home_fs::private_state_file(path).ok()?.read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

pub struct LocalStore {
    root: PathBuf,
    segment_bytes: u64,
    writers: Mutex<Writers>,
    /// The most logs held open ([`open_logs`]).
    open_logs: usize,
    /// Read-held by every write, true once `seal` ran: a write either lands before the seal
    /// returns or not at all.
    sealed: std::sync::RwLock<bool>,
    /// A log's sync on its close failed (`SegmentWriter::close`): its lines may be lost on the
    /// disk. The journal store then keeps every line in its journal (`store/journal_store.rs`).
    sync_failed: std::sync::atomic::AtomicBool,
    /// [`Store::unlisted`]: folders whose `session.json` is there and did not read.
    unlisted: Mutex<std::collections::BTreeSet<String>>,
    /// One lock per chat ([`cold::ChatLocks`]), held by every change that removes one of the
    /// chat's log's copies: a cold archive's commit, a rehydrate and its settle
    /// (`store/cold.rs`), and a cold segment's commit, warm and settle
    /// (`store/cold_segments.rs`). Always after the writers' lock when both are taken: two reads
    /// of an archived chat rehydrate it once.
    cold: cold::ChatLocks,
    /// What this store's temporary cold-segment files carry in their names
    /// (`store/cold_segments.rs`): a settle removes only those of another store, a crash's,
    /// never one a move or warm of this store is writing (#43562 review F1).
    cold_tag: String,
    /// [`Store::on_rehydrate`].
    rehydrate_hook: std::sync::OnceLock<RehydrateHook>,
    /// [`Store::on_segment_sealed`].
    seal_hook: std::sync::OnceLock<SealHook>,
    /// [`Store::on_log_grown`].
    grow_hook: std::sync::OnceLock<SealHook>,
    /// The parts files written or read (`store/meta_parts.rs`).
    parts: meta_parts::PartsMemo,
    /// The segments' record heads a keyed scan read (`store/kind_heads.rs`).
    kind_heads: kind_heads::KindHeads,
    /// The copies of segments' indexed kinds the reads checked (`store/kind_index.rs`).
    kind_index_checks: kind_index::Checked,
    /// Each segment's first seq, once read (`store/segment_starts.rs`).
    pub(crate) segment_starts: segment_starts::SegmentStarts,
    segment_table: segment_table::SegmentTable,
    #[cfg(test)]
    pub(crate) meta_saves: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

/// The logs held open, at most `LocalStore::open_logs` (`store/open_logs.rs`): the least
/// recently written one is closed for a new one.
#[derive(Default)]
struct Writers {
    open: HashMap<String, SegmentWriter>,
    /// Counts appends; a writer's `used` is the count at its last one.
    clock: u64,
    /// Each chat's count of changes to lines already written, once read (`store/log_bytes.rs`):
    /// read and bumped only under this lock.
    stamps: HashMap<String, u64>,
}

/// What a chat keeps while a journal restore holds it (`Store::keep_parked`), beside its log.
const PARKED: &str = "parked.json";
/// The folder of a chat's held tool output bodies (`Store::keep_held`), beside its log.
const HELD: &str = "held";

impl LocalStore {
    pub fn new(root: PathBuf, segment_bytes: u64) -> Result<Self> {
        crate::config::private_state_dir(&root)
            .with_context(|| format!("create private store {}", root.display()))?;
        Ok(Self {
            root,
            segment_bytes: segment_bytes.max(64 * 1024),
            writers: Mutex::new(Writers::default()),
            open_logs: open_logs::now(),
            sealed: Default::default(),
            sync_failed: Default::default(),
            unlisted: Default::default(),
            cold: Default::default(),
            cold_tag: format!("{}x{}", std::process::id(), uuid::Uuid::now_v7().simple()),
            rehydrate_hook: Default::default(),
            seal_hook: Default::default(),
            grow_hook: Default::default(),
            parts: Default::default(),
            kind_heads: Default::default(),
            kind_index_checks: Default::default(),
            segment_starts: Default::default(),
            segment_table: Default::default(),
            #[cfg(test)]
            meta_saves: Default::default(),
        })
    }

    /// Held through a write; refused once the store is sealed (`Store::seal`).
    fn writable(&self) -> Result<std::sync::RwLockReadGuard<'_, bool>> {
        let sealed = self.sealed.read().unwrap_or_else(std::sync::PoisonError::into_inner);
        if *sealed {
            anyhow::bail!("the store is sealed: the daemon has shut down");
        }
        Ok(sealed)
    }

    fn dir(&self, id: &str) -> PathBuf {
        self.root.join(id)
    }

    /// The log's segments, in order. A cut a crash or a failure left halfway
    /// (`store/compact.rs` `finish_cut_locked`) is finished first: no reader ever sees a log
    /// whose segments were cut to different ends (review of #37284 at b7496c3f, F2).
    /// The log's segments, oldest first. A cold-archived chat's log is rehydrated first
    /// (`store/cold.rs`): only a chat with no segment pays for the look, one `lstat` and a second
    /// listing. The listing is taken again whatever `rehydrate` answers: another thread's
    /// rehydrate may have put the log back since the first, and this one then answers false
    /// (review of #39141: an append went on in `000001` of a log that ran on past it).
    fn segments(&self, id: &str) -> Result<SegmentList> {
        let (segments, cut_pending) = self.list_segments(id)?;
        if !cut_pending {
            return Ok(segments);
        }
        // A sealed store writes nothing: the next daemon finishes it.
        let Ok(_open) = self.writable() else { return Ok(segments) };
        let mut writers = self.writers.lock_or_recover();
        self.finish_cut_locked(id, &mut writers)?;
        drop(writers);
        Ok(self.list_segments(id)?.0)
    }

    /// The log's segments, in order, as the folder lists them, and whether a cut's intent
    /// (`store/compact.rs` `CUT`) is beside them: read in the same listing, so it costs nothing.
    /// A cold archive's log is rehydrated first (`store/cold.rs`).
    /// Segments zstd'd in place by a tool outside acpmux are decoded back first
    /// (`store/sealed_segments.rs`): the same listing says whether there are any.
    fn list_segments(&self, id: &str) -> Result<(SegmentList, bool)> {
        let (mut segments, mut cut_pending, sealed) = self.listed_files(id)?;
        if sealed {
            match self.thaw_sealed(id) {
                Ok(0) => {}
                Ok(_) => (segments, cut_pending, _) = self.listed_files(id)?,
                Err(e) => tracing::warn!(session = %id, "sealed segments stay sealed: {e:#}"),
            }
        }
        if segments.is_empty() {
            self.rehydrate(id)?;
            let (segments, cut_pending, _) = self.listed_files(id)?;
            return Ok((segments, cut_pending));
        }
        Ok((segments, cut_pending))
    }

    /// The segments on the disk now, never rehydrated.
    fn segment_files(&self, id: &str) -> Result<SegmentList> {
        Ok(self.listed_files(id)?.0)
    }

    /// [`Self::segment_files`], whether a cut's intent is beside them, and whether a segment
    /// zstd'd in place with no plain one of its name is (`store/sealed_segments.rs`).
    fn listed_files(&self, id: &str) -> Result<(SegmentList, bool, bool)> {
        self.segment_table.list(id, &self.dir(id).join("events"))
    }

    fn list_entry(
        &self,
        root: &crate::home_fs::PrivateDir,
        name: &std::ffi::OsStr,
    ) -> Result<Option<SessionMeta>> {
        let entry = match root.entry(name) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            other => other?,
        };
        let session = root.path().join(name);
        anyhow::ensure!(!entry.is_symlink, "session entry {} is a link", session.display());
        if !entry.is_dir {
            return Ok(None);
        }
        let held = self.validate_session_dir(root, name)?;
        let path = session.join("session.json");
        let id = name.to_string_lossy().into_owned();
        let file = match held.private_file(std::ffi::OsStr::new("session.json")) {
            Ok(file) => file,
            Err(error) => {
                if !is_not_found(&error) {
                    self.mark_unlisted(&id, true);
                }
                return Ok(None);
            }
        };
        let mut text = String::new();
        BufReader::new(file).read_to_string(&mut text)?;
        // Only a closed chat can be a purged chat revived by a late save. Open chats need
        // no segment enumeration: that work belongs to their on-demand log read.
        if let Ok(meta) = serde_json::from_str::<StatusOnly>(&text)
            && self.purged_startup_entry(&id, meta.status)?
        {
            return Ok(None);
        }
        match serde_json::from_str::<SessionMeta>(&text) {
            Ok(mut meta) => {
                self.parts.merge_held(&held, text.as_bytes(), &mut meta);
                self.mark_unlisted(&id, false);
                Ok(Some(meta))
            }
            Err(e) => {
                tracing::warn!("skip {}: {e}", path.display());
                self.mark_unlisted(&id, true);
                Ok(None)
            }
        }
    }

    fn mark_unlisted(&self, id: &str, unread: bool) {
        let mut unlisted = self.unlisted.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if unread {
            unlisted.insert(id.to_owned());
        } else {
            unlisted.remove(id);
        }
    }

    /// Exact on-demand reads use the same directory checks as the background list before
    /// trusting metadata or reading any log. In particular, neither directory may be a link.
    fn validate_session_dir(
        &self,
        root: &crate::home_fs::PrivateDir,
        name: &std::ffi::OsStr,
    ) -> Result<crate::home_fs::PrivateDir> {
        let session = root.child(name)?;
        match session.child(std::ffi::OsStr::new("events")) {
            Err(error) if is_not_found(&error) => {}
            Err(error) => return Err(error),
            Ok(_) => {}
        }
        Ok(session)
    }

    fn purged_startup_entry(&self, id: &str, status: SessionStatus) -> Result<bool> {
        Ok(status == SessionStatus::Closed && !self.has_records(id)?)
    }

    /// Whether the session's log holds a record: a segment with a byte in it (no line
    /// is read), or a compaction's record (`store/compact.rs`), which keeps a closed
    /// chat's log however little of it stays. Every session the hub creates logs `created`
    /// right after its first save, so a record without a log is a purged session's that a
    /// late save wrote back.
    /// A cold archive (`store/cold.rs`) is a log too, and is not opened; so is its cloud stub
    /// (an archive offloaded to cloud history), and a segment zstd'd in place
    /// (`store/sealed_segments.rs`), which its first read decodes back.
    fn has_records(&self, id: &str) -> Result<bool> {
        // A home that is no longer the held one is an error, never "no record" (#41721
        // review F1): a closed chat with no record reads as purged.
        if crate::home_fs::try_exists_nofollow(self.marker(id))?
            || crate::home_fs::try_exists_nofollow(self.cold_path(id))?
            || crate::home_fs::try_exists_nofollow(self.cloud_stub_path(id))?
        {
            return Ok(true);
        }
        let (segments, _, sealed) = self.listed_files(id)?;
        if sealed {
            return Ok(true);
        }
        for (_, path) in segments {
            // An unreadable segment counts as a log: the session is listed as before.
            match crate::home_fs::symlink_metadata(&path) {
                Ok(meta) if meta.len() == 0 => {}
                _ => return Ok(true),
            }
        }
        Ok(false)
    }

    fn open_writer(&self, id: &str) -> Result<SegmentWriter> {
        let dir = self.dir(id).join("events");
        crate::config::private_state_dir(&self.dir(id))?;
        crate::config::private_state_dir(&dir)?;
        // Under the writers' lock (`append_line`), which finished any cut left halfway first.
        let (segs, _) = self.list_segments(id)?;
        // Never segment `000000`: it holds only a fork's history, written whole and renamed in
        // place (`history_writer`), which would replace a record appended to it (review of
        // #37020). A log whose only segment it is goes on in `000001`.
        // Nor a cold segment's archive (`store/cold_segments.rs`): the log goes on in the next.
        let (index, path) = match segs.last().filter(|(i, _)| *i > 0) {
            Some((i, p)) if cold_segments::is_cold(p) => {
                (i + 1, dir.join(format!("{:06}.ndjson", i + 1)))
            }
            Some((i, p)) => (*i, p.clone()),
            None => (1, dir.join("000001.ndjson")),
        };
        let file = open_private_append(&path)?;
        let written = cut_torn_tail(&file, &path)?;
        Ok(SegmentWriter::new(index, file, written, 0))
    }
}

fn is_not_found(error: &anyhow::Error) -> bool {
    error.downcast_ref::<std::io::Error>().is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound)
}

/// A session record's status alone, read without the rest of the record.
#[derive(Deserialize)]
struct StatusOnly {
    status: SessionStatus,
}

/// The event logs' write budget per kind (`cmux_tui_platform::write_budget`): a kind past 8 MiB
/// or 20,000 records an hour, or one whose records mostly repeat, is a writer to fix.
static EVENT_LOG_BUDGET: std::sync::LazyLock<cmux_tui_platform::write_budget::WriteBudget> =
    std::sync::LazyLock::new(|| {
        cmux_tui_platform::write_budget::WriteBudget::new(
            "acpmux event log",
            cmux_tui_platform::write_budget::WriteLimits {
                bytes: 8 << 20,
                records: 20_000,
                repeat_percent: 50,
                repeat_floor: 200,
            },
        )
    });

/// Counts `record`, `bytes` on disk, against [`EVENT_LOG_BUDGET`] where budgets count (debug
/// builds, tests, `CMUX_WRITE_BUDGET=1`), and warns once a kind is over.
fn note_write_budget(record: &EventRecord, bytes: usize) {
    if !cmux_tui_platform::write_budget::WriteBudget::enabled() {
        return;
    }
    if let Some(warning) = EVENT_LOG_BUDGET.note(&record.kind, bytes, &record.msg, now_ms()) {
        tracing::warn!("{warning}");
    }
}

/// Cuts the log segment at `path` to `len` bytes, through its own handle opened to write: the
/// writer's handle may only append (Windows grants it `FILE_APPEND_DATA` alone, and a truncate
/// needs `FILE_WRITE_DATA`). The handle gets the same owner-only, no-link checks as every other
/// open of a segment (`journal_store::repair::open_segment_to_write`).
fn cut_back(path: &Path, len: u64) -> Result<()> {
    #[cfg(test)]
    if test_write_fault::take_cut_failure() {
        anyhow::bail!("a failed cut (a test)");
    }
    let file = journal_store::repair::open_segment_to_write(path)?;
    file.set_len(len)?;
    #[cfg(all(test, unix))]
    sync_model::cut(&file, len);
    Ok(())
}

/// Cuts a segment opened for appending back to its last whole line and returns its length
/// after. Every record is written with its newline, so bytes after the last one are a torn
/// append (a process killed mid-write, a full disk): left there, the next record would be glued
/// onto them and lost. They never were a record, so nothing kept is cut.
fn cut_torn_tail(file: &File, path: &Path) -> Result<u64> {
    use std::io::{Seek, SeekFrom};
    let len = file.metadata()?.len();
    if len == 0 {
        return Ok(0);
    }
    let mut reader = crate::config::private_state_file(path)?;
    let mut end = len;
    let mut chunk = vec![0u8; 64 * 1024];
    while end > 0 {
        let start = end.saturating_sub(chunk.len() as u64);
        // `end - start` is at most the chunk length, so `get_mut` always finds the part.
        let want = usize::try_from(end - start)?;
        let Some(part) = chunk.get_mut(..want) else {
            anyhow::bail!("torn-tail read of {want} bytes is past its {} byte chunk", chunk.len());
        };
        reader.seek(SeekFrom::Start(start))?;
        reader.read_exact(part)?;
        if let Some(at) = part.iter().rposition(|b| *b == b'\n') {
            end = start + at as u64 + 1;
            break;
        }
        end = start;
    }
    if end < len {
        tracing::warn!(
            path = %path.display(),
            torn = len - end,
            "cutting a torn append from the end of an event log"
        );
        cut_back(path, end)?;
    }
    Ok(end)
}

#[cfg(debug_assertions)]
pub(crate) mod disk_fault;
#[cfg(test)]
pub(crate) mod test_write_fault;

/// [`LocalStore::history_writer`]'s segment `000000`.
struct SegmentZero {
    /// Taken by `commit`.
    file: Option<std::io::BufWriter<File>>,
    tmp: PathBuf,
    path: PathBuf,
    dir: PathBuf,
}

impl HistoryWriter for SegmentZero {
    fn write(&mut self, record: &EventRecord) -> Result<()> {
        let Some(file) = self.file.as_mut() else { anyhow::bail!("history segment committed") };
        serde_json::to_writer(&mut *file, record)?;
        file.write_all(b"\n")?;
        Ok(())
    }
    fn commit(mut self: Box<Self>) -> Result<()> {
        let Some(file) = self.file.take() else { anyhow::bail!("history segment committed") };
        let file = file.into_inner().map_err(|e| anyhow::anyhow!("{e}"))?;
        file.sync_all()?;
        crate::home_fs::rename(&self.tmp, &self.path)?;
        sync_directory(&self.dir)?;
        // `events/`, and the chat's folder, may be new (a fork with no record of its own yet): the
        // folders that name them are synced too, or a power loss could keep the meta that drops the
        // reference and lose the history it now stands for (review of #37020).
        for made in self.dir.ancestors().skip(1).take(2) {
            sync_directory(made)?;
        }
        Ok(())
    }
}

impl Drop for SegmentZero {
    /// One never committed leaves nothing; a committed one was renamed away.
    fn drop(&mut self) {
        let _ = crate::home_fs::remove_file(&self.tmp);
    }
}

impl Store for LocalStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        // No sessions folder yet: no chat. One that is there and does not read is a failed list,
        // never an empty one: an empty list proves every chat gone (`hub/hosts.rs`).
        if !crate::home_fs::try_exists_nofollow(&self.root)? {
            return Ok(Vec::new());
        }
        let root = match crate::home_fs::PrivateDir::open(&self.root) {
            Ok(root) => root,
            Err(error) if is_not_found(&error) => return Ok(Vec::new()),
            Err(error) => return Err(error.context(format!("list {}", self.root.display()))),
        };
        // Only enumeration fails the pass. Entry checks belong to each worker.
        let entries = root.names()?;
        if entries.is_empty() {
            return Ok(Vec::new());
        }
        // Hold the checked store for the pass. Each worker checks only its chats and their
        // events folders, never the same ancestors again.
        let workers = std::thread::available_parallelism().map_or(1, usize::from).min(8);
        std::thread::scope(|scope| {
            let workers: Vec<_> = entries
                .chunks(entries.len().div_ceil(workers))
                .map(|chunk| {
                    let root = &root;
                    scope.spawn(move || {
                        let mut metas = Vec::new();
                        for name in chunk {
                            // One chat that is refused or does not read is left out (and
                            // counted unread), never the reason no chat is listed.
                            match self.list_entry(root, name) {
                                Ok(Some(meta)) => metas.push(meta),
                                Ok(None) => {}
                                Err(e) => {
                                    tracing::warn!(
                                        "skip {}: {e:#}",
                                        root.path().join(name).display()
                                    );
                                    let id = name.to_string_lossy().into_owned();
                                    self.mark_unlisted(&id, true);
                                }
                            }
                        }
                        Ok::<_, anyhow::Error>(metas)
                    })
                })
                .collect();
            let mut metas = Vec::new();
            for worker in workers {
                metas.extend(
                    worker.join().map_err(|_| anyhow::anyhow!("store list worker failed"))??,
                );
            }
            Ok(metas)
        })
    }

    fn unlisted(&self) -> Vec<String> {
        let unlisted = self.unlisted.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        unlisted.iter().cloned().collect()
    }

    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        // An absent chat needs only search access, before opening folders for reading.
        if !crate::home_fs::try_exists_nofollow(self.dir(id))? {
            return Ok(None);
        }
        let root = match crate::home_fs::PrivateDir::open(&self.root) {
            Err(error) if is_not_found(&error) => return Ok(None),
            other => other?,
        };
        let held = match self.validate_session_dir(&root, std::ffi::OsStr::new(id)) {
            Err(error) if is_not_found(&error) => return Ok(None),
            other => other?,
        };
        let file = match held.private_file(std::ffi::OsStr::new("session.json")) {
            Err(error) if is_not_found(&error) => return Ok(None),
            other => other?,
        };
        let mut text = String::new();
        BufReader::new(file).read_to_string(&mut text)?;
        let mut meta: SessionMeta = serde_json::from_str(&text)?;
        self.parts.merge_held(&held, text.as_bytes(), &mut meta);
        Ok(Some(meta))
    }

    fn load_startup(&self, id: &str) -> Result<Option<SessionMeta>> {
        let Some(meta) = self.load(id)? else { return Ok(None) };
        if self.purged_startup_entry(id, meta.status)? {
            return Ok(None);
        }
        Ok(Some(meta))
    }

    fn save(&self, meta: &SessionMeta) -> Result<()> {
        #[cfg(test)]
        self.meta_saves.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let _open = self.writable()?;
        let dir = self.dir(&meta.id);
        crate::config::private_state_dir(&dir)?;
        // The large fields only when they changed (`store/meta_parts.rs`), then the rest.
        let parts = self.parts.write(&dir, meta)?;
        let text = meta_parts::to_string_pretty(meta, &parts)?;
        meta_parts::note_written(text.len());
        write_atomic(&dir.join("session.json"), text.as_bytes())
    }

    fn flush_session(&self, id: &str) -> Result<()> {
        let writers = self.writers.lock_or_recover();
        if let Some(writer) = writers.open.get(id) {
            log_sync::sync_segment(writer.file(), true).map_err(SyncFailed)?;
        }
        let session = self.dir(id);
        sync_directory(&session.join("events"))?;
        sync_directory(&session)?;
        sync_directory(&self.root)?;
        Ok(())
    }

    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut line = serde_json::to_string(record)?;
        line.push('\n');
        note_write_budget(record, line.len());
        self.append_line(id, line.as_bytes())
    }

    fn read_log(
        &self,
        id: &str,
        from: u64,
        filter: LogFilter<'_>,
        stamp: u64,
        marks: &mut LogMarks,
        out: &mut Vec<u8>,
    ) -> Result<LogChunk> {
        self.read_log_bytes(id, from, filter, stamp, marks, out)
    }

    fn read_log_part(
        &self,
        id: &str,
        seq: u64,
        offset: u64,
        max: usize,
        stamp: u64,
        marks: &mut LogMarks,
        out: &mut Vec<u8>,
    ) -> Result<LogPart> {
        self.read_log_part_bytes(id, seq, offset, max, stamp, marks, out)
    }

    fn log_stamp(&self, id: &str) -> Result<u64> {
        self.read_stamp(id)
    }

    fn bump_log_stamp(&self, id: &str, by: u64) -> Result<()> {
        self.bump_stamp(id, by)
    }

    fn writes_history(&self) -> bool {
        true
    }

    /// Segment `000000`, written beside the log under a temporary name and renamed in whole.
    fn history_writer(&self, id: &str) -> Result<Option<Box<dyn HistoryWriter + '_>>> {
        // An archived log comes back before a segment is written beside it.
        self.rehydrate(id)?;
        #[cfg(test)]
        log_sync::hold(&cold::HOLD_AFTER_HISTORY_REHYDRATE);
        let _open = self.writable()?;
        let dir = self.dir(id).join("events");
        crate::config::private_state_dir(&self.dir(id))?;
        crate::config::private_state_dir(&dir)?;
        let path = dir.join("000000.ndjson");
        let tmp = dir.join("000000.ndjson.history");
        let _ = crate::home_fs::remove_file(&tmp);
        let file = std::io::BufWriter::with_capacity(256 * 1024, open_private_append(&tmp)?);
        Ok(Some(Box::new(SegmentZero { file: Some(file), tmp, path, dir })))
    }

    /// Reads only past `after`: a segment whose successor starts at or before `after + 1`
    /// holds nothing past it and is not opened, and a line at or before `after` is passed
    /// on its `seq` alone, unparsed. A forward page of a long log costs its own records,
    /// not the log's prefix (perf100: a 70 MB log read in 10,000-record pages parsed
    /// every earlier record again on each page).
    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        self.scan_lines(id, after, false, None, visit)
    }

    fn scan_matching(
        &self,
        id: &str,
        after: u64,
        may_match: &dyn Fn(&[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_lines(id, after, false, Some(may_match), visit)
    }

    fn scan_strict(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_lines(id, after, true, None, visit)
    }

    /// Reads from `hint` when the line there holds `from` (an adoption's checkpoint: no byte
    /// before it), else from the start of the segment that holds `from`, passing the lines
    /// before `from` on their `seq` alone.
    fn scan_heads_from(
        &self,
        id: &str,
        from: u64,
        hint: Option<LinePos>,
        visit: &mut dyn FnMut(&RecordHead<'_>, Option<LinePos>) -> bool,
    ) -> Result<()> {
        use std::io::{Seek, SeekFrom};
        let segments = self.segments(id)?;
        let mut line = Vec::new();
        let hinted = hint.and_then(|h| {
            let (index, (_, path)) =
                segments.iter().enumerate().find(|(_, (n, _))| *n == h.segment)?;
            let mut reader =
                BufReader::with_capacity(64 * 1024, crate::config::private_state_file(path).ok()?);
            reader.seek(SeekFrom::Start(h.offset)).ok()?;
            line.clear();
            reader.read_until(b'\n', &mut line).ok()?;
            (record_seq(&line) == Some(from)).then_some((index, h.offset, reader))
        });
        let (start, mut first) = match hinted {
            Some((index, offset, reader)) => (index, Some((offset, reader))),
            None => (self.segment_starts.start(id, &segments, from.saturating_sub(1))?, None),
        };
        for (index, path) in segments.get(start..).unwrap_or_default() {
            let (mut pos, mut reader) = match first.take() {
                Some((offset, reader)) => (offset, reader),
                None => {
                    line.clear();
                    let file = crate::config::private_state_file(path)?;
                    (0, BufReader::with_capacity(256 * 1024, file))
                }
            };
            loop {
                // The hinted line was read already.
                let n =
                    if line.is_empty() { reader.read_until(b'\n', &mut line)? } else { line.len() };
                if n == 0 {
                    break;
                }
                let at = LinePos { segment: *index, offset: pos };
                pos += n as u64;
                let more = if line.iter().all(u8::is_ascii_whitespace)
                    || record_seq(&line).is_some_and(|seq| seq < from)
                {
                    true
                } else {
                    match RecordHead::read(&line) {
                        Some(head) => visit(&head, Some(at)),
                        None => match parse_record(&line) {
                            Ok(rec) if rec.seq >= from => {
                                visit(&RecordHead::parsed(&rec), Some(at))
                            }
                            _ => true,
                        },
                    }
                };
                line.clear();
                if !more {
                    return Ok(());
                }
            }
        }
        Ok(())
    }

    /// None once the log was compacted since it was saved: a compaction cuts records' strings
    /// in place (`store/compact.rs`), which a fold of them would read differently. The file's
    /// first line is the digest of the compaction marker it was saved under.
    fn adoption_checkpoint(&self, id: &str) -> Option<Vec<u8>> {
        let bytes = held_file_bytes(&self.dir(id).join(ADOPTION_CHECKPOINT))?;
        let nl = bytes.iter().position(|&b| b == b'\n')?;
        let (head, body) = bytes.split_at(nl);
        (head == self.compaction_digest(id).as_bytes())
            .then(|| body.get(1..).unwrap_or_default().to_vec())
    }

    fn save_adoption_checkpoint(&self, id: &str, bytes: &[u8]) -> Result<()> {
        let _open = self.writable()?;
        let dir = self.dir(id);
        // As `save_restore_point`: a chat whose folder went away gets no file of its own again.
        let folder = crate::home_fs::symlink_metadata(&dir).is_ok_and(|m| m.file_type().is_dir());
        anyhow::ensure!(folder, "no folder for {id}");
        let mut file = self.compaction_digest(id).into_bytes();
        file.push(b'\n');
        file.extend_from_slice(bytes);
        write_atomic(&dir.join(ADOPTION_CHECKPOINT), &file)
    }

    /// Reads each line's head (`RecordHead::read`) and parses only the lines the reader asks
    /// for, or a line whose head does not read.
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        let mut line = Vec::new();
        let mut pass = crate::perf_watch::LogPass::start(id, true);
        for (_, path) in self.segments(id)? {
            let mut reader =
                BufReader::with_capacity(256 * 1024, cold_segments::open_segment(&path)?);
            loop {
                line.clear();
                if reader.read_until(b'\n', &mut line)? == 0 {
                    break;
                }
                crate::perf_watch::LogPass::line(&mut pass, line.len());
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                let more = match RecordHead::read(&line) {
                    Some(head) => visit(&head),
                    None => {
                        let Ok(rec) = parse_record(&line) else { continue };
                        visit(&RecordHead::parsed(&rec))
                    }
                };
                if !more {
                    return Ok(());
                }
            }
        }
        Ok(())
    }

    fn tail_after(&self, id: &str, after: u64) -> Result<(u64, u64)> {
        let mut count = 0;
        let mut last = after;
        let mut done = false;
        for (_, path) in self.segments(id)?.into_iter().rev() {
            for_each_line_rev(&path, &mut |line| {
                let Ok(rec) = serde_json::from_slice::<EventRecord>(line) else { return true };
                if rec.seq <= after {
                    done = true;
                    return false;
                }
                count += 1;
                last = last.max(rec.seq);
                true
            })?;
            if done {
                break;
            }
        }
        Ok((count, last))
    }

    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_in(id, kinds, false, visit)
    }

    fn scan_kinds_strict(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_in(id, kinds, true, visit)
    }

    /// Back from the end of the records before `before`, segment by segment, reading each line's
    /// seq from its first bytes: no line is parsed but one whose header does not read.
    fn newest_window(&self, id: &str, before: u64, n: u64) -> Result<NewestWindow> {
        let mut window = NewestWindow::default();
        let mut seen = 0u64;
        let mut done = false;
        for (_, path) in self.segments(id)?.into_iter().rev() {
            if first_seq(&path)?.is_some_and(|first| first >= before) {
                continue;
            }
            let mut file = crate::config::private_state_file(&path)?;
            let end = offset_of_seq(&mut file, before)?;
            for_each_line_rev_from(&mut file, end, &mut |line| {
                let Some(seq) = record_seq(line).or_else(|| parse_record(line).ok().map(|r| r.seq))
                else {
                    return true;
                };
                if seq >= before {
                    return true;
                }
                window.newest = window.newest.max(seq);
                seen += 1;
                if seen > n {
                    window.after = seq;
                    done = true;
                    return false;
                }
                true
            })?;
            if done {
                break;
            }
        }
        Ok(window)
    }

    /// Through the copies of the kinds (`store/kind_index.rs`), past `after`: a scan of the log
    /// from the segment that holds `after + 1` parses that whole segment, for each fold of a
    /// load, and read more than the copies do (`a_restored_chats_log_load_reads_the_copies_not_its_log`).
    /// Only the copies from the segment that holds `after + 1` on (`scan_kinds_past`).
    fn scan_kinds_after(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_past(id, after, kinds, false, visit)
    }

    fn scan_kinds_after_strict(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_past(id, after, kinds, true, visit)
    }

    fn scan_kinds_keyed(
        &self,
        id: &str,
        kinds: &[&str],
        keep: &mut dyn FnMut(&KindHead<'_>) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_keyed_in(id, kinds, keep, visit)
    }

    fn restore_point(&self, id: &str) -> Option<Vec<u8>> {
        std::fs::read(self.dir(id).join(RESTORE_POINT)).ok()
    }

    fn save_restore_point(&self, id: &str, bytes: &[u8]) -> Result<()> {
        let _open = self.writable()?;
        let dir = self.dir(id);
        // A chat whose folder went away (a delete) gets no file of its own again. Read in the
        // held home, never by path (#41721 review F1).
        let folder = crate::home_fs::symlink_metadata(&dir).is_ok_and(|m| m.file_type().is_dir());
        anyhow::ensure!(folder, "no folder for {id}");
        write_atomic(&dir.join(RESTORE_POINT), bytes)
    }

    fn text_entries(
        &self,
        id: &str,
        visit: &mut dyn FnMut(crate::session_search::Entry),
    ) -> Result<()> {
        self.text_entries_in(id, visit)
    }

    fn search_records(&self, id: &str, visit: &mut dyn FnMut(EventRecord)) -> Result<()> {
        if self.is_cold(id) {
            self.cold_search_records(id, visit)
        } else {
            self.scan_kinds(id, crate::session_search::KINDS, &mut |rec| {
                visit(rec);
                true
            })
        }
    }

    /// Segments newest first, so a page from the end reads only the segments it
    /// needs however long the log is. A segment whose first record is at or past
    /// `before` holds nothing for the page and is skipped after one line.
    /// Reads backwards from the end of the records before `before` only: the
    /// segment is read in blocks from the offset where `before` starts (found
    /// by a search on the line headers), never whole, and a line `skip` names,
    /// or one at or past `before`, is passed on its header unparsed. A page
    /// costs its own bytes, not its segment's (perf100: every older page of a
    /// scroll to the first message read and parsed its whole 8 MiB segment,
    /// and opening a chat read the log once for each of its three reads).
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_back_in(id, after, before, skip, visit, false)
    }

    fn scan_back_indexed(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_back_in(id, after, before, skip, visit, true)
    }

    fn flush(&self) -> Result<()> {
        for w in self.writers.lock_or_recover().open.values() {
            log_sync::sync_segment(w.file(), false)?;
        }
        Ok(())
    }

    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        let mut out = Vec::new();
        self.scan(id, after, &mut |rec| {
            out.push(rec);
            out.len() < limit
        })?;
        Ok(out)
    }

    fn close_log(&self, id: &str) {
        let mut writers = self.writers.lock_or_recover();
        self.close_writer_locked(id, &mut writers);
    }

    fn compacted_seq(&self, id: &str) -> Option<u64> {
        LocalStore::compacted_seq(self, id)
    }

    fn log_written_at(&self, id: &str) -> Option<u64> {
        LocalStore::log_written_at(self, id)
    }

    fn stage_compaction(&self, id: &str, mode: CompactMode) -> Result<Option<Staged>> {
        // Not under the seal: staging writes only copies beside the log, and a large log's
        // stage would hold a shutdown's seal for as long as it reads (router review of #28503).
        // The commit that puts them in place is sealed.
        LocalStore::stage_compaction(self, id, mode)
    }

    fn commit_compaction(&self, id: &str, staged: Staged) -> Result<bool> {
        let _open = self.writable()?;
        LocalStore::commit_compaction(self, id, staged)
    }

    fn stage_cold(&self, id: &str) -> Result<Option<StagedCold>> {
        LocalStore::stage_cold(self, id)
    }

    fn commit_cold(&self, id: &str, staged: StagedCold) -> Result<bool> {
        let _open = self.writable()?;
        LocalStore::commit_cold(self, id, staged)
    }

    fn rehydrate(&self, id: &str) -> Result<bool> {
        LocalStore::rehydrate(self, id)
    }

    fn is_cold(&self, id: &str) -> bool {
        LocalStore::is_cold(self, id)
    }

    fn offload_cold(&self, id: &str) -> Result<Option<u64>> {
        let _open = self.writable()?;
        LocalStore::offload_cold(self, id)
    }

    fn register_cloud_root(&self) -> Result<Option<usize>> {
        LocalStore::register_cloud_root(self)
    }

    fn on_rehydrate(&self, hook: RehydrateHook) {
        let _ = self.rehydrate_hook.set(hook);
    }

    fn stage_cold_segments(
        &self,
        id: &str,
        max: usize,
        level: i32,
    ) -> Result<Option<StagedColdSegments>> {
        LocalStore::stage_cold_segments(self, id, max, level)
    }

    fn prepare_cold_segments(&self, _id: &str, _staged: &StagedColdSegments) -> Result<bool> {
        Ok(true)
    }

    fn commit_cold_segments(&self, id: &str, staged: StagedColdSegments) -> Result<ColdMoved> {
        LocalStore::commit_cold_segments(self, id, staged)
    }

    fn settle_cold_segments(&self, id: &str) -> Result<()> {
        LocalStore::settle_cold_segments(self, id)
    }

    fn warm_cold_segments(&self, id: &str) -> Result<ColdWarmed> {
        LocalStore::warm_cold_segments(self, id)
    }

    fn on_segment_sealed(&self, hook: SealHook) {
        let _ = self.seal_hook.set(hook);
    }

    fn on_log_grown(&self, hook: SealHook) {
        let _ = self.grow_hook.set(hook);
    }

    fn seal(&self) {
        *self.sealed.write().unwrap_or_else(std::sync::PoisonError::into_inner) = true;
    }

    /// `<id>/parked.json`, beside the chat's `events/`: written whole by a rename, its file and
    /// folder synced before it answers. Never makes the chat's folder: a purged chat keeps none.
    fn keep_parked(&self, id: &str, kept: Option<&[u8]>) -> Result<()> {
        let _open = self.writable()?;
        let path = self.dir(id).join(PARKED);
        match kept {
            Some(bytes) => compact::write_durably(&path, bytes),
            None => match crate::home_fs::remove_file(&path) {
                Ok(()) => sync_directory(&self.dir(id)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e).with_context(|| format!("remove {}", path.display())),
            },
        }
    }

    fn kept_parked(&self, id: &str) -> Result<Option<Vec<u8>>> {
        #[cfg(test)]
        if fails_kept_read(id) {
            anyhow::bail!("a test failed this read of {id}'s kept records");
        }
        let path = self.dir(id).join(PARKED);
        match crate::config::private_state_file(&path) {
            Ok(file) => {
                let mut bytes = Vec::new();
                BufReader::new(file).read_to_end(&mut bytes)?;
                Ok(Some(bytes))
            }
            Err(_) if crate::home_fs::symlink_metadata(&path).is_err() => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// `<id>/held/<slot>.json`, beside the chat's `events/`: written whole by a rename, not
    /// synced (a kill keeps what the kernel was given). Never makes the chat's folder: a deleted
    /// chat gets no file of its own again.
    fn keep_held(&self, id: &str, slot: &str, held: Option<&[u8]>) -> Result<()> {
        anyhow::ensure!(deferred::is_slot(slot), "{slot:?} names no held slot");
        let _open = self.writable()?;
        let dir = self.dir(id).join(HELD);
        let path = dir.join(format!("{slot}.json"));
        match held {
            Some(bytes) => {
                // `held/` alone, never its parent: whenever a delete removed the chat's folder,
                // this fails. Read in the held home, never by path (#41721 review F1).
                if crate::home_fs::symlink_metadata(&dir).is_err() {
                    match crate::home_fs::create_dir(&dir, 0o700) {
                        Ok(()) => {}
                        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(e) => {
                            return Err(e).with_context(|| format!("create {}", dir.display()));
                        }
                    }
                }
                crate::config::write_atomic_unsynced(&path, bytes)
            }
            None => match crate::home_fs::remove_file(&path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e).with_context(|| format!("remove {}", path.display())),
            },
        }
    }

    /// Every `<slot>.json` in `<id>/held/`; none without the folder. A copy a write left (named
    /// `<slot>.tmp-<pid>`) is no slot's.
    fn kept_held(&self, id: &str) -> Result<Vec<(String, Vec<u8>)>> {
        let dir = self.dir(id).join(HELD);
        let entries = match crate::home_fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e).with_context(|| format!("list {}", dir.display())),
        };
        let mut out = Vec::new();
        for entry in entries {
            let name = entry.name.to_str().and_then(|n| n.strip_suffix(".json"));
            let Some(slot) = name.filter(|s| entry.is_file && deferred::is_slot(s)) else {
                continue;
            };
            let mut bytes = Vec::new();
            crate::home_fs::private_state_file(dir.join(&entry.name))?.read_to_end(&mut bytes)?;
            out.push((slot.to_owned(), bytes));
        }
        Ok(out)
    }

    fn delete(&self, id: &str) -> Result<()> {
        let _open = self.writable()?;
        if let Some(w) = self.writers.lock_or_recover().open.remove(id) {
            w.retire();
        }
        self.kind_heads.forget(id);
        self.kind_index_checks.forget(id);
        self.segment_starts.forget(id);
        self.segment_table.forget(id);
        let dir = self.dir(id);
        // macOS returns ENOTEMPTY when a file lands mid-removal; retry briefly.
        let mut last = None;
        for _ in 0..5 {
            if !crate::home_fs::try_exists_nofollow(&dir)? {
                return Ok(());
            }
            match crate::home_fs::remove_dir_all(&dir) {
                Ok(()) => return Ok(()),
                Err(e) => {
                    last = Some(e);
                    std::thread::sleep(std::time::Duration::from_millis(40));
                }
            }
        }
        match last {
            Some(e) => Err(e.into()),
            None => Ok(()),
        }
    }

    fn session_dir(&self, id: &str) -> Option<PathBuf> {
        Some(self.dir(id))
    }

    fn handoff_dir(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("handoffs"))
    }

    fn peer_cache_dir(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("peers"))
    }

    fn briefs_path(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("briefs.json"))
    }

    fn audit_dir(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("audit"))
    }
}

/// Sync a directory entry after a file or subdirectory was created or replaced.
#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<()> {
    #[cfg(test)]
    if log_sync::fail_dir_sync(path) {
        return Err(SyncFailed(std::io::Error::other("a failed folder sync (a test)")).into());
    }
    // The folder the held home has at `path` (`home_fs`), the one a rename through it changed.
    let dir = crate::home_fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)?;
    log_sync::sync_full(&dir).map_err(SyncFailed)?;
    #[cfg(test)]
    sync_model::folder_synced(path);
    Ok(())
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<()> {
    Ok(())
}

/// Open one event segment for append, owner-only from creation and after an
/// older build left it with wider permissions.
#[cfg(unix)]
pub(crate) fn open_private_append(path: &Path) -> Result<File> {
    use std::os::unix::fs::PermissionsExt;
    crate::config::refuse_lost_home(path)?;

    // Through the folder this daemon holds (`home_fs`): a home replaced after the check never
    // gets the segment.
    let file = crate::home_fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    if file.metadata()?.permissions().mode() & 0o077 != 0 {
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(file)
}

#[cfg(windows)]
pub(crate) fn open_private_append(path: &Path) -> Result<File> {
    crate::config::refuse_lost_home(path)?;
    Ok(crate::owner_only::open_append(path)?)
}

#[cfg(all(test, unix))]
mod permission_tests;

#[cfg(test)]
mod torn_tail_tests;

#[cfg(all(test, unix))]
mod list_entry_tests;

#[cfg(all(test, unix))]
mod line_rev_tests;

#[cfg(test)]
mod agent_session_history_tests;

fn is_zero(v: &u64) -> bool {
    *v == 0
}

#[cfg(test)]
mod head_tests;
#[cfg(test)]
mod no_rolling_summary_tests;

#[cfg(all(test, unix))]
mod journal_meta_tests;
#[cfg(all(test, unix))]
mod journal_pause_tests;
#[cfg(all(test, unix))]
mod journal_store_tests;
#[cfg(all(test, unix))]
mod journal_sync_tests;
#[cfg(all(test, unix))]
mod journal_write_back_tests;

#[cfg(test)]
mod torn_append_tests;

#[cfg(test)]
mod held_home_reads_tests;

impl LocalStore {
    /// `Store::scan`, and with `strict` `Store::scan_strict`.
    fn scan_lines(
        &self,
        id: &str,
        after: u64,
        strict: bool,
        may_match: Option<&dyn Fn(&[u8]) -> bool>,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        // A strict read learns that the log's segments could not be listed (`segments` lists
        // none then).
        if strict {
            self.rehydrate(id)?;
            std::fs::read_dir(self.dir(id).join("events"))?;
        }
        let segments = self.segments(id)?;
        let mut line = Vec::new();
        let mut pass = crate::perf_watch::LogPass::start(id, after == 0);
        // The segment that holds `after + 1`, found from the segments' kept first seqs: the read
        // opens only the segments it reads (`store/segment_starts.rs`).
        let start = self.segment_starts.start(id, &segments, after)?;
        for (_, path) in &segments[start..] {
            let mut reader =
                BufReader::with_capacity(256 * 1024, cold_segments::open_segment(path)?);
            loop {
                line.clear();
                if reader.read_until(b'\n', &mut line)? == 0 {
                    break;
                }
                crate::perf_watch::LogPass::line(&mut pass, line.len());
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                if record_seq(&line).is_some_and(|seq| seq <= after) {
                    continue;
                }
                if may_match.is_some_and(|may_match| !may_match(&line)) {
                    continue;
                }
                let rec = match parse_record(&line) {
                    Ok(rec) => rec,
                    Err(e) if strict => {
                        anyhow::bail!("{}: a record could not be read: {e}", path.display())
                    }
                    Err(_) => continue,
                };
                if rec.seq > after && !visit(rec) {
                    return Ok(());
                }
            }
        }
        Ok(())
    }
}

#[cfg(all(test, unix))]
#[path = "store/startup_tests.rs"]
mod startup_tests;

/// Tests only: the chat whose next commit (`compact.rs` `commit_compaction`) fails once its
/// segments are in place, before its record says it is complete, as a failed write of that
/// record does: the log is the shorter one already, and the call fails (review of #37284 at
/// fd33a65b, F2).
#[cfg(test)]
static FAIL_BEFORE_MARKER: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// Tests only: arms [`FAIL_BEFORE_MARKER`] for chat `id`, once.
#[cfg(test)]
pub(crate) fn fail_before_marker_once(id: &str) {
    FAIL_BEFORE_MARKER.lock().unwrap_or_else(|e| e.into_inner()).push(id.to_owned());
}

/// Tests only: what runs once a commit of chat `id`'s staged log (`compact.rs`
/// `commit_compaction`) replaced its first segment, before its second: a crash there, as a test
/// copies what the disk holds then (review of #37284 at b7496c3f, F2).
#[cfg(test)]
type Crash = Box<dyn FnOnce() + Send>;

// test-hook-allow: armed per chat id, and only that chat's run takes it
#[cfg(test)]
static BETWEEN_SEGMENTS: std::sync::Mutex<Vec<(String, Crash)>> = std::sync::Mutex::new(Vec::new());

/// Tests only: arms [`BETWEEN_SEGMENTS`] for chat `id`, once. The hook is process-wide and tests
/// run in parallel: `id` is a chat no other test uses, or another test's commit takes the crash.
#[cfg(test)]
pub(crate) fn between_segments_once(id: &str, crash: Crash) {
    BETWEEN_SEGMENTS.lock().unwrap_or_else(|e| e.into_inner()).push((id.to_owned(), crash));
}

/// Runs [`between_segments_once`]'s crash of chat `id`, on the committing thread.
#[cfg(test)]
fn between_segments(id: &str) {
    let crash = {
        let mut armed = BETWEEN_SEGMENTS.lock().unwrap_or_else(|e| e.into_inner());
        let at = armed.iter().position(|(at, _)| at == id);
        at.map(|at| armed.swap_remove(at).1)
    };
    if let Some(crash) = crash {
        crash();
    }
}

/// Tests only: the chats whose reads of their kept records (`parked.json`, `Store::kept_parked`)
/// fail, as a transient read error does, until [`kept_reads_again`] (review of #37284 at
/// 23e76b07, F2). Per chat: tests run at once.
#[cfg(test)]
static FAIL_KEPT_READ: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// Tests only: every read of chat `id`'s kept records fails from now ([`FAIL_KEPT_READ`]).
#[cfg(test)]
pub(crate) fn fail_kept_reads(id: &str) {
    FAIL_KEPT_READ.lock().unwrap_or_else(|e| e.into_inner()).push(id.to_owned());
}

/// Tests only: chat `id`'s kept records read again.
#[cfg(test)]
pub(crate) fn kept_reads_again(id: &str) {
    FAIL_KEPT_READ.lock().unwrap_or_else(|e| e.into_inner()).retain(|a| a != id);
}

#[cfg(test)]
fn fails_kept_read(id: &str) -> bool {
    FAIL_KEPT_READ.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|a| a == id)
}

#[cfg(test)]
fn fails_before_marker(id: &str) -> bool {
    let mut armed = FAIL_BEFORE_MARKER.lock().unwrap_or_else(|e| e.into_inner());
    let at = armed.iter().position(|a| a == id);
    at.map(|at| armed.swap_remove(at)).is_some()
}
