//! The engine of a session bound to the app's provider (`cef` or `webkit`).
//!
//! The app announces its tabs (`hello`, `tab.announced`); a session lists
//! them with `tabs.list` and names one by `targetId` (the app's store tab
//! id) in every call. WebKit calls go to the app's driver as `call` frames
//! ([`ProviderDriver`]). A CEF tab gets its own [`CdpDriver`] on a
//! page-rooted relay (`cdp.attach`, `cdp` frames), shared by every session;
//! the host translates the app's tab id to the page's CDP target id and back.
//! Tab lifecycle calls (`tabs.open`, `tabs.close`, `tabs.activate`) go to the
//! app, which owns tabs. Every call that names a tab passes the provider's
//! refusal rules first (browser pages, the interim extension rule).

use crate::cdp::CdpDriver;
use crate::driver::{Driver, EventSink};
use crate::lease::{LeaseCaller, LeaseError, LeaseOp};
use crate::protocol::{DriverError, DriverEvent};
use crate::provider_link::ProviderDriver;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::sync::{Arc, Mutex, PoisonError};

/// The relay alias of a CEF tab's page session.
const PAGE_ALIAS: &str = "cmux-page";

/// One CEF tab's CDP driver on its relay.
pub struct CefTab {
    driver: CdpDriver,
    /// The page's CDP target id (the driver's tab id).
    cdp_id: String,
}

/// A session's request filter (its domain policy) and the CEF tabs it
/// drives, where the filter applies.
pub struct SessionFilter {
    filter: crate::driver::RequestFilter,
    tabs: std::collections::HashSet<String>,
}

impl ProviderDriver {
    /// The filter for one CEF tab's relay: every session that drives the tab
    /// decides each of its requests, named by the app's tab id; any refusal
    /// blocks. `None` when no session with a filter drives the tab.
    fn tab_filter(self: &Arc<Self>, app_id: &str) -> Option<crate::driver::RequestFilter> {
        let any = self
            .request_filters
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .any(|s| s.tabs.contains(app_id));
        if !any {
            return None;
        }
        let weak = Arc::downgrade(self);
        let app_id = app_id.to_owned();
        // The relay's own ids (the page's CDP target, its frames) never
        // reach the filters: every request on this relay is the app tab's.
        Some(Arc::new(move |_cdp_target: &str, url: &str| {
            let Some(provider) = weak.upgrade() else {
                return Some("the cmux app disconnected".to_owned());
            };
            let filters: Vec<crate::driver::RequestFilter> = provider
                .request_filters
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .values()
                .filter(|s| s.tabs.contains(&app_id))
                .map(|s| s.filter.clone())
                .collect();
            filters.iter().find_map(|f| f(&app_id, url))
        }))
    }

    /// Re-installs the filters of every attached CEF tab after a session's
    /// filter or tab set changed.
    fn sync_tab_filters(self: &Arc<Self>) {
        let tabs: Vec<(String, Arc<CefTab>)> = self
            .cef_tabs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .map(|(id, tab)| (id.clone(), tab.clone()))
            .collect();
        for (app_id, tab) in tabs {
            tab.driver.set_request_filter(self.tab_filter(&app_id));
        }
    }
}

/// A session's view of the provider: `engine` is `cef` or `webkit`.
pub struct ProviderEngine {
    provider: Arc<ProviderDriver>,
    engine: String,
    agent_source: Arc<str>,
    subscription: u64,
    /// The session's own event sink (the one the provider subscription
    /// holds, tee'd to the app for automation.input).
    events: EventSink,
    /// The session's lease identity (stamped from its connection).
    lease: LeaseCaller,
    /// Tabs the session created (`tabs.open` and their popups) and did not
    /// keep (`tab.keep`): they close when the session ends.
    created: Arc<Mutex<BTreeSet<String>>>,
    /// Set once the session's end released its leases (close, or the
    /// backstop drop), so a late drop of a closed engine never clears the
    /// leases of a new session with the same name.
    ended: std::sync::atomic::AtomicBool,
}

/// Driver methods that only read a tab: they never take or block a lease
/// (automation lease contract, `observe`). Every other call on a tab is an
/// `act`.
const OBSERVE_METHODS: &[&str] = &[
    "frame.observe",
    "tab.info",
    "tab.screenshot",
    "frames.list",
    "frame.contentFrame",
    "frame.contentFrames",
    "frame.ownerBox",
];

fn lease_refusal(method: &str, error: LeaseError) -> DriverError {
    let reason = match error {
        LeaseError::LeaseHeld => "another agent session holds this tab",
        LeaseError::PausedByUser => "the person used this tab; wait for them to hand it back",
        LeaseError::UserDriving => "the person is driving this tab; wait for them to hand it back",
        LeaseError::StaleAfterHandBack => "the person handed the tab back; observe it again first",
        LeaseError::StoppedByUser => "the person stopped this agent",
        LeaseError::SessionRequired => "the person's tabs need a named session",
        _ => "the tab's automation lease refused the call",
    };
    let mut refusal =
        DriverError::new(crate::protocol::ErrorCode::Forbidden, format!("{method}: {reason}"));
    refusal.error_name = Some(error.code().to_owned());
    refusal
}

impl ProviderEngine {
    pub fn new(
        provider: Arc<ProviderDriver>,
        engine: &str,
        agent_source: Arc<str>,
        events: EventSink,
        lease: LeaseCaller,
    ) -> Result<ProviderEngine, DriverError> {
        if let Some(reason) = provider.closed_reason() {
            return Err(DriverError::closed(reason));
        }
        // A popup of a tab the session created is the session's too.
        let created: Arc<Mutex<BTreeSet<String>>> = Arc::default();
        let popups = created.clone();
        let session_events = events.clone();
        let subscription = provider.subscribe(Arc::new(move |event: DriverEvent| {
            if event.name == "tab.created"
                && let (Some(target), Some(opener)) = (
                    event.payload.get("targetId").and_then(Value::as_str),
                    event.payload.get("openerTargetId").and_then(Value::as_str),
                )
            {
                let mut created = popups.lock().unwrap_or_else(PoisonError::into_inner);
                if created.contains(opener) {
                    created.insert(target.to_owned());
                }
            }
            session_events(event);
        }));
        Ok(ProviderEngine {
            created,
            provider,
            engine: engine.to_owned(),
            agent_source,
            subscription,
            events,
            lease,
            ended: std::sync::atomic::AtomicBool::new(false),
        })
    }

    fn tabs_list(&self) -> Value {
        let tabs: Vec<Value> = self
            .provider
            .tab_list(Some(&self.engine))
            .into_iter()
            .map(|tab| {
                json!({
                    "targetId": tab.target_id, "engine": tab.engine, "url": tab.url,
                    "title": tab.title, "workspace": tab.workspace, "profile": tab.profile,
                    "visible": tab.visible,
                })
            })
            .collect();
        json!({ "tabs": tabs })
    }

    /// The CEF tab's driver, attaching its relay on first use (or again
    /// after the relay closed).
    fn cef_tab(&self, target_id: &str) -> Result<Arc<CefTab>, DriverError> {
        let cached = |provider: &ProviderDriver| {
            provider
                .cef_tabs
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(target_id)
                .filter(|tab| tab.driver.is_open())
                .cloned()
        };
        if let Some(tab) = cached(&self.provider) {
            return Ok(tab);
        }
        let _attaching = self.provider.attach_lock.lock().unwrap_or_else(PoisonError::into_inner);
        let known = self
            .provider
            .cef_tabs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(target_id)
            .cloned();
        if let Some(tab) = known
            && tab.driver.is_open()
        {
            return Ok(tab);
        }
        let conn = self.provider.open_relay(target_id, PAGE_ALIAS)?;
        let weak = Arc::downgrade(&self.provider);
        let app_id = target_id.to_owned();
        let cdp_id = Arc::new(std::sync::OnceLock::<String>::new());
        let sink_cdp_id = cdp_id.clone();
        let events: EventSink = Arc::new(move |event: DriverEvent| {
            // The provider announces and retires tabs itself.
            if matches!(event.name.as_str(), "tab.created" | "tab.closed") {
                return;
            }
            let (Some(provider), Some(cdp)) = (weak.upgrade(), sink_cdp_id.get()) else { return };
            let mut payload = event.payload;
            rename_target(&mut payload, cdp, &app_id);
            provider.publish(DriverEvent { name: event.name, payload });
        });
        let (driver, id) = CdpDriver::attach_page(conn, self.agent_source.clone(), events)
            .inspect_err(|_| {
                self.provider.close_relay(target_id);
            })?;
        let _ = cdp_id.set(id.clone());
        let tab = Arc::new(CefTab { driver, cdp_id: id });
        let mut tabs = self.provider.cef_tabs.lock().unwrap_or_else(PoisonError::into_inner);
        // The tab went away (tab.gone) or its relay closed while attaching:
        // keep nothing, so no driver outlives its tab.
        if self.provider.tab_engine(target_id).is_none() || !tab.driver.is_open() {
            drop(tabs);
            self.provider.close_relay(target_id);
            return Err(DriverError::closed(format!("tab {target_id} went away while attaching")));
        }
        tabs.insert(target_id.to_owned(), tab.clone());
        drop(tabs);
        tab.driver.set_request_filter(self.provider.tab_filter(target_id));
        Ok(tab)
    }

    /// The session drives `target_id`: its filter (if any) applies there.
    fn drive_tab(&self, target_id: &str) {
        let changed = self
            .provider
            .request_filters
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(&self.subscription)
            .is_some_and(|s| s.tabs.insert(target_id.to_owned()));
        if changed {
            self.provider.sync_tab_filters();
        }
    }

    fn call_cef(
        &self,
        method: &str,
        target_id: &str,
        params: &Value,
    ) -> Result<Value, DriverError> {
        let tab = self.cef_tab(target_id)?;
        let mut params = params.clone();
        params["targetId"] = Value::String(tab.cdp_id.clone());
        let mut result = tab.driver.call(method, &params)?;
        rename_target(&mut result, &tab.cdp_id, target_id);
        Ok(result)
    }
}

/// Replaces `"targetId": from` (at any depth) with `to`.
fn rename_target(value: &mut Value, from: &str, to: &str) {
    match value {
        Value::Object(map) => {
            for (key, item) in map.iter_mut() {
                // `target_id`: automation.input events (schemas/automation-input).
                if (key.ends_with("argetId") || key == "target_id") && item.as_str() == Some(from) {
                    *item = Value::String(to.to_owned());
                } else {
                    rename_target(item, from, to);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(|item| rename_target(item, from, to)),
        _ => {}
    }
}

impl ProviderEngine {
    /// `Driver::call` with `announce` run after every check, right before
    /// the dispatch (never for a refused call).
    fn call_with(
        &self,
        method: &str,
        params: &Value,
        announce: &mut dyn FnMut(),
    ) -> Result<Value, DriverError> {
        // A closed session's engine can outlive the close (a timed-out cell
        // still runs); it must not take a lease nobody will end.
        if self.ended.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(DriverError::closed("the session was closed"));
        }
        if let Some(reason) = self.provider.closed_reason() {
            return Err(DriverError::closed(reason));
        }
        match method {
            "tabs.list" => return Ok(self.tabs_list()),
            // The app owns tabs: it opens them in the session's engine. Only
            // the URL and background pass; profile, workspace and focus are
            // never the agent's to pick (D12).
            "tabs.open" => {
                let mut open = serde_json::Map::new();
                for key in ["url", "background", "timeoutMs"] {
                    if let Some(value) = params.get(key) {
                        open.insert(key.into(), value.clone());
                    }
                }
                open.insert("engine".into(), Value::String(self.engine.clone()));
                announce();
                let opened = self.provider.call(method, &Value::Object(open))?;
                if let Some(target) = opened.get("targetId").and_then(Value::as_str) {
                    self.created_tabs().insert(target.to_owned());
                }
                return Ok(opened);
            }
            _ => {}
        }
        // Every other call names a tab: nothing tab-less (cookies of the
        // person's profile, for example) reaches the app.
        let target_id = match params.get("targetId") {
            Some(Value::String(id)) => id.as_str(),
            Some(_) => {
                return Err(DriverError::invalid(format!("{method}: targetId must be a string")));
            }
            None => {
                return Err(DriverError::new(
                    crate::protocol::ErrorCode::Unsupported,
                    format!("{method}: not available on the person's tabs without a targetId"),
                ));
            }
        };
        let Some(engine) = self.provider.tab_engine(target_id) else {
            return Err(DriverError::not_found(format!("{method}: no tab {target_id}")));
        };
        if engine != self.engine {
            return Err(DriverError::not_found(format!(
                "{method}: tab {target_id} is a {engine} tab; this session runs on {}",
                self.engine
            )));
        }
        if let Some(error) = self.provider.refusal(method, target_id) {
            return Err(error);
        }
        // Kept: the tab stays open when the session ends (the host owns the
        // session's tabs; the app has no part in it).
        if method == "tab.keep" {
            self.created_tabs().remove(target_id);
            return Ok(Value::Null);
        }
        // A structured read: refused before the lease sees it unless it
        // calls an allowlisted page agent function.
        let observe = match method {
            "frame.observe" => Some(crate::observe::evaluate_params(params)?),
            _ => None,
        };
        // The automation lease: any call that is not a read acts (and takes
        // the lease when the tab has none) before it runs.
        let reads = OBSERVE_METHODS.contains(&method);
        if !reads {
            let act = LeaseOp::Act { target: target_id.to_owned() };
            self.provider.lease(&act, &self.lease).map_err(|error| lease_refusal(method, error))?;
            // A close that ran between the check at the top and this lease
            // call must not leave a lease that nothing ends.
            if self.ended.load(std::sync::atomic::Ordering::SeqCst) {
                let release = LeaseOp::Release { target: target_id.to_owned() };
                let _ = self.provider.lease(&release, &self.lease);
                return Err(DriverError::closed("the session was closed"));
            }
        }
        // Every check passed (an ended session was refused above, also after
        // the lease): the caller's announcement goes out, then the dispatch.
        if self.ended.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(DriverError::closed("the session was closed"));
        }
        announce();
        let result = if engine == "cef" && !matches!(method, "tabs.close" | "tabs.activate") {
            self.drive_tab(target_id);
            self.call_cef(method, target_id, params)
        } else if let Some(evaluate) = observe {
            // The app's WebKit driver runs it as its agent-world evaluate.
            self.provider.call("frame.evaluate", &evaluate)
        } else {
            self.provider.call(method, params)
        };
        // A read is never blocked; only a read that succeeded is the fresh
        // observe after a hand back.
        if reads && result.is_ok() {
            let observe = LeaseOp::Observe { target: target_id.to_owned() };
            let _ = self.provider.lease(&observe, &self.lease);
        }
        result
    }
}

impl Driver for ProviderEngine {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        self.call_with(method, params, &mut || {})
    }

    fn call_announced(
        &self,
        method: &str,
        params: &Value,
        announce: &mut dyn FnMut(),
    ) -> Result<Value, DriverError> {
        self.call_with(method, params, announce)
    }

    fn end_session(&self) {
        self.release_session();
    }

    /// The gate's events for this session go through the session's sink
    /// only (never `publish`, which reaches every subscribed session).
    /// An ended session's events are dropped here (true: the gate must not
    /// deliver them elsewhere either).
    fn send_session_event(&self, event: DriverEvent) -> bool {
        if !self.ended.load(std::sync::atomic::Ordering::SeqCst) {
            (self.events)(event);
        }
        true
    }

    /// CEF tabs take the session's filter on their relays (for the tabs the
    /// session drives); WebKit provider tabs cannot filter yet, so the gate
    /// fails closed there.
    fn set_request_filter(&self, filter: Option<crate::driver::RequestFilter>) -> bool {
        if self.engine != "cef" {
            return false;
        }
        {
            let mut filters =
                self.provider.request_filters.lock().unwrap_or_else(PoisonError::into_inner);
            match filter {
                Some(filter) => {
                    let tabs =
                        filters.remove(&self.subscription).map(|s| s.tabs).unwrap_or_default();
                    filters.insert(self.subscription, SessionFilter { filter, tabs });
                }
                None => {
                    filters.remove(&self.subscription);
                }
            }
        }
        self.provider.sync_tab_filters();
        true
    }

    fn capabilities(&self) -> Vec<&'static str> {
        if self.engine == "cef" { vec!["cdp"] } else { self.provider.capabilities() }
    }
}

impl ProviderEngine {
    /// The session ends: its leases go (the app clears the badges). Runs
    /// once, from `end_session` (close) or, as a backstop, from drop.
    fn created_tabs(&self) -> std::sync::MutexGuard<'_, BTreeSet<String>> {
        self.created.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The session's end (close, reset, idle, the backstop drop), one path:
    /// the tabs it created and did not keep close (classic main), except a
    /// tab whose lease the person has taken (driving or paused), which stays
    /// as theirs; then every lease of the session is released.
    fn release_session(&self) {
        if !self.ended.swap(true, std::sync::atomic::Ordering::SeqCst) {
            let created = std::mem::take(&mut *self.created_tabs());
            for target in created {
                let users = matches!(
                    self.provider.lease_state(&target),
                    Some(
                        crate::provider::LeaseState::UserDriving
                            | crate::provider::LeaseState::Paused
                    )
                );
                if !users && self.provider.tab_engine(&target).is_some() {
                    let _ = self.provider.call(
                        "tabs.close",
                        &json!({"targetId": target, "timeoutMs": SESSION_END_CLOSE_MS}),
                    );
                }
            }
            let _ = self.provider.lease(&LeaseOp::SessionEnd, &self.lease);
            let removed = self
                .provider
                .request_filters
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&self.subscription)
                .is_some();
            if removed {
                self.provider.sync_tab_filters();
            }
        }
    }
}

/// How long the session's end waits for the app to close one tab.
const SESSION_END_CLOSE_MS: u64 = 5000;

impl Drop for ProviderEngine {
    fn drop(&mut self) {
        self.provider.unsubscribe(self.subscription);
        self.release_session();
    }
}

#[cfg(test)]
#[path = "provider_engine_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "provider_engine_lease_tests.rs"]
mod lease_tests;

#[cfg(test)]
#[path = "provider_engine_input_tests.rs"]
mod input_tests;

#[cfg(test)]
#[path = "provider_engine_reaper_tests.rs"]
mod reaper_tests;
