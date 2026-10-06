//! One headless Chromium per (host, profile) as a [`TabSource`] (item 4b,
//! ff decisions D1-D3, 2026-10-06).
//!
//! Every headless session of a profile is a view of one browser: the session
//! engine ([`crate::provider_engine::ProviderEngine`]) keeps the ownership
//! rules (created tabs close at the session's end unless kept, leases), so a
//! tab a one-shot run kept is there for the next session. The browser lives
//! while a session is attached or a kept tab is open (D3); the host closes
//! it, with its kept tabs, when it exits. One cookie jar per (host, profile)
//! matches D12's per-workspace agent profile; isolation between sessions of
//! one profile needs a proxy context (`session.configure {proxy}`).

use crate::cdp::CdpDriver;
use crate::cdp::pipe::HeadlessChromium;
use crate::driver::{Driver, EventSink, Reply, RequestFilter, RequestInfo};
use crate::lease::{LeaseCaller, LeaseError, LeaseOp, LeaseTable};
use crate::protocol::{DriverError, DriverEvent};
use crate::provider::LeaseState;
use crate::tab_source::{PolicyLogSink, TabCall, TabRow, TabSource};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};

type Subscribers = Arc<Mutex<Vec<(u64, EventSink)>>>;

/// A session's request filter and the tabs it drives.
struct SessionFilter {
    filter: RequestFilter,
    tabs: HashSet<String>,
}

pub struct HeadlessSource {
    pub(crate) driver: CdpDriver,
    pub(crate) profile: String,
    subscribers: Subscribers,
    next_subscriber: AtomicU64,
    leases: Mutex<LeaseTable>,
    filters: Mutex<HashMap<u64, SessionFilter>>,
    /// Which session gets each event (item 4c).
    routes: Mutex<crate::headless_routes::Routes>,
    /// Each subscriber's policy log (D2 log).
    policy_logs: Mutex<HashMap<u64, PolicyLogSink>>,
    /// Tab -> the sessions that called it (bounded: per tab until
    /// `tab.closed`, per session until its end). When the last one leaves,
    /// the input it left pressed is released.
    driven: Mutex<HashMap<String, HashSet<u64>>>,
    /// Each session's `session.configure` options (item 4d).
    pub(crate) configs: Mutex<crate::headless_configure::Configs>,
    // Last: the browser stops after the driver let go of it.
    _browser: HeadlessChromium,
}

/// A fetch's id on the shared driver: the session's own id with the
/// session in front, so two sessions' fetches never meet.
fn fetch_id(session: u64, id: &str) -> String {
    format!("s{session}/{id}")
}

impl HeadlessSource {
    /// Launches the browser of `profile` and takes it over.
    pub fn launch(
        options: &crate::cdp::pipe::HeadlessOptions,
        agent_source: Arc<str>,
        profile: &str,
    ) -> Result<Arc<HeadlessSource>, DriverError> {
        let browser = HeadlessChromium::launch(options)
            .map_err(|e| DriverError::closed(format!("engine_unavailable: headless: {e}")))?;
        let subscribers: Subscribers = Arc::default();
        let me: Arc<std::sync::OnceLock<Weak<HeadlessSource>>> = Arc::default();
        let sink_me = me.clone();
        let driver = CdpDriver::attach_browser(
            browser.connection().clone(),
            agent_source,
            Arc::new(move |event: DriverEvent| {
                if let Some(source) = sink_me.get().and_then(Weak::upgrade) {
                    source.publish(event);
                }
            }),
        )?;
        driver.save_downloads_in(browser.downloads_dir())?;
        // Headless: no person can see an Open panel, every tab intercepts.
        driver.intercept_all_choosers(options.headless);
        // Chromium opens a start tab; it is no session's tab, so sessions
        // start with none (headless Chromium keeps running without tabs).
        if let Ok(Value::Array(tabs)) = driver.call("tabs.list", &json!({})) {
            for tab in tabs {
                if let Some(target) = tab["targetId"].as_str() {
                    let _ = driver.call("tabs.close", &json!({"targetId": target}));
                }
            }
        }
        let source = Arc::new(HeadlessSource {
            driver,
            profile: profile.to_owned(),
            subscribers,
            next_subscriber: AtomicU64::new(1),
            leases: Mutex::default(),
            filters: Mutex::default(),
            routes: Mutex::default(),
            policy_logs: Mutex::default(),
            driven: Mutex::default(),
            configs: Mutex::default(),
            _browser: browser,
        });
        let _ = me.set(Arc::downgrade(&source));
        Ok(source)
    }

    /// True while a session is attached or a tab (a kept one) is open: the
    /// browser must stay (D3).
    pub fn in_use(&self) -> bool {
        !self.subscribers.lock().unwrap_or_else(PoisonError::into_inner).is_empty()
            || matches!(self.driver.call("tabs.list", &json!({})), Ok(Value::Array(tabs)) if !tabs.is_empty())
    }

    pub fn is_open(&self) -> bool {
        self.driver.is_open()
    }

    /// Installs the combined filter: a request of a tab is refused when a
    /// session that drives the tab refuses it; a fetch shell's requests
    /// follow the session that fetches; a tab no session drives yet (a
    /// popup before its first call) follows every session's filter.
    fn sync_filter(self: &Arc<Self>) {
        let any = !self.filters.lock().unwrap_or_else(PoisonError::into_inner).is_empty();
        if !any {
            self.driver.set_request_filter(None);
            return;
        }
        let weak: Weak<HeadlessSource> = Arc::downgrade(self);
        self.driver.set_request_filter(Some(Arc::new(move |request: &RequestInfo<'_>| {
            let Some(source) = weak.upgrade() else {
                return Some("the headless browser closed".to_owned());
            };
            let owner = source
                .driver
                .shell_fetch_id(request.target)
                .and_then(|id| id.strip_prefix('s')?.split_once('/')?.0.parse::<u64>().ok());
            let filters: Vec<RequestFilter> = {
                let filters = source.filters.lock().unwrap_or_else(PoisonError::into_inner);
                let driving: Vec<RequestFilter> = filters
                    .iter()
                    .filter(|(session, s)| {
                        owner.map_or(s.tabs.contains(request.target), |owner| **session == owner)
                    })
                    .map(|(_, s)| s.filter.clone())
                    .collect();
                if driving.is_empty() && owner.is_none() {
                    filters.values().map(|s| s.filter.clone()).collect()
                } else {
                    driving
                }
            };
            filters.iter().find_map(|f| f(request))
        })));
    }

    fn drive(self: &Arc<Self>, session: u64, target: &str) {
        self.driven
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(target.to_owned())
            .or_default()
            .insert(session);
        // Headful: a tab a session drives intercepts its file choosers. On
        // every call: the first (tabs.open) can come before the driver
        // knows the tab; the driver does nothing once it is on.
        self.driver.set_tab_choosers(target, true);
        let changed = self
            .filters
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(&session)
            .is_some_and(|s| s.tabs.insert(target.to_owned()));
        if changed {
            self.sync_filter();
        }
    }
}

impl HeadlessSource {
    /// A tab's URL ("" when the tab is gone).
    fn tab_url(&self, target: &str) -> String {
        let Ok(Value::Array(tabs)) = self.driver.call("tabs.list", &json!({})) else {
            return String::new();
        };
        tabs.iter()
            .find(|tab| tab["targetId"] == target)
            .and_then(|tab| tab["url"].as_str())
            .unwrap_or("")
            .to_owned()
    }

    /// The open tabs `session` created and did not keep.
    pub(crate) fn routes_tabs_of(&self, session: u64) -> Vec<String> {
        self.routes().tabs_of(session)
    }

    fn routes(&self) -> std::sync::MutexGuard<'_, crate::headless_routes::Routes> {
        self.routes.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Delivers a driver event (on the driver's event thread, which may call
    /// the driver): to one session, to every session, or, when no session
    /// takes a dialog or download, the host answers it and logs it (D2).
    fn publish(&self, event: DriverEvent) {
        use crate::headless_routes::{Route, unrouted_entry};
        let sinks: Vec<(u64, EventSink)> =
            self.subscribers.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let attached = |session: u64| sinks.iter().any(|(s, _)| *s == session);
        if event.name == "tab.closed"
            && let Some(target) = event.payload.get("targetId").and_then(Value::as_str)
        {
            self.driven.lock().unwrap_or_else(PoisonError::into_inner).remove(target);
            // A closed tab takes its automation lease with it (as the app's
            // tab.gone does): the table stays bounded.
            let gone = LeaseOp::TargetGone { target: target.to_owned() };
            let _ = self.leases.lock().unwrap_or_else(PoisonError::into_inner).apply(
                &gone,
                &LeaseCaller::default(),
                0,
            );
        }
        let route = self.routes().route(&event, &attached);
        match route {
            Route::Everyone => sinks.iter().for_each(|(_, sink)| sink(event.clone())),
            Route::Session(session) => {
                sinks
                    .iter()
                    .filter(|(s, _)| *s == session)
                    .for_each(|(_, sink)| sink(event.clone()));
            }
            Route::Unrouted(kind) => {
                let target = event.payload.get("targetId").cloned().unwrap_or(Value::Null);
                let action = match kind {
                    // beforeunload too: the page stays.
                    "dialog" => {
                        let dialog = event.payload.get("dialogId").cloned().unwrap_or(Value::Null);
                        let _ = self.driver.call(
                            "dialog.respond",
                            &json!({"targetId": target, "dialogId": dialog, "accept": false}),
                        );
                        "dismissed"
                    }
                    "download" if event.name == "download.started" => {
                        let id = event.payload.get("downloadId").cloned().unwrap_or(Value::Null);
                        let _ = self.driver.call("download.cancel", &json!({"downloadId": id}));
                        "cancelled"
                    }
                    "download" => "dropped",
                    // filechooser: the page sees the browser's cancel.
                    _ => {
                        let chooser =
                            event.payload.get("chooserId").cloned().unwrap_or(Value::Null);
                        let _ = self.driver.call(
                            "filechooser.respond",
                            &json!({"targetId": target, "chooserId": chooser, "cancel": true}),
                        );
                        "cancelled"
                    }
                };
                let url = self.tab_url(target.as_str().unwrap_or(""));
                let entry = unrouted_entry(&event, action, &url);
                let log_session = {
                    let mut routes = self.routes();
                    routes.log_unrouted(entry.clone());
                    routes.log_session(target.as_str().unwrap_or(""))
                };
                // The tab's opener, while it is attached, sees it in its
                // own policy log.
                let sink = log_session.filter(|s| attached(*s)).and_then(|session| {
                    self.policy_logs
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .get(&session)
                        .cloned()
                });
                if let Some(sink) = sink {
                    sink(entry);
                }
            }
        }
    }
}

/// The source as the session engine sees it (an `Arc`, for the filter's
/// weak reference).
pub struct SharedHeadless(pub Arc<HeadlessSource>);

impl TabSource for SharedHeadless {
    fn closed_reason(&self) -> Option<String> {
        (!self.0.driver.is_open()).then(|| "the headless browser closed".to_owned())
    }

    fn subscribe(&self, sink: EventSink) -> u64 {
        let id = self.0.next_subscriber.fetch_add(1, Ordering::Relaxed);
        self.0.subscribers.lock().unwrap_or_else(PoisonError::into_inner).push((id, sink));
        id
    }

    fn unsubscribe(&self, id: u64) {
        self.0.subscribers.lock().unwrap_or_else(PoisonError::into_inner).retain(|(s, _)| *s != id);
        self.0.policy_logs.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
    }

    fn policy_log(&self, id: u64, sink: PolicyLogSink) {
        self.0.policy_logs.lock().unwrap_or_else(PoisonError::into_inner).insert(id, sink);
    }

    /// The browser's tabs; every tab of the profile shares its data store.
    fn tab_rows(&self, _engine: &str) -> Vec<TabRow> {
        let Ok(Value::Array(tabs)) = self.0.driver.call("tabs.list", &json!({})) else {
            return Vec::new();
        };
        tabs.iter()
            .filter_map(|tab| {
                Some(TabRow {
                    target_id: tab["targetId"].as_str()?.to_owned(),
                    title: tab["title"].as_str().unwrap_or("").to_owned(),
                    url: tab["url"].as_str().unwrap_or("").to_owned(),
                    active: tab["active"].as_bool().unwrap_or(false),
                    window_id: tab.get("windowId").cloned().unwrap_or(json!(1)),
                    state: "live".to_owned(),
                    data_store: tab["targetId"]
                        .as_str()
                        .and_then(|target| self.0.data_store_of(target))
                        .unwrap_or_else(|| self.0.profile.clone()),
                    opener: tab["openerTargetId"].as_str().map(str::to_owned),
                })
            })
            .collect()
    }

    fn tab_engine(&self, target_id: &str) -> Option<String> {
        let Ok(Value::Array(tabs)) = self.0.driver.call("tabs.list", &json!({})) else {
            return None;
        };
        tabs.iter().any(|tab| tab["targetId"] == target_id).then(|| "headless".to_owned())
    }

    /// The driver refuses browser pages itself.
    fn refusal(&self, _method: &str, _target_id: &str) -> Option<DriverError> {
        None
    }

    fn lease(&self, op: &LeaseOp, caller: &LeaseCaller) -> Result<(), LeaseError> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        self.0
            .leases
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .apply(op, caller, now)
            .map(|_| ())
    }

    fn lease_state(&self, target_id: &str) -> Option<LeaseState> {
        self.0
            .leases
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(target_id)
            .map(|record| record.lease.state)
    }

    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        self.0.driver.call(method, params)
    }

    fn opened(&self, session: u64, target_id: &str) {
        self.0.routes().created(session, target_id);
        self.0.drive(session, target_id);
    }

    fn kept(&self, session: u64, target_id: &str) {
        let created = self.0.routes().is_creator(session, target_id);
        self.0.configure_kept(session, target_id, created);
        self.0.routes().kept(session, target_id);
    }

    fn open_tab(&self, session: u64, params: &Value) -> Result<Value, DriverError> {
        self.0.open_configured(session, params)
    }

    fn session_call(
        &self,
        session: u64,
        method: &str,
        params: &Value,
    ) -> Option<Result<Value, DriverError>> {
        // Tab-less calls reach the browser as they did with a browser per
        // session (fetch shells, the profile's cookies, downloads).
        let mut params = params.clone();
        if let Some(id) = params.get("fetchId").and_then(Value::as_str) {
            params["fetchId"] = json!(fetch_id(session, id));
        }
        if method == "session.configure" {
            return Some(self.0.configure(session, &params));
        }
        // Only the host names a store: tab-less cookies.* use the
        // session's proxy store, else the profile's.
        if let Some(fields) = params.as_object_mut() {
            fields.remove("browserContextId");
        }
        if method.starts_with("cookies.")
            && let Some(context) = self.0.proxy_of(session)
        {
            params["browserContextId"] = json!(context);
        }
        Some(self.0.driver.call(method, &params))
    }

    fn tab_call(&self, call: &TabCall<'_>) -> Result<Reply, DriverError> {
        self.0.drive(call.session, call.target_id);
        match call.method {
            // The events this session has a handler for in the tab (routing).
            "tab.handleEvents" => {
                let events = call.params["events"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect();
                self.0.routes().handle_events(call.session, call.target_id, events);
                return Ok(Reply::Value(Value::Null));
            }
            // Only the session a dialog went to answers it.
            "dialog.respond" => {
                let dialog = call.params["dialogId"].as_str().unwrap_or("");
                let owner = self.0.routes().dialog_owner(dialog);
                if owner.is_some_and(|owner| owner != call.session) {
                    return Err(DriverError::not_found(format!("No dialog {dialog}")));
                }
                self.0.routes().dialog_answered(dialog);
            }
            // Copy, Cut and Paste run only in tabs a session created
            // (driver-protocol.md), refused before a key reaches the page.
            "input.key"
                if crate::cdp::clipboard::shortcut(call.method, call.params).is_some()
                    && !self.0.routes().is_creator(call.session, call.target_id) =>
            {
                return Err(DriverError::new(
                    crate::protocol::ErrorCode::Unsupported,
                    "Copy, Cut and Paste run only in tabs a session created; refused in a user's tab",
                ));
            }
            // Only the session a file chooser went to answers it.
            "filechooser.respond" => {
                let chooser = call.params["chooserId"].as_str().unwrap_or("");
                let owner = self.0.routes().chooser_owner(chooser);
                if owner.is_some_and(|owner| owner != call.session) {
                    return Err(DriverError::not_found(format!("No file chooser {chooser}")));
                }
                self.0.routes().chooser_answered(chooser);
            }
            _ => {}
        }
        // A dialog or chooser the page opens during this call is the caller's.
        let reads = call.observe.is_some() || call.method == "tab.info";
        if !reads {
            self.0.routes().call_started(call.session, call.target_id);
        }
        let mut result = self.dispatch(call);
        if !reads {
            self.0.routes().call_ended(call.session, call.target_id);
        }
        // Host diagnostics for the person only: the events of this tab no
        // session took (the host's bounded log, D2).
        if call.method == "tab.info"
            && call.origin == "user"
            && let Ok(Reply::Value(Value::Object(info))) = &mut result
        {
            info.insert(
                "unroutedEvents".into(),
                Value::Array(self.0.routes().unrouted_for(call.target_id)),
            );
        }
        result
    }

    fn set_request_filter(
        &self,
        session: u64,
        _engine: &str,
        filter: Option<RequestFilter>,
    ) -> bool {
        {
            let mut filters = self.0.filters.lock().unwrap_or_else(PoisonError::into_inner);
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
        self.0.sync_filter();
        true
    }

    fn session_ended(&self, session: u64) {
        self.0.configure_ended(session);
        // Its open dialogs are dismissed (beforeunload: the page stays) and
        // its file choosers cancelled (driver-protocol.md: when the session
        // leaves the tab).
        let left = self.0.routes().session_ended(session);
        for (target, dialog) in left.dialogs {
            let _ = self.0.driver.call(
                "dialog.respond",
                &json!({"targetId": target, "dialogId": dialog, "accept": false}),
            );
        }
        for (target, chooser) in left.choosers {
            let _ = self.0.driver.call(
                "filechooser.respond",
                &json!({"targetId": target, "chooserId": chooser, "cancel": true}),
            );
        }
        // The last session left these tabs: release what was left pressed.
        let left: Vec<String> = {
            let mut driven = self.0.driven.lock().unwrap_or_else(PoisonError::into_inner);
            let mut left = Vec::new();
            driven.retain(|target, sessions| {
                if sessions.remove(&session) && sessions.is_empty() {
                    left.push(target.clone());
                }
                !sessions.is_empty()
            });
            left
        };
        for target in left {
            let _ = self.0.driver.release_held_input(&target);
            // Headful: the person's Open panel again.
            self.0.driver.set_tab_choosers(&target, false);
        }
        let removed = self
            .0
            .filters
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&session)
            .is_some();
        if removed {
            self.0.sync_filter();
        }
    }

    fn capabilities(&self, _engine: &str) -> Vec<&'static str> {
        self.0.driver.capabilities()
    }
}

impl SharedHeadless {
    fn dispatch(&self, call: &TabCall<'_>) -> Result<Reply, DriverError> {
        let mut params = call.params.clone();
        // A tab call's store is its tab's; only the host names one.
        if let Some(fields) = params.as_object_mut() {
            fields.remove("browserContextId");
        }
        if let Some(id) = params.get("fetchId").and_then(Value::as_str) {
            params["fetchId"] = json!(fetch_id(call.session, id));
        }
        if call.raw {
            // Script values keep the page's key order (a9 raw_value).
            return self.0.driver.call_reply_announced(call.method, &params, &mut || {});
        }
        self.0.driver.call(call.method, &params).map(Reply::Value)
    }
}

/// The shared browsers of a host, by profile (D3: a browser stays while a
/// session is attached or a kept tab is open).
pub type HeadlessBrowsers = Arc<Mutex<HashMap<String, Arc<HeadlessSource>>>>;

/// The shared browser of `profile`, launched on first use.
pub fn browser_for(
    browsers: &HeadlessBrowsers,
    profile: &str,
    launch: impl FnOnce() -> Result<Arc<HeadlessSource>, DriverError>,
) -> Result<Arc<HeadlessSource>, DriverError> {
    let mut map = browsers.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(source) = map.get(profile).filter(|source| source.is_open()) {
        return Ok(source.clone());
    }
    let source = launch()?;
    map.insert(profile.to_owned(), source.clone());
    Ok(source)
}

/// One headless session: the session engine over the shared browser. When
/// the session ends and the browser has no other session and no open tab,
/// the browser closes (D3).
pub struct HeadlessSession {
    engine: Option<crate::provider_engine::ProviderEngine>,
    source: Arc<HeadlessSource>,
    browsers: Weak<Mutex<HashMap<String, Arc<HeadlessSource>>>>,
}

impl HeadlessSession {
    pub fn new(
        source: Arc<HeadlessSource>,
        browsers: &HeadlessBrowsers,
        agent_source: Arc<str>,
        events: EventSink,
        lease: LeaseCaller,
    ) -> Result<HeadlessSession, DriverError> {
        let engine = crate::provider_engine::ProviderEngine::with_source(
            Arc::new(SharedHeadless(source.clone())),
            "headless",
            agent_source,
            events,
            lease,
        )?;
        Ok(HeadlessSession { engine: Some(engine), source, browsers: Arc::downgrade(browsers) })
    }

    fn engine(&self) -> Result<&crate::provider_engine::ProviderEngine, DriverError> {
        self.engine.as_ref().ok_or_else(|| DriverError::closed("the session was closed"))
    }

    /// Drops the browser from the host when nothing uses it.
    fn release_if_idle(&self) {
        let Some(browsers) = self.browsers.upgrade() else { return };
        let mut map = browsers.lock().unwrap_or_else(PoisonError::into_inner);
        if !self.source.in_use() {
            map.retain(|_, source| !Arc::ptr_eq(source, &self.source));
        }
    }
}

impl Driver for HeadlessSession {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        self.engine()?.call(method, params)
    }

    fn call_announced(
        &self,
        method: &str,
        params: &Value,
        announce: &mut dyn FnMut(),
    ) -> Result<Value, DriverError> {
        self.engine()?.call_announced(method, params, announce)
    }

    fn call_reply_announced(
        &self,
        method: &str,
        params: &Value,
        announce: &mut dyn FnMut(),
    ) -> Result<Reply, DriverError> {
        self.engine()?.call_reply_announced(method, params, announce)
    }

    fn capabilities(&self) -> Vec<&'static str> {
        self.engine.as_ref().map(|e| e.capabilities()).unwrap_or_default()
    }

    fn set_request_filter(&self, filter: Option<RequestFilter>) -> bool {
        self.engine.as_ref().is_some_and(|e| e.set_request_filter(filter))
    }

    fn send_session_event(&self, event: DriverEvent) -> bool {
        self.engine.as_ref().is_some_and(|e| e.send_session_event(event))
    }

    fn end_session(&self) {
        if let Some(engine) = &self.engine {
            engine.end_session();
        }
    }
}

impl Drop for HeadlessSession {
    fn drop(&mut self) {
        // The engine unsubscribes when it drops; then the browser may go.
        drop(self.engine.take());
        self.release_if_idle();
    }
}
