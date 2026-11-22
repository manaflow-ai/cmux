//! `_acpmux/login_flow {op, ...}` (`crate::login_flow`): setup's provider sign-in for one chosen
//! target, observed until done. Part of the request handler (`requests.rs`).
//!
//! - `start {target, restart?}`: the live flow for `target` (harness, host, cwd, routeId), or a
//!   new one (`starting`).
//! - `opened {flowId}`: the app opened the login (its terminal tab): `waiting`.
//! - `openFailed {flowId}`: it could not: `failed`, retryable.
//! - `check {flowId, ended?}`: read the target's sign-in again as a send would
//!   (`_acpmux/session/auth` with `refresh`, forwarded to `target.host`): `succeeded` on a `ready`
//!   observed after the start, else `waiting` (or `failed` when `ended`, the login is over).
//! - `cancel {flowId}`, `get {flowId}`.
//!
//! Only this machine's app and unix socket run one: a sign-in changes the machine's login for
//! every chat on it, so a browser page or a paired device may not drive it. The flow carries no
//! login command, callback URL, code or check text (`crate::login_flow` docs).

use super::Conn;
use crate::hub::{Control, Hub};
use crate::login_flow::{self as flows, Observation};
use crate::protocol::auth::{SessionAuthResult, SessionAuthTarget};
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;

fn reply(flow: flows::Flow) -> Result<Value, RpcError> {
    serde_json::to_value(flow).map_err(|e| RpcError::internal(e.to_string()))
}

fn unknown(id: &str) -> RpcError {
    RpcError::invalid_params(format!("no login flow {id:?}"))
        .with_data(json!({"reason": flows::reason::UNKNOWN_FLOW}))
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    if super::remote_guard::control_of(conn.origin, conn.auth, &params) == Control::Web {
        return Err(RpcError::invalid_params(
            "a sign-in is accepted only from this machine's app or unix socket",
        ));
    }
    let op = params.get("op").and_then(Value::as_str).unwrap_or_default();
    let now = crate::store::now_ms;
    if op == "start" {
        let target: SessionAuthTarget = params
            .get("target")
            .cloned()
            .ok_or_else(|| RpcError::invalid_params("start needs a target"))
            .and_then(|t| {
                serde_json::from_value(t).map_err(|e| {
                    RpcError::invalid_params(format!("{}: target: {e}", method::MUX_LOGIN_FLOW))
                })
            })?;
        if target.harness.is_empty() {
            return Err(RpcError::invalid_params("target.harness is required"));
        }
        let restart = params.get("restart").and_then(Value::as_bool).unwrap_or(false);
        return reply(flows::flows().start(target, restart, now()));
    }
    let id = params
        .get("flowId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .ok_or_else(|| RpcError::invalid_params("flowId is required"))?;
    let answered = match op {
        "get" => flows::flows().get(id, now()),
        "opened" => flows::flows().opened(id, now()),
        "openFailed" => flows::flows().open_failed(id, now()),
        "cancel" => flows::flows().cancel(id, now()),
        "check" => {
            let ended = params.get("ended").and_then(Value::as_bool).unwrap_or(false);
            let Some((flow, run)) = flows::flows().begin_check(id, now()) else {
                return Err(unknown(id));
            };
            if !run {
                return reply(flow);
            }
            let seen = observe(hub, conn, &flow.target).await;
            flows::flows().finish_check(id, &seen, ended, now())
        }
        other => {
            return Err(RpcError::invalid_params(format!(
                "op must be start, get, opened, openFailed, check or cancel, not {other:?}"
            )));
        }
    };
    reply(answered.ok_or_else(|| unknown(id))?)
}

/// The target's sign-in as `_acpmux/session/auth` answers it with `refresh`, on its machine.
async fn observe(hub: &Arc<Hub>, conn: &Arc<Conn>, target: &SessionAuthTarget) -> Observation {
    let params = json!({"target": target, "refresh": true});
    match super::session_auth::handle(hub, conn, params).await {
        Ok(value) => serde_json::from_value::<SessionAuthResult>(value)
            .map(Observation::Auth)
            .unwrap_or(Observation::Error),
        Err(e) => {
            // The reason only: a check's message may quote a provider's words.
            tracing::debug!(code = e.code, "login flow: the sign-in check failed");
            Observation::Error
        }
    }
}
