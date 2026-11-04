//! cmux Remote's daemon commands (`remote-host-v1`; docs/cmux-remote.md):
//!
//! - `remote-host-status`: the host's state (never starts it). Any local
//!   Unix connection; the device list only for the verified app.
//! - `remote-host-call {method, params}`: one host request (`status`,
//!   `refresh`, `request`, `open_settings`, `restart`, `screen.share`,
//!   `screen.access`, `screen.stop_session`). Any local Unix connection may
//!   read, refresh, request a grant (macOS still asks the person), restart a
//!   worker, and lower access (sharing off, a viewer to None or Ask from more,
//!   a session stopped). Raising (sharing on, a viewer to Ask from None, View
//!   or Full) needs the verified app: an agent in a terminal never grants a
//!   device access to this Mac.
//! - `remote-host-config {computer_use, screen_sharing, headless}`: the
//!   person's switches, from the verified app.
//! - `remote-host-app`: the app socket's credentials for the verified app's
//!   own process (the host admits that process only).

use serde_json::{Value, json};

use super::{ClientTransport, Mux};
use crate::request_origin::{HelloRole, RequestOrigin};

const ORIGIN_FORBIDDEN: &str = "origin.forbidden";
const UNAVAILABLE: &str = "remote_host_unavailable";

#[derive(Debug)]
pub(super) struct RemoteRefused {
    code: &'static str,
    message: String,
}

impl std::fmt::Display for RemoteRefused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for RemoteRefused {}

pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<RemoteRefused>().map(|refused| refused.code.to_string())
}

/// Who is asking: a local Unix connection, and whether it is the verified app.
struct Caller {
    verified_app: bool,
    peer_pid: Option<u32>,
}

fn caller(mux: &Mux, client: u64) -> Result<Caller, RemoteRefused> {
    let state = mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let record = state.clients.get(&client).ok_or_else(|| forbidden("needs a registered local connection"))?;
    if !matches!(record.transport, ClientTransport::Unix) {
        return Err(forbidden("needs a local Unix socket connection"));
    }
    if record.origin.derive() == RequestOrigin::Page {
        return Err(forbidden("is not available to pages"));
    }
    let verified_app = record.origin.role == HelloRole::Main && record.origin.verified_app;
    // `token:<pid>.<pidversion>`
    let peer_pid = record
        .origin
        .peer_key
        .as_deref()
        .and_then(|key| key.strip_prefix("token:"))
        .and_then(|rest| rest.split('.').next())
        .and_then(|pid| pid.parse().ok());
    Ok(Caller { verified_app, peer_pid })
}

fn forbidden(reason: &str) -> RemoteRefused {
    RemoteRefused { code: ORIGIN_FORBIDDEN, message: format!("cmux Remote {reason}") }
}

fn unavailable(message: String) -> anyhow::Error {
    RemoteRefused { code: UNAVAILABLE, message }.into()
}

pub(super) fn status(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    let caller = caller(mux, client)?;
    let mut status = mux.control_clients.remote_host.status();
    if !caller.verified_app
        && let Some(screen) = status.pointer_mut("/host/screen").and_then(Value::as_object_mut)
    {
        screen.remove("devices");
    }
    Ok(status)
}

/// The access levels in order; raising is moving right.
fn rank(scope: &str) -> Option<u8> {
    ["none", "ask", "view", "full"].iter().position(|name| *name == scope).map(|index| index as u8)
}

pub(super) fn call(mux: &Mux, client: u64, method: &str, params: Value) -> anyhow::Result<Value> {
    let caller = caller(mux, client)?;
    let host = &mux.control_clients.remote_host;
    match method {
        "status" | "refresh" | "request" | "open_settings" | "restart" | "screen.stop_session" => {}
        "screen.share" => {
            let on = params.get("on").and_then(Value::as_bool).ok_or_else(|| {
                RemoteRefused { code: "bad_request", message: "screen.share needs on: true or false".into() }
            })?;
            if on && !caller.verified_app {
                return Err(forbidden("Share This Mac on needs the cmux app (palette or Settings)").into());
            }
        }
        "screen.access" => {
            let device = params.get("device").and_then(Value::as_str).unwrap_or_default();
            let wanted = params.get("scope").and_then(Value::as_str).and_then(rank).ok_or_else(|| {
                RemoteRefused { code: "bad_request", message: "screen.access needs device and scope (none, ask, view, full)".into() }
            })?;
            if !caller.verified_app {
                // The worker and the hub refuse a raise too; this is the daemon's own first check.
                let current = host
                    .status()
                    .pointer("/host/screen/devices")
                    .and_then(Value::as_array)
                    .and_then(|devices| devices.iter().find(|entry| entry["id"] == device))
                    .and_then(|entry| entry["access"].as_str())
                    .and_then(rank);
                if current.is_none_or(|current| wanted > current) {
                    return Err(forbidden("raising a device's access needs the cmux app (palette or Settings)").into());
                }
            }
        }
        _ => {
            return Err(RemoteRefused { code: "bad_request", message: format!("unknown cmux Remote method {method}") }.into());
        }
    }
    let mut answer = host.call(method, params).map_err(unavailable)?;
    // The device list is the verified app's only, whichever command reads it.
    if !caller.verified_app
        && let Some(screen) = answer.get_mut("screen").and_then(Value::as_object_mut)
    {
        screen.remove("devices");
    }
    Ok(answer)
}

pub(super) fn config(mux: &Mux, client: u64, update: Value) -> anyhow::Result<Value> {
    if !caller(mux, client)?.verified_app {
        return Err(forbidden("switches come from the cmux app").into());
    }
    mux.control_clients.remote_host.set_config(&update).map_err(unavailable)
}

pub(super) fn app(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    let caller = caller(mux, client)?;
    if !caller.verified_app {
        return Err(forbidden("app credentials need a verified cmux app connection").into());
    }
    let pid = caller.peer_pid.ok_or_else(|| forbidden("needs a known peer process"))?;
    let stamp = app_stamp(pid).ok_or_else(|| forbidden("the app process is gone"))?;
    mux.control_clients.remote_host.call("app_grant", json!({ "app": stamp })).map_err(unavailable)
}

#[cfg(target_os = "macos")]
fn app_stamp(pid: u32) -> Option<Value> {
    crate::remote_host::process_stamp(pid).map(|(seconds, micros)| json!({"pid": pid, "start_sec": seconds, "start_usec": micros}))
}

#[cfg(not(target_os = "macos"))]
fn app_stamp(_pid: u32) -> Option<Value> {
    None
}
