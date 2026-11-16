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
//!   device access to this Mac. Three methods are the daemon's own, never the host's
//!   (`remote_host/agent_share.rs`): `agent.ticket` (an agent asks for a single-use ticket
//!   for one share or unshare), `agent.redeem` and `agent.person` (the verified app only): with
//!   the account's "My agents can turn screen sharing and control on my machines" on, the app
//!   makes the agent's change with no dialog; the permission itself is never a ticket.
//! - `remote-host-config {computer_use, screen_sharing, headless}`: the
//!   person's switches, from the verified app.
//! - `remote-host-app`: the app socket's credentials for the verified app's
//!   own process (the host admits that process only).

use serde_json::{Value, json};

use super::{ClientTransport, Mux};
use crate::remote_host::agent_share;
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
    peer_token: Option<cmux_link::app_caller::PeerToken>,
}

impl Caller {
    /// The agent-share module's view: the verified app, or an agent of this OS user on this Mac.
    fn agent_kind(&self) -> agent_share::Caller {
        if self.verified_app {
            agent_share::Caller::App
        } else {
            agent_share::Caller::LocalAgent { pid: self.peer_pid }
        }
    }
}

/// Whether a connection may use cmux Remote at all, and whether it is the verified app: a local
/// Unix connection (this OS user on this Mac) that is not a page. A remote link or a WebSocket
/// (another device, a browser) and a page never are, whatever they claim.
fn admit(unix: bool, origin: RequestOrigin, verified_app: bool) -> Result<bool, RemoteRefused> {
    if !unix {
        return Err(forbidden("needs a local Unix socket connection"));
    }
    if origin == RequestOrigin::Page {
        return Err(forbidden("is not available to pages"));
    }
    Ok(verified_app)
}

fn caller(mux: &Mux, client: u64) -> Result<Caller, RemoteRefused> {
    let state = mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let record = state
        .clients
        .get(&client)
        .ok_or_else(|| forbidden("needs a registered local connection"))?;
    let verified_app = admit(
        matches!(record.transport, ClientTransport::Unix),
        record.origin.derive(),
        record.origin.role == HelloRole::Main && record.origin.verified_app,
    )?;
    // `token:<pid>.<pidversion>`
    let peer_pid = record
        .origin
        .peer_key
        .as_deref()
        .and_then(|key| key.strip_prefix("token:"))
        .and_then(|rest| rest.split('.').next())
        .and_then(|pid| pid.parse().ok());
    Ok(Caller { verified_app, peer_pid, peer_token: record.origin.peer_token })
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
        strip_private(screen);
    }
    // Whether an agent's share is armed to turn itself off; who and the notices are the app's.
    let mut agents = mux.control_clients.remote_agents.status();
    if !caller.verified_app {
        let field = |name: &str| agents.get(name).cloned().unwrap_or(Value::Null);
        agents = json!({"active": field("active"), "off_in_s": field("off_in_s")});
    }
    if let Some(fields) = status.as_object_mut() {
        fields.insert("agent_share".into(), agents);
    }
    Ok(status)
}

/// What only the verified app reads: the person's devices, and who views this Mac or asks to
/// (the session, the pending asks, the indicator text and banner that name the viewer).
fn strip_private(screen: &mut serde_json::Map<String, Value>) {
    for key in ["devices", "session", "pending", "indicator", "banner"] {
        screen.remove(key);
    }
}

/// The access levels in order; raising is moving right.
fn rank(scope: &str) -> Option<u8> {
    ["none", "ask", "view", "full"].iter().position(|name| *name == scope).map(|index| index as u8)
}

pub(super) fn call(mux: &Mux, client: u64, method: &str, params: Value) -> anyhow::Result<Value> {
    let agents = &mux.control_clients.remote_agents;
    let caller = match caller(mux, client) {
        Ok(caller) => caller,
        Err(refusal) => {
            if method.starts_with("agent.") {
                agents.refuse_caller(method, &params, refusal.code, &refusal.message);
            }
            return Err(refusal.into());
        }
    };
    let host = &mux.control_clients.remote_host;
    // The account's standing permission for the owner's agents (remote_host/agent_share.rs):
    // never forwarded to the host, and never a way to turn the permission itself on.
    let agent_answer = match method {
        "agent.ticket" => Some(agents.ticket(caller.agent_kind(), &params)),
        "agent.redeem" => Some(agents.redeem(caller.agent_kind(), &params)),
        "agent.person" => Some(agents.person(caller.agent_kind())),
        _ => None,
    };
    if let Some(answer) = agent_answer {
        return answer.map_err(|refused| {
            RemoteRefused { code: refused.code, message: refused.message }.into()
        });
    }
    match method {
        "capture.prepare" | "capture.resume" | "capture.cleanup" => {
            if !caller.verified_app || !super::origin_gate::app_process(mux, client) {
                return Err(forbidden("capture needs a verified cmux app connection").into());
            }
            let pid =
                caller.peer_pid.ok_or_else(|| forbidden("capture needs a known peer process"))?;
            let stamp = app_stamp(pid).ok_or_else(|| forbidden("the app process is gone"))?;
            return host.capture(method, params, stamp, caller.peer_token).map_err(unavailable);
        }
        "status" | "refresh" | "request" | "open_settings" | "restart" | "screen.stop_session" => {}
        "screen.share" => {
            let on = params.get("on").and_then(Value::as_bool).ok_or_else(|| RemoteRefused {
                code: "bad_request",
                message: "screen.share needs on: true or false".into(),
            })?;
            if on && !caller.verified_app {
                return Err(forbidden(
                    "Share This Mac on needs the cmux app (palette or Settings)",
                )
                .into());
            }
            if !on {
                // Sharing goes off: nothing is left for an agent's share to turn off later.
                agents.sharing_off();
            }
        }
        "screen.access" => {
            let device = params.get("device").and_then(Value::as_str).unwrap_or_default();
            let wanted =
                params.get("scope").and_then(Value::as_str).and_then(rank).ok_or_else(|| {
                    RemoteRefused {
                        code: "bad_request",
                        message: "screen.access needs device and scope (none, ask, view, full)"
                            .into(),
                    }
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
                    return Err(forbidden(
                        "raising a device's access needs the cmux app (palette or Settings)",
                    )
                    .into());
                }
            }
        }
        _ => {
            return Err(RemoteRefused {
                code: "bad_request",
                message: format!("unknown cmux Remote method {method}"),
            }
            .into());
        }
    }
    let mut answer = host.call(method, params).map_err(unavailable)?;
    // The device list is the verified app's only, whichever command reads it.
    if !caller.verified_app
        && let Some(screen) = answer.get_mut("screen").and_then(Value::as_object_mut)
    {
        strip_private(screen);
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
    crate::remote_host::process_stamp(pid)
        .map(|(seconds, micros)| json!({"pid": pid, "start_sec": seconds, "start_usec": micros}))
}

#[cfg(not(target_os = "macos"))]
fn app_stamp(_pid: u32) -> Option<Value> {
    None
}

#[cfg(test)]
mod tests {
    use super::{RequestOrigin, admit};

    #[test]
    fn only_a_local_connection_that_is_not_a_page_reaches_cmux_remote() {
        // The owner's agent: a local Unix connection of this OS user, not the app.
        assert_eq!(admit(true, RequestOrigin::Agent, false).ok(), Some(false));
        // The verified app.
        assert_eq!(admit(true, RequestOrigin::User, true).ok(), Some(true));
        // A page, even one that relays as the app, is refused.
        let page = admit(true, RequestOrigin::Page, true).unwrap_err();
        assert_eq!(page.code, super::ORIGIN_FORBIDDEN);
        // Another device (a remote link) or a browser socket: refused whatever it claims, so no
        // agent of another person or another account's device reaches the ticket path.
        for origin in [RequestOrigin::Agent, RequestOrigin::User] {
            let remote = admit(false, origin, true).unwrap_err();
            assert_eq!(remote.code, super::ORIGIN_FORBIDDEN);
        }
    }
}

#[cfg(test)]
#[path = "remote_host_capture_tests.rs"]
mod capture_tests;
