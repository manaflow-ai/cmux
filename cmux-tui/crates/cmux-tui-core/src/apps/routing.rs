//! Routes an app's catalog op into this daemon's own `cmux.protocol/2`
//! dispatcher, the same validation and owner code every client goes
//! through, and bridges daemon change events to app subscriptions.
//!
//! Gap: the protocol has no actor field yet, so `actor = app:<id>` and the
//! call's origin are enforced here (scopes, gesture-gated focus ops) and not
//! stamped on the owner's records. When the dispatcher grows an actor, pass
//! `app` and `origin` through.

use std::sync::{Arc, Weak};

use serde_json::{Value, json};

use super::mirror::Origin;
use super::supervisor::OpRouter;
use crate::mux::Mux;
use crate::{Actor, MuxEvent, resource_router};

use super::envelope::error;
pub(crate) use super::envelope::{answer, is_daemon_op, request};

pub struct MuxRouter {
    mux: Weak<Mux>,
}

impl MuxRouter {
    pub fn new(mux: &Arc<Mux>) -> Self {
        Self { mux: Arc::downgrade(mux) }
    }
}

impl OpRouter for MuxRouter {
    fn route(
        &self,
        app: &str,
        op: &str,
        params: Value,
        idempotency_key: Option<String>,
        _origin: Origin,
    ) -> Result<Value, Value> {
        let mux = self
            .mux
            .upgrade()
            .ok_or_else(|| error("operation.failed", "the daemon is shutting down"))?;
        if op == AGENT_CHAT_LIST {
            return agent_chat_list(&mux, &params);
        }
        // An app's call has origin app (request-origin.md): gate A2 refuses
        // the operations that need the user.
        crate::request_origin::require_origin(op, crate::request_origin::RequestOrigin::App)
            .map_err(|e| json!({ "code": e.code, "message": e.message, "details": e.details, "retryable": e.retryable }))?;
        let message = request(op, params, idempotency_key)?;
        let parsed = resource_router::parse_resource_request_as(
            &message,
            Actor::App { id: app.to_string() },
        )
        .map_err(|e| answer(op, json!({ "ok": false, "error": e })).unwrap_err())?;
        if resource_router::requires_connection_context(parsed.envelope.operation) {
            return Err(error(
                "operation.unsupported",
                format!("{op} needs a client connection and is not available to apps"),
            ));
        }
        let response = resource_router::handle_parsed_resource_request(&mux, parsed)
            .map_err(|e| answer(op, json!({ "ok": false, "error": e })).unwrap_err())?;
        answer(op, response)
    }

    fn place_sidebar_sections(
        &self,
        sections: &[cmux_layout_reducer::sidebar_doc::Section],
        automatic: bool,
    ) -> Result<Value, super::supervisor::ApiError> {
        let mux = self.mux.upgrade().ok_or_else(|| {
            super::supervisor::ApiError::new("apps.sidebar.unavailable", "the daemon is stopping")
        })?;
        super::sidebar::place(&mux, sections, automatic)
            .map_err(|error| super::supervisor::ApiError::new("apps.sidebar", error.to_string()))
    }

    fn initialize_sidebar_placements(
        &self,
        sections: &[cmux_layout_reducer::sidebar_doc::Section],
    ) -> Result<(), super::supervisor::ApiError> {
        let mux = self.mux.upgrade().ok_or_else(|| {
            super::supervisor::ApiError::new("apps.sidebar.unavailable", "the daemon is stopping")
        })?;
        super::sidebar::initialize(&mux, sections)
            .map_err(|error| super::supervisor::ApiError::new("apps.sidebar", error.to_string()))
    }

    fn owns(&self, op: &str) -> bool {
        is_daemon_op(op) || op == AGENT_CHAT_LIST
    }

    fn start_events(&self, publish: super::supervisor::StreamPublish) {
        let Some(mux) = self.mux.upgrade() else { return };
        // Only the events that invalidate an app stream: every other daemon
        // event (terminal output, titles, notifications) was cloned into this
        // mailbox and woke this thread for nothing.
        let events = mux.subscribe_matching(|event| !streams(event).is_empty());
        drop(mux);
        let _ = std::thread::Builder::new().name("cmux-apps-events".into()).spawn(move || {
            while let Ok(event) = events.recv() {
                for stream in streams(&event) {
                    publish(stream, body(&event));
                }
            }
        });
    }

    /// `github.changed` is live while the Cloud pushes GitHub changes on the feed socket.
    fn stream_live(&self, stream: &str) -> Option<bool> {
        if !GITHUB_STREAMS.contains(&stream) {
            return None;
        }
        Some(self.mux.upgrade().is_some_and(|mux| mux.feed_client().github_push_live()))
    }

    fn spawn_backend_terminal(
        &self,
        side: crate::terminal_backend::pty::BackendSide,
    ) -> anyhow::Result<crate::mux::app_terminals::BackendTerminal> {
        let mux = self.mux.upgrade().ok_or_else(|| anyhow::anyhow!("the daemon is stopping"))?;
        mux.spawn_backend_terminal(side)
    }

    fn backend_terminal_viewed(&self, surface: crate::SurfaceId) -> bool {
        self.mux.upgrade().is_some_and(|mux| mux.backend_terminal_viewed(surface))
    }

    fn close_backend_terminal(&self, surface: crate::SurfaceId) {
        if let Some(mux) = self.mux.upgrade() {
            mux.close_backend_terminal(surface);
        }
    }
}

/// The first App Store chat read (scope `agent_chat:read`), kept for the apps and templates
/// that call it: the daemon answers it from the same chat index as `chat.list`
/// (`mux/chat_index.rs`), in its first shape `{chats}` with times as numbers. It takes
/// `chat.list`'s fields (`limit`, `state`, `before_ms`, `before_id`, `before_machine`), newest first.
const AGENT_CHAT_LIST: &str = "agent_chat.list";

fn agent_chat_list(mux: &Mux, params: &Value) -> Result<Value, Value> {
    let empty = serde_json::Map::new();
    let fields = match params {
        Value::Null => &empty,
        Value::Object(fields) => fields,
        _ => return Err(error("validation.invalid", "agent_chat.list takes an object of fields")),
    };
    let query = crate::mux::chat_index::ChatQuery::from_fields(fields)
        .map_err(|(field, reason)| error("validation.invalid", format!("{field}: {reason}")))?;
    let chats = mux
        .chat_rows_matching(&query)
        .into_iter()
        .map(|mut row| {
            if let Some(fields) = row.as_object_mut() {
                for name in ["since_ms", "updated_ms", "created_ms"] {
                    let number = fields
                        .get(name)
                        .and_then(Value::as_str)
                        .and_then(|ms| ms.parse::<u64>().ok())
                        .map_or(Value::Null, Value::from);
                    fields.insert(name.into(), number);
                }
            }
            row
        })
        .collect::<Vec<_>>();
    Ok(json!({ "value": { "chats": chats } }))
}

/// The streams a change to the workspace tree invalidates.
const TREE_STREAMS: &[&str] =
    &["workspace.changed", "screen.changed", "pane.changed", "tab.changed", "terminal.changed"];
/// The stream an agent state change invalidates.
const AGENT_STREAMS: &[&str] = &["agent.changed"];
/// The streams a change to the chat index (`mux/chat_index.rs`) invalidates.
const CHAT_STREAMS: &[&str] = &["chat.changed", "agent_chat.changed"];

/// The stream a Cloud-pushed GitHub change invalidates (feed_client.rs, the Cloud's webhooks).
const GITHUB_STREAMS: &[&str] = &["github.changed"];

/// The stream every settings change invalidates (`settings-v1`; `mux/settings.rs`).
const SETTINGS_STREAMS: &[&str] = &["settings.changed"];
/// The streams a settings change that touches the theme invalidates.
const SETTINGS_AND_THEME_STREAMS: &[&str] = &["settings.changed", "theme.changed"];
/// The settings the theme is made from: a change to one of these keys (or a key under one, such as
/// `appearance.themeEdits.dark.background`) is a theme change.
const THEME_KEYS: &[&str] = &[
    "appearance.theme",
    "appearance.appTheme",
    "appearance.themeFile",
    "appearance.themeEdits",
    "appearance.accent",
    "appearance.hue",
    "appearance.saturation",
    "appearance.highlightColor",
];

fn is_theme_key(key: &str) -> bool {
    THEME_KEYS.iter().any(|theme| {
        key.strip_prefix(theme).is_some_and(|rest| rest.is_empty() || rest.starts_with('.'))
    })
}

/// The app streams a daemon event invalidates (`cmux.live` re-reads on them). Every one is
/// declared in `cmux-app-host/schema/v2/events.json`, the table the extension SDKs are made from.
fn streams(event: &MuxEvent) -> &'static [&'static str] {
    match event {
        MuxEvent::TreeChanged
        | MuxEvent::TreeSelectionChanged(_)
        | MuxEvent::WorkspacePresentationChanged(_)
        | MuxEvent::TreeDelta(_) => TREE_STREAMS,
        MuxEvent::AgentChanged { .. } => AGENT_STREAMS,
        MuxEvent::ChatsChanged { .. } => CHAT_STREAMS,
        MuxEvent::SettingsChanged(change) if change.keys.iter().any(|key| is_theme_key(key)) => {
            SETTINGS_AND_THEME_STREAMS
        }
        MuxEvent::SettingsChanged(_) => SETTINGS_STREAMS,
        MuxEvent::GitHubChanged { .. } => GITHUB_STREAMS,
        _ => &[],
    }
}

/// An event's body for apps: `{}` (an invalidation), or `{"live": bool}` when a pushed stream's
/// channel went up or down (a watch keeps its slow re-read while it is down).
fn body(event: &MuxEvent) -> Value {
    match event {
        MuxEvent::GitHubChanged { live: Some(live) } => json!({ "live": live }),
        _ => json!({}),
    }
}

#[cfg(test)]
#[path = "routing_tests.rs"]
mod tests;
