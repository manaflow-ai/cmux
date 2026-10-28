//! Notification records: who posted one (`NotificationSource`), the event
//! broadcast when it is posted, the durable resource row, and the per-surface
//! unread marker.

use std::sync::Arc;

use super::NotificationLevel;
use crate::SurfaceId;
use crate::resource::{NotificationPublicId, TerminalPublicId, WorkspacePublicId};

/// Who posted a notification (`notification-source-v1`). Frontends apply
/// per-source preferences from it instead of guessing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NotificationSource {
    /// `cmux notify`, the `notify` verb without a source, or
    /// `notification.create`.
    Cli,
    /// A program in the terminal: OSC 9, OSC 777 `notify` or kitty OSC 99,
    /// parsed by the daemon from the terminal's output.
    Terminal,
    /// An agent hook (Claude Code, Codex, ...), daemon-side or reported by a
    /// frontend.
    Agent,
    /// Any other daemon producer.
    Daemon,
}

impl NotificationSource {
    pub fn as_str(self) -> &'static str {
        match self {
            NotificationSource::Cli => "cli",
            NotificationSource::Terminal => "terminal",
            NotificationSource::Agent => "agent",
            NotificationSource::Daemon => "daemon",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "cli" => Some(NotificationSource::Cli),
            "terminal" => Some(NotificationSource::Terminal),
            "agent" => Some(NotificationSource::Agent),
            "daemon" => Some(NotificationSource::Daemon),
            _ => None,
        }
    }

    /// The source of a durable notification written before sources existed,
    /// from its idempotency key: agent hooks mint `agent-hook-notification-*`;
    /// every other producer then was `notify` or `notification.create`.
    pub(crate) fn from_legacy_key(idempotency_key: &str) -> Self {
        if idempotency_key.starts_with("agent-hook-notification-") {
            NotificationSource::Agent
        } else {
            NotificationSource::Cli
        }
    }
}

/// `desktop` on `notification.create` and the `notification` event: false
/// asks the app for no desktop banner (`cmux notify --desktop false`).
pub const NOTIFICATION_DESKTOP_CAPABILITY: &str = "notification-desktop-v1";

/// `reply` on `notification.create` and the `notification` event: true asks
/// the app for a banner that takes a typed reply, which it pastes into the
/// notifying terminal and submits (`cmux notify --reply`).
pub const NOTIFICATION_REPLY_CAPABILITY: &str = "notification-reply-v1";

#[derive(Debug, Clone)]
pub struct NotificationEvent {
    /// The ledger row's id (`list-notifications` `id`), so a client joins this event's
    /// memory-only texts to the durable row. None for a notification with no row.
    pub id: Option<String>,
    /// An agent's whole last message (markdown, up to `LIVE_MESSAGE_CHARS`), or the error text
    /// of a failed turn, memory only, for the phone's Feed (`preview` is the banner's cut).
    pub message: Option<String>,
    /// The prompt of the agent turn this notification ends (markdown, up to
    /// `LIVE_MESSAGE_CHARS`), memory only, for the phone Feed's quote.
    pub prompt: Option<String>,
    /// The posting agent's harness session id (`list-agents` `agent_session_id`), so a reply
    /// from the Feed goes only to that session (`send` `expect_agent`).
    pub session: Option<String>,
    pub notification: u64,
    pub title: String,
    /// Second line under the title, as `cmux notify --subtitle`.
    pub subtitle: Option<String>,
    pub body: String,
    /// An agent's last message for a turn-done or error banner, memory only: never in the
    /// durable ledger (`agent_prompts.rs`). The app shows it per its Show Previews setting.
    pub preview: Option<String>,
    /// The question an agent's question notification asks (`agent_hook_question.rs`), memory
    /// only: `{harness, tool_use_id?, questions: [{question, header?, multiSelect, options}]}`.
    pub question: Option<Arc<serde_json::Value>>,
    pub level: NotificationLevel,
    pub surface: Option<SurfaceId>,
    /// The workspace a terminal-less notification belongs to (`cmux notify
    /// --workspace ws_…`); None for a terminal's or a session-level one.
    pub workspace_id: Option<WorkspacePublicId>,
    pub source: NotificationSource,
    /// false: the app shows no desktop banner (`notify --desktop false`).
    pub desktop: bool,
    /// true: the banner takes a typed reply for the terminal (`notify --reply`).
    pub reply: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceNotification {
    pub id: NotificationPublicId,
    pub title: String,
    /// Second line under the title, as `cmux notify --subtitle`.
    pub subtitle: Option<String>,
    pub body: String,
    pub level: NotificationLevel,
    pub terminal_id: Option<TerminalPublicId>,
    /// `notify --workspace ws_…`: the workspace it belongs to, with no
    /// terminal. Stored as the row's `extra.workspace_id`.
    pub workspace_id: Option<WorkspacePublicId>,
    pub created_at_ms: u64,
    pub source: NotificationSource,
    pub(crate) surface: Option<SurfaceId>,
    /// false: the app shows no desktop banner (`notify --desktop false`).
    pub desktop: bool,
    /// true: the banner takes a typed reply for the terminal (`notify --reply`).
    pub reply: bool,
}

/// The program that held a notification's terminal when it was posted
/// (memory only): a typed reply goes only to that same program
/// (cmux-next-ios `mailbox_apply.rs`), never to whatever runs there later.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationPoster {
    /// The terminal's foreground process-group leader.
    pub pid: u32,
    /// Its executable, as `process-info`'s `foreground_executable` names it.
    pub executable: String,
}

/// What the daemon remembers about a ledger row it posted in this run
/// (memory only): the `notification` event's number and the poster.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationPost {
    /// The `notification` field of the `notification` event.
    pub notification: u64,
    pub poster: Option<NotificationPoster>,
}

#[derive(Debug, Clone, Copy)]
pub struct SurfaceNotification {
    pub notification: u64,
    pub level: NotificationLevel,
    pub unread: bool,
    pub source: NotificationSource,
}
