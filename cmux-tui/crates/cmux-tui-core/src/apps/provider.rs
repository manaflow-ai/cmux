//! The provider channel (plans/cmux-next/app-op-routing.md): app calls to
//! ops the daemon does not own go to the connection that registered as
//! their provider (the Mac app: file panels, actions, app settings, and the
//! cloud ops it sends with its install token). The supervisor's scope,
//! grant, sandbox and gesture checks run first; the provider sees the
//! stamped actor (`app:<id>`) and origin and enforces its own owner rules.
//!
//! Wire (local connections only):
//! - `apps-provider-register {families}` -> `{families}`; one provider per
//!   family, a later registration replaces an earlier one; it ends with the
//!   connection.
//! - event `apps-provider-request {request_id, app, actor, origin, op,
//!   params, idempotency_key?, deadline_ms}` to the provider only;
//! - `apps-provider-result {request_id, ok, body}` (ABI bodies) -> `{}`;
//! - event `apps-provider-cancel {request_id, reason}`: `timeout` (the
//!   deadline passed first), `revoked` (the app was disabled, uninstalled or
//!   re-granted) or `host_exited`.
//! - A family held by a live connection cannot be taken over
//!   (`apps.provider.taken`); it frees up when that connection closes.
//!
//! APP-R1: a call with no provider fails at once, never waits, with
//! `provider.unavailable` (retryable, details `{family}`); a provider that
//! disconnects mid-call fails its pending calls the same way. A provider that
//! is connected but does not answer in time fails with `operation.failed`
//! (reason `timeout`).

use std::time::Duration;

use cmux_app_host::ToHost;
use serde_json::{Value, json};

use super::mirror::Origin;
use super::supervisor::{ApiError, HostKey, Inner, Out, Supervisor};
use super::timer::TimerId;

/// Families a provider may serve. The supervisor's own ops (`app.storage.*`,
/// `net.fetch`) and the daemon's catalog ops are never routed.
/// The allowlist stays explicit: a new family is a decision, never "any
/// family the daemon does not own".
/// `credential` is the host credential relay (`relay.rs`): first-party app
/// servers' Cloud API calls, sent by the Mac app with its install token.
pub const FAMILIES: &[&str] = &[
    "fs",
    "action",
    "app.settings",
    "power",
    "feed",
    "integration",
    "team",
    "app",
    "coderouter",
    "credential",
];

/// Ops that wait for the user (a file panel) get the long deadline.
const WAITS_FOR_USER: &[&str] = &["fs.pick"];
/// Largest params a routed call may carry (the provider's control queue is
/// bounded; an untrusted app must not be able to overflow it).
pub(super) const MAX_PARAMS_BYTES: usize = 64 * 1024;
/// Calls one provider may have outstanding across every app.
pub(super) const MAX_OUTSTANDING: usize = 64;

/// Who waits for a provider call's answer.
pub(super) enum Target {
    /// An app host's call; `cb` is its callback in that host process.
    Host { host: HostKey, generation: u64, cb: u64 },
    /// An app server's `relay.op` or `relay.session` line (`relay.rs`),
    /// answered on that server process's input.
    Relay { app: String, generation: u64, id: Value, session: bool },
}

pub(super) struct ProviderCall {
    pub client: u64,
    pub op: String,
    pub target: Target,
    pub timer: TimerId,
}

/// How a provider call ended.
pub(super) enum Ending {
    /// The provider answered (`body` in the ABI shape).
    Answer { ok: bool, body: Value },
    /// It timed out.
    Timeout,
    /// No provider could take it (the send failed or the provider left).
    Gone,
}

/// The provider family of `op`.
pub fn family_of(op: &str) -> &str {
    if op.starts_with("app.settings.") {
        return "app.settings";
    }
    op.split('.').next().unwrap_or_default()
}

/// APP-R1: no provider for the op's family (none connected, or it left).
pub fn unavailable(op: &str) -> Value {
    json!({
        "code": "provider.unavailable",
        "message": "needs the cmux Mac app connected",
        "details": { "family": family_of(op), "op": op },
        "retryable": true,
    })
}

/// `integration.request` without a method is a GET for the grant check;
/// the provider gets that method explicitly, upper-cased.
pub fn normalize_method(params: &mut Value) {
    if let Some(fields) = params.as_object_mut() {
        let method =
            fields.get("method").and_then(Value::as_str).unwrap_or("GET").to_ascii_uppercase();
        fields.insert("method".into(), Value::String(method));
    }
}

/// A provider's error body in the ABI shape `{code, message, retryable}`.
pub(super) fn error_body(body: Value) -> Value {
    let code = body.get("code").and_then(Value::as_str).unwrap_or("operation.failed").to_string();
    let message = body
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("the cmux app refused the call")
        .to_string();
    let retryable = body.get("retryable").and_then(Value::as_bool).unwrap_or(false);
    let mut out = json!({ "code": code, "message": message, "retryable": retryable });
    if let Some(details) = body.get("details") {
        out["details"] = details.clone();
    }
    out
}

/// What the daemon knows about the registering connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderClaim {
    /// The connection is bound to an agent (its conversation principal is
    /// not the local user).
    pub agent: bool,
    /// The connection proved it is the cmux app (`verified_app`: install-key
    /// hello or the app's code signature, server/app_trust.rs). A
    /// self-declared `set-client-info` kind never sets it.
    pub verified_app: bool,
}

/// Whether the connection is the hosting cmux app: the one check behind
/// `apps-provider-register` and behind origin `user` on every `apps-*`
/// command. Not an agent connection, and a verified app connection.
pub fn hosting_app_connection(claim: &ProviderClaim) -> bool {
    !claim.agent && claim.verified_app
}

/// Admits a request's `origin`. Origin `user` (installs, grants, gestures)
/// is accepted only from the hosting app connection; any other connection
/// that sends it gets `apps.origin_forbidden`, never a silent downgrade.
/// The other origins are unchanged.
pub fn admit_origin(origin: Origin, claim: &ProviderClaim) -> Result<(), ApiError> {
    if origin != Origin::User || hosting_app_connection(claim) {
        return Ok(());
    }
    let why = if claim.agent {
        "an agent connection cannot act with origin user"
    } else {
        "only the verified cmux app connection can act with origin user"
    };
    Err(ApiError::new("apps.origin_forbidden", why))
}

impl Supervisor {
    /// `apps-provider-register`. Two gates (app platform lead, 2026-10-03):
    /// an agent connection is refused outright, and the connection must be
    /// the verified app (install-key hello or code signature; P8 3b-2).
    pub fn register_provider(
        &self,
        client: u64,
        claim: ProviderClaim,
        families: Vec<String>,
    ) -> Result<Value, ApiError> {
        if !hosting_app_connection(&claim) {
            let why = if claim.agent {
                "agent connections cannot provide app ops"
            } else {
                "only the verified cmux app connection can provide app ops"
            };
            return Err(ApiError::new("apps.provider.forbidden", why));
        }
        if families.is_empty() {
            return Err(ApiError::new("bad-request", "families must not be empty"));
        }
        if let Some(unknown) = families.iter().find(|f| !FAMILIES.contains(&f.as_str())) {
            return Err(ApiError::new(
                "bad-request",
                format!("{unknown} is not a provider family"),
            ));
        }
        let mut inner = self.inner.lock().unwrap();
        // No takeover: a family held by another live connection stays with it
        // until that connection closes (any same-uid process may connect).
        if let Some(taken) = families
            .iter()
            .find(|f| inner.providers.get(*f).is_some_and(|holder| *holder != client))
        {
            return Err(ApiError::new(
                "apps.provider.taken",
                format!("another connection already provides {taken}"),
            ));
        }
        for family in &families {
            inner.providers.insert(family.clone(), client);
        }
        Ok(json!({ "families": families }))
    }

    /// Queues an admitted call for its provider; the error is the ABI body
    /// to answer at once (no family, no provider, too large, too many).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn route_to_provider_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        cb: u64,
        op: &str,
        params: Value,
        origin: Origin,
        idempotency_key: Option<String>,
    ) -> Result<Vec<Out>, Value> {
        // The credential relay serves app servers' relay lines only
        // (`relay.rs`), never an app host's call, whatever its scopes say.
        if !FAMILIES.contains(&family_of(op)) || family_of(op) == "credential" {
            return Err(
                json!({ "code": "operation.unsupported", "message": format!("{op} has no owner reachable from apps yet"), "details": { "op": op }, "retryable": false }),
            );
        }
        let Some(&client) = inner.providers.get(family_of(op)) else { return Err(unavailable(op)) };
        let version =
            inner.catalog.packages.get(&key.app).map(|p| p.version.clone()).unwrap_or_default();
        if serde_json::to_vec(&params).map_or(usize::MAX, |b| b.len()) > MAX_PARAMS_BYTES {
            return Err(
                json!({ "code": "validation.invalid", "message": "params are larger than 64 KiB", "retryable": false }),
            );
        }
        if inner.provider_calls.values().filter(|c| c.client == client).count() >= MAX_OUTSTANDING {
            return Err(
                json!({ "code": "app.limit", "message": "the cmux app has too many calls outstanding", "retryable": true }),
            );
        }
        let generation = inner.hosts.get(key).map_or(0, |h| h.generation);
        let deadline = if WAITS_FOR_USER.contains(&op) {
            self.config.provider_user_deadline
        } else {
            self.config.provider_deadline
        };
        inner.next_provider_request += 1;
        let request_id = inner.next_provider_request;
        let me = self.me.clone();
        let timer = self.timers.schedule(deadline, move || {
            if let Some(me) = me.upgrade() {
                me.provider_timeout(request_id);
            }
        });
        inner.provider_calls.insert(
            request_id,
            ProviderCall {
                client,
                op: op.to_string(),
                target: Target::Host { host: key.clone(), generation, cb },
                timer,
            },
        );
        if let Some(host) = inner.hosts.get_mut(key) {
            host.inflight += 1;
        }
        let mut event = json!({
            "event": "apps-provider-request",
            "request_id": request_id,
            "app": key.app,
            // The identity.md section 3 `app` actor (only the supervisor sets it).
            "actor": {
                "kind": "app",
                "id": key.app,
                "host": crate::machine_name::machine_name(),
                "version": version,
                "on_behalf_of": { "kind": "user", "id": crate::conversation_store::LOCAL_USER },
            },
            "origin": origin,
            "op": op,
            "params": params,
            "deadline_ms": deadline_ms(deadline),
        });
        if let Some(key) = idempotency_key {
            event["idempotency_key"] = Value::String(key);
        }
        // Sent after the lock is released; a failed send fails the call.
        Ok(vec![Out::Provider(client, request_id, event)])
    }

    /// The provider's connection refused the event (closed or full).
    pub(super) fn provider_send_failed(&self, request_id: u64) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let Some(call) = inner.provider_calls.remove(&request_id) else { return };
            self.timers.cancel(call.timer);
            self.finish_locked(&mut inner, &call, Ending::Gone)
        };
        self.emit(outs);
    }

    /// A host stopped, restarted or lost its grant: its provider calls end,
    /// and the provider is told so it can drop the work (an open panel).
    pub(super) fn cancel_provider_calls_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        reason: &str,
    ) -> Vec<Out> {
        let ids: Vec<u64> = inner
            .provider_calls
            .iter()
            .filter(|(_, c)| matches!(&c.target, Target::Host { host, .. } if host == key))
            .map(|(id, _)| *id)
            .collect();
        let mut outs = Vec::new();
        for id in ids {
            let call = inner.provider_calls.remove(&id).expect("listed");
            self.timers.cancel(call.timer);
            if let Target::Host { host, generation, .. } = &call.target
                && let Some(host) =
                    inner.hosts.get_mut(host).filter(|h| h.generation == *generation)
            {
                host.inflight = host.inflight.saturating_sub(1);
            }
            outs.push(Out::Client(
                call.client,
                json!({ "event": "apps-provider-cancel", "request_id": id, "reason": reason }),
            ));
        }
        outs
    }

    /// Answers whoever waits for `call`: the host that asked (same process
    /// only, then an idle host may stop) or the server's relay line.
    pub(super) fn finish_locked(
        &self,
        inner: &mut Inner,
        call: &ProviderCall,
        ending: Ending,
    ) -> Vec<Out> {
        match &call.target {
            Target::Host { host, generation, cb } => {
                let (ok, body) = match ending {
                    Ending::Answer { ok, body } => (ok, body),
                    Ending::Timeout => (
                        false,
                        json!({ "code": "operation.failed", "message": "the cmux app did not answer in time", "details": { "reason": "timeout" }, "retryable": true }),
                    ),
                    Ending::Gone => (false, unavailable(&call.op)),
                };
                answer_locked(inner, host, *generation, ToHost::Resolve { cb: *cb, ok, body });
                self.idle_check_locked(inner, host)
            }
            Target::Relay { app, generation, id, session } => {
                let reply = super::relay::relay_reply(id, *session, ending);
                if let Some(server) =
                    inner.servers.get(app).filter(|s| s.generation == *generation && !s.stopping)
                {
                    server.process.send(super::servers::line(&reply));
                }
                vec![]
            }
        }
    }

    /// `apps-provider-result`: only the provider the call went to may answer.
    pub fn provider_result(
        &self,
        client: u64,
        request_id: u64,
        ok: bool,
        body: Value,
    ) -> Result<Value, ApiError> {
        let mut inner = self.inner.lock().unwrap();
        match inner.provider_calls.get(&request_id) {
            Some(call) if call.client == client => {}
            _ => {
                return Err(ApiError::new(
                    "apps.provider.unknown",
                    "no such provider request on this connection",
                ));
            }
        }
        let call = inner.provider_calls.remove(&request_id).expect("checked");
        self.timers.cancel(call.timer);
        let body = match (ok, body.is_object()) {
            (true, true) => body,
            (true, false) => json!({ "value": body }),
            (false, _) => error_body(body),
        };
        let outs = self.finish_locked(&mut inner, &call, Ending::Answer { ok, body });
        drop(inner);
        self.emit(outs);
        Ok(json!({}))
    }

    pub(super) fn provider_timeout(&self, request_id: u64) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let Some(call) = inner.provider_calls.remove(&request_id) else { return };
            let mut outs = self.finish_locked(&mut inner, &call, Ending::Timeout);
            outs.push(Out::Client(
                call.client,
                json!({ "event": "apps-provider-cancel", "request_id": request_id, "reason": "timeout" }),
            ));
            outs
        };
        self.emit(outs);
    }

    /// A provider connection closed: its families go away and its pending
    /// calls fail at once.
    pub(super) fn provider_disconnect_locked(&self, inner: &mut Inner, client: u64) -> Vec<Out> {
        inner.providers.retain(|_, provider| *provider != client);
        let gone: Vec<u64> = inner
            .provider_calls
            .iter()
            .filter(|(_, c)| c.client == client)
            .map(|(id, _)| *id)
            .collect();
        let mut outs = Vec::new();
        for id in gone {
            let call = inner.provider_calls.remove(&id).expect("listed");
            self.timers.cancel(call.timer);
            outs.extend(self.finish_locked(inner, &call, Ending::Gone));
        }
        outs
    }
}

/// Answers the host that asked, if it is still the same process.
fn answer_locked(inner: &mut Inner, host: &HostKey, generation: u64, message: ToHost) {
    if let Some(host) = inner.hosts.get_mut(host).filter(|h| h.generation == generation) {
        host.inflight = host.inflight.saturating_sub(1);
        if let Some(process) = &host.process {
            process.send(&message);
        }
    }
}

pub(super) fn deadline_ms(deadline: Duration) -> u64 {
    deadline.as_millis().min(u128::from(u64::MAX)) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn families_and_methods() {
        assert_eq!(family_of("app.settings.set"), "app.settings");
        assert_eq!(family_of("fs.pick"), "fs");
        let mut params = json!({ "provider": "github" });
        normalize_method(&mut params);
        assert_eq!(params["method"], "GET");
        let mut post = json!({ "method": "post" });
        normalize_method(&mut post);
        assert_eq!(post["method"], "POST");
    }

    /// A new `app.*` op must be a decision: the supervisor keeps
    /// `app.storage.*`; anything else in the catalog would silently go to
    /// the provider's `app` family.
    #[test]
    fn every_app_op_in_the_scope_table_has_a_known_owner() {
        for op in super::super::grants::ScopeTable::get().known_ops() {
            if family_of(&op) == "app" {
                assert!(op.starts_with("app.storage."), "{op}: decide its owner before adding it");
            }
        }
    }
}
