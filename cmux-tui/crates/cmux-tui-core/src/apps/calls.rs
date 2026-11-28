//! App calls: the per-call decision (scope, grant, sandbox, gesture,
//! in-flight cap) under the supervisor lock, then the work on a worker
//! thread (storage, egress, or the daemon's own dispatcher), answered back
//! to the host that asked if it is still the same process.

use std::sync::Arc;
use std::time::Instant;

use cmux_app_host::ToHost;
use serde_json::{Value, json};

use super::actions::{self, ActionDecision};
use super::egress;
use super::grants::{Decision, GestureCheck, Grant, OpClass, ScopeTable, needs_gesture};
use super::host::HostProcess;
use super::mirror::Origin;
use super::provider;
use super::supervisor::{HostKey, Inner, Out, Supervisor};

/// Calls one host may have in flight (the VM caps itself at 64 too, but the
/// VM is untrusted).
const MAX_INFLIGHT: usize = 64;

fn error(code: &str, message: impl Into<String>) -> Value {
    json!({ "code": code, "message": message.into(), "retryable": false })
}

struct Work {
    app: String,
    op: String,
    params: Value,
    idempotency_key: Option<String>,
    origin: Origin,
    grant: Grant,
    generation: u64,
}

impl Supervisor {
    pub(super) fn call_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        cb: u64,
        op: String,
        mut params: Value,
        options: Value,
    ) -> Vec<Out> {
        let host = inner.hosts.get(key).expect("host");
        let Some(process) = host.process.clone() else { return vec![] };
        let grant = host.grant.clone();
        let generation = host.generation;
        let reject = |body: Value| {
            process.send(&ToHost::Resolve { cb, ok: false, body });
            Vec::new()
        };
        if host.inflight >= MAX_INFLIGHT {
            return reject(
                json!({ "code": "app.limit", "message": "too many calls in flight", "retryable": true }),
            );
        }
        let class = match ScopeTable::get().check(&op, &params, &grant) {
            Decision::Unsupported => {
                return reject(error(
                    "operation.unsupported",
                    format!("{op} is not an operation of this cmux version"),
                ));
            }
            Decision::ScopeMissing(reason) => {
                return reject(
                    json!({ "code": "scope.missing", "message": reason, "details": { "op": op }, "retryable": false }),
                );
            }
            Decision::Allow(class) => class,
        };
        let mutation = class == OpClass::Mutation;
        // action.run: the inner action decides (refused classes, gesture).
        let mut view_op = needs_gesture(&op);
        if op == "action.run" {
            match actions::decide(params.get("id").and_then(Value::as_str)) {
                ActionDecision::Unknown => {
                    return reject(error(
                        "operation.unsupported",
                        "no such action in this cmux version",
                    ));
                }
                ActionDecision::Refused(reason) => {
                    return reject(
                        json!({ "code": "scope.missing", "message": format!("apps cannot run {reason} actions"), "details": { "op": op, "reason": reason }, "retryable": false }),
                    );
                }
                ActionDecision::NeedsGesture => view_op = true,
            }
        }
        let token = options.get("gesture").and_then(Value::as_str);
        // One token allows one view-state change: a view-state op, or any op
        // asked to move focus. Other calls run as the user while it is live.
        let changes_view = view_op || params.get("focus") == Some(&Value::Bool(true));
        let gesture = inner.gestures.present(&key.app, token, changes_view, Instant::now());
        if view_op && gesture != GestureCheck::User {
            return reject(error(
                "gesture.required",
                format!("{op} changes what the user sees and needs a user gesture"),
            ));
        }
        let origin = if gesture == GestureCheck::User { Origin::User } else { Origin::Script };
        // Without a spent gesture an app never asks an owner to move focus.
        if origin != Origin::User
            && let Some(fields) = params.as_object_mut()
        {
            fields.remove("focus");
        }
        // App keys live in their own namespace so they never meet another
        // actor's keys in an owner's replay cache.
        let idempotency_key = mutation.then(|| {
            let own =
                options.get("idempotencyKey").and_then(Value::as_str).filter(|k| !k.is_empty());
            format!("app:{}:{}", key.app, own.map_or_else(mint_key, str::to_string))
        });
        // Ops the daemon does not own go to their provider (the Mac app), or
        // fail at once when none is connected (APP-R1).
        let supervisor_op = op.starts_with("app.storage.") || op == "net.fetch";
        if !supervisor_op && !self.router.owns(&op) {
            if op == "integration.request" {
                // The provider sees the method the grant check decided on.
                provider::normalize_method(&mut params);
            }
            let routed =
                self.route_to_provider_locked(inner, key, cb, &op, params, origin, idempotency_key);
            return match routed {
                Ok(outs) => outs,
                Err(body) => reject(body),
            };
        }
        inner.hosts.get_mut(key).expect("host").inflight += 1;
        let work =
            Work { app: key.app.clone(), op, params, idempotency_key, origin, grant, generation };
        let me = self.me.clone();
        let host_key = key.clone();
        let answer_to = process.clone();
        let spawned = std::thread::Builder::new().name("cmux-app-call".into()).spawn(move || {
            let Some(me) = me.upgrade() else { return };
            let (ok, body) = match me.execute(&host_key, work) {
                Ok(body) => (true, body),
                Err(body) => (false, body),
            };
            me.answer(&host_key, generation, &answer_to, ToHost::Resolve { cb, ok, body });
        });
        if let Err(e) = spawned {
            inner.hosts.get_mut(key).expect("host").inflight -= 1;
            return reject(
                json!({ "code": "operation.failed", "message": format!("no worker thread: {e}"), "retryable": true }),
            );
        }
        vec![]
    }

    fn execute(&self, key: &HostKey, work: Work) -> Result<Value, Value> {
        let Work { app, op, params, idempotency_key, origin, grant, generation } = work;
        if op.starts_with("app.storage.") {
            // Under the supervisor lock: an uninstall (which drops the
            // table under the same lock) cannot interleave with this write.
            let inner = self.inner.lock().unwrap();
            let current = inner
                .hosts
                .get(key)
                .is_some_and(|h| h.generation == generation && !h.grant.revoked);
            let installed = inner.mirror.apps.get(&app).is_some_and(|r| r.installed);
            if !current || !installed || key.preview {
                return Err(error("scope.missing", "the app is not installed"));
            }
            let storage = self.storage();
            let storage = storage
                .as_ref()
                .ok_or_else(|| error("operation.failed", "app storage is unavailable"))?;
            return storage
                .call(&app, &op, &params)
                .map(|value| json!({ "value": value }))
                .map_err(|e| error(e.code, e.message));
        }
        if op == "net.fetch" {
            let request = egress::admit(&params, &grant.scopes, grant.sandboxed)
                .map_err(|e| error(e.code, e.message))?;
            return self
                .fetcher
                .fetch(request)
                .map(egress::response_json)
                .map_err(|e| error(e.code, e.message));
        }
        self.router.route(&app, &op, params, idempotency_key, origin)
    }

    /// Writes the answer if the host that asked is still the current process.
    fn answer(&self, key: &HostKey, generation: u64, process: &Arc<HostProcess>, message: ToHost) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let Some(host) = inner.hosts.get_mut(key).filter(|h| h.generation == generation) else {
                return;
            };
            host.inflight = host.inflight.saturating_sub(1);
            process.send(&message);
            // The idle stop waits for calls in flight; this one is done.
            self.idle_check_locked(&mut inner, key)
        };
        self.emit(outs);
    }
}

fn mint_key() -> String {
    let mut bytes = [0u8; 12];
    let _ = getrandom::fill(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
