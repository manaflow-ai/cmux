//! Calls and console lines from an app's web pane (plans/cmux-next/
//! custom-panes-DESIGN.md sections 2 and 3). The Mac app hosts the page in a
//! sandboxed web view and forwards its `cmux.call(op, params)` here as
//! `apps-web-call`; the page's console goes to the app's log ring as
//! `apps-web-log`. Only the hosting app connection may send either
//! (`server/apps.rs`): an agent or a page cannot act as an app.
//!
//! A web pane call is decided as a call from the app's QuickJS host is
//! (`calls.rs`): the install record's grant, no more than the manifest asks
//! for; `operation.unsupported` and `scope.missing`; no `net:` or
//! `integration:` call while sandboxed. A page cannot prove a gesture, so
//! every view-state op and every action that needs one answers
//! `gesture.required`, and `focus` is never passed to an owner. Ops the Mac
//! app's provider owns are not open to web panes yet.

use std::sync::PoisonError;

use serde_json::{Value, json};

use super::actions::{self, ActionDecision};
use super::calls::mint_key;
use super::egress;
use super::grants::{Decision, OpClass, ScopeTable, needs_gesture};
use super::mirror::Origin;
use super::supervisor::{ApiError, HostKey, Inner, Responder, Supervisor};

/// The longest console line kept (a page can log anything; the ring is shared).
const MAX_LOG_CHARS: usize = 2_000;

/// Calls one app's web panes may have in flight, as an app host (`calls.rs`):
/// each runs on its own worker thread, and a page is as untrusted as the VM.
const MAX_WEB_INFLIGHT: usize = 64;

/// What a web pane may log at.
const LOG_LEVELS: [&str; 4] = ["error", "warn", "info", "debug"];

fn api(code: &str, message: impl Into<String>) -> ApiError {
    ApiError::new(code, message)
}

/// Whether `manifest` has a web implementation (`implements.<iface>.web`).
pub(super) fn has_web_pane(manifest: &Value) -> bool {
    manifest["implements"]
        .as_object()
        .is_some_and(|implements| implements.values().any(|imp| imp.get("web").is_some()))
}

/// One call the decision admitted, for the worker thread.
pub(super) struct Admitted {
    app: String,
    op: String,
    params: Value,
    idempotency_key: Option<String>,
}

/// One in-flight web call of `app` (`Supervisor::web_slot`).
struct WebSlot {
    supervisor: std::sync::Weak<Supervisor>,
    app: String,
}

impl Drop for WebSlot {
    fn drop(&mut self) {
        let Some(supervisor) = self.supervisor.upgrade() else { return };
        let mut inflight = supervisor.web_inflight.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(count) = inflight.get_mut(&self.app) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                inflight.remove(&self.app);
            }
        }
    }
}

impl Supervisor {
    /// `apps-web-call`: decides `op` for `app`'s web pane under the lock,
    /// then runs it on a worker thread and answers `respond` from there.
    pub fn web_call(
        &self,
        app: &str,
        op: &str,
        params: Value,
        idempotency_key: Option<String>,
        respond: Responder,
    ) {
        let admitted = {
            let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            Self::admit_web_call(&inner, app, op, params, idempotency_key)
        };
        let admitted = match admitted {
            Ok(admitted) => admitted,
            Err(error) => return respond(Err(error)),
        };
        // A call that is not the supervisor's own and not the daemon's goes to
        // the Mac app's provider; web panes do not reach it in this version.
        let supervisor_op = admitted.op.starts_with("app.storage.") || admitted.op == "net.fetch";
        if !supervisor_op && !self.router.owns(&admitted.op) {
            return respond(Err(api(
                "operation.unsupported",
                format!("{} is not available to web panes yet", admitted.op),
            )));
        }
        let Some(slot_guard) = self.web_slot(&admitted.app) else {
            let mut error = api("app.limit", "too many calls in flight");
            error.retryable = true;
            return respond(Err(error));
        };
        let me = self.me.clone();
        // Shared with the worker so a failed spawn can still answer the caller.
        let slot = std::sync::Arc::new(std::sync::Mutex::new(Some(respond)));
        let worker_slot = slot.clone();
        let spawned =
            std::thread::Builder::new().name("cmux-app-web-call".into()).spawn(move || {
                let _slot = slot_guard;
                let Some(respond) = worker_slot.lock().ok().and_then(|mut r| r.take()) else {
                    return;
                };
                let Some(me) = me.upgrade() else {
                    return respond(Err(api("operation.failed", "the daemon is shutting down")));
                };
                respond(
                    me.execute_web(admitted)
                        .map_err(|body| ApiError::from_body(&body, "operation.failed")),
                );
            });
        if let Err(e) = spawned
            && let Some(respond) = slot.lock().ok().and_then(|mut r| r.take())
        {
            let mut error = api("operation.failed", format!("no worker thread: {e}"));
            error.retryable = true;
            respond(Err(error));
        }
    }

    /// Takes one of `app`'s in-flight web call slots, or None at the cap. The
    /// slot is given back when the guard drops (the call answered, or the
    /// worker never started).
    fn web_slot(&self, app: &str) -> Option<WebSlot> {
        let mut inflight = self.web_inflight.lock().unwrap_or_else(PoisonError::into_inner);
        let count = inflight.entry(app.to_string()).or_default();
        if *count >= MAX_WEB_INFLIGHT {
            return None;
        }
        *count += 1;
        Some(WebSlot { supervisor: self.me.clone(), app: app.to_string() })
    }

    /// The per-call decision (see the module docs). Pure over `inner`.
    pub(super) fn admit_web_call(
        inner: &Inner,
        app: &str,
        op: &str,
        mut params: Value,
        idempotency_key: Option<String>,
    ) -> Result<Admitted, ApiError> {
        let package =
            inner.catalog.packages.get(app).ok_or_else(|| api("apps.unknown", "no such app"))?;
        if !has_web_pane(&package.manifest) {
            return Err(api("apps.web.none", "the app has no web pane"));
        }
        let record = inner.mirror.apps.get(app);
        if !record.is_some_and(|r| r.installed && r.enabled) {
            return Err(api("scope.missing", "the app is not installed and enabled"));
        }
        let op = package.resolve_op(op).to_string();
        let grant = Self::grant_for(inner, &HostKey { app: app.to_string(), preview: false });
        let class = match ScopeTable::get().check(&op, &params, &grant) {
            Decision::Unsupported => {
                return Err(api(
                    "operation.unsupported",
                    format!("{op} is not an operation of this cmux version"),
                ));
            }
            Decision::ScopeMissing(reason) => {
                let mut error = api("scope.missing", reason);
                error.details = Some(json!({ "op": op }));
                return Err(error);
            }
            Decision::Allow(class) => class,
        };
        let mut gesture = needs_gesture(&op);
        if op == "action.run" {
            match actions::decide(params.get("id").and_then(Value::as_str)) {
                ActionDecision::Unknown => {
                    return Err(api(
                        "operation.unsupported",
                        "no such action in this cmux version",
                    ));
                }
                ActionDecision::Refused(reason) => {
                    return Err(api("scope.missing", format!("apps cannot run {reason} actions")));
                }
                ActionDecision::NeedsGesture => gesture = true,
            }
        }
        if gesture {
            return Err(api(
                "gesture.required",
                format!("{op} changes what the user sees; a web pane cannot run it"),
            ));
        }
        if let Some(fields) = params.as_object_mut() {
            fields.remove("focus");
        }
        // Web pane keys live in their own namespace, apart from the app
        // host's and every other actor's, in an owner's replay cache.
        let idempotency_key = (class == OpClass::Mutation).then(|| {
            let own = idempotency_key.filter(|k| !k.is_empty()).unwrap_or_else(mint_key);
            format!("app:{app}:web:{own}")
        });
        Ok(Admitted { app: app.to_string(), op, params, idempotency_key })
    }

    pub(super) fn execute_web(&self, call: Admitted) -> Result<Value, Value> {
        let Admitted { app, op, params, idempotency_key } = call;
        let error = |code: &str, message: &str| json!({ "code": code, "message": message, "retryable": false });
        // The grant is read again under the supervisor lock: a revoke, an
        // uninstall or a switch to sandboxed between admission and now
        // refuses the call (the app host's calls check the same in calls.rs).
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if !inner.mirror.apps.get(&app).is_some_and(|r| r.installed && r.enabled) {
            return Err(error("scope.missing", "the app is not installed"));
        }
        let grant = Self::grant_for(&inner, &HostKey { app: app.clone(), preview: false });
        if !matches!(ScopeTable::get().check(&op, &params, &grant), Decision::Allow(_)) {
            return Err(error("scope.missing", "the app's grant no longer covers this call"));
        }
        if op.starts_with("app.storage.") {
            // Still under the lock: an uninstall (which drops the table under
            // the same lock) cannot interleave with this write.
            let storage = self.storage();
            let storage = storage
                .as_ref()
                .ok_or_else(|| error("operation.failed", "app storage is unavailable"))?;
            return storage
                .call(&app, &op, &params)
                .map(|value| json!({ "value": value }))
                .map_err(|e| error(e.code, &e.message));
        }
        drop(inner);
        if op == "net.fetch" {
            let request = egress::admit(&params, &grant.scopes, grant.sandboxed)
                .map_err(|e| error(e.code, &e.message))?;
            return self
                .fetcher
                .fetch(request)
                .map(egress::response_json)
                .map_err(|e| error(e.code, &e.message));
        }
        self.router.route(&app, &op, params, idempotency_key, Origin::Script)
    }

    /// `apps-web-log`: one console line of `app`'s web pane into its log ring
    /// (what `apps-logs` reads and follows).
    pub fn web_log(&self, app: &str, level: &str, message: &str) -> Result<Value, ApiError> {
        let level = if LOG_LEVELS.contains(&level) { level } else { "info" };
        let truncated = message.chars().count() > MAX_LOG_CHARS;
        let mut message: String = message.chars().take(MAX_LOG_CHARS).collect();
        if truncated {
            message.push('…');
        }
        let outs = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            let web = inner.catalog.packages.get(app).is_some_and(|p| has_web_pane(&p.manifest));
            if !web {
                return Err(api("apps.web.none", "the app has no web pane"));
            }
            self.log_locked(&mut inner, app, level, format!("pane: {message}"))
        };
        self.emit(outs);
        Ok(json!({}))
    }
}
