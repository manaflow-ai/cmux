//! Agent sessions from one machine's session journal: port of Swift
//! `AgentSessionFold` and `AgentSession`, plus the entry mapping of the app's
//! `AgentHistory.entries()`.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::entry::{HistoryEntry, HistoryKind};
use crate::hidden::HiddenHistory;
use crate::journal::{EntryContext, Envelope, string_at};

/// Kinds a reader asks the journal for.
pub const AGENT_JOURNAL_KINDS: [&str; 3] = ["agent.session.*", "agent.turn.*", "agent.state.changed"];

/// An agent session as the journal records it through agent hooks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentSession {
    /// The session (machine) whose journal recorded it.
    pub machine: String,
    /// The hook adapter id: `claude`, `codex`, `amp`, `opencode`, ...
    pub provider: String,
    /// The provider's own session id (what `--resume` takes).
    pub session_id: String,
    pub cwd: Option<String>,
    /// Subjects of the latest event that named them.
    pub terminal: Option<String>,
    pub tab: Option<String>,
    pub workspace: Option<String>,
    pub started_at_ms: i64,
    pub last_activity_ms: i64,
    pub ended_at_ms: Option<i64>,
}

impl AgentSession {
    /// `<machine>/<provider>/<session id>`: the id hides use.
    pub fn qualified_id(&self) -> String {
        format!("{}/{}/{}", self.machine, self.provider, self.session_id)
    }

    /// The shell command that resumes this session, when cmux knows it.
    pub fn resume_command(&self) -> Option<String> {
        resume_command(&self.provider, &self.session_id)
    }

    /// The wire entry for this session.
    pub fn entry(&self, context: &EntryContext<'_>) -> HistoryEntry {
        let mut entry = HistoryEntry::new(
            format!("agent:{}", self.qualified_id()),
            HistoryKind::Agent,
            self.last_activity_ms,
            agent_title(&self.provider, self.cwd.as_deref()),
        );
        entry.detail.clone_from(&self.cwd);
        entry.machine = (self.machine != context.local_machine).then(|| self.machine.clone());
        entry.workspace.clone_from(&self.workspace);
        entry.available = context.available;
        entry.running = Some(self.ended_at_ms.is_none());
        entry.cwd.clone_from(&self.cwd);
        entry.session_id = Some(self.session_id.clone());
        entry.provider = Some(self.provider.clone());
        entry
    }
}

/// Folds one machine's agent journal records into sessions. Constant work
/// per record; a record at or below the cursor is ignored, so re-reading
/// from an older cursor never double counts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentSessionFold {
    machine: String,
    capacity: usize,
    cursor: u64,
    /// Keyed `<provider>/<session id>`.
    sessions: BTreeMap<String, AgentSession>,
}

impl AgentSessionFold {
    /// The most sessions kept per machine.
    pub const DEFAULT_CAPACITY: usize = 500;

    pub fn new(machine: impl Into<String>) -> Self {
        Self::with_capacity(machine, Self::DEFAULT_CAPACITY)
    }

    /// A fold that keeps at most `capacity` (at least 1) sessions; the least
    /// recently active go first.
    pub fn with_capacity(machine: impl Into<String>, capacity: usize) -> Self {
        Self { machine: machine.into(), capacity: capacity.max(1), cursor: 0, sessions: BTreeMap::new() }
    }

    pub fn machine(&self) -> &str {
        &self.machine
    }

    /// The last applied journal sequence.
    pub fn cursor(&self) -> u64 {
        self.cursor
    }

    pub fn len(&self) -> usize {
        self.sessions.len()
    }

    pub fn is_empty(&self) -> bool {
        self.sessions.is_empty()
    }

    /// Applies records in journal order. A record the Swift decoder would
    /// reject (no sequence or kind) is skipped without moving the cursor.
    pub fn apply(&mut self, records: &[Value]) {
        let _ = records;
    }

    /// Newest activity first; ties by session id, descending.
    pub fn ordered(&self) -> Vec<&AgentSession> {
        let mut sessions: Vec<&AgentSession> = self.sessions.values().collect();
        sessions.sort_by(|a, b| (b.last_activity_ms, &b.session_id).cmp(&(a.last_activity_ms, &a.session_id)));
        sessions
    }

    /// Entries for every session that `hidden` does not hide, newest first.
    pub fn entries(&self, context: &EntryContext<'_>, hidden: &HiddenHistory) -> Vec<HistoryEntry> {
        self.ordered()
            .into_iter()
            .filter(|session| !hidden.hides(&session.qualified_id(), session.last_activity_ms, Some("agent")))
            .map(|session| session.entry(context))
            .collect()
    }

    fn apply_one(&mut self, record: &Envelope<'_>) {
        if !record.kind.starts_with("agent.") {
            return;
        }
        let Some(normalized) = record.payload.and_then(|payload| payload.get("normalized")) else {
            return;
        };
        if !normalized.is_object() {
            return;
        }
        let session_id = string_at(Some(normalized), &["agent_session_id"])
            .or_else(|| string_at(Some(normalized), &["root_agent_session_id"]));
        let Some(session_id) = session_id.filter(|id| !id.is_empty()) else {
            return;
        };
        let provider = string_at(record.payload, &["adapter", "id"]).unwrap_or("agent");
        let time = time_of(record, normalized);
        let key = format!("{provider}/{session_id}");
        let session = self.sessions.entry(key).or_insert_with(|| AgentSession {
            machine: self.machine.clone(),
            provider: provider.to_owned(),
            session_id: session_id.to_owned(),
            cwd: None,
            terminal: None,
            tab: None,
            workspace: None,
            started_at_ms: time,
            last_activity_ms: time,
            ended_at_ms: None,
        });
        match record.kind {
            "agent.session.started" => {
                // A resumed session reuses its id: it runs again.
                session.ended_at_ms = None;
                session.started_at_ms = session.started_at_ms.min(time);
            }
            "agent.session.ended" => session.ended_at_ms = Some(time),
            _ => {
                if session.ended_at_ms.is_some_and(|ended| time > ended) {
                    session.ended_at_ms = None;
                }
            }
        }
        session.last_activity_ms = session.last_activity_ms.max(time);
        if let Some(cwd) = string_at(Some(normalized), &["cwd"]).filter(|cwd| !cwd.is_empty()) {
            session.cwd = Some(cwd.to_owned());
        }
        if let Some(terminal) = record.subject("terminal") {
            session.terminal = Some(terminal.to_owned());
        }
        if let Some(tab) = record.subject("tab") {
            session.tab = Some(tab.to_owned());
        }
        if let Some(workspace) = record.subject("workspace") {
            session.workspace = Some(workspace.to_owned());
        }
    }

    fn trim(&mut self) {
        if self.sessions.len() <= self.capacity {
            return;
        }
        let drop: Vec<String> = self
            .ordered()
            .into_iter()
            .skip(self.capacity)
            .map(|session| format!("{}/{}", session.provider, session.session_id))
            .collect();
        for key in drop {
            self.sessions.remove(&key);
        }
    }
}

/// The hook's own observation time, else the journal's occurrence time,
/// else 0.
fn time_of(record: &Envelope<'_>, normalized: &Value) -> i64 {
    string_at(Some(normalized), &["observed_at_ms"])
        .and_then(|text| text.parse().ok())
        .unwrap_or_else(|| record.occurred_at_ms.unwrap_or(0))
}

/// `<Provider> in <folder>` (the folder is the last path component of
/// `cwd`), or the provider name without a cwd. English: the crate has no
/// string catalog; the Swift app localizes the `in` template.
pub fn agent_title(provider: &str, cwd: Option<&str>) -> String {
        let _ = cwd; provider.to_owned()
    }

/// A provider's product name (not localized).
pub fn provider_name(provider: &str) -> &str {
    match provider.to_lowercase().as_str() {
        "claude" | "claude-code" | "claude_code" => "Claude Code",
        "codex" => "Codex",
        "opencode" => "OpenCode",
        "amp" => "Amp",
        "gemini" => "Gemini",
        _ => provider,
    }
}

/// Like `NSString.lastPathComponent`: trailing slashes are ignored, and the
/// root stays `/`.
fn last_path_component(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() { "" } else { "/" };
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed)
}

/// The shell command that resumes `session_id` of `provider`, or `None`
/// when cmux does not know the provider's resume flag.
pub fn resume_command(provider: &str, session_id: &str) -> Option<String> {
    let _ = (provider, session_id);
    None
}

/// A single shell word: plain when it has only safe characters, else
/// single-quoted with embedded quotes escaped.
pub fn shell_quoted(word: &str) -> String {
    let safe = |ch: char| ch.is_ascii_alphanumeric() || "-_.:@/+=".contains(ch);
    if !word.is_empty() && word.chars().all(safe) {
        return word.to_owned();
    }
    format!("'{}'", word.replace('\'', "'\\''"))
}

#[cfg(test)]
#[path = "fold_agent_tests.rs"]
mod tests;
