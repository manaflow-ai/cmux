//! The records a chat's log and status carry: events, waits, watches, forks and returns.

use super::*;

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

/// A chat's model switch for a sustained overload (`SessionMeta::capacity_fallback`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CapacityFallback {
    /// The chat's own model, as it named it.
    pub from: String,
    /// The smaller model it runs meanwhile.
    pub to: String,
}
