//! Persistence tiers for session metadata and the event log.
//!
//! `Local` writes `sessions/<id>/session.json` and append-only
//! `events/NNNNNN.ndjson` segments. `Memory` keeps the same data in RAM.
//! Both expose the same API so the hub does not care which is active.

use crate::config::{StoreConfig, StoreMode, write_atomic};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

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
    /// Model family of the profile at creation (`claude`, `codex`, ...).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
    /// Preset the session was created from (`-p NAME`); its env is
    /// re-applied on every respawn.
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
    #[serde(default)]
    pub modes: Option<Value>,
    #[serde(default)]
    pub config_options: Option<Value>,
    #[serde(default)]
    pub models: Option<Value>,
    #[serde(default)]
    pub permission_policy: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    /// Who set `title` (`hub/titles.rs`): `prompt` (its first prompt's line),
    /// `harness` (its own `session_info_update`), `asked` (a generated title
    /// is on its way or failed; never asked again), `generated` or `adopted`.
    /// None: a chat titled before acpmux generated titles; kept as is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title_source: Option<String>,
    /// The first prompt a `prompt` title came from, until a title is asked for.
    #[serde(skip)]
    pub title_prompt: Option<String>,
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
    /// The profile whose Claude store (its CLAUDE_CONFIG_DIR) holds the
    /// current Claude conversation: the one that started or forked it. A
    /// respawn on another profile (a failover) resumes only when that
    /// profile's store has the conversation, else starts fresh (E1).
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
    /// The branch checked out in `cwd` when the session started (session/new,
    /// or a fork at fork time; `git_state.rs`). `None` on a detached HEAD or
    /// outside a repository. Never updated after: it joins the session to the
    /// pull request it produced (hq#1920).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<String>,
    /// The full HEAD commit of `cwd` when the session started, as `git_branch`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_head: Option<String>,
    /// The sum of what this session's turns reported (`hub/turn_usage.rs`).
    /// `None` until a harness reports any; a fork starts its own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub totals: Option<TurnUsage>,
    /// The harness's own running cost after the last turn (Claude Code's
    /// `total_cost_usd`), which the next turn's cost is measured from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness_cost_usd: Option<f64>,
    /// The session whose agent started this one with its `start_session`
    /// tool (`hub/subsessions.rs`), with its short name and depth. `None`
    /// for a session a person or client started. Never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subsession: Option<SubsessionLink>,
    /// This session's own sub-session limits, set at runtime by the person
    /// or by an ancestor within its budget; unset fields inherit.
    #[serde(default, skip_serializing_if = "SubsessionLimits::is_empty")]
    pub subsession_limits: SubsessionLimits,
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
}

impl SubsessionLimits {
    pub fn is_empty(&self) -> bool {
        self.max_children.is_none() && self.max_depth.is_none()
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
    /// Visit records with `after < seq < before` newest first until `visit`
    /// returns false: the reverse of `scan`, for pages taken from the end.
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        let mut found = Vec::new();
        self.scan(id, after, &mut |rec| {
            if rec.seq >= before {
                return false;
            }
            found.push(rec);
            true
        })?;
        for rec in found.into_iter().rev() {
            if !visit(rec) {
                break;
            }
        }
        Ok(())
    }
    /// Make every appended record durable (called on shutdown).
    fn flush(&self) -> Result<()> {
        Ok(())
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
        Ok(self.inner.lock().unwrap().values().map(|(m, _)| m.clone()).collect())
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        Ok(self.inner.lock().unwrap().get(id).map(|(m, _)| m.clone()))
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        let mut g = self.inner.lock().unwrap();
        g.entry(meta.id.clone())
            .and_modify(|(m, _)| *m = meta.clone())
            .or_insert_with(|| (meta.clone(), Vec::new()));
        Ok(())
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut g = self.inner.lock().unwrap();
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
        let g = self.inner.lock().unwrap();
        Ok(g.get(id)
            .map(|(_, ev)| ev.iter().filter(|e| e.seq > after).take(limit).cloned().collect())
            .unwrap_or_default())
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.inner.lock().unwrap().remove(id);
        Ok(())
    }
}

// ----------------------------------------------------------------- local

pub struct LocalStore {
    root: PathBuf,
    segment_bytes: u64,
    writers: Mutex<HashMap<String, SegmentWriter>>,
}

struct SegmentWriter {
    index: u32,
    file: File,
    written: u64,
}

impl LocalStore {
    pub fn new(root: PathBuf, segment_bytes: u64) -> Result<Self> {
        crate::config::private_state_dir(&root)
            .with_context(|| format!("create private store {}", root.display()))?;
        Ok(Self {
            root,
            segment_bytes: segment_bytes.max(64 * 1024),
            writers: Mutex::new(HashMap::new()),
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
        Ok(SegmentWriter { index, file, written })
    }
}

/// The seq of a segment's first readable record.
fn first_seq(path: &Path) -> Result<Option<u64>> {
    for line in BufReader::new(crate::config::private_state_file(path)?).lines() {
        let line = line?;
        if let Ok(rec) = serde_json::from_str::<EventRecord>(&line) {
            return Ok(Some(rec.seq));
        }
    }
    Ok(None)
}

impl Store for LocalStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        let mut out = Vec::new();
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
                match serde_json::from_str::<SessionMeta>(&text) {
                    Ok(meta) => out.push(meta),
                    Err(e) => tracing::warn!("skip {}: {e}", path.display()),
                }
            }
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

    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut writers = self.writers.lock().unwrap();
        if !writers.contains_key(id) {
            writers.insert(id.to_owned(), self.open_writer(id)?);
        }
        let w = writers.get_mut(id).unwrap();
        if w.written >= self.segment_bytes {
            let index = w.index + 1;
            let path = self.dir(id).join("events").join(format!("{index:06}.ndjson"));
            let file = open_private_append(&path)?;
            *w = SegmentWriter { index, file, written: 0 };
        }
        let mut line = serde_json::to_string(record)?;
        line.push('\n');
        w.file.write_all(line.as_bytes())?;
        w.written += line.len() as u64;
        Ok(())
    }

    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        for (_, path) in self.segments(id)? {
            let file = crate::config::private_state_file(&path)?;
            for line in BufReader::new(file).lines() {
                let line = line?;
                if line.trim().is_empty() {
                    continue;
                }
                let Ok(rec) = serde_json::from_str::<EventRecord>(&line) else { continue };
                if rec.seq > after && !visit(rec) {
                    return Ok(());
                }
            }
        }
        Ok(())
    }

    /// Segments newest first, so a page from the end reads only the segments it
    /// needs however long the log is. A segment whose first record is at or past
    /// `before` holds nothing for the page and is skipped after one line.
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        for (_, path) in self.segments(id)?.into_iter().rev() {
            if first_seq(&path)?.is_some_and(|first| first >= before) {
                continue;
            }
            let mut text = String::new();
            BufReader::new(crate::config::private_state_file(&path)?).read_to_string(&mut text)?;
            for line in text.lines().rev() {
                if line.trim().is_empty() {
                    continue;
                }
                let Ok(rec) = serde_json::from_str::<EventRecord>(line) else { continue };
                if rec.seq >= before {
                    continue;
                }
                if rec.seq <= after || !visit(rec) {
                    return Ok(());
                }
            }
        }
        Ok(())
    }

    fn flush(&self) -> Result<()> {
        for w in self.writers.lock().unwrap().values() {
            w.file.sync_data()?;
        }
        Ok(())
    }

    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        let mut out = Vec::new();
        for (_, path) in self.segments(id)? {
            let file = crate::config::private_state_file(&path)?;
            for line in BufReader::new(file).lines() {
                let line = line?;
                if line.trim().is_empty() {
                    continue;
                }
                let rec: EventRecord = match serde_json::from_str(&line) {
                    Ok(r) => r,
                    Err(_) => continue,
                };
                if rec.seq > after {
                    out.push(rec);
                    if out.len() >= limit {
                        return Ok(out);
                    }
                }
            }
        }
        Ok(out)
    }

    fn delete(&self, id: &str) -> Result<()> {
        self.writers.lock().unwrap().remove(id);
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
