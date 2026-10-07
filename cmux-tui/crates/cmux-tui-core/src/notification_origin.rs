//! Who posted a notification and why: `source` (`notification-source-v1`)
//! and `program_status` (`notification-program-status-v1`), and the JSON
//! every notification surface builds from them (the `notification` event,
//! `list-notifications` rows, the resource value and its durable receipt).
//!
//! `program_status` is the structured reason of a notification the daemon
//! posts for an OSC 7501 record that entered `blocked` or `error`
//! (`Mux::post_program_status_alerts`). The daemon still sends the English
//! title and body; a client that knows the field builds the body in its own
//! language from it. Every other producer leaves it absent.

use std::collections::HashMap;

use serde_json::{Value, json};

use crate::mux::{NotificationEvent, ResourceNotification};

/// `program_status` on the `notification` event, `list-notifications` rows
/// and resource notification values (`extra.program_status`).
pub const NOTIFICATION_PROGRAM_STATUS_CAPABILITY: &str = "notification-program-status-v1";

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

/// The record state a program status notification reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProgramStatusNoticeState {
    /// The program waits for the user.
    Blocked,
    /// The program failed.
    Error,
}

impl ProgramStatusNoticeState {
    pub fn as_str(self) -> &'static str {
        match self {
            ProgramStatusNoticeState::Blocked => "blocked",
            ProgramStatusNoticeState::Error => "error",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "blocked" => Some(ProgramStatusNoticeState::Blocked),
            "error" => Some(ProgramStatusNoticeState::Error),
            _ => None,
        }
    }
}

/// What a `blocked` program waits for (OSC 7501 `kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProgramStatusNoticeKind {
    Permission,
    Question,
    Auth,
}

impl ProgramStatusNoticeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ProgramStatusNoticeKind::Permission => "permission",
            ProgramStatusNoticeKind::Question => "question",
            ProgramStatusNoticeKind::Auth => "auth",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "permission" => Some(ProgramStatusNoticeKind::Permission),
            "question" => Some(ProgramStatusNoticeKind::Question),
            "auth" => Some(ProgramStatusNoticeKind::Auth),
            _ => None,
        }
    }
}

/// `program_status` of a notification:
/// `{"state": "blocked"|"error", "kind": "permission"|"question"|"auth"|null,
/// "msg": string|null}`. `msg` is the program's message after the daemon
/// removed control and invisible formatting characters and capped it; it is
/// display text only, never a link or a command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationProgramStatus {
    pub state: ProgramStatusNoticeState,
    pub kind: Option<ProgramStatusNoticeKind>,
    pub msg: Option<String>,
}

impl NotificationProgramStatus {
    pub fn to_json(&self) -> Value {
        json!({
            "state": self.state.as_str(),
            "kind": self.kind.map(ProgramStatusNoticeKind::as_str),
            "msg": self.msg,
        })
    }

    /// `None` unless `value` is an object with a known `state`. An unknown
    /// `kind` reads as no kind and a `msg` that is not a string as no message,
    /// so a newer writer's value still shows.
    pub fn from_json(value: &Value) -> Option<Self> {
        let state = value.get("state").and_then(Value::as_str)?;
        Some(NotificationProgramStatus {
            state: ProgramStatusNoticeState::parse(state)?,
            kind: value
                .get("kind")
                .and_then(Value::as_str)
                .and_then(ProgramStatusNoticeKind::parse),
            msg: value.get("msg").and_then(Value::as_str).map(str::to_owned),
        })
    }

    /// `program_status` of a stored `notification.create` intent (absent in
    /// intents written before it existed).
    pub(crate) fn from_intent(intent: &Value) -> Option<Self> {
        intent.get("program_status").and_then(Self::from_json)
    }
}

/// The resource value's `extra`: `source`, and `program_status` when the
/// notification has one. Stored under `extra`, which every registry schema
/// already accepts, so a downgraded daemon still opens the receipt.
pub(crate) fn notification_extra(notification: &ResourceNotification) -> Value {
    extra_value(notification.source, notification.program_status.as_ref())
}

pub(crate) fn extra_value(
    source: NotificationSource,
    program_status: Option<&NotificationProgramStatus>,
) -> Value {
    let mut extra = json!({"source": source.as_str()});
    if let Some(program_status) = program_status {
        extra["program_status"] = program_status.to_json();
    }
    extra
}

/// `source` and `program_status` of a durable receipt from its `extra`. A
/// receipt written before sources derives its source from the idempotency
/// key; one written before program statuses has none.
pub(crate) fn receipt_origin(
    extra: Option<&HashMap<String, Value>>,
    idempotency_key: &str,
) -> (NotificationSource, Option<NotificationProgramStatus>) {
    let source = extra
        .and_then(|extra| extra.get("source"))
        .and_then(Value::as_str)
        .and_then(NotificationSource::parse)
        .unwrap_or_else(|| NotificationSource::from_legacy_key(idempotency_key));
    let program_status = extra
        .and_then(|extra| extra.get("program_status"))
        .and_then(NotificationProgramStatus::from_json);
    (source, program_status)
}

impl NotificationEvent {
    /// The legacy `notification` event.
    pub(crate) fn event_json(&self) -> Value {
        let mut value = json!({
            "event": "notification",
            "notification": self.notification,
            "title": self.title,
            "body": self.body,
            "level": self.level.as_str(),
            "surface": self.surface,
            "source": self.source.as_str(),
        });
        if let Some(program_status) = &self.program_status {
            value["program_status"] = program_status.to_json();
        }
        value
    }
}

/// One `list-notifications` row.
pub(crate) fn list_row_json(row: &ResourceNotification, acknowledged: bool) -> Value {
    let mut value = json!({
        "id": row.id,
        "title": row.title,
        "subtitle": row.subtitle,
        "body": row.body,
        "level": row.level.as_str(),
        "terminal_id": row.terminal_id,
        "surface": row.surface,
        "created_at_ms": row.created_at_ms,
        "source": row.source.as_str(),
        "acknowledged": acknowledged,
    });
    if let Some(program_status) = &row.program_status {
        value["program_status"] = program_status.to_json();
    }
    value
}
