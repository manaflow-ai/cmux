//! The daemon side of `cmux.credential.relay`: a first-party app server asks
//! the host to call the cmux Cloud API with the user's sign-in. The daemon
//! holds no credential: it forwards the request to the cmux Mac app over the
//! provider channel (APP-R1, family `credential`), and the Mac app adds the
//! sign-in and calls the API. The server never sees a token.
//!
//! Frames (the server's JSON-lines channel, `host_ops.rs`):
//!
//! - server -> supervisor: `{"t":"host.request","id":7,"op":"cmux.credential.relay",
//!   "params":{"method":"GET","path":"/api/vm","body"?:{},"team"?:"t1","interactive"?:true}}`.
//!   `method` is GET, POST, PUT, PATCH or DELETE; `path` starts with `/`.
//!   `interactive` (a call that waits for the user) gets the long deadline.
//! - supervisor -> Mac app (the registered `credential` provider):
//!   `{"event":"apps-provider-request","request_id":n,"app":"cmux/cloud",
//!   "actor":{"kind":"app","id":"cmux/cloud","host","version","on_behalf_of":{"kind":"user","id"}},
//!   "origin":"script","op":"cmux.credential.relay",
//!   "params":{"method","path","body"?,"team"?},"deadline_ms":n}`.
//! - Mac app -> supervisor: `apps-provider-result {request_id, ok: true,
//!   body: {"status":200,"headers"?:{},"body"?:...}}`, or `ok: false` with
//!   `{code, message, details?, retryable}`.
//! - supervisor -> server: `{"t":"host.result","id":7,"value":{status, headers?, body?}}`,
//!   or `{"t":"host.error","id":7,"code","message","details"?,"retryable"}`.
//!
//! Errors: `apps.scope_missing` (not a first-party server with the server
//! scope `op:cmux.credential.relay`), `validation.invalid`,
//! `provider.unavailable` at once when no Mac app is registered (never a
//! hang), `provider.timeout` past the deadline (the Mac app gets
//! `apps-provider-cancel` with reason `timeout`), `provider.cancelled` when
//! the Mac app disconnects, `app.limit` when the Mac app has 64 calls
//! outstanding, and the Mac app's own errors unchanged. When the server
//! exits, its relays end and the Mac app gets `apps-provider-cancel` with
//! reason `host_exited`.

use serde::Deserialize;
use serde_json::{Value, json};

use super::servers::line;
use super::supervisor::{Inner, Out, Supervisor};
use super::timer::TimerId;

pub(super) const RELAY_OP: &str = "cmux.credential.relay";
/// The provider family the Mac app registers for the relay.
const FAMILY: &str = "credential";
/// Largest relay params (the provider's control queue is bounded).
const MAX_PARAMS_BYTES: usize = 64 * 1024;
/// Calls one provider may have outstanding.
const MAX_OUTSTANDING: usize = 64;
const METHODS: &[&str] = &["GET", "POST", "PUT", "PATCH", "DELETE"];

/// A relay waiting for the Mac app.
pub(super) struct RelayCall {
    pub client: u64,
    pub app: String,
    /// The server process that asked; a reply goes only to it.
    pub generation: u64,
    /// The server's own request id, echoed back.
    pub id: Value,
    pub timer: TimerId,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RelayParams {
    method: String,
    path: String,
    body: Option<Value>,
    team: Option<String>,
    interactive: Option<bool>,
}

fn host_error(id: &Value, code: &str, message: &str, retryable: bool) -> Value {
    json!({ "t": "host.error", "id": id, "code": code, "message": message, "retryable": retryable })
}

impl Supervisor {
    /// Sends one frame to the server process that asked, if it still runs.
    fn relay_reply_locked(inner: &Inner, app: &str, generation: u64, frame: &Value) {
        if let Some(server) = inner.servers.get(app).filter(|s| s.generation == generation) {
            server.process.send(line(frame));
        }
    }

    /// A `host.request` for `cmux.credential.relay` from `app`'s server.
    /// Refusals are answered at once; an accepted relay goes to the Mac app.
    pub(super) fn relay_locked(
        &self,
        inner: &mut Inner,
        app: &str,
        generation: u64,
        request: &Value,
    ) -> Vec<Out> {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let refuse = |inner: &Inner, code: &str, message: &str, retryable: bool| {
            Self::relay_reply_locked(
                inner,
                app,
                generation,
                &host_error(&id, code, message, retryable),
            );
            Vec::new()
        };
        if !Self::host_op_allowed(inner, app, RELAY_OP) {
            return refuse(
                inner,
                "apps.scope_missing",
                "the server does not declare op:cmux.credential.relay",
                false,
            );
        }
        let params = match serde_json::from_value::<RelayParams>(request["params"].clone()) {
            Ok(params) => params,
            Err(e) => return refuse(inner, "validation.invalid", &e.to_string(), false),
        };
        let method = params.method.to_ascii_uppercase();
        if !METHODS.contains(&method.as_str()) {
            return refuse(
                inner,
                "validation.invalid",
                "method must be GET, POST, PUT, PATCH or DELETE",
                false,
            );
        }
        if !params.path.starts_with('/') || params.path.starts_with("//") {
            return refuse(inner, "validation.invalid", "path must start with a single /", false);
        }
        let mut forwarded = json!({ "method": method, "path": params.path });
        if let Some(body) = params.body {
            forwarded["body"] = body;
        }
        if let Some(team) = params.team {
            forwarded["team"] = json!(team);
        }
        if serde_json::to_vec(&forwarded).map_or(usize::MAX, |b| b.len()) > MAX_PARAMS_BYTES {
            return refuse(inner, "validation.invalid", "params are larger than 64 KiB", false);
        }
        let Some(&client) = inner.providers.get(FAMILY) else {
            return refuse(inner, "provider.unavailable", "needs the cmux Mac app connected", true);
        };
        let outstanding = inner.provider_calls.values().filter(|c| c.client == client).count()
            + inner.relay_calls.values().filter(|c| c.client == client).count();
        if outstanding >= MAX_OUTSTANDING {
            return refuse(inner, "app.limit", "the cmux app has too many calls outstanding", true);
        }
        let deadline = if params.interactive == Some(true) {
            self.config.provider_user_deadline
        } else {
            self.config.provider_deadline
        };
        inner.next_provider_request += 1;
        let request_id = inner.next_provider_request;
        let me = self.me.clone();
        let timer = self.timers.schedule(deadline, move || {
            if let Some(me) = me.upgrade() {
                me.relay_timeout(request_id);
            }
        });
        inner
            .relay_calls
            .insert(request_id, RelayCall { client, app: app.to_string(), generation, id, timer });
        let version =
            inner.catalog.packages.get(app).map(|p| p.version.clone()).unwrap_or_default();
        let event = json!({
            "event": "apps-provider-request",
            "request_id": request_id,
            "app": app,
            "actor": {
                "kind": "app",
                "id": app,
                "host": crate::machine_name::machine_name(),
                "version": version,
                "on_behalf_of": { "kind": "user", "id": crate::conversation_store::LOCAL_USER },
            },
            "origin": "script",
            "op": RELAY_OP,
            "params": forwarded,
            "deadline_ms": deadline.as_millis() as u64,
        });
        vec![Out::Provider(client, request_id, event)]
    }

    /// `apps-provider-result` for a relay: `None` when `request_id` is not
    /// one; `Some(false)` when another connection answers it.
    pub(super) fn relay_result_locked(
        &self,
        inner: &mut Inner,
        client: u64,
        request_id: u64,
        ok: bool,
        body: Value,
    ) -> Option<bool> {
        if inner.relay_calls.get(&request_id)?.client != client {
            return Some(false);
        }
        let call = inner.relay_calls.remove(&request_id).expect("checked");
        self.timers.cancel(call.timer);
        let frame = if ok {
            json!({ "t": "host.result", "id": call.id, "value": body })
        } else {
            let mut error = super::provider::error_body(body);
            error["t"] = json!("host.error");
            error["id"] = call.id.clone();
            error
        };
        Self::relay_reply_locked(inner, &call.app, call.generation, &frame);
        Some(true)
    }

    fn relay_timeout(&self, request_id: u64) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let Some(call) = inner.relay_calls.remove(&request_id) else { return };
            let frame = host_error(
                &call.id,
                "provider.timeout",
                "the cmux app did not answer in time",
                true,
            );
            Self::relay_reply_locked(&inner, &call.app, call.generation, &frame);
            vec![Out::Client(
                call.client,
                json!({ "event": "apps-provider-cancel", "request_id": request_id, "reason": "timeout" }),
            )]
        };
        self.emit(outs);
    }

    /// The Mac app's connection refused the request: the relay fails as
    /// unavailable. False when `request_id` is not a relay.
    pub(super) fn relay_send_failed_locked(&self, inner: &mut Inner, request_id: u64) -> bool {
        let Some(call) = inner.relay_calls.remove(&request_id) else { return false };
        self.timers.cancel(call.timer);
        let frame =
            host_error(&call.id, "provider.unavailable", "needs the cmux Mac app connected", true);
        Self::relay_reply_locked(inner, &call.app, call.generation, &frame);
        true
    }

    /// The Mac app disconnected: its relays end as cancelled.
    pub(super) fn relay_provider_gone_locked(&self, inner: &mut Inner, client: u64) {
        let gone: Vec<u64> = inner
            .relay_calls
            .iter()
            .filter(|(_, c)| c.client == client)
            .map(|(id, _)| *id)
            .collect();
        for id in gone {
            let call = inner.relay_calls.remove(&id).expect("listed");
            self.timers.cancel(call.timer);
            let frame =
                host_error(&call.id, "provider.cancelled", "the cmux app disconnected", true);
            Self::relay_reply_locked(inner, &call.app, call.generation, &frame);
        }
    }

    /// `app`'s server exited: its relays end, and the Mac app is told.
    pub(super) fn relay_server_gone_locked(&self, inner: &mut Inner, app: &str) -> Vec<Out> {
        let gone: Vec<u64> =
            inner.relay_calls.iter().filter(|(_, c)| c.app == app).map(|(id, _)| *id).collect();
        gone.into_iter()
            .map(|id| {
                let call = inner.relay_calls.remove(&id).expect("listed");
                self.timers.cancel(call.timer);
                Out::Client(
                    call.client,
                    json!({ "event": "apps-provider-cancel", "request_id": id, "reason": "host_exited" }),
                )
            })
            .collect()
    }
}
