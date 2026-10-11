use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// A built-in session store format. The id is the `sessions.adapter` value
/// of a harness profile. Store layouts per version and the evidence for each
/// are in plans/cmux-next/chat-index-formats.md; default roots per platform
/// are in `roots/table.rs`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AdapterKind {
    /// Root: `<CLAUDE_CONFIG_DIR|~/.claude>/projects`.
    ClaudeCode,
    /// Root: `<CODEX_HOME|~/.codex>` (state DB, session index, rollouts).
    Codex,
    /// Root: the OpenCode data dir (`<XDG_DATA_HOME>/opencode`): DBs and JSON storage.
    OpenCode,
    /// Root: the Pi sessions dir (`<PI_CODING_AGENT_DIR|~/.pi/agent>/sessions`).
    Pi,
    /// Root: the Gemini home (`<GEMINI_CLI_HOME|~>/.gemini`).
    Gemini,
    /// Root: `~/.cursor/chats`. `meta.json`, else the `meta` row of `store.db`.
    CursorAgent,
    /// Root: the Amp local thread mirror (`~/.local/share/amp/threads`).
    Amp,
    /// Root: the Qwen Code home (`<QWEN_HOME|~/.qwen>`).
    QwenCode,
    /// Root: the Copilot CLI home (`<COPILOT_HOME|~/.copilot>`).
    CopilotCli,
    /// xAI Grok Build. Root: `<GROK_HOME|~/.grok>/sessions`.
    Grok,
    /// superagent-ai grok-cli (`grok-dev`). Root: `~/.grok` (`grok.db`).
    GrokCli,
    /// Moonshot kimi-cli (Python). Root: `<KIMI_SHARE_DIR|~/.kimi>`.
    KimiCli,
    /// Moonshot Kimi Code (TypeScript). Root: `<KIMI_CODE_HOME|~/.kimi-code>`.
    KimiCode,
    /// Root: the goose sessions dir (`sessions.db` and legacy `.jsonl`).
    Goose,
    /// Factory Droid. Root: `~/.factory/sessions`.
    Droid,
    /// Cline: a VS Code globalStorage dir (`saoudrizwan.claude-dev`) or the
    /// CLI data dir (`~/.cline/data`).
    Cline,
    /// Roo Code: a VS Code globalStorage dir (`rooveterinaryinc.roo-cline`).
    RooCode,
    /// Kilo Code extension before the Kilo CLI (`kilocode.kilo-code`
    /// globalStorage, `~/.kilocode/cli/global`).
    KiloCode,
    /// Kilo CLI (OpenCode fork). Root: `<XDG_DATA_HOME>/kilo`.
    Kilo,
    /// Charm Crush. Root: one project data dir holding `crush.db`.
    Crush,
    /// Augment Auggie CLI. Root: `~/.augment/sessions`.
    Auggie,
    /// Continue (CLI and IDE). Root: `<CONTINUE_GLOBAL_DIR|~/.continue>/sessions`.
    Continue,
    /// OpenHands CLI. Root: `~/.openhands/conversations`.
    #[serde(rename = "openhands")]
    OpenHands,
}

impl AdapterKind {
    pub const ALL: [Self; 23] = [
        Self::ClaudeCode,
        Self::Codex,
        Self::OpenCode,
        Self::Pi,
        Self::Gemini,
        Self::CursorAgent,
        Self::Amp,
        Self::QwenCode,
        Self::CopilotCli,
        Self::Grok,
        Self::GrokCli,
        Self::KimiCli,
        Self::KimiCode,
        Self::Goose,
        Self::Droid,
        Self::Cline,
        Self::RooCode,
        Self::KiloCode,
        Self::Kilo,
        Self::Crush,
        Self::Auggie,
        Self::Continue,
        Self::OpenHands,
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
            Self::QwenCode => "qwen-code",
            Self::CopilotCli => "copilot-cli",
            Self::Grok => "grok",
            Self::GrokCli => "grok-cli",
            Self::KimiCli => "kimi-cli",
            Self::KimiCode => "kimi-code",
            Self::Goose => "goose",
            Self::Droid => "droid",
            Self::Cline => "cline",
            Self::RooCode => "roo-code",
            Self::KiloCode => "kilo-code",
            Self::Kilo => "kilo",
            Self::Crush => "crush",
            Self::Auggie => "auggie",
            Self::Continue => "continue",
            Self::OpenHands => "openhands",
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
