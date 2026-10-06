//! The app's provider link as a [`TabSource`]: WebKit tabs through the
//! app's driver (`call` frames), CEF tabs through a [`CdpDriver`] on each
//! tab's page-rooted relay, shared by every session; the host translates
//! the app's tab id to the page's CDP target id and back.

use crate::cdp::CdpDriver;
use crate::driver::{Driver, EventSink};
use crate::lease::{LeaseCaller, LeaseError, LeaseOp};
use crate::protocol::{DriverError, DriverEvent};
use crate::provider::{LeaseState, TabAnnounce};
use crate::provider_link::ProviderDriver;
use crate::tab_source::{TabCall, TabSource};
use serde_json::Value;
use std::sync::{Arc, PoisonError};

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
        Some(Arc::new(move |request: &crate::driver::RequestInfo<'_>| {
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
            let info = crate::driver::RequestInfo { target: &app_id, ..*request };
            filters.iter().find_map(|f| f(&info))
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

impl ProviderDriver {
    /// The CEF tab's driver, attaching its relay on first use (or again
    /// after the relay closed).
    fn cef_tab(
        self: &Arc<Self>,
        target_id: &str,
        agent_source: &Arc<str>,
    ) -> Result<Arc<CefTab>, DriverError> {
        let cached = |provider: &ProviderDriver| {
            provider
                .cef_tabs
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(target_id)
                .filter(|tab| tab.driver.is_open())
                .cloned()
        };
        if let Some(tab) = cached(self) {
            return Ok(tab);
        }
        let _attaching = self.attach_lock.lock().unwrap_or_else(PoisonError::into_inner);
        let known =
            self.cef_tabs.lock().unwrap_or_else(PoisonError::into_inner).get(target_id).cloned();
        if let Some(tab) = known
            && tab.driver.is_open()
        {
            return Ok(tab);
        }
        let conn = self.open_relay(target_id, PAGE_ALIAS)?;
        let weak = Arc::downgrade(self);
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
        let (driver, id) =
            CdpDriver::attach_page(conn, agent_source.clone(), events).inspect_err(|_| {
                self.close_relay(target_id);
            })?;
        let _ = cdp_id.set(id.clone());
        let tab = Arc::new(CefTab { driver, cdp_id: id });
        let mut tabs = self.cef_tabs.lock().unwrap_or_else(PoisonError::into_inner);
        // The tab went away (tab.gone) or its relay closed while attaching:
        // keep nothing, so no driver outlives its tab.
        if self.tab_engine(target_id).is_none() || !tab.driver.is_open() {
            drop(tabs);
            self.close_relay(target_id);
            return Err(DriverError::closed(format!("tab {target_id} went away while attaching")));
        }
        tabs.insert(target_id.to_owned(), tab.clone());
        drop(tabs);
        tab.driver.set_request_filter(self.tab_filter(target_id));
        Ok(tab)
    }

    /// The session drives `target_id`: its filter (if any) applies there.
    fn drive_tab(self: &Arc<Self>, session: u64, target_id: &str) {
        let changed = self
            .request_filters
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(&session)
            .is_some_and(|s| s.tabs.insert(target_id.to_owned()));
        if changed {
            self.sync_tab_filters();
        }
    }

    fn call_cef(
        self: &Arc<Self>,
        method: &str,
        target_id: &str,
        params: &Value,
        agent_source: &Arc<str>,
    ) -> Result<Value, DriverError> {
        let tab = self.cef_tab(target_id, agent_source)?;
        let mut params = params.clone();
        params["targetId"] = Value::String(tab.cdp_id.clone());
        let mut result = tab.driver.call(method, &params)?;
        rename_target(&mut result, &tab.cdp_id, target_id);
        Ok(result)
    }
}

/// Replaces `"targetId": from` (at any depth) with `to`.
pub(crate) fn rename_target(value: &mut Value, from: &str, to: &str) {
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

/// The provider link behind the session engine.
pub struct ProviderSource(pub Arc<ProviderDriver>);

impl TabSource for ProviderSource {
    fn closed_reason(&self) -> Option<String> {
        self.0.closed_reason()
    }

    fn subscribe(&self, sink: EventSink) -> u64 {
        self.0.subscribe(sink)
    }

    fn unsubscribe(&self, id: u64) {
        self.0.unsubscribe(id);
    }

    fn tab_list(&self, engine: &str) -> Vec<TabAnnounce> {
        self.0.tab_list(Some(engine))
    }

    fn tab_engine(&self, target_id: &str) -> Option<String> {
        self.0.tab_engine(target_id)
    }

    fn refusal(&self, method: &str, target_id: &str) -> Option<DriverError> {
        self.0.refusal(method, target_id)
    }

    fn lease(&self, op: &LeaseOp, caller: &LeaseCaller) -> Result<(), LeaseError> {
        self.0.lease(op, caller)
    }

    fn lease_state(&self, target_id: &str) -> Option<LeaseState> {
        self.0.lease_state(target_id)
    }

    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        Driver::call(&*self.0, method, params)
    }

    fn tab_call(&self, call: &TabCall<'_>) -> Result<Value, DriverError> {
        if call.engine == "cef" && !matches!(call.method, "tabs.close" | "tabs.activate") {
            self.0.drive_tab(call.session, call.target_id);
            self.0.call_cef(call.method, call.target_id, call.params, call.agent_source)
        } else if let Some(evaluate) = call.observe {
            // The app's WebKit driver runs it as its agent-world evaluate.
            Driver::call(&*self.0, "frame.evaluate", evaluate)
        } else {
            Driver::call(&*self.0, call.method, call.params)
        }
    }

    /// CEF tabs take the session's filter on their relays (for the tabs the
    /// session drives); WebKit provider tabs cannot filter yet, so the gate
    /// fails closed there.
    fn set_request_filter(
        &self,
        session: u64,
        engine: &str,
        filter: Option<crate::driver::RequestFilter>,
    ) -> bool {
        if engine != "cef" {
            return false;
        }
        {
            let mut filters = self.0.request_filters.lock().unwrap_or_else(PoisonError::into_inner);
            match filter {
                Some(filter) => {
                    let tabs = filters.remove(&session).map(|s| s.tabs).unwrap_or_default();
                    filters.insert(session, SessionFilter { filter, tabs });
                }
                None => {
                    filters.remove(&session);
                }
            }
        }
        self.0.sync_tab_filters();
        true
    }

    fn session_ended(&self, session: u64) {
        let removed = self
            .0
            .request_filters
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&session)
            .is_some();
        if removed {
            self.0.sync_tab_filters();
        }
    }

    fn capabilities(&self, engine: &str) -> Vec<&'static str> {
        if engine == "cef" { vec!["cdp"] } else { self.0.capabilities() }
    }
}
