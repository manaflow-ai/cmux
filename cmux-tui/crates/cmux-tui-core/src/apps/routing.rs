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

    fn start_events(&self, publish: Box<dyn Fn(&str) + Send + Sync>) {
        let Some(mux) = self.mux.upgrade() else { return };
        // Only the events that invalidate an app stream: every other daemon
        // event (terminal output, titles, notifications) was cloned into this
        // mailbox and woke this thread for nothing.
        let events = mux.subscribe_matching(|event| !streams(event).is_empty());
        drop(mux);
        let _ = std::thread::Builder::new().name("cmux-apps-events".into()).spawn(move || {
            while let Ok(event) = events.recv() {
                for stream in streams(&event) {
                    publish(stream);
                }
            }
        });
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
/// (`mux/chat_index.rs`), in its first shape `{chats}` with times as numbers.
const AGENT_CHAT_LIST: &str = "agent_chat.list";

fn agent_chat_list(mux: &Mux, params: &Value) -> Result<Value, Value> {
    if !(params.is_null() || params.as_object().is_some_and(serde_json::Map::is_empty)) {
        return Err(error("validation.invalid", "agent_chat.list takes no params"));
    }
    let chats = mux
        .chat_rows()
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
        _ => &[],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_stream_the_daemon_publishes_is_in_the_sdks_event_table() {
        let table: Value =
            serde_json::from_str(include_str!("../../../cmux-app-host/schema/v2/events.json"))
                .unwrap();
        let declared = table["events"].as_object().unwrap();
        assert_eq!(streams(&MuxEvent::TreeChanged), TREE_STREAMS);
        for stream in TREE_STREAMS
            .iter()
            .chain(AGENT_STREAMS)
            .chain(CHAT_STREAMS)
            .chain(SETTINGS_STREAMS)
            .chain(SETTINGS_AND_THEME_STREAMS)
        {
            assert!(
                declared.contains_key(*stream),
                "{stream} is published to apps but not declared in schema/v2/events.json"
            );
        }
    }

    fn settings_changed(keys: &[&str]) -> MuxEvent {
        MuxEvent::SettingsChanged(cmux_config::store::Change {
            revision: 1,
            keys: keys.iter().map(|key| (*key).to_string()).collect(),
            origin: cmux_config::store::Origin::User,
        })
    }

    /// Every settings change invalidates `settings.changed`; one that touches a key the theme is
    /// made from also invalidates `theme.changed`. Both are declared with `settings.get`, so an app
    /// hears them with `settings:read`.
    #[test]
    fn settings_changes_publish_settings_changed_and_theme_keys_also_theme_changed() {
        assert_eq!(streams(&settings_changed(&["terminal.fontSize"])), ["settings.changed"]);
        for key in ["appearance.theme", "appearance.themeFile", "appearance.accent"] {
            assert_eq!(
                streams(&settings_changed(&["terminal.fontSize", key])),
                ["settings.changed", "theme.changed"],
                "{key}"
            );
        }
        assert_eq!(
            streams(&settings_changed(&["appearance.themeEdits.dark.background"])),
            ["settings.changed", "theme.changed"]
        );
        assert_eq!(streams(&settings_changed(&["appearance.themeful"])), ["settings.changed"]);
        for stream in ["settings.changed", "theme.changed"] {
            assert_eq!(super::super::subscriptions::declared_reads(stream), Some("settings.get"));
        }
        assert_eq!(super::super::subscriptions::declared_reads("made.changed"), None);
    }

    #[test]
    fn requests_fill_current_selectors_only_where_the_op_takes_them() {
        let message: Value =
            serde_json::from_str(&request("workspace.list", json!({}), None).unwrap()).unwrap();
        assert_eq!(message["params"], json!({ "machine": "current", "session": "current" }));
        assert!(message.get("idempotency_key").is_none());
        let focus: Value = serde_json::from_str(
            &request("tab.focus", json!({ "tab": "tab_1" }), Some("k".into())).unwrap(),
        )
        .unwrap();
        assert_eq!(focus["idempotency_key"], "k");
        assert_eq!(
            request("made.up", json!({}), None).unwrap_err()["code"],
            "operation.unsupported"
        );
    }

    #[test]
    fn answers_wrap_reads_and_pass_mutation_results_through() {
        assert_eq!(
            answer("workspace.list", json!({ "ok": true, "result": [1] })).unwrap(),
            json!({ "value": [1] })
        );
        let mutation =
            json!({ "value": {}, "revision": "3", "replayed": false, "generation": "g" });
        assert_eq!(
            answer("tab.focus", json!({ "ok": true, "result": mutation.clone() })).unwrap(),
            mutation
        );
        let err = answer("tab.focus", json!({ "ok": false, "error": { "code": "selector.not_found", "message": "no tab", "retryable": false } })).unwrap_err();
        assert_eq!(err["code"], "selector.not_found");
    }

    /// `chat.list` and its older name `agent_chat.list` answer the same chats from the daemon's
    /// chat index (no Mac provider), and a chat change invalidates both app streams.
    #[test]
    fn chat_list_and_agent_chat_list_answer_the_same_chats() {
        let mux = Mux::new_for_test("apps-chat-list", crate::SurfaceOptions::default());
        mux.change_chats(|chats| {
            chats.page(&[json!({
                "sessionId": "s1", "name": "fix", "harness": "codex", "status": "idle",
                "cwd": "/src/cmux", "unread": true, "unreadTurns": 1, "tags": {"pinned": "true"},
                "updatedAt": 2_000, "createdAt": 1_000, "pullRequests": [],
                "lane": {"state": "idle", "title": "Fix upload", "since": 1_500},
            })])
        });
        let router = MuxRouter::new(&mux);
        assert!(router.owns("chat.list") && router.owns("agent_chat.list"));
        let list = router.route("a/b", "chat.list", json!({}), None, Origin::Script).unwrap();
        let row = &list["value"][0];
        assert_eq!(
            (row["id"].clone(), row["pinned"].clone(), row["since_ms"].clone()),
            (json!("s1"), json!(true), json!("1500"))
        );
        let old = router.route("a/b", "agent_chat.list", json!({}), None, Origin::Script).unwrap();
        let chat = &old["value"]["chats"][0];
        assert_eq!(
            (chat["id"].clone(), chat["unread"].clone(), chat["since_ms"].clone()),
            (json!("s1"), json!(true), json!(1500))
        );
        assert_eq!(
            router
                .route("a/b", "agent_chat.list", json!({"x": 1}), None, Origin::Script)
                .unwrap_err()["code"],
            "validation.invalid"
        );
        assert_eq!(
            streams(&MuxEvent::ChatsChanged { revision: 1 }),
            ["chat.changed", "agent_chat.changed"]
        );
    }
}
