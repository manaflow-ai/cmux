use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// A built-in session store format. The id is the `sessions.adapter` value
/// of a harness profile.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AdapterKind {
    /// Root: `<CLAUDE_CONFIG_DIR|~/.claude>/projects`.
    ClaudeCode,
    /// Root: `<CODEX_HOME|~/.codex>` (state DB, session index, rollouts).
    Codex,
    /// Root: the OpenCode data dir (`<XDG_DATA_HOME>/opencode`) with `opencode*.db`.
    OpenCode,
    /// Root: the Pi sessions dir (`<PI_CODING_AGENT_DIR|~/.pi/agent>/sessions`).
    Pi,
    /// Root: the Gemini home (`<GEMINI_CLI_HOME|~>/.gemini`).
    Gemini,
    /// Root: `~/.cursor/chats`. Only `meta.json` is read.
    CursorAgent,
    /// Root: the Amp local thread mirror (`~/.local/share/amp/threads`).
    Amp,
}

impl AdapterKind {
    pub const ALL: [Self; 7] = [
        Self::ClaudeCode,
        Self::Codex,
        Self::OpenCode,
        Self::Pi,
        Self::Gemini,
        Self::CursorAgent,
        Self::Amp,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::ClaudeCode => "claude-code",
            Self::Codex => "codex",
            Self::OpenCode => "opencode",
            Self::Pi => "pi",
            Self::Gemini => "gemini",
            Self::CursorAgent => "cursor-agent",
            Self::Amp => "amp",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.id() == id)
    }
}

/// Where a title came from, best first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TitleSource {
    /// The user named the chat (Claude custom title, Codex name, Pi name).
    Custom,
    /// The harness generated a title or summary.
    Ai,
    /// A prompt the user typed (last or first).
    Prompt,
}

/// How a chat opens again.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Resume {
    /// Resume through acpmux adopt (ACP `session/load` or `--resume`).
    Adopt,
    /// Run this argv in a terminal tab. `cwd_needed`: run it in the recorded cwd.
    #[serde(rename_all = "camelCase")]
    Argv { argv: Vec<String>, cwd_needed: bool },
    /// No resume path; show the transcript read-only.
    ReadOnly,
}

/// Merge key: the same session seen through two roots is one chat.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatKey {
    pub harness: AdapterKind,
    pub session_id: String,
}

/// One chat as an adapter reads it. Metadata only: `title` is the one piece
/// of user text it holds (first line, at most 120 characters).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatEntry {
    pub harness: AdapterKind,
    pub session_id: String,
    pub title: Option<String>,
    pub title_source: Option<TitleSource>,
    pub cwd: Option<String>,
    pub created_ms: Option<i64>,
    pub updated_ms: i64,
    /// None when the store gives no cheap count (Cursor, Codex `.zst`).
    pub message_count: Option<u64>,
    pub source_path: PathBuf,
    /// Codex: the client that started the thread (for example "Codex Desktop").
    pub originator: Option<String>,
    pub archived: bool,
    pub resume: Resume,
}

impl ChatEntry {
    pub fn key(&self) -> ChatKey {
        ChatKey { harness: self.harness, session_id: self.session_id.clone() }
    }
}
