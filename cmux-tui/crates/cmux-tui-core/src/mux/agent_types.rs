//! Agent status records: the public state and source enums, the per-terminal
//! record, the journal roster host, and the pure helpers that map agent hook
//! journal entries to states, notifications and published session ids.

use serde_json::Value;

use super::NotificationLevel;
use crate::SurfaceId;
use crate::resource::TerminalPublicId;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    Working,
    Blocked,
    Idle,
    Done,
    Unknown,
}

impl AgentState {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentState::Working => "working",
            AgentState::Blocked => "blocked",
            AgentState::Idle => "idle",
            AgentState::Done => "done",
            AgentState::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentSource {
    /// An installed userland agent plugin wrote the observation.
    Plugin,
    /// Legacy source value emitted by pre-userland screen detection. Current
    /// core code never emits it; the reducer keeps it so old journals replay
    /// after screen detection moves to a userland plugin.
    Detected,
    Socket,
    Hook,
}

impl AgentSource {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentSource::Plugin => "plugin",
            AgentSource::Detected => "detected",
            AgentSource::Socket => "socket",
            AgentSource::Hook => "hook",
        }
    }
}

/// The agent-record state a committed hook journal event implies, or `None`
/// for events that carry no lifecycle transition (child agents, unclassified
/// state changes) so they never churn the record.
pub(super) fn agent_state_for_hook_kind(kind: &str) -> Option<AgentState> {
    Some(match kind {
        // A freshly started session sits at its prompt; a completed turn
        // returns to it.
        "agent.session.started" | "agent.turn.completed" => AgentState::Idle,
        "agent.turn.started" => AgentState::Working,
        "agent.approval.requested"
        | "agent.question.requested"
        | "agent.plan_review.requested"
        | "agent.error.reported" => AgentState::Blocked,
        "agent.session.ended" => AgentState::Done,
        _ => return None,
    })
}

/// Title, body, and level for the notification an agent hook event earns,
/// or `None` for transitions that need no attention (session start, turn
/// start, child lifecycle, session end).
pub(super) fn agent_hook_notification(
    ingress: &crate::JournalIngress,
) -> Option<(String, String, NotificationLevel)> {
    const BODY_MAX_CHARS: usize = 512;
    let (verb, level) = match ingress.kind.as_str() {
        "agent.turn.completed" => ("finished", NotificationLevel::Info),
        "agent.approval.requested" => ("needs approval", NotificationLevel::Warning),
        "agent.question.requested" => ("asked a question", NotificationLevel::Warning),
        "agent.plan_review.requested" => ("requested plan review", NotificationLevel::Warning),
        "agent.error.reported" => ("reported an error", NotificationLevel::Error),
        _ => return None,
    };
    let adapter = ingress
        .payload
        .get("adapter")
        .and_then(|adapter| adapter.get("id"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .unwrap_or("Agent");
    let mut agent = String::with_capacity(adapter.len());
    let mut chars = adapter.chars();
    if let Some(first) = chars.next() {
        agent.extend(first.to_uppercase());
        agent.push_str(chars.as_str());
    }
    // Prompt and message text is redacted before the journal accepts it, so
    // the body is the one structural field a viewer can act on: the tool an
    // approval is waiting on. Everything else stays empty rather than leaking
    // a redaction marker into the notification feed.
    let normalized = ingress.payload.get("normalized");
    let body = ["tool_name"]
        .into_iter()
        .filter_map(|field| normalized.and_then(|value| value.get(field)).and_then(Value::as_str))
        .map(str::trim)
        .find(|text| !text.is_empty() && *text != "[redacted]")
        .map(|text| text.chars().take(BODY_MAX_CHARS).collect::<String>())
        .unwrap_or_default();
    Some((format!("{agent} {verb}"), body, level))
}

/// A stored projection state string as its typed form; unknown spellings
/// degrade to `Unknown`, which every agents view hides.
pub(super) fn parse_projection_agent_state(value: &str) -> AgentState {
    match value {
        "working" => AgentState::Working,
        "blocked" => AgentState::Blocked,
        "idle" => AgentState::Idle,
        "done" => AgentState::Done,
        _ => AgentState::Unknown,
    }
}

/// The agent roster host: reducer state plus its journal fold cursor.
/// Lock ordering rule: never acquire another `Mux` lock while holding this
/// one - fold paths release it before persisting, and commit paths only
/// take a read after their registry/state locks, so `registry -> roster`
/// is the single global order.
#[derive(Debug, Default)]
pub(super) struct AgentRosterHost {
    pub(super) roster: crate::journal_reducers::AgentRoster,
    pub(super) cursor: u64,
}

pub(super) fn agent_provider_identity(ingress: &crate::JournalIngress) -> Option<String> {
    ingress
        .payload
        .get("normalized")
        .and_then(|normalized| normalized.get("agent_type"))
        .and_then(Value::as_str)
        .or_else(|| {
            ingress
                .payload
                .get("adapter")
                .and_then(|adapter| adapter.get("id"))
                .and_then(Value::as_str)
        })
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_ascii_lowercase)
}

#[derive(Debug, Clone)]
pub struct AgentRecord {
    pub surface: SurfaceId,
    pub terminal_id: TerminalPublicId,
    pub state: AgentState,
    pub source: AgentSource,
    pub session: Option<String>,
    /// The reporting adapter id (`claude`, `codex`, ...) when a hook has
    /// claimed the terminal; absent for socket-only reports.
    pub agent: Option<String>,
    pub updated_at_ms: u64,
}

/// Longest hook session id published for resume. Claude session ids are
/// UUIDs; longer values are dropped rather than truncated into a wrong id.
const MAX_PUBLISHED_AGENT_SESSION_ID_BYTES: usize = 256;

/// The hook session id a client may use to resume the agent, or `None` for
/// the local generation token that session-less adapters receive and for ids
/// that are too long or contain anything beyond `[A-Za-z0-9._:-]`. Hook
/// payloads can come from remote hosts, and clients pass the id to a resume
/// command.
pub(super) fn published_agent_session_id(
    terminal_id: &TerminalPublicId,
    session_id: &str,
) -> Option<String> {
    let portable = !session_id.is_empty()
        && session_id.len() <= MAX_PUBLISHED_AGENT_SESSION_ID_BYTES
        && session_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'));
    (portable && !session_id.starts_with(&format!("legacy:{terminal_id}:")))
        .then(|| session_id.to_owned())
}

/// Session-less adapters get a local generation token. The journal sequence
/// is durable and strictly increasing, so a new legacy lifecycle cannot reuse
/// the previous fence identity after restart.
pub(super) fn legacy_hook_session_id(terminal_id: &TerminalPublicId, sequence: u64) -> String {
    crate::journal_reducers::legacy_hook_session_id(terminal_id.as_str(), sequence)
}

#[derive(Debug, Clone)]
pub(super) struct TerminalAgentRecord {
    pub(super) state: AgentState,
    pub(super) source: AgentSource,
    pub(super) session: Option<String>,
    pub(super) agent: Option<String>,
    /// The agent's own session id from its hook stream (Claude's
    /// `session_id`), published as `extra.agent_session_id` so clients can
    /// resume it. Absent for agents without a native hook session.
    pub(super) agent_session_id: Option<String>,
    pub(super) updated_at_ms: u64,
}

/// Who initiated an agent projection commit: a direct socket/SDK report
/// (which must echo its intent into the journal so the roster fold sees
/// it), or the roster fold itself applying a journal-derived delta (which
/// must not echo, or every hook event would append a second record).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum AgentReportOrigin {
    Direct,
    RosterFold,
}

pub(super) enum AgentReportTarget<'a> {
    Surface(SurfaceId),
    Resource { selectors: &'a crate::ResourceSelectors, terminal_id: &'a TerminalPublicId },
}
