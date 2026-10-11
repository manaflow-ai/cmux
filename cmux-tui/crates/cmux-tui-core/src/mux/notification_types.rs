//! Notification records: who posted one (`NotificationSource`), the event
//! broadcast when it is posted, the durable resource row, and the per-surface
//! unread marker.

use super::NotificationLevel;
use crate::SurfaceId;
use crate::resource::{NotificationPublicId, TerminalPublicId};

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

#[derive(Debug, Clone)]
pub struct NotificationEvent {
    pub notification: u64,
    pub title: String,
    pub body: String,
    pub level: NotificationLevel,
    pub surface: Option<SurfaceId>,
    pub source: NotificationSource,
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
    pub created_at_ms: u64,
    pub source: NotificationSource,
    pub(crate) surface: Option<SurfaceId>,
}

#[derive(Debug, Clone, Copy)]
pub struct SurfaceNotification {
    pub notification: u64,
    pub level: NotificationLevel,
    pub unread: bool,
    pub source: NotificationSource,
}
