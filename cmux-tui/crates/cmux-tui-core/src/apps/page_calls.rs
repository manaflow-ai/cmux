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
//! off or in safe mode has a revoked grant (nothing admitted). Taking access
//! back (uninstall, disable, a grant change, safe mode) also ends the calls
//! already admitted: each runs its op only while its app still holds the
//! grant it was admitted under, and the waiting ones end with `app.revoked`.
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
use std::sync::PoisonError;
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

/// Who waits for a page call that went to a provider (`provider.rs`): its
/// waiter in [`Pages`].
pub(super) struct PageTarget {
    pub waiter: u64,
}

/// Who waits for one admitted page call, until its worker or provider
/// answers or its app's access is taken back (`cancel_page_calls_locked`).
struct PageWaiter {
    app: String,
    key: (u64, String),
    id: String,
    respond: Responder,
}

/// The supervisor's page state (`Inner::pages`).
#[derive(Default)]
pub(super) struct Pages {
    slots: HashMap<(u64, String), PageSlot>,
    waiters: HashMap<u64, PageWaiter>,
    next_waiter: u64,
}

impl Pages {
    /// A connection closed: its pages' budgets go with it.
    pub(super) fn client_gone(&mut self, client: u64) {
        self.slots.retain(|(owner, _), _| *owner != client);
    }

    /// The slot of page `key`, made with `grant` when it is new. At
    /// [`MAX_PAGES`] a new page first drops the idle slots; when every slot
    /// still has a call in flight it gets none (`None`), so the count stays
    /// bounded.
    fn slot(&mut self, key: &(u64, String), grant: &Grant) -> Option<&mut PageSlot> {
        if !self.slots.contains_key(key) && self.slots.len() >= MAX_PAGES {
            self.slots.retain(|_, slot| slot.inflight > 0);
            if self.slots.len() >= MAX_PAGES {
                return None;
            }
        }
        Some(
            self.slots.entry(key.clone()).or_insert_with(|| PageSlot {
                bridge: PageBridge::new(grant.clone()),
                inflight: 0,
            }),
        )
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
        if (installed && !record.is_some_and(|r| r.enabled))
            || super::safe_mode_bisect::held_off(inner, app)
        {
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

    pub(super) fn page_call_locked(
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
        let Some(slot) = inner.pages.slot(&key, &grant) else {
            let mut error = ApiError::new(
                "app.limit",
                format!("{MAX_PAGES} pages are open and every one has a call in flight"),
            );
            error.retryable = true;
            return vec![Out::Respond(respond, Err(error))];
        };
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
        inner.pages.next_waiter += 1;
        let waiter = inner.pages.next_waiter;
        inner
            .pages
            .waiters
            .insert(waiter, PageWaiter { app: app.to_string(), key: key.clone(), id, respond });
        let supervisor_op = op.starts_with("app.storage.") || op == "net.fetch";
        if !supervisor_op && !self.router.owns(&op) {
            if op == "integration.request" {
                // The provider sees the method the grant check decided on.
                super::provider::normalize_method(&mut params);
            }
            let target = Target::Page(PageTarget { waiter });
            return self
                .send_to_provider_locked(
                    inner,
                    app,
                    target,
                    &op,
                    params,
                    Origin::Script,
                    idempotency_key,
                )
                .unwrap_or_else(|body| Self::page_end_locked(inner, waiter, false, body));
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
        let me = self.me.clone();
        let spawned =
            std::thread::Builder::new().name("cmux-app-page-call".into()).spawn(move || {
                let Some(me) = me.upgrade() else { return };
                let (app, admitted) = (work.app.clone(), work.grant.clone());
                // Right before the op: the call was not cancelled, its page is
                // open, and its app still holds the grant it was admitted
                // under (an uninstall makes it a preview, a disable or safe
                // mode revokes it, a regrant replaces it).
                let result = me.execute_with(work, |inner| {
                    inner.pages.waiters.contains_key(&waiter)
                        && inner.pages.slots.contains_key(&key)
                        && Self::page_grant_locked(inner, &app) == admitted
                });
                let (ok, body) = match result {
                    Ok(body) => (true, body),
                    Err(body) => (false, body),
                };
                let outs = {
                    let mut inner = me.inner.lock().unwrap_or_else(PoisonError::into_inner);
                    Self::page_end_locked(&mut inner, waiter, ok, body)
                };
                me.emit(outs);
            });
        match spawned {
            Ok(_) => vec![],
            Err(e) => Self::page_end_locked(
                inner,
                waiter,
                false,
                json!({ "code": "operation.failed", "message": format!("no worker thread: {e}"), "retryable": true }),
            ),
        }
    }

    /// Page call `waiter` ended: its slot frees and its page gets the answer,
    /// unless it was already cancelled (then both happened at the cancel).
    fn page_end_locked(inner: &mut Inner, waiter: u64, ok: bool, body: Value) -> Vec<Out> {
        let Some(PageWaiter { key, id, respond, .. }) = inner.pages.waiters.remove(&waiter) else {
            return vec![];
        };
        if let Some(slot) = inner.pages.slots.get_mut(&key) {
            slot.inflight = slot.inflight.saturating_sub(1);
        }
        vec![Out::Respond(respond, Ok(page_answer(&id, ok, body)))]
    }

    /// A provider answered (or failed) a page's call (`provider.rs`).
    pub(super) fn page_answer_locked(
        inner: &mut Inner,
        target: &PageTarget,
        ok: bool,
        body: Value,
    ) -> Vec<Out> {
        Self::page_end_locked(inner, target.waiter, ok, body)
    }

    /// `app`'s access was taken back (uninstall, disable, a grant change;
    /// every app when `app` is `None`: safe mode): its pages' admitted
    /// calls end now with `app.revoked` and free their slots, a worker that
    /// has not run its op yet never runs it, and the provider is told to
    /// drop the ones it holds, as a host's calls are
    /// (`cancel_provider_calls_locked`).
    pub(super) fn cancel_page_calls_locked(
        &self,
        inner: &mut Inner,
        app: Option<&str>,
        reason: &str,
    ) -> Vec<Out> {
        let doomed: Vec<u64> = inner
            .pages
            .waiters
            .iter()
            .filter(|(_, w)| app.is_none_or(|app| w.app == app))
            .map(|(waiter, _)| *waiter)
            .collect();
        if doomed.is_empty() {
            return vec![];
        }
        let queued: Vec<_> = inner
            .provider_calls
            .extract_if(|_, c| matches!(&c.target, Target::Page(t) if doomed.contains(&t.waiter)))
            .collect();
        let mut outs = Vec::new();
        for (id, call) in queued {
            self.timers.cancel(call.timer);
            outs.push(Out::Client(
                call.client,
                json!({ "event": "apps-provider-cancel", "request_id": id, "reason": "revoked" }),
            ));
        }
        let body = json!({
            "code": "app.revoked",
            "message": format!("the app's access was taken back ({reason})"),
            "details": { "reason": reason },
            "retryable": false,
        });
        for waiter in doomed {
            outs.extend(Self::page_end_locked(inner, waiter, false, body.clone()));
        }
        outs
    }
}

#[cfg(test)]
#[path = "page_calls_tests.rs"]
mod tests;
