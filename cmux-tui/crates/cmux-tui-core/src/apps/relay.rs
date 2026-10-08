//! The host credential relay (bead cx-wb5.57; app-op-routing.md, APP-R1;
//! cloud-app.md 3.2): a first-party app server calls the cmux Cloud API
//! without ever holding a credential. The server sends
//! (first-party-apps/cloud/server/src/api/relay.rs):
//!
//! - `{"type":"relay.op","id","op","params","idempotency_key"?,"origin"?}`:
//!   one `cmux.wire/1` op;
//! - `{"type":"relay.session","id"}`: whether the cmux app is signed in.
//!
//! The supervisor checks that the server's app is first-party and declares
//! the server scope `op:cmux.credential.relay`, then routes the line over
//! the provider channel to the `credential` provider (the Mac app) as
//! `credential.relay {op, params, idempotency_key?, origin?}` or
//! `credential.session {}`. The Mac app adds its install token (never a
//! Stack bearer; chief decision 2026-10-08) and calls `POST /v1/read` or
//! `/v1/ops`. Answers to the server:
//!
//! - `{"type":"relay.result","id","ok":true,"value","revision"?,"replayed"?}`
//!   or `{"type":"relay.result","id","ok":false,"error":{code,message,retryable,details?}}`;
//! - `{"type":"relay.session","id","signed_in","team"}`;
//! - `{"type":"relay.error","id","code","message"}`: `not_signed_in` (the
//!   provider said so), `unavailable` (no provider, it left, or it did not
//!   answer in the provider deadline), `apps.scope_missing`,
//!   `validation.invalid` (a malformed line). The server treats every code
//!   but `not_signed_in` as unavailable.
//!
//! No line in either direction carries a credential, and the daemon never
//! sees one. The `origin` a server sends echoes the one the supervisor
//! stamped on its op line: `user` is accepted only while a call of that
//! server admitted with origin user is in flight (`apps.origin_forbidden`
//! otherwise); the provider stamps the `app:<id>` actor and enforces its own
//! owner rules. One server has at most four relay calls outstanding. A
//! server that is stopping starts none, and one that stops or exits cancels
//! its pending relay calls (`apps-provider-cancel`, reason `host_exited`).
//! App hosts never reach the `credential` family (`provider.rs`).

use serde_json::{Value, json};

use super::provider::{
    self, Ending, MAX_OUTSTANDING, MAX_PARAMS_BYTES, ProviderCall, Target, deadline_ms,
};
use super::supervisor::{Inner, Out, Supervisor};

/// The server scope that allows relay lines.
pub(super) const RELAY_SCOPE_OP: &str = "cmux.credential.relay";
/// Longest wire op name accepted.
const MAX_OP: usize = 128;
/// Longest idempotency key accepted.
const MAX_KEY: usize = 256;
/// Origins a relayed mutation may carry (`OpRequest.origin`).
const ORIGINS: &[&str] = &["user", "cli", "mcp", "script", "remote"];
/// Relay calls one server may have outstanding (the Cloud server is serial;
/// a server must not fill the provider's queue for the app hosts).
const MAX_PER_SERVER: usize = 4;
/// Longest relay line id accepted (the Cloud server sends `r<n>`).
const MAX_ID: usize = 64;

/// Whether `line` is a relay line the supervisor answers.
pub(super) fn is_relay_line(line: &Value) -> bool {
    matches!(line["type"].as_str(), Some("relay.op" | "relay.session"))
}

fn relay_error(id: &Value, code: &str, message: &str) -> Value {
    json!({ "type": "relay.error", "id": id, "code": code, "message": message })
}

/// The answer to a relay line from a server that is stopping.
pub(super) fn stopping_reply(line: &Value) -> Value {
    relay_error(&line["id"], "unavailable", "the app server is stopping")
}

/// The provider op and params of a relay line, or the `relay.error` to
/// answer at once.
fn provider_call(line: &Value) -> Result<(&'static str, Value), Value> {
    let id = &line["id"];
    if !id.as_str().is_some_and(|id| !id.is_empty() && id.len() <= MAX_ID) {
        return Err(relay_error(
            id,
            "validation.invalid",
            "a relay line id is a string of 1 to 64 bytes",
        ));
    }
    if line["type"] == "relay.session" {
        return Ok(("credential.session", json!({})));
    }
    let invalid = |why: &str| relay_error(id, "validation.invalid", why);
    let op = line["op"].as_str().unwrap_or_default();
    let op_ok = !op.is_empty()
        && op.len() <= MAX_OP
        && op.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b));
    if !op_ok {
        return Err(invalid(
            "relay.op needs an op name (lowercase letters, digits, '.', '_', '-')",
        ));
    }
    let params = match line.get("params") {
        None | Some(Value::Null) => json!({}),
        Some(params @ Value::Object(_)) => params.clone(),
        Some(_) => return Err(invalid("relay.op params must be an object")),
    };
    let mut forwarded = json!({ "op": op, "params": params });
    match line.get("idempotency_key") {
        None | Some(Value::Null) => {}
        Some(Value::String(key)) if !key.is_empty() && key.len() <= MAX_KEY => {
            forwarded["idempotency_key"] = json!(key);
        }
        Some(_) => {
            return Err(invalid("relay.op idempotency_key must be a string of 1 to 256 bytes"));
        }
    }
    match line.get("origin") {
        None | Some(Value::Null) => {}
        Some(Value::String(origin)) if ORIGINS.contains(&origin.as_str()) => {
            forwarded["origin"] = json!(origin);
        }
        Some(_) => return Err(invalid("relay.op origin is not a known origin")),
    }
    Ok(("credential.relay", forwarded))
}

/// The line that answers a relay call that ended with `ending`.
pub(super) fn relay_reply(id: &Value, session: bool, ending: Ending) -> Value {
    let (ok, body) = match ending {
        Ending::Answer { ok, body } => (ok, body),
        Ending::Timeout => {
            return relay_error(id, "unavailable", "the cmux app did not answer in time");
        }
        Ending::Gone => return relay_error(id, "unavailable", "needs the cmux Mac app connected"),
    };
    if !ok && body["code"] == "not_signed_in" {
        let message = body["message"].as_str().unwrap_or("sign in to cmux");
        return relay_error(id, "not_signed_in", message);
    }
    match (session, ok) {
        (true, true) => json!({
            "type": "relay.session",
            "id": id,
            "signed_in": body["signed_in"].as_bool().unwrap_or(false),
            "team": body["team"].as_str(),
        }),
        (true, false) => relay_error(
            id,
            "unavailable",
            body["message"].as_str().unwrap_or("the cmux app could not read its session"),
        ),
        (false, true) => {
            let mut reply = json!({
                "type": "relay.result", "id": id, "ok": true,
                "value": body.get("value").cloned().unwrap_or(Value::Null),
            });
            if let Some(revision) = body.get("revision").filter(|r| r.is_string()) {
                reply["revision"] = revision.clone();
            }
            if let Some(replayed) = body.get("replayed").filter(|r| r.is_boolean()) {
                reply["replayed"] = replayed.clone();
            }
            reply
        }
        (false, false) => json!({ "type": "relay.result", "id": id, "ok": false, "error": body }),
    }
}

impl Supervisor {
    /// A relay line from `app`'s server (generation `generation`): queues it
    /// for the `credential` provider, or returns the line to answer at once.
    pub(super) fn relay_line_locked(
        &self,
        inner: &mut Inner,
        app: &str,
        generation: u64,
        line: &Value,
    ) -> Result<Vec<Out>, Value> {
        let id = line["id"].clone();
        if !Self::host_op_allowed(inner, app, RELAY_SCOPE_OP) {
            return Err(relay_error(
                &id,
                "apps.scope_missing",
                "the server does not declare op:cmux.credential.relay",
            ));
        }
        let (op, params) = provider_call(line)?;
        // A server echoes the origin the supervisor stamped on its op line;
        // it may claim user only while a call admitted with origin user is
        // in flight (never a silent downgrade).
        if params["origin"] == "user" {
            let user_run = inner
                .servers
                .get(app)
                .is_some_and(|s| s.pending.keys().any(|wire| s.user_ops.contains(wire)));
            if !user_run {
                return Err(relay_error(
                    &id,
                    "apps.origin_forbidden",
                    "origin user needs a user run of this app in flight",
                ));
            }
        }
        let gone = || relay_error(&id, "unavailable", "needs the cmux Mac app connected");
        let Some(&client) = inner.providers.get(provider::family_of(op)) else {
            return Err(gone());
        };
        if serde_json::to_vec(&params).map_or(usize::MAX, |b| b.len()) > MAX_PARAMS_BYTES {
            return Err(relay_error(
                &id,
                "validation.invalid",
                "relay params are larger than 64 KiB",
            ));
        }
        let own = |c: &&ProviderCall| matches!(&c.target, Target::Relay { app: owner, .. } if owner == app);
        if inner.provider_calls.values().filter(own).count() >= MAX_PER_SERVER {
            return Err(relay_error(
                &id,
                "unavailable",
                "this app server has too many relay calls outstanding",
            ));
        }
        if inner.provider_calls.values().filter(|c| c.client == client).count() >= MAX_OUTSTANDING {
            return Err(relay_error(
                &id,
                "unavailable",
                "the cmux app has too many calls outstanding",
            ));
        }
        let version =
            inner.catalog.packages.get(app).map(|p| p.version.clone()).unwrap_or_default();

        let deadline = self.config.provider_deadline;
        inner.next_provider_request += 1;
        let request_id = inner.next_provider_request;
        let me = self.me.clone();
        let timer = self.timers.schedule(deadline, move || {
            if let Some(me) = me.upgrade() {
                me.provider_timeout(request_id);
            }
        });
        let session = op == "credential.session";
        inner.provider_calls.insert(
            request_id,
            ProviderCall {
                client,
                op: op.to_string(),
                target: Target::Relay { app: app.to_string(), generation, id, session },
                timer,
            },
        );
        let mut event = json!({
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
            "op": op,
            "params": params,
            "deadline_ms": deadline_ms(deadline),
        });
        // Only a relay.op that carries an origin has one (relay.session and
        // reads have none).
        if let Some(origin) = event["params"].get("origin").cloned() {
            event["origin"] = origin;
        }
        Ok(vec![Out::Provider(client, request_id, event)])
    }

    /// `app`'s server stopped or exited: its relay calls end, and the
    /// provider is told so it can drop the work.
    pub(super) fn cancel_relay_calls_locked(&self, inner: &mut Inner, app: &str) -> Vec<Out> {
        let ids: Vec<u64> = inner
            .provider_calls
            .iter()
            .filter(|(_, c)| matches!(&c.target, Target::Relay { app: owner, .. } if owner == app))
            .map(|(id, _)| *id)
            .collect();
        ids.into_iter()
            .filter_map(|id| inner.provider_calls.remove(&id).map(|call| (id, call)))
            .map(|(id, call)| {
                self.timers.cancel(call.timer);
                Out::Client(
                    call.client,
                    json!({ "event": "apps-provider-cancel", "request_id": id, "reason": "host_exited" }),
                )
            })
            .collect()
    }
}
