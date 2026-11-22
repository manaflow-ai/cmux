//! Host-only ops of app servers: the `host.request` frames (`servers.rs`
//! has the rest of the wire).
//!
//! Host-only ops (one shape for every op the host answers), server ->
//! supervisor `{"t":"host.request","id":1,"op":"cmux.host.…","params":{}}`;
//! supervisor -> server `{"t":"host.result","id":1,"value":{}}` or
//! `{"t":"host.error","id":1,"code","message","retryable"}`. Host events,
//! supervisor -> server: `{"t":"host.event","op":"cmux.host.…","data":{}}`.
//! The id is the server's own (any JSON value), echoed back.
//! - `cmux.host.link.get {}` -> `{binary, hub_socket, state_dir,
//!   socket_dir, device_name}` from the daemon's own values (see
//!   [`Supervisor::host_link`]; `hub_socket` is `null` until the link
//!   lane's registration exists); event `cmux.host.link.changed` with the
//!   same value. Needs server scope `op:cmux.host.link.get` and a
//!   first-party app, else `host.error` `apps.scope_missing`.
//! - `cmux.credential.relay` as a `host.request` answers `host.error`
//!   `unavailable`: the relay is served for the server's `relay.op` and
//!   `relay.session` lines (`relay.rs`), which the scope
//!   `op:cmux.credential.relay` allows; no user credential enters the daemon.
//! - Any other `cmux.host.*` op answers `host.error` `apps.op.unknown`.

use serde_json::{Value, json};

use super::mirror::Tier;
use super::servers::line;
use super::supervisor::{Inner, Supervisor};

impl Supervisor {
    /// `cmux.host.link.get` for `app`: the daemon executable, the WireGuard
    /// hub socket, a link state directory in the app's data directory, the
    /// app's temporary directory for link sockets, and this machine's name.
    ///
    /// `hub_socket` is always `null` for now. The link lane (lane 12: the
    /// WireGuard engine and the `cmux link` agent) owns that socket; the
    /// daemon neither spawns it nor reads it from its launch environment. It
    /// will come from the link agent's registration file at a well-known
    /// path under the daemon state directory, which lane 12 defines. Until
    /// then the Cloud server answers `link_unavailable`.
    pub(super) fn host_link(&self, app: &str) -> Value {
        let (data, tmp) = self.server_dirs(app);
        let state_dir = data.join("link");
        let _ = std::fs::create_dir_all(&state_dir);
        json!({
            "binary": std::env::current_exe().ok(),
            "hub_socket": Value::Null,
            "state_dir": state_dir,
            "socket_dir": tmp,
            "device_name": device_name(),
        })
    }

    /// Whether `app` may call the host op `op`: a first-party app whose
    /// manifest declares the server scope `op:<op>`.
    pub(super) fn host_op_allowed(inner: &Inner, app: &str, op: &str) -> bool {
        inner.catalog.packages.get(app).is_some_and(|package| {
            package.tier == Tier::FirstParty
                && package
                    .manifest
                    .pointer("/server/scopes")
                    .and_then(Value::as_object)
                    .is_some_and(|scopes| scopes.contains_key(&format!("op:{op}")))
        })
    }

    /// Answers one `host.request` frame of `app`'s server.
    pub(super) fn host_request_locked(&self, inner: &Inner, app: &str, request: &Value) -> Value {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let error = |code: &str, message: &str, retryable: bool| json!({ "t": "host.error", "id": id, "code": code, "message": message, "retryable": retryable });
        match request["op"].as_str().unwrap_or_default() {
            op @ "cmux.host.link.get" => {
                if Self::host_op_allowed(inner, app, op) {
                    json!({ "t": "host.result", "id": id, "value": self.host_link(app) })
                } else {
                    error(
                        "apps.scope_missing",
                        "the server does not declare op:cmux.host.link.get",
                        false,
                    )
                }
            }
            "cmux.credential.relay" => {
                error("unavailable", "the cmux credential relay is not available yet", true)
            }
            op => error("apps.op.unknown", &format!("the host has no op {op}"), false),
        }
    }

    /// Sends `cmux.host.link.changed` to every running server that may read
    /// the link. Nothing changes the daemon's link values during its life
    /// yet; the daemon calls this when the link agent's registration (lane
    /// 12) appears or changes.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(super) fn host_link_changed(&self) {
        let inner = self.inner.lock().unwrap();
        for (app, server) in &inner.servers {
            if !server.stopping && Self::host_op_allowed(&inner, app, "cmux.host.link.get") {
                server.process.send(line(&json!({
                    "t": "host.event", "op": "cmux.host.link.changed", "data": self.host_link(app),
                })));
            }
        }
    }
}

/// This machine's name, or `cmux`.
fn device_name() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: gethostname writes at most buf.len() bytes into our buffer.
    let ok = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0;
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    let name = if ok { String::from_utf8_lossy(&buf[..end]).into_owned() } else { String::new() };
    if name.is_empty() || name.chars().any(char::is_control) { "cmux".into() } else { name }
}
