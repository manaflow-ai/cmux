//! Persistence tiers for session metadata and the event log.
//!
//! `Local` writes `sessions/<id>/session.json` and append-only
//! `events/NNNNNN.ndjson` segments. `Memory` keeps the same data in RAM.
//! Both expose the same API so the hub does not care which is active.

use crate::config::{StoreConfig, StoreMode, write_atomic};
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionMeta {
    pub schema: String,
    pub id: String,
    pub name: String,
    #[serde(alias = "harness")]
    pub harness: String,
    #[serde(default, alias = "agent_argv")]
    pub harness_argv: Vec<String>,
    /// The argv its agent last started with: a config or preset reload since creation can change
    /// it (`harness_argv` is the creation's). None before any start (#23322, review 36).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spawn_argv: Option<Vec<String>>,
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
    #[serde(default)]
    pub agent_session_id: Option<String>,
    pub status: SessionStatus,
    pub created_at: u64,
    pub updated_at: u64,
    #[serde(default)]
    pub last_seq: u64,
    #[serde(default)]
    pub parent_id: Option<String>,
    #[serde(default)]
    pub fork_seq: Option<u64>,
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
    pub config_options: Option<Value>,
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
    /// is on its way or came back empty; a later turn asks again, `hub/titles.rs`), `generated` or `adopted`.
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
    /// The account's plan usage limits (`claude_stdio::usage_limits`), newest per window, from
    /// Claude Code's `rate_limit_event`; none from any other harness.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage_limits: Option<Value>,
    /// The agent's newest `available_commands_update` (its slash commands), so
    /// opening a chat names them without reading its log back to the start,
    /// where an agent lists them once (perf100).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub available_commands: Option<Value>,
    /// Last goal reported by the harness. Codex owns its persistence and continuation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub goal: Option<Value>,
    /// Per-session permission rules layered above the policy (see hub/rules.rs).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_rules: Option<Value>,
    /// Orchestrator labels: key -> (value, expiry unix ms).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub tags: BTreeMap<String, Tag>,
    /// A turn ended while no client was attached.
    #[serde(default)]
    pub unread: bool,
    /// The Claude conversation acpmux started with a fresh id has not
    /// finished a turn, so Claude may never have stored it (a launcher that
    /// died before the prompt reached Claude stores nothing). A respawn (a
    /// fallback profile, a dead process, a daemon restart) then starts a
    /// fresh conversation instead of `--resume`, which would fail the turn
    /// with "No conversation found with session ID".
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub claude_unstored: bool,
    /// When (Unix ms) the idle exit hibernated its agent, 0 when no start woke it since
    /// (`hub/idle.rs`): after a restart, opening it wakes it and its wake draws no row, as
    /// before the restart, and the wake's log says how long it slept.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub hibernated_ms: u64,
    /// The profile whose Claude store (its CLAUDE_CONFIG_DIR) holds the current Claude
    /// conversation: the one that started or forked it. A respawn on another profile (a failover)
    /// resumes only when that profile's store has the conversation, else starts fresh (E1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_profile: Option<String>,
    /// Outcome of the last turn: {turnId, promptId, status, stopReason?,
    /// errorText?, errorSource?, endedAt}.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_turn: Option<Value>,
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
    /// The tools the chat has (`hub/tools.rs`).
    #[serde(default, skip_serializing_if = "ToolInventory::is_empty")]
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
    /// The session whose agent started this one with its `start_session`
    /// tool (`hub/subsessions.rs`), with its short name and depth. `None`
    /// for a session a person or client started. Never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subsession: Option<SubsessionLink>,
    /// This session's own sub-session limits, set at runtime by the person
    /// or by an ancestor within its budget; unset fields inherit.
    #[serde(default, skip_serializing_if = "SubsessionLimits::is_empty")]
    pub subsession_limits: SubsessionLimits,
    /// The session whose agent started this one, recorded once at creation from
    /// the proven caller (`hub/lineage.rs`): `acpmux new` run in an agent's
    /// shell, or its `start_session` tool. `None` for a session a person or
    /// the app started (a root), and for one saved before lineage existed.
    /// Never copied to a fork or a moved-in session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lineage: Option<Lineage>,
    /// The log holds a subagent entry with a retry waiting or in flight that no later entry
    /// cleared yet (`hub/subagent_retry.rs`): the next load clears it, as the restart dropped
    /// that retry. Never copied to a fork.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub subagent_retry_open: bool,
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

impl SessionMeta {
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
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub trait Store: Send + Sync {
    fn list(&self) -> Result<Vec<SessionMeta>>;
    fn load(&self, id: &str) -> Result<Option<SessionMeta>>;
    fn save(&self, meta: &SessionMeta) -> Result<()>;
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
    /// `scan` from the start, passing each record's head ([`RecordHead`]) until `visit` returns
    /// false; the reader parses only the records it needs (`RecordHead::record`). A file store
    /// reads a head without parsing its line: adopting a host after a restart reads its whole
    /// log four times, and parsing every line held big-red's daemon at a full core for minutes.
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        self.scan(id, 0, &mut |rec| visit(&RecordHead::parsed(&rec)))
    }
    /// Make every appended record durable (called on shutdown).
    fn flush(&self) -> Result<()> {
        Ok(())
    }
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
    fn delete(&self, id: &str) -> Result<()>;
    fn session_dir(&self, _id: &str) -> Option<PathBuf> {
        None
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
}

/// One record as [`Store::scan_heads`] passes it: the fields a log line holds before its `msg`,
/// and the whole record on demand.
pub struct RecordHead<'a> {
    pub seq: u64,
    pub at: u64,
    pub dir: &'a str,
    pub kind: &'a str,
    pub host_seq: Option<u64>,
    body: HeadBody<'a>,
}

enum HeadBody<'a> {
    /// A log line, not parsed yet.
    Line(&'a [u8]),
    /// A record the store holds parsed, or a line whose head did not read.
    Parsed(&'a EventRecord),
}

impl<'a> RecordHead<'a> {
    fn parsed(rec: &'a EventRecord) -> Self {
        Self {
            seq: rec.seq,
            at: rec.at,
            dir: &rec.dir,
            kind: &rec.kind,
            host_seq: rec.host_seq,
            body: HeadBody::Parsed(rec),
        }
    }

    /// The head of a line the daemon wrote (`{"seq":N,"at":N,"dir":"..","kind":"..","msg":..}`,
    /// then `"hostSeq":N` when it has one); None for any other shape, which the caller parses.
    fn read(line: &'a [u8]) -> Option<Self> {
        let body = line.trim_ascii_end();
        if body.last() != Some(&b'}') {
            return None;
        }
        let text = |field: &'a [u8]| {
            std::str::from_utf8(field).ok().filter(|s| !s.contains('\\') && !s.is_empty())
        };
        let host_seq = record_host_seq(body);
        // A `hostSeq` anywhere but last is not the daemon's field order.
        let head = body.get(..160).unwrap_or(body);
        let head = head.get(..memchr::memmem::find(head, b"\"msg\":")?).unwrap_or_default();
        if host_seq.is_none() && memchr::memmem::find(head, b"\"hostSeq\"").is_some() {
            return None;
        }
        Some(Self {
            seq: record_seq(body)?,
            at: record_at(body)?,
            dir: text(record_dir(body)?)?,
            kind: text(record_kind(body)?)?,
            host_seq,
            body: HeadBody::Line(body),
        })
    }

    /// The whole record (None for a line that does not parse, which `scan` passes too).
    pub fn record(&self) -> Option<EventRecord> {
        match self.body {
            HeadBody::Line(line) => parse_record(line).ok(),
            HeadBody::Parsed(rec) => Some(rec.clone()),
        }
    }

    /// Whether the record's line may hold `needle`: true for a record held parsed, so a reader
    /// uses it only to pass a record it surely does not need.
    pub fn may_contain(&self, needle: &[u8]) -> bool {
        match self.body {
            HeadBody::Line(line) => memchr::memmem::find(line, needle).is_some(),
            HeadBody::Parsed(_) => true,
        }
    }
}

#[cfg(test)]
thread_local! {
    /// Log lines parsed on this thread by `scan` and `scan_heads` (tests count them).
    pub(crate) static PARSED_LINES: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Parses one log line into its record.
fn parse_record(line: &[u8]) -> serde_json::Result<EventRecord> {
    #[cfg(test)]
    PARSED_LINES.with(|n| n.set(n.get() + 1));
    serde_json::from_slice(line)
}

pub fn open(config: &StoreConfig, root: &Path) -> Result<Box<dyn Store>> {
    Ok(match config.mode {
        StoreMode::Memory => Box::new(MemoryStore::default()),
        StoreMode::Local => Box::new(LocalStore::new(root.join("sessions"), config.segment_bytes)?),
    })
}

// ---------------------------------------------------------------- memory

#[derive(Default)]
pub struct MemoryStore {
    inner: Mutex<HashMap<String, (SessionMeta, Vec<EventRecord>)>>,
}

impl Store for MemoryStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        Ok(self.inner.lock_or_recover().values().map(|(m, _)| m.clone()).collect())
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        Ok(self.inner.lock_or_recover().get(id).map(|(m, _)| m.clone()))
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        let mut g = self.inner.lock_or_recover();
        g.entry(meta.id.clone())
            .and_modify(|(m, _)| *m = meta.clone())
            .or_insert_with(|| (meta.clone(), Vec::new()));
        Ok(())
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut g = self.inner.lock_or_recover();
        if let Some((_, events)) = g.get_mut(id) {
            events.push(record.clone());
            // Bound memory: keep the newest 20k events.
            if events.len() > 20_000 {
                let drop = events.len() - 20_000;
                events.drain(..drop);
            }
        }
        Ok(())
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        let g = self.inner.lock_or_recover();
        Ok(g.get(id)
            .map(|(_, ev)| ev.iter().filter(|e| e.seq > after).take(limit).cloned().collect())
            .unwrap_or_default())
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.inner.lock_or_recover().remove(id);
        Ok(())
    }
}

// ----------------------------------------------------------------- local

pub struct LocalStore {
    root: PathBuf,
    segment_bytes: u64,
    writers: Mutex<Writers>,
}

/// The logs held open, at most [`OPEN_LOGS`]: the least recently written one
/// is closed for a new one. A daemon held one descriptor per session it wrote
/// since it started, closed ones too, and ran out (cmux16, 2026-10-22: 193 of
/// its 256, every agent start failing with "Too many open files").
#[derive(Default)]
struct Writers {
    open: HashMap<String, SegmentWriter>,
    /// Counts appends; a writer's `used` is the count at its last one.
    clock: u64,
}

const OPEN_LOGS: usize = 64;

struct SegmentWriter {
    index: u32,
    file: File,
    written: u64,
    used: u64,
}

impl SegmentWriter {
    /// Closes the log, durable first as `flush` would have made it. Called under the
    /// writers' lock, so the cache never holds more than [`OPEN_LOGS`] and a session's
    /// records stay in order. A failed sync is logged: its records were written (an append is
    /// never synced on its own), so only a machine crash before the kernel writes them back
    /// loses them, as it would any append since the last `flush`.
    fn close(self, id: &str) {
        if let Err(e) = self.file.sync_data() {
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
        })
    }

    fn dir(&self, id: &str) -> PathBuf {
        self.root.join(id)
    }

    fn segments(&self, id: &str) -> Result<Vec<(u32, PathBuf)>> {
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

    /// Whether the session's log holds a record: a segment with a byte in it (no line
    /// is read), or a compaction's record (`store/compact.rs`), which keeps a closed
    /// chat's log however little of it stays. Every session the hub creates logs `created`
    /// right after its first save, so a record without a log is a purged session's that a
    /// late save wrote back.
    fn has_records(&self, id: &str) -> Result<bool> {
        if std::fs::symlink_metadata(self.marker(id)).is_ok() {
            return Ok(true);
        }
        for (_, path) in self.segments(id)? {
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
        let (index, path) = match segs.last() {
            Some((i, p)) => (*i, p.clone()),
            None => (1, dir.join("000001.ndjson")),
        };
        let file = open_private_append(&path)?;
        let written = file.metadata().map(|m| m.len()).unwrap_or(0);
        Ok(SegmentWriter { index, file, written, used: 0 })
    }
}

/// A session record's status alone, read without the rest of the record.
#[derive(Deserialize)]
struct StatusOnly {
    status: SessionStatus,
}

/// The seq of a segment's first readable record.
/// The `kind` of one serialized record, read without parsing it: records are written
/// `{"seq":..,"at":..,"dir":"..","kind":"..","msg":..}`, so the first `"kind":"` is the
/// record's own (its fields before `msg` hold numbers and a fixed word). None for a line
/// that does not start that way; the caller then parses it.
fn record_kind(line: &[u8]) -> Option<&[u8]> {
    record_head_field(line, b"\"kind\":\"")
}

/// The string value after `key` (`"name":"`) in the first 160 bytes of a record, before
/// its `"msg":`; None when it is not there.
fn record_head_field<'a>(line: &'a [u8], key: &[u8]) -> Option<&'a [u8]> {
    let head = line.get(..160).unwrap_or(line);
    let msg = head.windows(6).position(|w| w == b"\"msg\":").unwrap_or(head.len());
    let start = head.get(..msg)?.windows(key.len()).position(|w| w == key)? + key.len();
    let rest = line.get(start..)?;
    let len = rest.iter().position(|&b| b == b'"')?;
    rest.get(..len)
}

/// The `seq` of one serialized record, read without parsing it: records are written
/// `{"seq":N,...}`. None for a line that does not start that way; the caller parses it.
fn record_seq(line: &[u8]) -> Option<u64> {
    let rest = line.strip_prefix(b"{\"seq\":")?;
    let digits = rest.iter().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 || digits > 19 || rest.get(digits) != Some(&b',') {
        return None;
    }
    std::str::from_utf8(rest.get(..digits)?).ok()?.parse().ok()
}

/// The `at` of one serialized record, read without parsing it: `{"seq":N,"at":N,...`.
fn record_at(line: &[u8]) -> Option<u64> {
    let rest = line.strip_prefix(b"{\"seq\":")?;
    let rest = rest.get(rest.iter().take_while(|b| b.is_ascii_digit()).count()..)?;
    let rest = rest.strip_prefix(b",\"at\":")?;
    let digits = rest.iter().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 || digits > 19 || rest.get(digits) != Some(&b',') {
        return None;
    }
    std::str::from_utf8(rest.get(..digits)?).ok()?.parse().ok()
}

/// The `hostSeq` of one serialized record, read without parsing it: the daemon writes it last
/// (`...,"hostSeq":N}`), so a nested one is followed by more than the record's closing brace.
fn record_host_seq(line: &[u8]) -> Option<u64> {
    let rest = line.strip_suffix(b"}")?;
    let digits = rest.iter().rev().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 || digits > 19 {
        return None;
    }
    let (rest, number) = rest.split_at(rest.len() - digits);
    rest.strip_suffix(b",\"hostSeq\":")?;
    std::str::from_utf8(number).ok()?.parse().ok()
}

/// The `dir` of one serialized record, read without parsing it, as `record_kind` reads its kind.
fn record_dir(line: &[u8]) -> Option<&[u8]> {
    record_head_field(line, b"\"dir\":\"")
}

/// The byte offset in segment `path` where its first record with `seq >= before` starts (the
/// file's length when it has none), found by a binary search on line headers: the records of a
/// segment are appended in `seq` order. A line whose header does not read (an older field
/// order) ends the search at the file's length, which reads the segment from its end as before.
/// The caller reads back from the offset through the same `file`: log retention may rename a
/// compacted segment over the path meanwhile (`store/compact.rs`).
fn offset_of_seq(file: &mut File, before: u64) -> Result<u64> {
    use std::io::{Seek, SeekFrom};
    const PROBE: usize = 64 * 1024;
    let len = file.seek(SeekFrom::End(0))?;
    let mut buf = vec![0u8; PROBE];
    // A segment whose last record is before `before` (every older segment of a page) needs no
    // search: its end is the offset.
    if len > PROBE as u64 {
        file.seek(SeekFrom::Start(len - PROBE as u64))?;
        file.read_exact(&mut buf)?;
        let body = buf.strip_suffix(b"\n").unwrap_or(&buf);
        if let Some(nl) = body.iter().rposition(|&b| b == b'\n')
            && body.get(nl + 1..).and_then(record_seq).is_some_and(|seq| seq < before)
        {
            return Ok(len);
        }
    }
    // The first line starting at or after `pos`: its offset and seq; None past the end, or when
    // no line starts in the probe (a line over 64 KiB) or its header does not read.
    let mut line_at = |pos: u64| -> Result<Option<(u64, Option<u64>)>> {
        file.seek(SeekFrom::Start(pos))?;
        let mut filled = 0;
        while let Some(rest) = buf.get_mut(filled..).filter(|rest| !rest.is_empty()) {
            let n = file.read(rest)?;
            if n == 0 {
                break;
            }
            filled += n;
        }
        let data = buf.get(..filled).unwrap_or_default();
        let start = if pos == 0 {
            0
        } else {
            match data.iter().position(|&b| b == b'\n') {
                Some(nl) => nl + 1,
                None => return Ok(None),
            }
        };
        if start >= data.len() {
            return Ok(None);
        }
        Ok(Some((pos + start as u64, data.get(start..).and_then(record_seq))))
    };
    let (mut lo, mut hi, mut end) = (0u64, len, len);
    while hi - lo > PROBE as u64 {
        let mid = lo + (hi - lo) / 2;
        match line_at(mid)? {
            Some((_, None)) | None => return Ok(len),
            Some((start, Some(seq))) if seq >= before => {
                hi = mid;
                end = start;
            }
            Some(_) => lo = mid,
        }
    }
    Ok(end)
}

/// Visits `path`'s lines newest first, reading 64 KiB blocks from the end, until `visit`
/// returns false: a tail costs its own bytes, not the segment's.
fn for_each_line_rev(path: &Path, visit: &mut dyn FnMut(&[u8]) -> bool) -> Result<()> {
    for_each_line_rev_from(&mut crate::config::private_state_file(path)?, u64::MAX, visit)
}

/// `for_each_line_rev` over the bytes of `file` before offset `end` (a line start, or past the end).
fn for_each_line_rev_from(
    file: &mut File,
    end: u64,
    visit: &mut dyn FnMut(&[u8]) -> bool,
) -> Result<()> {
    use std::io::{Seek, SeekFrom};
    const BLOCK: u64 = 64 * 1024;
    let mut end = file.seek(SeekFrom::End(0))?.min(end);
    // The blocks of a line whose start is in an earlier block, newest first: each block is read
    // and scanned once, so a line of many megabytes costs its length, not its length squared.
    let mut carry: Vec<Vec<u8>> = Vec::new();
    let joined = |head: &[u8], carry: &mut Vec<Vec<u8>>| {
        let mut line = head.to_vec();
        for piece in carry.drain(..).rev() {
            line.extend_from_slice(&piece);
        }
        line
    };
    while end > 0 {
        let start = end.saturating_sub(BLOCK);
        let mut block = vec![0u8; (end - start) as usize];
        file.seek(SeekFrom::Start(start))?;
        file.read_exact(&mut block)?;
        let mut cut = block.len();
        while let Some(newline) =
            block.get(..cut).unwrap_or_default().iter().rposition(|&b| b == b'\n')
        {
            let head = block.get(newline + 1..cut).unwrap_or_default();
            let whole;
            let line = if carry.is_empty() {
                head
            } else {
                whole = joined(head, &mut carry);
                whole.as_slice()
            };
            if !line.iter().all(u8::is_ascii_whitespace) && !visit(line) {
                return Ok(());
            }
            cut = newline;
        }
        block.truncate(cut);
        carry.push(block);
        end = start;
    }
    let line = joined(&[], &mut carry);
    if !line.iter().all(u8::is_ascii_whitespace) {
        visit(&line);
    }
    Ok(())
}

fn first_seq(path: &Path) -> Result<Option<u64>> {
    let mut reader = BufReader::new(crate::config::private_state_file(path)?);
    let mut line = Vec::new();
    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            return Ok(None);
        }
        // The header alone when the line has the daemon's field order; else a parse.
        if let Some(seq) = record_seq(&line) {
            return Ok(Some(seq));
        }
        if let Ok(rec) = serde_json::from_slice::<EventRecord>(&line) {
            return Ok(Some(rec.seq));
        }
    }
}

impl Store for LocalStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        let mut out = Vec::new();
        let mut skipped = 0usize;
        let Ok(rd) = std::fs::read_dir(&self.root) else {
            return Ok(out);
        };
        for entry in rd {
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_symlink() {
                anyhow::bail!("session entry {} is a link", entry.path().display());
            }
            if !kind.is_dir() {
                continue;
            }
            let session = entry.path();
            crate::config::private_state_dir(&session)?;
            let events = session.join("events");
            match std::fs::symlink_metadata(&events) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
                Ok(_) => crate::config::private_state_dir(&events)?,
            }
            let path = session.join("session.json");
            if let Ok(file) = crate::config::private_state_file(&path) {
                let mut text = String::new();
                BufReader::new(file).read_to_string(&mut text)?;
                // A closed session with no log is a purged one whose record a late save
                // wrote back (`Hub::load_from_store`): only its status is read, so a home
                // of thousands of them never holds their records, not even while listing.
                let id = entry.file_name().to_string_lossy().into_owned();
                if !self.has_records(&id)?
                    && serde_json::from_str::<StatusOnly>(&text)
                        .is_ok_and(|m| m.status == SessionStatus::Closed)
                {
                    skipped += 1;
                    continue;
                }
                match serde_json::from_str::<SessionMeta>(&text) {
                    Ok(meta) => out.push(meta),
                    Err(e) => tracing::warn!("skip {}: {e}", path.display()),
                }
            }
        }
        if skipped > 0 {
            tracing::info!(
                "skipped {skipped} closed sessions with no log (purged; a late save wrote them back)"
            );
        }
        Ok(out)
    }

    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        let path = self.dir(id).join("session.json");
        if !path.exists() {
            return Ok(None);
        }
        let mut text = String::new();
        BufReader::new(crate::config::private_state_file(&path)?).read_to_string(&mut text)?;
        Ok(Some(serde_json::from_str(&text)?))
    }

    fn save(&self, meta: &SessionMeta) -> Result<()> {
        let dir = self.dir(&meta.id);
        crate::config::private_state_dir(&dir)?;
        write_atomic(&dir.join("session.json"), serde_json::to_string_pretty(meta)?.as_bytes())
    }

    fn flush_session(&self, id: &str) -> Result<()> {
        let writers = self.writers.lock_or_recover();
        if let Some(writer) = writers.open.get(id) {
            writer.file.sync_all()?;
        }
        let session = self.dir(id);
        sync_directory(&session.join("events"))?;
        sync_directory(&session)?;
        sync_directory(&self.root)?;
        Ok(())
    }

    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        // One lock hold from the eviction to the write: the least recently written log is
        // closed before this one opens, so no more than `OPEN_LOGS` are ever open, and no other
        // append comes between (a session's records stay in order). Its sync runs under the lock,
        // once per eviction: only while more than `OPEN_LOGS` sessions are written.
        let mut writers = self.writers.lock_or_recover();
        if !writers.open.contains_key(id)
            && writers.open.len() >= OPEN_LOGS
            && let Some(oldest) =
                writers.open.iter().min_by_key(|(_, w)| w.used).map(|(k, _)| k.clone())
            && let Some(w) = writers.open.remove(&oldest)
        {
            w.close(&oldest);
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
            old.close(id);
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
        let mut line = serde_json::to_string(record)?;
        line.push('\n');
        w.file.write_all(line.as_bytes())?;
        w.written += line.len() as u64;
        Ok(())
    }

    /// Reads only past `after`: a segment whose successor starts at or before `after + 1`
    /// holds nothing past it and is not opened, and a line at or before `after` is passed
    /// on its `seq` alone, unparsed. A forward page of a long log costs its own records,
    /// not the log's prefix (perf100: a 70 MB log read in 10,000-record pages parsed
    /// every earlier record again on each page).
    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        self.scan_lines(id, after, false, visit)
    }

    fn scan_strict(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_lines(id, after, true, visit)
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
        // Debug builds only: `ACPMUX_TEST_SCAN_DELAY_MS` holds each log scan, as a slow disk or a
        // long log does (`tests/restart_reattach.rs`). Bounded; release builds have no seam.
        #[cfg(debug_assertions)]
        if let Some(ms) =
            std::env::var("ACPMUX_TEST_SCAN_DELAY_MS").ok().and_then(|v| v.parse::<u64>().ok())
        {
            std::thread::sleep(std::time::Duration::from_millis(ms.min(1_000)));
        }
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
                if record_kind(&line)
                    .is_some_and(|kind| !kinds.iter().any(|k| k.as_bytes() == kind))
                {
                    continue;
                }
                let Ok(rec) = serde_json::from_slice::<EventRecord>(&line) else { continue };
                if kinds.contains(&rec.kind.as_str()) && !visit(rec) {
                    return Ok(());
                }
            }
        }
        Ok(())
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
        for (_, path) in self.segments(id)?.into_iter().rev() {
            if first_seq(&path)?.is_some_and(|first| first >= before) {
                continue;
            }
            let mut done = false;
            let mut file = crate::config::private_state_file(&path)?;
            let end = offset_of_seq(&mut file, before)?;
            for_each_line_rev_from(&mut file, end, &mut |line| {
                match record_seq(line) {
                    Some(seq) if seq >= before => return true,
                    Some(seq) if seq <= after => {
                        done = true;
                        return false;
                    }
                    _ => {}
                }
                if let (Some(dir), Some(kind)) = (record_dir(line), record_kind(line))
                    && skip(dir, kind)
                {
                    return true;
                }
                let Ok(rec) = serde_json::from_slice::<EventRecord>(line) else { return true };
                if rec.seq >= before {
                    return true;
                }
                if rec.seq <= after || !visit(rec) {
                    done = true;
                    return false;
                }
                true
            })?;
            if done {
                return Ok(());
            }
        }
        Ok(())
    }

    fn flush(&self) -> Result<()> {
        for w in self.writers.lock_or_recover().open.values() {
            w.file.sync_data()?;
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
            w.close(id);
        }
    }

    fn compacted_seq(&self, id: &str) -> Option<u64> {
        LocalStore::compacted_seq(self, id)
    }

    fn log_written_at(&self, id: &str) -> Option<u64> {
        LocalStore::log_written_at(self, id)
    }

    fn stage_compaction(&self, id: &str, mode: CompactMode) -> Result<Option<Staged>> {
        LocalStore::stage_compaction(self, id, mode)
    }

    fn commit_compaction(&self, id: &str, staged: Staged) -> Result<bool> {
        LocalStore::commit_compaction(self, id, staged)
    }

    fn delete(&self, id: &str) -> Result<()> {
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
}

/// Sync a directory entry after a file or subdirectory was created or replaced.
#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let dir = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)?;
    dir.sync_all()?;
    Ok(())
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<()> {
    Ok(())
}

/// Open one event segment for append, owner-only from creation and after an
/// older build left it with wider permissions.
#[cfg(unix)]
fn open_private_append(path: &Path) -> Result<File> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

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
fn open_private_append(path: &Path) -> Result<File> {
    Ok(crate::owner_only::open_append(path)?)
}

#[cfg(all(test, unix))]
mod permission_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "acpmux-store-permissions-{}-{}",
                std::process::id(),
                uuid::Uuid::now_v7()
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn mode(path: &Path) -> u32 {
        std::fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn local_store_makes_existing_state_private_and_writes_private_events() {
        let temp = TempDir::new();
        let root = temp.0.join("sessions");
        let session = root.join("session-1");
        let events = session.join("events");
        std::fs::create_dir_all(&events).unwrap();
        let metadata = session.join("session.json");
        let first = events.join("000001.ndjson");
        let second = events.join("000002.ndjson");
        std::fs::write(&metadata, "{}").unwrap();
        std::fs::write(&first, "").unwrap();
        std::fs::write(&second, "").unwrap();
        for directory in [&root, &session, &events] {
            std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        for file in [&metadata, &first, &second] {
            std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o644)).unwrap();
        }

        let store = LocalStore::new(root.clone(), 64 * 1024).unwrap();
        let _ = store.list().unwrap();
        store
            .append(
                "session-1",
                &EventRecord {
                    seq: 1,
                    at: 1,
                    dir: "mux".into(),
                    kind: "test".into(),
                    msg: serde_json::json!({"text": "private"}),
                    host_seq: None,
                },
            )
            .unwrap();
        // Old segments are authenticated and narrowed when a read reaches
        // them. Merely finding their names stays lazy so a tail page never
        // opens an older segment it does not need.
        store.events("session-1", 0, usize::MAX).unwrap();

        assert_eq!(mode(&root), 0o700, "the sessions root contains every chat");
        assert_eq!(mode(&session), 0o700);
        assert_eq!(mode(&events), 0o700);
        assert_eq!(mode(&metadata), 0o600);
        assert_eq!(mode(&first), 0o600);
        assert_eq!(mode(&second), 0o600);
    }

    /// Review 2 of #26054: a strict read of a log whose segments cannot be listed fails; `scan`
    /// reads no record of it.
    #[test]
    fn a_strict_read_fails_when_the_log_cannot_be_listed() {
        let temp = TempDir::new();
        let root = temp.0.join("sessions");
        let store = LocalStore::new(root.clone(), 64 * 1024).unwrap();
        let record = EventRecord {
            seq: 1,
            at: 1,
            dir: "mux".into(),
            kind: "host_started".into(),
            msg: serde_json::json!({}),
            host_seq: None,
        };
        store.append("session-1", &record).unwrap();
        let events = root.join("session-1").join("events");
        std::fs::remove_dir_all(&events).unwrap();
        std::fs::write(&events, "not a directory").unwrap();
        assert!(store.scan("session-1", 0, &mut |_| true).is_ok());
        assert!(
            store.scan_strict("session-1", 0, &mut |_| true).is_err(),
            "a strict read of a log it could not list read nothing and passed"
        );
    }

    #[test]
    fn local_store_refuses_a_symlinked_existing_session() {
        let temp = TempDir::new();
        let root = temp.0.join("sessions");
        let outside = temp.0.join("outside");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("linked-session")).unwrap();
        let store = LocalStore::new(root, 64 * 1024).unwrap();
        assert!(store.list().is_err());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn local_store_refuses_a_state_root_with_an_extended_acl() {
        let temp = TempDir::new();
        let root = temp.0.join("sessions");
        std::fs::create_dir_all(&root).unwrap();
        let status = std::process::Command::new("/bin/chmod")
            .args(["+a", "group:staff allow read", root.to_str().unwrap()])
            .status()
            .unwrap();
        assert!(status.success());
        assert!(LocalStore::new(root, 64 * 1024).is_err());
    }
}

#[cfg(all(test, unix))]
mod line_rev_tests;

fn is_zero(v: &u64) -> bool {
    *v == 0
}

#[cfg(test)]
mod head_tests;

impl LocalStore {
    /// `Store::scan`, and with `strict` `Store::scan_strict`.
    fn scan_lines(
        &self,
        id: &str,
        after: u64,
        strict: bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        // A strict read learns that the log's segments could not be listed (`segments` lists
        // none then).
        if strict {
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
