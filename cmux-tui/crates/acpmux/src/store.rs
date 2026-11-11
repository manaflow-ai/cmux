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
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

mod compact;
pub use compact::{CompactMode, Compaction, Staged};
mod deferred;
pub use deferred::{Deferral, Keep};
mod cold;
pub use cold::{COLD_FILE, ColdStats, RehydrateHook, StagedCold};
mod superseded;
pub use superseded::{Superseded, starts_prompt};
mod kind_index;
pub use kind_index::{DIR as KIND_INDEX_DIR, INDEXED_KINDS};
mod fork_view;
pub use fork_view::{
    ForkView, HISTORY_KINDS, HistoryFence, HistoryRef, HistoryWriter, fence_history,
    folder_to_replace,
};
mod meta_parts;
pub use meta_parts::PARTS_FILE;
mod shared_value;
mod text_index;
pub use shared_value::SharedValue;

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

impl std::fmt::Display for SessionStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::Idle => "idle",
            Self::Ready => "ready",
            Self::Running => "running",
            Self::Waiting => "waiting",
            Self::Disconnected => "disconnected",
            Self::Closed => "closed",
        };
        f.write_str(s)
    }
}

/// What a watched chat follows (`hub/watch.rs`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

/// Reserved before creating a child; retained even if the child is purged.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ForkRequest {
    pub prompt_id: String,
    pub child_id: String,
}

/// A person's return to a chat that kept working (`hub/seen.rs`): the log seq they had seen when
/// they left, and how many turns ended while nobody showed it.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, schemars::JsonSchema)]
pub struct LastReturn {
    pub since: u64,
    pub turns: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionMeta {
    pub schema: String,
    pub id: String,
    pub name: String,
    /// Someone gave `name` (at the start, a fork's or a rename), not the daemon's `HARNESS-N`
    /// default (`hub/new_request.rs` `unique_name_among`). False in a log from before it was kept.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub name_given: bool,
    #[serde(alias = "harness")]
    pub harness: String,
    #[serde(default, alias = "agent_argv")]
    pub harness_argv: Vec<String>,
    /// The argv its agent last started with: a config or preset reload since creation can change
    /// it (`harness_argv` is the creation's). None before any start (#23322, review 36).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spawn_argv: Option<Vec<String>>,
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
    pub cwd: PathBuf,
    /// Folders the chat sees beside `cwd` (ACP `session/new` `additionalDirectories`, its
    /// Sources): every start of its harness gets them (`hub/additional_dirs.rs`). Absolute,
    /// canonical, each once, never `cwd` itself.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub additional_directories: Vec<PathBuf>,
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
    pub available_commands: Option<Value>,
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
    /// The Claude conversation acpmux started with a fresh id has not
    /// finished a turn, so Claude may never have stored it (a launcher that
    /// died before the prompt reached Claude stores nothing). A respawn (a
    /// fallback profile, a dead process, a daemon restart) then starts a
    /// fresh conversation instead of `--resume`, which would fail the turn
    /// with "No conversation found with session ID".
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub claude_unstored: bool,
    /// Its creator asked every start of its agent to wait on the harness rather than a wall
    /// clock (`_meta.acpmux.waitStart`, `Session::wait_start`; the Chief's own sessions). Kept on
    /// disk, so a wake after hibernation or a daemon restart waits as its first start did: on
    /// 2026-11-04 a kept Chief session that woke after a restart died at the 90 s deadline again.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub wait_start: bool,
    /// When (Unix ms) the idle exit hibernated its agent, 0 when no start woke it since
    /// (`hub/idle.rs`): after a restart, opening it wakes it and its wake draws no row, as
    /// before the restart, and the wake's log says how long it slept.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub hibernated_ms: u64,
    /// What the idle census knew of its hosted harness's MCP servers, for the next daemon that
    /// adopts that host (`hub/idle_census.rs`, `StoredLaunch`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_launch: Option<crate::hub::StoredLaunch>,
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
    /// The pull requests this session's `gh pr create` calls printed (`hub/pull_requests.rs`),
    /// once each, oldest first. A fork starts with none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pull_requests: Vec<String>,
    /// When each of `pull_requests` was opened (Unix ms), by URL: the review queue's window
    /// counts from it (`hub/review_queue.rs`). One without a time (a meta written before this
    /// field) counts from the session's creation. A fork starts with none.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub pull_request_times: BTreeMap<String, u64>,
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
    pub races: std::sync::Arc<Vec<crate::hub::races::Race>>,
    /// The plan builds started from this chat's plan approvals (`hub/plan_build.rs`): set by
    /// acpmux alone, never from a request. Shared as `races` is.
    #[serde(default, skip_serializing_if = "crate::hub::plan_build::no_records")]
    pub plan_builds: std::sync::Arc<Vec<crate::hub::plan_build::PlanBuildRecord>>,
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
    pub rows: Vec<ToolRow>,
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
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
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
#[cfg(test)]
pub(crate) mod test_clock {
    use std::cell::Cell;

    thread_local!(static AHEAD_MS: Cell<u64> = const { Cell::new(0) });
    thread_local!(static FOLLOW: Cell<Option<tokio::time::Instant>> = const { Cell::new(None) });

    pub(crate) fn ahead_ms() -> u64 {
        let followed = FOLLOW.with(Cell::get).map_or(0, |origin| origin.elapsed().as_millis());
        AHEAD_MS.with(Cell::get) + followed as u64
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
        FOLLOW.with(|f| f.set(Some(tokio::time::Instant::now())));
    }

    /// Back to the real wall clock.
    pub(crate) fn reset() {
        AHEAD_MS.with(|a| a.set(0));
        FOLLOW.with(|f| f.set(None));
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
    /// `scan` from the start, passing each record's head ([`RecordHead`]) until `visit` returns
    /// false; the reader parses only the records it needs (`RecordHead::record`). A file store
    /// reads a head without parsing its line: adopting a host after a restart reads its whole
    /// log four times, and parsing every line held big-red's daemon at a full core for minutes.
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        self.scan(id, 0, &mut |rec| visit(&RecordHead::parsed(&rec)))
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
    /// Called with a chat's id each time its log comes back from its cold archive, on any path
    /// (a read, an append, a fork's history): the hub drops the chat's preview
    /// (`hub/cold_archive.rs`). Called inside the store's own locks: it must take none of its
    /// own that a store caller may hold. Set once.
    fn on_rehydrate(&self, _hook: RehydrateHook) {}
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

mod log_line;
pub use log_line::RecordHead;

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
pub use durability::{Durability, ShowAfter};
pub(crate) use durability::{RecordClass, record_class, streamed};
mod journal_store;
#[cfg(test)]
pub(crate) use journal_store::open_with_journal;
mod log_sync;
pub mod open_logs;
#[cfg(test)]
pub(crate) use journal_store::pause_next_log_write_on_this_thread;
pub(crate) use log_sync::SyncFailed;
#[cfg(all(test, unix))]
mod sync_model;

mod memory;
pub use memory::MemoryStore;

// ----------------------------------------------------------------- local

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
    /// Held by a cold archive's commit and by a rehydrate (`store/cold.rs`), always after the
    /// writers' lock when both are taken: two reads of an archived chat rehydrate it once.
    cold: Mutex<()>,
    /// [`Store::on_rehydrate`].
    rehydrate_hook: std::sync::OnceLock<RehydrateHook>,
    /// The parts files written or read (`store/meta_parts.rs`).
    parts: meta_parts::PartsMemo,
}

/// The logs held open, at most `LocalStore::open_logs` (`store/open_logs.rs`): the least
/// recently written one is closed for a new one.
#[derive(Default)]
struct Writers {
    open: HashMap<String, SegmentWriter>,
    /// Counts appends; a writer's `used` is the count at its last one.
    clock: u64,
}

struct SegmentWriter {
    index: u32,
    file: File,
    written: u64,
    used: u64,
}

impl SegmentWriter {
    /// Closes the log, durable first as `flush` would have made it. Called under the
    /// writers' lock, so the cache never holds more than `open_logs` and a session's
    /// records stay in order. A failed sync is logged and noted in `failed`: its records were
    /// written (an append is never synced on its own), so only a machine crash before the kernel
    /// writes them back loses them, as it would any append since the last `flush`.
    fn close(self, id: &str, failed: &std::sync::atomic::AtomicBool) {
        if let Err(e) = log_sync::sync_segment(&self.file, false) {
            #[cfg(test)]
            log_sync::hold(&log_sync::HOLD_BEFORE_CLOSE_NOTE);
            failed.store(true, std::sync::atomic::Ordering::SeqCst);
            tracing::warn!(session = %id, "sync event log on close: {e}");
        }
    }
}

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
            rehydrate_hook: Default::default(),
            parts: Default::default(),
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

    /// The log's segments, oldest first. A cold-archived chat's log is rehydrated first
    /// (`store/cold.rs`): only a chat with no segment pays for the look, one `lstat` and a second
    /// listing. The listing is taken again whatever `rehydrate` answers: another thread's
    /// rehydrate may have put the log back since the first, and this one then answers false
    /// (review of #39141: an append went on in `000001` of a log that ran on past it).
    fn segments(&self, id: &str) -> Result<Vec<(u32, PathBuf)>> {
        let segments = self.segment_files(id)?;
        if segments.is_empty() {
            self.rehydrate(id)?;
            return self.segment_files(id);
        }
        Ok(segments)
    }

    /// The segments on the disk now, never rehydrated.
    fn segment_files(&self, id: &str) -> Result<Vec<(u32, PathBuf)>> {
        let dir = self.dir(id).join("events");
        let mut out = Vec::new();
        let Ok(rd) = std::fs::read_dir(&dir) else {
            return Ok(out);
        };
        for entry in rd {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if let Some(stem) = name.strip_suffix(".ndjson")
                && let Ok(idx) = stem.parse::<u32>()
            {
                out.push((idx, entry.path()));
            }
        }
        out.sort();
        Ok(out)
    }

    fn list_entry(&self, entry: &std::fs::DirEntry) -> Result<Option<SessionMeta>> {
        let kind = entry.file_type()?;
        anyhow::ensure!(!kind.is_symlink(), "session entry {} is a link", entry.path().display());
        if !kind.is_dir() {
            return Ok(None);
        }
        let session = entry.path();
        self.validate_session_dir(&session)?;
        let path = session.join("session.json");
        let id = entry.file_name().to_string_lossy().into_owned();
        let Ok(file) = crate::config::private_state_file(&path) else {
            if path.exists() {
                self.mark_unlisted(&id, true);
            }
            return Ok(None);
        };
        let mut text = String::new();
        BufReader::new(file).read_to_string(&mut text)?;
        // Only a closed chat can be a purged chat revived by a late save. Open chats need
        // no segment enumeration: that work belongs to their on-demand log read.
        if let Ok(meta) = serde_json::from_str::<StatusOnly>(&text)
            && self.purged_startup_entry(&entry.file_name().to_string_lossy(), meta.status)?
        {
            return Ok(None);
        }
        match serde_json::from_str::<SessionMeta>(&text) {
            Ok(mut meta) => {
                self.parts.merge(&session, text.as_bytes(), &mut meta);
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
    fn validate_session_dir(&self, session: &Path) -> Result<()> {
        crate::config::private_state_dir(session)?;
        let events = session.join("events");
        match std::fs::symlink_metadata(&events) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
            Ok(_) => crate::config::private_state_dir(&events)?,
        }
        Ok(())
    }

    fn purged_startup_entry(&self, id: &str, status: SessionStatus) -> Result<bool> {
        Ok(status == SessionStatus::Closed && !self.has_records(id)?)
    }

    /// Whether the session's log holds a record: a segment with a byte in it (no line
    /// is read), or a compaction's record (`store/compact.rs`), which keeps a closed
    /// chat's log however little of it stays. Every session the hub creates logs `created`
    /// right after its first save, so a record without a log is a purged session's that a
    /// late save wrote back.
    /// A cold archive (`store/cold.rs`) is a log too, and is not opened.
    fn has_records(&self, id: &str) -> Result<bool> {
        if std::fs::symlink_metadata(self.marker(id)).is_ok()
            || std::fs::symlink_metadata(self.cold_path(id)).is_ok()
        {
            return Ok(true);
        }
        for (_, path) in self.segment_files(id)? {
            // An unreadable segment counts as a log: the session is listed as before.
            match std::fs::symlink_metadata(&path) {
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
        let segs = self.segments(id)?;
        // Never segment `000000`: it holds only a fork's history, written whole and renamed in
        // place (`history_writer`), which would replace a record appended to it (review of
        // #37020). A log whose only segment it is goes on in `000001`.
        let (index, path) = match segs.last().filter(|(i, _)| *i > 0) {
            Some((i, p)) => (*i, p.clone()),
            None => (1, dir.join("000001.ndjson")),
        };
        let file = open_private_append(&path)?;
        let written = cut_torn_tail(&file, &path)?;
        Ok(SegmentWriter { index, file, written, used: 0 })
    }
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

impl LocalStore {
    /// One whole serialized record (`line` ends with its newline) at the end of `id`'s log: the
    /// body of [`Store::append`], and the journal store's write of a journaled line
    /// (`store/journal_store.rs`). Refused once the store is sealed.
    pub(super) fn append_line(&self, id: &str, line: &[u8]) -> Result<()> {
        // One lock hold from the eviction to the write: the least recently written log is
        // closed before this one opens, so no more than `open_logs` are ever open, and no other
        // append comes between (a session's records stay in order). Its sync runs under the lock,
        // once per eviction: only while more than `open_logs` sessions are written.
        let _open = self.writable()?;
        let mut writers = self.writers.lock_or_recover();
        if !writers.open.contains_key(id)
            && writers.open.len() >= self.open_logs
            && let Some(oldest) =
                writers.open.iter().min_by_key(|(_, w)| w.used).map(|(k, _)| k.clone())
            && let Some(w) = writers.open.remove(&oldest)
        {
            w.close(&oldest, &self.sync_failed);
        }
        if !writers.open.contains_key(id) {
            let writer = self.open_writer(id)?;
            writers.open.insert(id.to_owned(), writer);
        }
        writers.clock += 1;
        let clock = writers.clock;
        let full = writers.open.get(id).is_some_and(|w| w.written >= self.segment_bytes);
        if full && let Some(old) = writers.open.remove(id) {
            // The full segment closes before the next one opens (rare: once per segment).
            let index = old.index + 1;
            old.close(id, &self.sync_failed);
            let path = self.dir(id).join("events").join(format!("{index:06}.ndjson"));
            let file = open_private_append(&path)?;
            writers
                .open
                .insert(id.to_owned(), SegmentWriter { index, file, written: 0, used: clock });
        }
        let Some(w) = writers.open.get_mut(id) else {
            anyhow::bail!("no segment writer for session {id}");
        };
        w.used = clock;
        #[cfg(test)]
        let wrote = match test_write_fault::take() {
            Some(kept) => w.file.write_all(&line[..kept.min(line.len())]).and(Err(
                std::io::Error::new(std::io::ErrorKind::StorageFull, "no space left (a test)"),
            )),
            None => w.file.write_all(line),
        };
        #[cfg(not(test))]
        let wrote = w.file.write_all(line);
        if let Err(e) = wrote {
            // A full disk (or a signal) can write part of the line before the error. Cut it back
            // to the last whole record, or the next append is glued onto the torn bytes: the
            // merged line reads as no record, so that record is lost and a strict read fails.
            // If the cut fails too, the writer is closed, not dropped: its earlier appends are
            // synced as at any close (a checkpoint's `sync_log` takes a log with no open writer
            // as synced), and the next open cuts the tail.
            let segment = self.dir(id).join("events").join(format!("{:06}.ndjson", w.index));
            if cut_back(&segment, w.written).is_err()
                && let Some(w) = writers.open.remove(id)
            {
                w.close(id, &self.sync_failed);
            }
            return Err(e.into());
        }
        w.written += line.len() as u64;
        Ok(())
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

/// The next log append on this thread writes only its first `kept` bytes and then fails as a
/// full disk does (`ENOSPC`), the partial write a full disk or a killed process leaves.
#[cfg(test)]
pub(crate) mod test_write_fault {
    use std::cell::Cell;

    thread_local!(static NEXT: Cell<Option<usize>> = const { Cell::new(None) });
    thread_local!(static FAIL_CUT: Cell<bool> = const { Cell::new(false) });

    pub(crate) fn partial(kept: usize) {
        NEXT.with(|n| n.set(Some(kept)));
    }

    /// `partial`, and the cut back after it fails too (the disk refuses the truncate).
    pub(crate) fn partial_and_failed_cut(kept: usize) {
        partial(kept);
        FAIL_CUT.with(|f| f.set(true));
    }

    pub(super) fn take() -> Option<usize> {
        NEXT.with(Cell::take)
    }

    pub(super) fn take_cut_failure() -> bool {
        FAIL_CUT.with(|f| f.replace(false))
    }
}

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
        std::fs::rename(&self.tmp, &self.path)?;
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
        let _ = std::fs::remove_file(&self.tmp);
    }
}

impl Store for LocalStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        // No sessions folder yet: no chat. One that is there and does not read is a failed list,
        // never an empty one: an empty list proves every chat gone (`hub/hosts.rs`).
        let rd = match std::fs::read_dir(&self.root) {
            Ok(rd) => rd,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => {
                return Err(
                    anyhow::Error::new(error).context(format!("list {}", self.root.display()))
                );
            }
        };
        let entries = rd.collect::<std::io::Result<Vec<_>>>()?;
        if entries.is_empty() {
            return Ok(Vec::new());
        }
        // Metadata reads do independent filesystem/ACL checks. Keep those checks, but do
        // not put every chat behind every earlier chat's disk latency at daemon startup.
        let workers = std::thread::available_parallelism().map_or(1, usize::from).min(8);
        std::thread::scope(|scope| {
            let workers: Vec<_> = entries
                .chunks(entries.len().div_ceil(workers))
                .map(|chunk| {
                    scope.spawn(move || {
                        let mut metas = Vec::new();
                        for entry in chunk {
                            // One chat that is refused or does not read is left out (and
                            // counted unread), never the reason no chat is listed.
                            match self.list_entry(entry) {
                                Ok(Some(meta)) => metas.push(meta),
                                Ok(None) => {}
                                Err(e) => {
                                    tracing::warn!("skip {}: {e:#}", entry.path().display());
                                    let id = entry.file_name().to_string_lossy().into_owned();
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
        let session = self.dir(id);
        match std::fs::symlink_metadata(&session) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
            Ok(_) => self.validate_session_dir(&session)?,
        }
        let path = session.join("session.json");
        if !path.exists() {
            return Ok(None);
        }
        let mut text = String::new();
        BufReader::new(crate::config::private_state_file(&path)?).read_to_string(&mut text)?;
        let mut meta: SessionMeta = serde_json::from_str(&text)?;
        self.parts.merge(&session, text.as_bytes(), &mut meta);
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
            log_sync::sync_segment(&writer.file, true).map_err(SyncFailed)?;
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
        let _ = std::fs::remove_file(&tmp);
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

    /// Reads each line's head (`RecordHead::read`) and parses only the lines the reader asks
    /// for, or a line whose head does not read.
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        let mut line = Vec::new();
        for (_, path) in self.segments(id)? {
            let mut reader =
                BufReader::with_capacity(256 * 1024, crate::config::private_state_file(&path)?);
            loop {
                line.clear();
                if reader.read_until(b'\n', &mut line)? == 0 {
                    break;
                }
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

    fn text_entries(
        &self,
        id: &str,
        visit: &mut dyn FnMut(crate::session_search::Entry),
    ) -> Result<()> {
        self.text_entries_in(id, visit)
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
            log_sync::sync_segment(&w.file, false)?;
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
        if let Some(w) = writers.open.remove(id) {
            w.close(id, &self.sync_failed);
        }
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

    fn on_rehydrate(&self, hook: RehydrateHook) {
        let _ = self.rehydrate_hook.set(hook);
    }

    fn seal(&self) {
        *self.sealed.write().unwrap_or_else(std::sync::PoisonError::into_inner) = true;
    }

    fn delete(&self, id: &str) -> Result<()> {
        let _open = self.writable()?;
        self.writers.lock_or_recover().open.remove(id);
        let dir = self.dir(id);
        // macOS returns ENOTEMPTY when a file lands mid-removal; retry briefly.
        let mut last = None;
        for _ in 0..5 {
            if !dir.exists() {
                return Ok(());
            }
            match std::fs::remove_dir_all(&dir) {
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
    use std::os::unix::fs::OpenOptionsExt;
    #[cfg(test)]
    if log_sync::fail_dir_sync(path) {
        return Err(SyncFailed(std::io::Error::other("a failed folder sync (a test)")).into());
    }
    let dir = OpenOptions::new()
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
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    crate::config::refuse_lost_home(path)?;

    let file = OpenOptions::new()
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
        for (index, (_, path)) in segments.iter().enumerate() {
            if after > 0
                && let Some((_, next)) = segments.get(index + 1)
                && first_seq(next)?.is_some_and(|first| first <= after.saturating_add(1))
            {
                continue;
            }
            let mut reader =
                BufReader::with_capacity(256 * 1024, crate::config::private_state_file(path)?);
            loop {
                line.clear();
                if reader.read_until(b'\n', &mut line)? == 0 {
                    break;
                }
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
