//! Message actions in the agent chat (`cmux.chat.action/1`, DESIGN section
//! 3): rows an installed extension adds to a message's actions menu, such as
//! "Make an issue from this". The rows are data in the manifest, so the
//! daemon answers the menu from the catalog it holds with no app host
//! (`apps.chat_actions.list {role}`); the chat only draws what that returns.
//!
//! Picking a row sends `apps-chat-action {app, action, message, gesture?}`.
//! The daemon finds the action in the app's manifest now (a row the app no
//! longer has is refused) and runs its catalog op on the `apps-run` path
//! (`runs.rs`) with `{action, message}`, so the op's install, enable, hidden
//! and grant checks hold as for any run. Only installed, enabled and visible
//! apps contribute, none in safe mode (`composer::places`). An action id an
//! app lists twice keeps its first entry.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::composer::{places, string};
use super::mirror::Origin;
use super::runs::{Caller, RunRequest};
use super::supervisor::{ApiError, Responder, Supervisor};

pub(super) const INTERFACE: &str = "cmux.chat.action/1";

/// The most rows `apps.chat_actions.list` answers, over every app.
const MAX_ACTIONS: usize = 64;
/// The roles a message has, and so the roles an action may name.
const ROLES: [&str; 2] = ["user", "assistant"];

#[derive(Debug, Serialize)]
struct Row {
    app: String,
    /// The app's name, which the menu shows as the row's source.
    extension: String,
    id: String,
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    symbol: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ListParams {
    /// The message's role; absent lists every row.
    role: Option<String>,
}

/// The message an action runs on, as the chat sends it.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ChatMessage {
    pub id: String,
    pub role: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
}

/// One `apps-chat-action` request.
pub struct ChatActionRequest {
    pub app: String,
    pub action: String,
    pub message: ChatMessage,
    pub origin: Origin,
    /// The click's token (origin user only), as `apps-run` takes it.
    pub gesture: Option<String>,
    pub caller: Option<Caller>,
}

/// Whether `entry` shows on a message of `role`: when it names no roles, on
/// every message.
fn shows_on(entry: &Value, role: &str) -> bool {
    match entry.get("roles").and_then(Value::as_array) {
        None => true,
        Some(roles) => roles.iter().any(|r| r.as_str() == Some(role)),
    }
}

fn actions(options: &Value) -> impl Iterator<Item = &Value> {
    options.get("actions").and_then(Value::as_array).into_iter().flatten()
}

impl Supervisor {
    /// `apps.chat_actions.list {role?}`: the extension rows of a message's
    /// actions menu, in app id and manifest order.
    pub(super) fn chat_actions_list(&self, p: ListParams) -> Result<Value, ApiError> {
        if let Some(role) = &p.role
            && !ROLES.contains(&role.as_str())
        {
            return Err(ApiError::new("apps.chat_action.role", format!("no message role {role}")));
        }
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut rows = Vec::new();
        for (app, extension, options) in places(&inner, INTERFACE) {
            let mut seen = HashSet::new();
            for entry in actions(options) {
                let (Some(id), Some(title)) = (string(entry, "id"), string(entry, "title")) else {
                    continue;
                };
                if string(entry, "op").is_none()
                    || p.role.as_deref().is_some_and(|role| !shows_on(entry, role))
                    || !seen.insert(id.clone())
                    || rows.len() >= MAX_ACTIONS
                {
                    continue;
                }
                rows.push(Row {
                    app: app.to_string(),
                    extension: extension.clone(),
                    id,
                    title,
                    symbol: string(entry, "symbol"),
                });
            }
        }
        Ok(json!({ "actions": rows }))
    }

    /// The op of `app`'s action `id` for a message of `role`, if the app
    /// lists that row now.
    fn chat_action_op(&self, app: &str, id: &str, role: &str) -> Option<String> {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let (_, _, options) = places(&inner, INTERFACE).into_iter().find(|(a, _, _)| *a == app)?;
        actions(options)
            .find(|entry| string(entry, "id").as_deref() == Some(id))
            .filter(|entry| shows_on(entry, role))
            .and_then(|entry| string(entry, "op"))
    }

    /// `apps-chat-action`: runs the picked row's catalog op with
    /// `{action, message}` and answers what the op answers.
    pub fn chat_action(&self, request: ChatActionRequest, respond: Responder) {
        let ChatActionRequest { app, action, message, origin, gesture, caller } = request;
        if !ROLES.contains(&message.role.as_str()) {
            let error = format!("no message role {}", message.role);
            respond(Err(ApiError::new("apps.chat_action.role", error)));
            return;
        }
        let Some(op) = self.chat_action_op(&app, &action, &message.role) else {
            let error = format!("{app} has no message action {action} for this message");
            respond(Err(ApiError::new("apps.chat_action.unknown", error)));
            return;
        };
        let args = json!({ "action": action, "message": message });
        let run = RunRequest { app, op, args, idempotency_key: None, origin, gesture, caller };
        self.run(run, respond);
    }
}
