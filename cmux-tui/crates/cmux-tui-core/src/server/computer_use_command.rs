//! cmux Computer Use's daemon commands (`computer-use-v1`):
//!
//! - `computer-use-endpoint`: the worker's agent socket for acpmux's bridge,
//!   `{"state":"ready","socket","secret","pid"}` or
//!   `{"state":"starting"|"off"|"unavailable","reason"}`. Starts the worker
//!   when needed and waits up to 10 s for it. Local same-user connections
//!   only (never a page, a WebSocket or a `cmux link` peer): the answer holds
//!   the worker's secret. On a Mac whose cmux build embeds cmux Remote it is
//!   that host's `computer_use.endpoint`; otherwise the daemon's own worker
//!   runs in the Screen Sharing helper (`computer_use_host/macos.rs`).
//! - `computer-use-config {config}`: a `PolicyConfig` from the verified app.
//!   The machine owner's file (`/etc/cmux/computer-use.json`,
//!   `%ProgramData%\cmux\computer-use.json`) still wins.
//! - `computer-use-approvals {action, app_id?, id?, answer?}`: `list` (saved
//!   approvals and the questions waiting), `never` and `revoke_sessions`
//!   lower trust and are open to any local connection; `always`, `forget`
//!   (it also removes a saved Never) and an `answer` that allows raise it
//!   and need the verified app.
//!
//! Questions from the daemon's own worker reach the person as a cmux
//! notification while a verified app is connected ([`route_ask`]); the app
//! answers them here. With no app connected they are `unavailable` at once.

use std::sync::Arc;

use cmux_computer_use::policy::PolicyConfig;
use serde::Deserialize as _;
use serde_json::{Value, json};

use super::{ClientTransport, Mux};
use crate::request_origin::{HelloRole, RequestOrigin};

const ORIGIN_FORBIDDEN: &str = "origin.forbidden";
const UNAVAILABLE: &str = "computer_use_unavailable";
const BAD_REQUEST: &str = "bad_request";

#[derive(Debug)]
pub(super) struct Refused {
    code: &'static str,
    message: String,
}

impl std::fmt::Display for Refused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for Refused {}

pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<Refused>().map(|refused| refused.code.to_string())
}

fn refused(code: &'static str, message: impl Into<String>) -> anyhow::Error {
    Refused { code, message: message.into() }.into()
}

/// A local Unix connection of this user; whether it is the verified app.
fn caller(mux: &Mux, client: u64) -> Result<bool, anyhow::Error> {
    let state = mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let record = state.clients.get(&client).ok_or_else(|| {
        refused(ORIGIN_FORBIDDEN, "Computer Use needs a registered local connection")
    })?;
    if !matches!(record.transport, ClientTransport::Unix) {
        return Err(refused(ORIGIN_FORBIDDEN, "Computer Use needs a local socket connection"));
    }
    if record.origin.derive() == RequestOrigin::Page {
        return Err(refused(ORIGIN_FORBIDDEN, "Computer Use is not available to pages"));
    }
    Ok(record.origin.role == HelloRole::Main && record.origin.verified_app)
}

/// Whether a verified cmux app is connected now (someone can answer a question).
fn app_connected(mux: &Mux) -> bool {
    let state = mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    state.clients.values().any(|record| {
        matches!(record.transport, ClientTransport::Unix)
            && record.origin.role == HelloRole::Main
            && record.origin.verified_app
    })
}

/// Whether the daemon's own worker serves Computer Use on this Mac: the build
/// embeds no cmux Remote, so the Screen Sharing helper runs the worker
/// (`configure_remote_host` configured it). Linux and Windows always do.
#[cfg(target_os = "macos")]
fn own_worker(mux: &Mux) -> bool {
    mux.control_clients.computer_use.configured()
}

pub(super) fn endpoint(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    caller(mux, client)?;
    #[cfg(target_os = "macos")]
    if !own_worker(mux) {
        let wait = crate::computer_use_host::ENDPOINT_WAIT.as_millis() as u64;
        return Ok(
            match mux
                .control_clients
                .remote_host
                .call("computer_use.endpoint", json!({"wait_ms": wait}))
            {
                Ok(answer) if answer.get("state").and_then(Value::as_str).is_some() => answer,
                Ok(answer) => {
                    json!({"state": "unavailable", "reason": format!("cmux Remote answered {answer}")})
                }
                Err(reason) if reason.contains("is off") => {
                    json!({"state": "off", "reason": reason})
                }
                Err(reason) => json!({"state": "unavailable", "reason": reason}),
            },
        );
    }
    Ok(mux.control_clients.computer_use.endpoint(crate::computer_use_host::ENDPOINT_WAIT))
}

pub(super) fn config(mux: &Mux, client: u64, config: Value) -> anyhow::Result<Value> {
    if !caller(mux, client)? {
        return Err(refused(ORIGIN_FORBIDDEN, "Computer Use settings come from the cmux app"));
    }
    let policy = PolicyConfig::deserialize(&config).map_err(|error| {
        refused(BAD_REQUEST, format!("config is not a Computer Use policy: {error}"))
    })?;
    #[cfg(target_os = "macos")]
    if !own_worker(mux) {
        return mux
            .control_clients
            .remote_host
            .call("computer_use.config", json!({"config": config}))
            .map_err(|reason| refused(UNAVAILABLE, reason));
    }
    let host = &mux.control_clients.computer_use;
    if let Some((_, crate::computer_use_host::config::Source::Owner(path))) = host.config() {
        return Ok(json!({
            "applied": false,
            "reason": format!("this machine's owner sets Computer Use in {}", path.display()),
        }));
    }
    host.set_config(policy, crate::computer_use_host::config::Source::App);
    Ok(json!({"applied": true, "status": host.status()}))
}

/// Answers that grant access (the rest only narrow it).
fn allows(answer: &str) -> bool {
    matches!(answer, "allow_once" | "allow_session" | "always")
}

pub(super) fn approvals(mux: &Mux, client: u64, params: Value) -> anyhow::Result<Value> {
    let verified_app = caller(mux, client)?;
    let action = params.get("action").and_then(Value::as_str).unwrap_or_default();
    let app_id = params.get("app_id").and_then(Value::as_str).unwrap_or_default();
    let raises = match action {
        "list" | "revoke_sessions" => false,
        "never" => {
            if app_id.is_empty() {
                return Err(refused(BAD_REQUEST, "never needs app_id"));
            }
            false
        }
        // Forgetting removes a saved Never as well as an Always, which widens
        // access, so it needs the cmux app like an Always does.
        "forget" | "always" => {
            if app_id.is_empty() {
                return Err(refused(BAD_REQUEST, format!("{action} needs app_id")));
            }
            true
        }
        "answer" => {
            let answer = params.get("answer").and_then(Value::as_str).unwrap_or_default();
            if !matches!(
                answer,
                "allow_once" | "allow_session" | "always" | "deny" | "never" | "unavailable"
            ) || params.get("id").and_then(Value::as_u64).is_none()
            {
                return Err(refused(
                    BAD_REQUEST,
                    "answer needs id and answer (allow_once, allow_session, always, deny, never)",
                ));
            }
            allows(answer)
        }
        _ => {
            return Err(refused(
                BAD_REQUEST,
                "action is one of list, forget, always, never, revoke_sessions, answer",
            ));
        }
    };
    if raises && !verified_app {
        return Err(refused(
            ORIGIN_FORBIDDEN,
            "allowing an app or forgetting an answer needs the cmux app (Settings > Computer Use)",
        ));
    }
    #[cfg(target_os = "macos")]
    if !own_worker(mux) {
        let mut answer = mux
            .control_clients
            .remote_host
            .call("computer_use.approvals", params)
            .map_err(|reason| refused(UNAVAILABLE, reason))?;
        if !verified_app && let Some(fields) = answer.as_object_mut() {
            fields.remove("pending");
        }
        return Ok(answer);
    }
    let host = &mux.control_clients.computer_use;
    let unavailable = |reason: String| refused(UNAVAILABLE, reason);
    match action {
        "list" => {
            let mut list = host.list_approvals().map_err(unavailable)?;
            // Who asks for what is the app's to show.
            if !verified_app && let Some(fields) = list.as_object_mut() {
                fields.remove("pending");
            }
            Ok(list)
        }
        "answer" => {
            let id = params.get("id").and_then(Value::as_u64).unwrap_or_default();
            let answer = params.get("answer").and_then(Value::as_str).unwrap_or_default();
            host.answer(id, answer).map_err(|reason| refused(BAD_REQUEST, reason))?;
            Ok(json!({"answered": id}))
        }
        _ => {
            host.edit_approvals(action, app_id).map_err(unavailable)?;
            Ok(json!({"done": action}))
        }
    }
}

/// A question from the worker: a notification for the connected app, which
/// answers it through `computer-use-approvals`. False when no app is
/// connected (the worker gets `unavailable` and refuses the call).
pub(crate) fn route_ask(mux: &Arc<Mux>, ask: &crate::computer_use_host::PendingAsk) -> bool {
    if !app_connected(mux) {
        return false;
    }
    let question = &ask.question;
    let text = |pointer: &str| {
        question.pointer(pointer).and_then(Value::as_str).unwrap_or_default().to_string()
    };
    let agent = Some(text("/agent")).filter(|s| !s.is_empty()).unwrap_or_else(|| "An agent".into());
    let app = Some(text("/app/name")).filter(|s| !s.is_empty()).unwrap_or_else(|| text("/app/id"));
    let from = question
        .get("from_machine")
        .and_then(Value::as_str)
        .map(|machine| format!(" from {machine}"))
        .unwrap_or_default();
    mux.post_notification_as(
        &crate::workspace_registry::Actor::Daemon,
        "Computer Use".into(),
        format!(
            "{agent}{from} wants to use {app}. Answer in cmux (Computer Use request {}).",
            ask.id
        ),
        crate::mux::NotificationLevel::Warning,
        None,
        crate::mux::NotificationSource::Daemon,
    )
    .is_ok()
}
