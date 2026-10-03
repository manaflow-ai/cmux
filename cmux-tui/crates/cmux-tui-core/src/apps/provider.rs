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
//! - event `apps-provider-cancel {request_id, reason}` when the deadline
//!   passes first.
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
pub const FAMILIES: &[&str] =
    &["fs", "action", "app.settings", "power", "feed", "integration", "team", "app"];

/// Ops that wait for the user (a file panel) get the long deadline.
const WAITS_FOR_USER: &[&str] = &["fs.pick"];

pub(super) struct ProviderCall {
    pub client: u64,
    pub op: String,
    pub host: HostKey,
    pub generation: u64,
    pub cb: u64,
    pub timer: TimerId,
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

impl Supervisor {
    /// `apps-provider-register`.
    pub fn register_provider(&self, client: u64, families: Vec<String>) -> Result<Value, ApiError> {
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
        for family in &families {
            inner.providers.insert(family.clone(), client);
        }
        Ok(json!({ "families": families }))
    }

    /// Sends an admitted call to its provider; false when none serves it.
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
    ) -> bool {
        let Some(&client) = inner.providers.get(family_of(op)) else { return false };
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
            ProviderCall { client, op: op.to_string(), host: key.clone(), generation, cb, timer },
        );
        if let Some(host) = inner.hosts.get_mut(key) {
            host.inflight += 1;
        }
        let mut event = json!({
            "event": "apps-provider-request",
            "request_id": request_id,
            "app": key.app,
            "actor": format!("app:{}", key.app),
            "origin": origin,
            "op": op,
            "params": params,
            "deadline_ms": deadline_ms(deadline),
        });
        if let Some(key) = idempotency_key {
            event["idempotency_key"] = Value::String(key);
        }
        if let Some(sink) = inner.sinks.get(&client).cloned() {
            // The sink only queues on the connection's writer.
            sink(&event);
        }
        true
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
        let body = if body.is_object() { body } else { json!({ "value": body }) };
        answer_locked(&mut inner, &call, ToHost::Resolve { cb: call.cb, ok, body });
        Ok(json!({}))
    }

    fn provider_timeout(&self, request_id: u64) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let Some(call) = inner.provider_calls.remove(&request_id) else { return };
            let body = json!({ "code": "operation.failed", "message": "the cmux app did not answer in time", "details": { "reason": "timeout" }, "retryable": true });
            answer_locked(&mut inner, &call, ToHost::Resolve { cb: call.cb, ok: false, body });
            vec![Out::Client(
                call.client,
                json!({ "event": "apps-provider-cancel", "request_id": request_id, "reason": "timeout" }),
            )]
        };
        self.emit(outs);
    }

    /// A provider connection closed: its families go away and its pending
    /// calls fail at once.
    pub(super) fn provider_disconnect_locked(&self, inner: &mut Inner, client: u64) {
        inner.providers.retain(|_, provider| *provider != client);
        let gone: Vec<u64> = inner
            .provider_calls
            .iter()
            .filter(|(_, c)| c.client == client)
            .map(|(id, _)| *id)
            .collect();
        for id in gone {
            let call = inner.provider_calls.remove(&id).expect("listed");
            self.timers.cancel(call.timer);
            let body = unavailable(&call.op);
            answer_locked(inner, &call, ToHost::Resolve { cb: call.cb, ok: false, body });
        }
    }
}

/// Answers the host that asked, if it is still the same process.
fn answer_locked(inner: &mut Inner, call: &ProviderCall, message: ToHost) {
    if let Some(host) = inner.hosts.get_mut(&call.host).filter(|h| h.generation == call.generation)
    {
        host.inflight = host.inflight.saturating_sub(1);
        if let Some(process) = &host.process {
            process.send(&message);
        }
    }
}

fn deadline_ms(deadline: Duration) -> u64 {
    deadline.as_millis().min(u128::from(u64::MAX)) as u64
}
