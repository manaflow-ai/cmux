//! Calls from an extension's web pane (`render: web`, `apps-page-call`).
//!
//! A web pane reaches cmux through the same scoped door as the app's QuickJS
//! host: the pane's bridge ([`PageBridge`]: async only, 256 KiB a message,
//! 200 calls a second) checks each call against the app's grant with the
//! same scope table, and an admitted call runs on the same path as a host's
//! call (`calls.rs`: storage, egress, the daemon's dispatcher, or the Mac
//! app's provider), as the app, with origin `script`. A page has no ambient
//! access: what its app was not granted is `scope.missing`, an app that is
//! not installed is a preview (nothing granted), and an app that is turned
//! off or in safe mode has a revoked grant (nothing admitted).
//!
//! Ops that change what the person sees (`needs_gesture`) and `action.run`
//! need a tap the supervisor minted; a page has no such token yet, so they
//! are `gesture.required`. Only the verified cmux app connection hosts pages
//! (server/apps.rs), so an agent cannot borrow an extension's grant.
//!
//! Each open page (the client's connection and its page key) keeps its own
//! bridge, so one tab's flood cannot spend another tab's budget. Slots end
//! with their connection; their count is bounded.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use serde_json::{Value, json};

use super::calls::{Work, mint_key};
use super::grants::{Grant, OpClass, needs_gesture};
use super::mirror::Origin;
use super::page_bridge::{PageBridge, PageCall};
use super::provider::Target;
use super::supervisor::{ApiError, HostKey, Inner, Out, Responder, Supervisor};

/// Calls one page may have in flight (as a host: `calls.rs`).
const MAX_PAGE_INFLIGHT: usize = 64;
/// Open page slots kept across every connection; past it, idle ones go.
const MAX_PAGES: usize = 256;

struct PageSlot {
    bridge: PageBridge,
    inflight: usize,
}

/// Who waits for a page call that went to a provider (`provider.rs`).
pub(super) struct PageTarget {
    pub client: u64,
    pub page: String,
    pub id: String,
    pub waiter: u64,
}

/// The supervisor's page state (`Inner::pages`).
#[derive(Default)]
pub(super) struct Pages {
    slots: HashMap<(u64, String), PageSlot>,
    waiters: HashMap<u64, Responder>,
    next_waiter: u64,
}

impl Pages {
    /// A connection closed: its pages' budgets go with it.
    pub(super) fn client_gone(&mut self, client: u64) {
        self.slots.retain(|(owner, _), _| *owner != client);
    }
}

/// The answer the page receives for call `id`: `{id, ok: true, value}` or
/// `{id, ok: false, error: {code, message, retryable, details?}}`.
pub fn page_answer(id: &str, ok: bool, body: Value) -> Value {
    if !ok {
        return json!({ "id": id, "ok": false, "error": body });
    }
    let value = match body {
        Value::Object(mut fields) => fields.remove("value").unwrap_or(Value::Null),
        other => other,
    };
    json!({ "id": id, "ok": true, "value": value })
}

fn refused(respond: Responder, id: &str, code: &str, message: String, retryable: bool) -> Vec<Out> {
    let error = json!({ "code": code, "message": message, "retryable": retryable });
    vec![Out::Respond(respond, Ok(page_answer(id, false, error)))]
}

impl Supervisor {
    /// The grant a web pane of `app` calls with: the app's own grant; a
    /// preview grant when it is not installed; revoked while it is turned off
    /// or safe mode is on.
    fn page_grant_locked(inner: &Inner, app: &str) -> Grant {
        let record = inner.mirror.apps.get(app);
        let installed = record.is_some_and(|r| r.installed);
        let mut grant =
            Self::grant_for(inner, &HostKey { app: app.to_string(), preview: !installed });
        if (installed && !record.is_some_and(|r| r.enabled)) || inner.safe_mode.is_some() {
            grant.revoked = true;
        }
        grant
    }

    /// `apps-page-call`: one raw bridge message of `app`'s web pane `page`.
    /// `respond` gets the page's answer (refusals included) or, when the
    /// app has no web pane, an error.
    pub fn page_call(&self, client: u64, app: &str, page: &str, raw: &str, respond: Responder) {
        let outs = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            self.page_call_locked(&mut inner, client, app, page, raw, respond)
        };
        self.emit(outs);
    }

    fn page_call_locked(
        &self,
        inner: &mut Inner,
        client: u64,
        app: &str,
        page: &str,
        raw: &str,
        respond: Responder,
    ) -> Vec<Out> {
        let has_page = inner
            .catalog
            .packages
            .get(app)
            .is_some_and(|p| !cmux_app_manifest::web_pages(&p.manifest).is_empty());
        if !has_page {
            let error = ApiError::new("apps.page.unknown", format!("{app} has no web pane"));
            return vec![Out::Respond(respond, Err(error))];
        }
        let grant = Self::page_grant_locked(inner, app);
        let key = (client, page.to_string());
        if inner.pages.slots.len() >= MAX_PAGES && !inner.pages.slots.contains_key(&key) {
            inner.pages.slots.retain(|_, slot| slot.inflight > 0);
        }
        let slot = inner
            .pages
            .slots
            .entry(key.clone())
            .or_insert_with(|| PageSlot { bridge: PageBridge::new(grant.clone()), inflight: 0 });
        slot.bridge.set_grant(grant.clone());
        let PageCall { id, op, mut params, class } = match slot.bridge.admit(raw, Instant::now()) {
            Ok(call) => call,
            Err(refusal) => return vec![Out::Respond(respond, Ok(refusal.to_answer()))],
        };
        if slot.inflight >= MAX_PAGE_INFLIGHT {
            return refused(respond, &id, "app.limit", "too many calls in flight".into(), true);
        }
        if needs_gesture(&op) || op == "action.run" {
            let message = format!(
                "{op} changes what the person sees and needs their tap in cmux, which a web pane cannot give yet"
            );
            return refused(respond, &id, "gesture.required", message, false);
        }
        if params.is_null() {
            params = json!({});
        }
        // Without a gesture an app never asks an owner to move focus.
        if let Some(fields) = params.as_object_mut() {
            fields.remove("focus");
        }
        // Page keys live in the app's own namespace, as a host's do.
        let idempotency_key =
            (class == OpClass::Mutation).then(|| format!("app:{app}:{}", mint_key()));
        slot.inflight += 1;
        let supervisor_op = op.starts_with("app.storage.") || op == "net.fetch";
        if !supervisor_op && !self.router.owns(&op) {
            inner.pages.next_waiter += 1;
            let waiter = inner.pages.next_waiter;
            let target =
                Target::Page(PageTarget { client, page: page.to_string(), id: id.clone(), waiter });
            return match self.send_to_provider_locked(
                inner,
                app,
                target,
                &op,
                params,
                Origin::Script,
                idempotency_key,
            ) {
                Ok(outs) => {
                    inner.pages.waiters.insert(waiter, respond);
                    outs
                }
                Err(body) => {
                    Self::page_done_locked(inner, &key);
                    vec![Out::Respond(respond, Ok(page_answer(&id, false, body)))]
                }
            };
        }
        let work = Work {
            app: app.to_string(),
            op,
            params,
            idempotency_key,
            origin: Origin::Script,
            grant,
            generation: 0,
        };
        // One owner of the answer: the worker, or this frame when no worker starts.
        let answer_to = Arc::new(Mutex::new(Some(respond)));
        let worker_answer = answer_to.clone();
        let me = self.me.clone();
        let (call_id, slot_key) = (id.clone(), key.clone());
        let spawned =
            std::thread::Builder::new().name("cmux-app-page-call".into()).spawn(move || {
                let Some(me) = me.upgrade() else { return };
                let app = work.app.clone();
                // A storage write runs only while the page's slot and its app's grant stand.
                let result = me.execute_with(work, |inner| {
                    inner.pages.slots.contains_key(&slot_key)
                        && !Self::page_grant_locked(inner, &app).revoked
                });
                let (ok, body) = match result {
                    Ok(body) => (true, body),
                    Err(body) => (false, body),
                };
                let outs = {
                    let mut inner = me.inner.lock().unwrap_or_else(PoisonError::into_inner);
                    Self::page_done_locked(&mut inner, &slot_key);
                    worker_answer
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .take()
                        .map(|respond| Out::Respond(respond, Ok(page_answer(&call_id, ok, body))))
                        .into_iter()
                        .collect()
                };
                me.emit(outs);
            });
        match spawned {
            Ok(_) => vec![],
            Err(e) => {
                Self::page_done_locked(inner, &key);
                let respond = answer_to.lock().unwrap_or_else(PoisonError::into_inner).take();
                respond.map_or_else(Vec::new, |respond| {
                    refused(
                        respond,
                        &id,
                        "operation.failed",
                        format!("no worker thread: {e}"),
                        true,
                    )
                })
            }
        }
    }

    /// A call of the page `key` ended.
    fn page_done_locked(inner: &mut Inner, key: &(u64, String)) {
        if let Some(slot) = inner.pages.slots.get_mut(key) {
            slot.inflight = slot.inflight.saturating_sub(1);
        }
    }

    /// A provider answered (or failed) a page's call (`provider.rs`).
    pub(super) fn page_answer_locked(
        inner: &mut Inner,
        target: &PageTarget,
        ok: bool,
        body: Value,
    ) -> Vec<Out> {
        Self::page_done_locked(inner, &(target.client, target.page.clone()));
        let Some(respond) = inner.pages.waiters.remove(&target.waiter) else { return vec![] };
        vec![Out::Respond(respond, Ok(page_answer(&target.id, ok, body)))]
    }
}
