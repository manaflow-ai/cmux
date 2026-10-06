//! The CDP driver: driver protocol methods on a Chromium browser connection.
//!
//! Tabs are page targets auto-attached with flat sessions
//! (`Target.setAutoAttach {waitForDebuggerOnStart, flatten}`), so every page
//! gets its domains and the agent world before its first script runs.
//! Threads: CDP events are applied on the transport's reader thread under the
//! state lock; CDP calls are made only from caller threads and short-lived
//! setup threads, never while the state lock is held.

use super::connection::{CdpConnection, CdpEvent};
use super::dispatch::Dispatch;
use super::state::{AGENT_WORLD, FollowUp, State, TabState};
use crate::driver::{Driver, EventSink};
use crate::protocol::{DriverError, ErrorCode, timeout_of};
use serde_json::{Value, json};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, Weak, mpsc};
use std::time::{Duration, Instant};

/// Deadline for internal calls.
pub(super) const INTERNAL_TIMEOUT: Duration = Duration::from_secs(10);
/// Deadline for a new target's setup batch: its replies wait for the
/// renderer process to start, which takes seconds on a cold, loaded machine
/// (hosted macOS runners exceeded 10 s).
pub(super) const SETUP_TIMEOUT: Duration = Duration::from_secs(30);

pub struct CdpDriver {
    pub(super) inner: Arc<Inner>,
}

pub(super) struct Inner {
    pub(super) conn: Arc<CdpConnection>,
    pub(super) agent_source: Arc<str>,
    /// Driver events go to the sink from a dispatcher thread, in order, so a
    /// sink that answers an event with a driver call cannot block the reader.
    pub(super) events: Mutex<mpsc::Sender<Dispatch>>,
    state: Mutex<State>,
    pub(super) changed: Condvar,
    /// The request filter (`set_request_filter`), shared with the worker
    /// that decides paused requests.
    pub(super) request_filter: Arc<Mutex<Option<crate::driver::RequestFilter>>>,
    /// Paused requests to decide: (session, request id, URL).
    pub(super) paused: Mutex<mpsc::Sender<super::requests::PausedRequest>>,
    /// HOST-FETCH-CORS tokens of the host's fetches in flight.
    pub(super) cors: Arc<Mutex<super::cors::Cors>>,
    /// Headless Chromium: every tab gets the protocol's hidden-tab viewport
    /// (new headless takes its window chrome out of --window-size). None
    /// for an app tab, which keeps its real size.
    pub(super) hidden_viewport: Option<(i64, i64)>,
    /// Fetch shells that are open, and whether the session ended.
    pub(super) shells: Mutex<super::fetch::Shells>,
    /// The browser's own user agent (`Browser.getVersion`), what a tab
    /// without a `session.configure` user agent goes back to.
    pub(super) default_ua: std::sync::OnceLock<String>,
    /// Browser contexts this driver created (proxy stores); every other tab
    /// is in the default context, which `Storage.*` names by omission.
    pub(super) proxy_contexts: Mutex<std::collections::HashSet<String>>,
    /// A browser the driver owns (headless, or headful on Xvfb) has no
    /// person's UI: it intercepts every file chooser (`choosers.rs`) and
    /// runs Copy, Cut and Paste on the tab's clipboard (`clipboard.rs`). An
    /// app's CEF tab keeps the app's Open panel and clipboard.
    pub(super) owns_browser: bool,
}

/// The protocol's hidden-tab size (driver-protocol.md: 1280x800).
pub const HIDDEN_VIEWPORT: (i64, i64) = (1280, 800);

impl CdpDriver {
    /// Takes over a browser-level CDP connection (headless Chromium over the
    /// pipe). `agent_source` is the page agent bundle installed in every
    /// frame's `cmux-agent` world.
    pub fn attach_browser(
        conn: Arc<CdpConnection>,
        agent_source: impl Into<Arc<str>>,
        events: EventSink,
    ) -> Result<CdpDriver, DriverError> {
        let inner =
            Inner::start(conn.clone(), agent_source.into(), events, Some(HIDDEN_VIEWPORT), true)?;
        Self::set_up_browser(&inner, &conn)?;
        Ok(CdpDriver { inner })
    }

    /// Takes over a page-rooted connection (one in-app CEF tab's DevTools
    /// relay, [`CdpConnection::page_rooted`]): the page is the driver's only
    /// tab, under the connection's alias; its out-of-process frames attach
    /// as flat child sessions. Returns the driver and the page's CDP target id.
    pub fn attach_page(
        conn: Arc<CdpConnection>,
        agent_source: impl Into<Arc<str>>,
        events: EventSink,
    ) -> Result<(CdpDriver, String), DriverError> {
        let alias = conn
            .root_alias()
            .map(str::to_owned)
            .ok_or_else(|| DriverError::invalid("attach_page needs a page-rooted connection"))?;
        let reply = conn.call(Some(&alias), "Target.getTargetInfo", json!({}), INTERNAL_TIMEOUT)?;
        let info = reply["targetInfo"].clone();
        let target_id = info
            .get("targetId")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| DriverError::invalid("Target.getTargetInfo returned no targetId"))?;
        let inner = Inner::start(conn, agent_source.into(), events, None, false)?;
        // The page is already attached: the relay is its session.
        inner.handle_event(CdpEvent {
            session_id: None,
            method: "Target.attachedToTarget".into(),
            params: json!({"sessionId": alias, "targetInfo": info, "waitingForDebugger": false}),
        });
        Ok((CdpDriver { inner }, target_id))
    }
}

impl Inner {
    fn start(
        conn: Arc<CdpConnection>,
        agent_source: Arc<str>,
        events: EventSink,
        hidden_viewport: Option<(i64, i64)>,
        owns_browser: bool,
    ) -> Result<Arc<Inner>, DriverError> {
        let event_tx = super::dispatch::start(events)?;
        let request_filter = Arc::new(Mutex::new(None));
        let cors: Arc<Mutex<super::cors::Cors>> = Arc::default();
        let paused =
            super::requests::start_worker(conn.clone(), request_filter.clone(), cors.clone())?;
        let inner = Arc::new(Inner {
            conn: conn.clone(),
            agent_source,
            events: Mutex::new(event_tx),
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
            request_filter,
            paused: Mutex::new(paused),
            cors,
            hidden_viewport,
            shells: Mutex::default(),
            default_ua: std::sync::OnceLock::new(),
            proxy_contexts: Mutex::default(),
            owns_browser,
        });
        let weak: Weak<Inner> = Arc::downgrade(&inner);
        conn.set_event_handler(Arc::new(move |event| {
            if let Some(inner) = weak.upgrade() {
                inner.handle_event(event);
            }
        }));
        let weak: Weak<Inner> = Arc::downgrade(&inner);
        conn.set_close_handler(Arc::new(move || {
            if let Some(inner) = weak.upgrade() {
                // Take the lock so no waiter misses the wake-up between its check and its wait.
                drop(inner.lock());
                inner.changed.notify_all();
            }
        }));
        Ok(inner)
    }
}

impl CdpDriver {
    fn set_up_browser(inner: &Arc<Inner>, conn: &Arc<CdpConnection>) -> Result<(), DriverError> {
        conn.call(None, "Target.setDiscoverTargets", json!({"discover": true}), INTERNAL_TIMEOUT)?;
        conn.call(
            None,
            "Target.setAutoAttach",
            json!({"autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true}),
            INTERNAL_TIMEOUT,
        )?;
        // Pages that existed before auto-attach (the launch tab) are attached explicitly.
        let targets = conn.call(None, "Target.getTargets", json!({}), INTERNAL_TIMEOUT)?;
        for info in targets["targetInfos"].as_array().into_iter().flatten() {
            let (Some("page"), Some(target_id)) = (
                info.get("type").and_then(Value::as_str),
                info.get("targetId").and_then(Value::as_str),
            ) else {
                continue;
            };
            if info.get("attached").and_then(Value::as_bool) == Some(true)
                || info
                    .get("url")
                    .and_then(Value::as_str)
                    .is_some_and(crate::policy::is_browser_page)
                || inner.lock().tabs.contains_key(target_id)
            {
                continue;
            }
            conn.call(
                None,
                "Target.attachToTarget",
                json!({"targetId": target_id, "flatten": true}),
                INTERNAL_TIMEOUT,
            )?;
        }
        Ok(())
    }
}

impl CdpDriver {
    /// Sets (or with `None` removes) a tab's `session.configure` user agent
    /// and headers; its next request and document use them, and so do the
    /// popups it opens from now on.
    pub fn set_tab_overrides(
        &self,
        target_id: &str,
        overrides: Option<super::state::TabOverrides>,
    ) -> Result<(), DriverError> {
        self.inner.set_tab_overrides(target_id, overrides)
    }

    /// `tabs.open` with the creating session's options: in browser context
    /// `context` (a proxy store) when set, and with `overrides` set before
    /// the first request.
    pub fn open_tab(
        &self,
        params: &Value,
        context: Option<&str>,
        overrides: Option<super::state::TabOverrides>,
    ) -> Result<Value, DriverError> {
        self.inner.browser_page_refusal("tabs.open", params)?;
        self.inner.tabs_open_in(params, context, overrides)
    }

    /// The browser context (cookie jar) a tab is in.
    pub fn tab_context(&self, target_id: &str) -> Option<String> {
        self.inner.lock().tabs.get(target_id).and_then(|tab| tab.context.clone())
    }

    /// A private store for a session's `session.configure {proxy}`.
    pub fn create_proxy_context(
        &self,
        server: &str,
        bypass: Option<&str>,
    ) -> Result<String, DriverError> {
        let mut params = json!({"proxyServer": server});
        if let Some(bypass) = bypass {
            params["proxyBypassList"] = json!(bypass);
        }
        let created =
            self.inner.conn.call(None, "Target.createBrowserContext", params, INTERNAL_TIMEOUT)?;
        let context =
            created.get("browserContextId").and_then(Value::as_str).map(str::to_owned).ok_or_else(
                || DriverError::invalid("Target.createBrowserContext returned no id"),
            )?;
        self.inner
            .proxy_contexts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(context.clone());
        Ok(context)
    }

    /// Closes a proxy store and every tab in it.
    pub fn dispose_context(&self, context: &str) -> Result<(), DriverError> {
        self.inner.proxy_contexts.lock().unwrap_or_else(PoisonError::into_inner).remove(context);
        self.inner
            .conn
            .call(
                None,
                "Target.disposeBrowserContext",
                json!({"browserContextId": context}),
                INTERNAL_TIMEOUT,
            )
            .map(|_| ())
    }

    /// Releases the keys and mouse buttons left pressed in a tab; the
    /// session engine's source calls it when the last session leaves the
    /// tab. A gone tab has nothing to release.
    pub fn release_held_input(&self, target_id: &str) -> Result<(), DriverError> {
        self.inner.release_held_input(target_id)
    }

    /// False once the connection closed (a relayed tab went away).
    pub fn is_open(&self) -> bool {
        self.inner.conn.closed_reason().is_none()
    }
}

impl Driver for CdpDriver {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        let inner = &self.inner;
        inner.browser_page_refusal(method, params)?;
        inner.shell_refusal(params)?;
        match method {
            "tabs.list" => Ok(inner.tabs_list()),
            "tabs.open" => inner.tabs_open(params),
            "tabs.close" => inner.tabs_close(params),
            "tabs.activate" | "tab.bringToFront" => inner.tabs_activate(params),
            "tab.navigate" => inner.navigate(params),
            "tab.history" => inner.history(params),
            "tab.reload" => inner.reload(params),
            "tab.info" => inner.info(params),
            "tab.setViewport" => inner.set_viewport(params),
            "frames.list" => inner.frames_list(params),
            "frame.evaluate" => {
                // The host's capture mask also hides secrets in closed shadow roots.
                if params.get("closedRoots").and_then(Value::as_bool) == Some(true)
                    && params.get("world").and_then(Value::as_str) == Some("host")
                {
                    inner.sync_closed_roots_for(params, super::state::World::Host)?;
                }
                inner.evaluate(params)
            }
            "frame.observe" => {
                let evaluate = crate::observe::evaluate_params(params)?;
                // Reads that walk the DOM see closed shadow roots; without
                // them the read misses closed-root content but still runs.
                if params
                    .get("method")
                    .and_then(Value::as_str)
                    .is_some_and(|m| super::closed_roots::WALKING_OBSERVE_METHODS.contains(&m))
                {
                    let _ = inner.sync_closed_roots_for(params, super::state::World::Agent);
                }
                inner.evaluate(&evaluate)
            }
            "frame.contentFrame" => inner.content_frame(params),
            "frame.contentFrames" => inner.content_frames(params),
            "frame.ownerBox" => inner.owner_box(params),
            "frame.focused" => inner.focused_frame(params),
            "input.mouse" => inner.with_chooser_events(method, params, || inner.mouse(params)),
            "input.key" => match super::clipboard::shortcut(method, params) {
                Some(kind) if inner.owns_browser => inner.clipboard_key(kind, params),
                _ => inner.with_chooser_events(method, params, || inner.key(params)),
            },
            "clipboard.read" if inner.owns_browser => inner.clipboard_read(params),
            "clipboard.write" if inner.owns_browser => inner.clipboard_write(params),
            "input.setFiles" => inner.set_files(params),
            "filechooser.respond" => inner.chooser_respond(params),
            "input.insertText" => inner.insert_text(params),
            "tab.screenshot" => inner.screenshot(params),
            "tab.pdf" => inner.pdf(params),
            // The host stops a load whose response came from a refused
            // address (DNS rebinding).
            "tab.stop" => {
                let session = inner.session(params)?;
                inner.send(&session, "Page.stopLoading", json!({}))?;
                Ok(Value::Null)
            }
            "net.fetch" => inner.net_fetch(params),
            "net.fetch.cancel" => inner.net_fetch_cancel(params),
            "net.fetch.done" => inner.net_fetch_done(params),
            "dialog.respond" => inner.dialog_respond(params),
            "download.path" => inner.download_path(params),
            "download.cancel" => inner.download_cancel(params),
            "cookies.get" => inner.cookies_get(params),
            "cookies.set" => inner.cookies_set(params),
            "cookies.clear" => inner.cookies_clear(params),
            "cdp" => inner.raw_cdp(params),
            _ => Err(DriverError::unsupported_method(method)),
        }
    }

    fn capabilities(&self) -> Vec<&'static str> {
        vec!["cdp"]
    }

    fn set_request_filter(&self, filter: Option<crate::driver::RequestFilter>) -> bool {
        self.inner.set_request_filter(filter);
        true
    }

    fn end_session(&self) {
        self.inner.end_shells();
    }

    /// A script's value goes on as the JSON text Chromium sent (a9
    /// raw_value); every other result is parsed.
    fn call_reply_announced(
        &self,
        method: &str,
        params: &Value,
        announce: &mut dyn FnMut(),
    ) -> Result<crate::driver::Reply, DriverError> {
        if method != "frame.evaluate" {
            return self.call_announced(method, params, announce).map(crate::driver::Reply::Value);
        }
        announce();
        self.inner.browser_page_refusal(method, params)?;
        self.inner.shell_refusal(params)?;
        self.inner.evaluate_raw(params).map(crate::driver::Reply::Json)
    }
}

/// A ready tab's session.
pub(super) struct Session {
    pub(super) target_id: String,
    pub(super) session_id: String,
}

impl Inner {
    pub(super) fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn handle_event(self: &Arc<Self>, event: CdpEvent) {
        if event.method == "Fetch.requestPaused" {
            self.request_paused(&event);
            return;
        }
        let applied = self.lock().apply(&event);
        self.changed.notify_all();
        if !applied.events.is_empty() {
            let events = self.events.lock().unwrap_or_else(PoisonError::into_inner);
            for event in applied.events {
                let _ = events.send(Dispatch::Event(event));
            }
        }
        for follow_up in applied.follow_ups {
            let inner = self.clone();
            let spawned = std::thread::Builder::new()
                .name("cmux-browser-host-cdp-setup".into())
                .spawn(move || inner.run_follow_up(follow_up));
            if spawned.is_err() {
                self.conn.close("could not start a CDP setup thread");
            }
        }
    }

    fn run_follow_up(&self, follow_up: FollowUp) {
        match follow_up {
            FollowUp::Resume { session_id } => {
                // Workers and prerenders make requests too: interception
                // first while a filter is set, then let them run.
                let steps: Vec<(&str, Value)> = self
                    .fetch_enable_step()
                    .into_iter()
                    .chain([("Runtime.runIfWaitingForDebugger", json!({}))])
                    .collect();
                let _ = self.conn.call_batch(Some(&session_id), steps, INTERNAL_TIMEOUT);
            }
            FollowUp::Release { session_id, waiting, parent } => {
                if waiting {
                    let _ = self.conn.call(
                        Some(&session_id),
                        "Runtime.runIfWaitingForDebugger",
                        json!({}),
                        INTERNAL_TIMEOUT,
                    );
                }
                let _ = self.conn.call(
                    parent.as_deref(),
                    "Target.detachFromTarget",
                    json!({"sessionId": session_id}),
                    INTERNAL_TIMEOUT,
                );
            }
            FollowUp::DismissDialog { dialog_id } => {
                let _ = self.dialog_respond(&json!({"dialogId": dialog_id, "accept": false}));
            }
            FollowUp::ChooserOpened { target_id, chooser_id } => {
                self.send_chooser_opened(&target_id, &chooser_id);
            }
            FollowUp::DisableDom { session_id } => {
                let _ =
                    self.conn.call(Some(&session_id), "DOM.disable", json!({}), INTERNAL_TIMEOUT);
            }
            FollowUp::SetUpFrame { target_id: _, session_id } => {
                // Failures leave the frame unreachable; it must still run.
                if self.set_up_frame(&session_id).is_err() {
                    let _ = self.conn.call(
                        Some(&session_id),
                        "Runtime.runIfWaitingForDebugger",
                        json!({}),
                        INTERNAL_TIMEOUT,
                    );
                }
            }
            FollowUp::SetUpPage { target_id, session_id } => {
                let result = self.set_up_page(&target_id, &session_id);
                if result.is_err() {
                    // Never leave a page paused: a popup would hang its opener.
                    let _ = self.conn.call(
                        Some(&session_id),
                        "Runtime.runIfWaitingForDebugger",
                        json!({}),
                        INTERNAL_TIMEOUT,
                    );
                }
                let mut state = self.lock();
                if let Some(tab) = state.tabs.get_mut(&target_id) {
                    tab.ready = true;
                    tab.setup_error = result.err().map(|error| error.message);
                }
                drop(state);
                self.changed.notify_all();
            }
        }
    }

    fn set_up_page(&self, target_id: &str, session_id: &str) -> Result<(), DriverError> {
        let auto_attach =
            json!({"autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true});
        // A fetch shell runs no page agent and needs no focus or viewport.
        let shell = self.lock().is_hidden(target_id);
        let agent = (!shell).then(|| {
            [
                (
                    "Page.addScriptToEvaluateOnNewDocument",
                    json!({"source": &*self.agent_source, "worldName": AGENT_WORLD, "runImmediately": true}),
                ),
                ("Emulation.setFocusEmulationEnabled", json!({"enabled": true})),
            ]
        });
        let results = self.conn.call_batch(
            Some(session_id),
            vec![
                ("Page.enable", json!({})),
                ("Page.getFrameTree", json!({})),
                ("Page.setLifecycleEventsEnabled", json!({"enabled": true})),
                ("Runtime.enable", json!({})),
            ]
            .into_iter()
            .chain(agent.into_iter().flatten())
            // Request and response events (page.on("request"), ...).
            .chain([("Network.enable", json!({}))])
            // A popup's opener's session.configure options, before its first request.
            .chain(self.inherited_override_steps(target_id))
            .chain(self.hidden_viewport_step().filter(|_| !shell))
            // Out-of-process iframes attach as child sessions of this page.
            .chain([("Target.setAutoAttach", auto_attach)])
            .chain(self.fetch_enable_step())
            .chain([("Runtime.runIfWaitingForDebugger", json!({}))])
            .collect(),
            SETUP_TIMEOUT,
        );
        self.intercept_choosers_on(session_id, self.owns_browser && !shell);
        if let Some(Ok(tree)) = results.get(1) {
            let frame = &tree["frameTree"]["frame"];
            let mut state = self.lock();
            if let Some(tab) = state.tabs.get_mut(target_id)
                && tab.main_frame.is_none()
            {
                tab.main_frame = frame.get("id").and_then(Value::as_str).map(str::to_owned);
                tab.loader = frame.get("loaderId").and_then(Value::as_str).map(str::to_owned);
                tab.url = super::state::frame_url(frame);
            }
        }
        results.into_iter().find_map(Result::err).map_or(Ok(()), Err)
    }

    /// Headless tabs get the protocol's hidden-tab viewport.
    pub(super) fn hidden_viewport_step(&self) -> Option<(&'static str, Value)> {
        self.hidden_viewport.map(|(width, height)| {
            (
                "Emulation.setDeviceMetricsOverride",
                json!({"width": width, "height": height, "deviceScaleFactor": 0, "mobile": false}),
            )
        })
    }

    fn set_up_frame(&self, session_id: &str) -> Result<(), DriverError> {
        let auto_attach =
            json!({"autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true});
        let results = self.conn.call_batch(
            Some(session_id),
            vec![
                ("Page.enable", json!({})),
                ("Page.setLifecycleEventsEnabled", json!({"enabled": true})),
                ("Runtime.enable", json!({})),
                (
                    "Page.addScriptToEvaluateOnNewDocument",
                    json!({"source": &*self.agent_source, "worldName": AGENT_WORLD, "runImmediately": true}),
                ),
                ("Network.enable", json!({})),
                ("Target.setAutoAttach", auto_attach),
            ]
            .into_iter()
            .chain(self.fetch_enable_step())
            .chain([("Runtime.runIfWaitingForDebugger", json!({}))])
            .collect(),
            SETUP_TIMEOUT,
        );
        self.intercept_choosers_on(session_id, self.owns_browser);
        results.into_iter().find_map(Result::err).map_or(Ok(()), Err)
    }

    /// The CDP session that owns a frame of a tab (its own session for an
    /// out-of-process frame, else the tab's).
    pub(super) fn frame_session(&self, session: &Session, frame_id: &str) -> String {
        self.lock()
            .tabs
            .get(&session.target_id)
            .and_then(|tab| tab.frame_sessions.get(frame_id).cloned())
            .unwrap_or_else(|| session.session_id.clone())
    }

    pub(super) fn send_on(
        &self,
        session_id: &str,
        method: &str,
        params: Value,
        deadline: Instant,
    ) -> Result<Value, DriverError> {
        let left = deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(1));
        self.conn.call(Some(session_id), method, params, left)
    }

    /// Waits until `check` returns a value for the tab, the tab goes away, or
    /// the deadline passes.
    pub(super) fn wait_for<T>(
        &self,
        target_id: &str,
        deadline: Instant,
        what: &str,
        mut check: impl FnMut(&TabState) -> Option<Result<T, DriverError>>,
    ) -> Result<T, DriverError> {
        let mut state = self.lock();
        loop {
            let Some(tab) = state.tabs.get(target_id) else {
                return Err(DriverError::closed(format!("Tab {target_id} closed")));
            };
            if let Some(result) = check(tab) {
                return result;
            }
            if tab.crashed {
                return Err(DriverError::closed(format!("Tab {target_id} crashed")));
            }
            if let Some(reason) = self.conn.closed_reason() {
                return Err(DriverError::closed(reason));
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(DriverError::timeout(format!("Timed out waiting for {what}")));
            }
            state = self
                .changed
                .wait_timeout(state, deadline - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    /// The session of a tab, after its setup finished.
    pub(super) fn session(&self, params: &Value) -> Result<Session, DriverError> {
        let target_id = params
            .get("targetId")
            .and_then(Value::as_str)
            .ok_or_else(|| DriverError::invalid("targetId: expected a string"))?;
        if !self.lock().tabs.contains_key(target_id) {
            return Err(DriverError::not_found(format!("No tab {target_id}")));
        }
        let deadline = Instant::now() + timeout_of(params);
        self.wait_for(target_id, deadline, "the tab to be ready", |tab| {
            tab.ready.then(|| match &tab.setup_error {
                Some(error) => Err(DriverError::closed(format!("Tab setup failed: {error}"))),
                None => Ok(Session {
                    target_id: target_id.to_owned(),
                    session_id: tab.session_id.clone(),
                }),
            })
        })
    }

    pub(super) fn send(
        &self,
        session: &Session,
        method: &str,
        params: Value,
    ) -> Result<Value, DriverError> {
        self.conn.call(Some(&session.session_id), method, params, INTERNAL_TIMEOUT)
    }

    pub(super) fn send_until(
        &self,
        session: &Session,
        method: &str,
        params: Value,
        deadline: Instant,
    ) -> Result<Value, DriverError> {
        let left = deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(1));
        self.conn.call(Some(&session.session_id), method, params, left)
    }

    fn tabs_list(&self) -> Value {
        let state = self.lock();
        let tabs: Vec<Value> = state
            .order
            .iter()
            .filter_map(|id| state.tabs.get(id).map(|tab| (id, tab)))
            .filter(|(_, tab)| !tab.hidden)
            .map(|(id, tab)| {
                let mut entry = json!({
                    "targetId": id,
                    "title": tab.title,
                    "url": tab.url,
                    "active": state.active.as_deref() == Some(id.as_str()),
                    "windowId": 1,
                });
                if let Some(opener) = &tab.opener {
                    entry["openerTargetId"] = json!(opener);
                }
                entry
            })
            .collect();
        Value::Array(tabs)
    }

    pub(super) fn tabs_open(&self, params: &Value) -> Result<Value, DriverError> {
        self.tabs_open_in(params, None, None)
    }

    pub(super) fn tabs_open_in(
        &self,
        params: &Value,
        context: Option<&str>,
        overrides: Option<super::state::TabOverrides>,
    ) -> Result<Value, DriverError> {
        let deadline = Instant::now() + timeout_of(params);
        let background = params.get("background").and_then(Value::as_bool).unwrap_or(false);
        let mut create = json!({"url": "about:blank", "background": true});
        if let Some(context) = context {
            create["browserContextId"] = json!(context);
        }
        let created = self.conn.call(None, "Target.createTarget", create, INTERNAL_TIMEOUT)?;
        let target_id = created
            .get("targetId")
            .and_then(Value::as_str)
            .ok_or_else(|| DriverError::invalid("Target.createTarget returned no targetId"))?
            .to_owned();
        // Auto-attach reports the target; wait for its setup.
        {
            let mut state = self.lock();
            loop {
                if state.tabs.get(&target_id).is_some_and(|tab| tab.ready) {
                    break;
                }
                let now = Instant::now();
                if now >= deadline {
                    return Err(DriverError::timeout("Timed out waiting for the new tab"));
                }
                if let Some(reason) = self.conn.closed_reason() {
                    return Err(DriverError::closed(reason));
                }
                state = self
                    .changed
                    .wait_timeout(state, deadline - now)
                    .unwrap_or_else(PoisonError::into_inner)
                    .0;
            }
            if let Some(error) = state.tabs.get(&target_id).and_then(|tab| tab.setup_error.clone())
            {
                return Err(DriverError::closed(format!("Tab setup failed: {error}")));
            }
            if !background {
                state.active = Some(target_id.clone());
            }
        }
        if overrides.is_some() {
            self.set_tab_overrides(&target_id, overrides)?;
        }
        if let Some(url) = params.get("url").and_then(Value::as_str).filter(|url| !url.is_empty()) {
            let left = deadline.saturating_duration_since(Instant::now()).as_millis() as u64;
            self.navigate(&json!({"targetId": target_id, "url": url, "waitUntil": "commit", "timeoutMs": left}))?;
        }
        Ok(json!({"targetId": target_id}))
    }

    pub(super) fn tabs_close(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        if params.get("runBeforeUnload").and_then(Value::as_bool) == Some(true) {
            // Fires beforeunload; a handler that asks opens a dialog instead of closing.
            self.send(&session, "Page.close", json!({}))?;
            return Ok(Value::Null);
        }
        self.conn.call(
            None,
            "Target.closeTarget",
            json!({"targetId": session.target_id}),
            INTERNAL_TIMEOUT,
        )?;
        let mut state = self.lock();
        while state.tabs.contains_key(&session.target_id) {
            if let Some(reason) = self.conn.closed_reason() {
                return Err(DriverError::closed(reason));
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(DriverError::timeout("Timed out waiting for the tab to close"));
            }
            state = self
                .changed
                .wait_timeout(state, deadline - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
        Ok(Value::Null)
    }

    fn tabs_activate(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        self.conn.call(
            None,
            "Target.activateTarget",
            json!({"targetId": session.target_id}),
            INTERNAL_TIMEOUT,
        )?;
        self.lock().active = Some(session.target_id);
        Ok(Value::Null)
    }

    fn dialog_respond(&self, params: &Value) -> Result<Value, DriverError> {
        let dialog_id = crate::protocol::required_str(params, "dialogId")?;
        let (_, session_id) = self
            .lock()
            .dialogs
            .get(dialog_id)
            .cloned()
            .ok_or_else(|| DriverError::not_found(format!("Dialog {dialog_id} is gone")))?;
        let accept = params.get("accept").and_then(Value::as_bool).unwrap_or(false);
        let mut args = json!({"accept": accept});
        if let Some(text) = params.get("promptText").and_then(Value::as_str) {
            args["promptText"] = json!(text);
        }
        let deadline = Instant::now() + timeout_of(params);
        self.send_on(&session_id, "Page.handleJavaScriptDialog", args, deadline)?;
        self.lock().dialogs.remove(dialog_id);
        Ok(Value::Null)
    }

    fn cookies_get(&self, params: &Value) -> Result<Value, DriverError> {
        let cookies = self.conn.call(
            None,
            "Storage.getCookies",
            self.cookie_store(params),
            INTERNAL_TIMEOUT,
        )?;
        let all = cookies["cookies"].as_array().cloned().unwrap_or_default();
        let urls: Vec<url::Url> = params
            .get("urls")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(Value::as_str)
                    .filter_map(|u| url::Url::parse(u).ok())
                    .collect()
            })
            .unwrap_or_default();
        let matching = all
            .iter()
            .filter(|cookie| urls.is_empty() || urls.iter().any(|url| cookie_matches(cookie, url)))
            .map(playwright_cookie)
            .collect();
        Ok(Value::Array(matching))
    }

    fn cookies_set(&self, params: &Value) -> Result<Value, DriverError> {
        let cookies = params.get("cookies").cloned().unwrap_or_else(|| json!([]));
        let mut args = self.cookie_store(params);
        args["cookies"] = cookies;
        self.conn.call(None, "Storage.setCookies", args, INTERNAL_TIMEOUT)?;
        Ok(Value::Null)
    }

    /// Raw CDP on a tab's session (capability `cdp`). The host grants it per
    /// session; the driver only routes allowlisted domains. Domains that could
    /// navigate around the policy, read other origins' cookies, write files,
    /// capture without masking or stop the driver's own instrumentation
    /// (`Page`, `Network`, `Fetch`, `Storage`, `Target`, `Browser`, `IO`,
    /// `Security`, `ServiceWorker`, `SystemInfo`) are refused.
    fn raw_cdp(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let method = crate::protocol::required_str(params, "method")?;
        if !raw_cdp_allowed(method) {
            return Err(DriverError::new(
                ErrorCode::Forbidden,
                format!("{method}: this CDP domain is not available to sessions"),
            ));
        }
        let args = params.get("params").cloned().unwrap_or_else(|| json!({}));
        self.send_until(&session, method, args, Instant::now() + timeout_of(params))
    }
}

/// CDP domains a session with the raw CDP grant may use.
const RAW_CDP_DOMAINS: &[&str] = &[
    "Accessibility",
    "Animation",
    "CSS",
    "DOM",
    "DOMDebugger",
    "DOMSnapshot",
    "Emulation",
    "Input",
    "LayerTree",
    "Log",
    "Overlay",
    "Performance",
    "Profiler",
    "HeapProfiler",
    "Runtime",
    "Debugger",
];

/// Runtime methods that would stop the driver's own context tracking.
const RAW_CDP_DENIED: &[&str] = &["Runtime.disable", "Emulation.setFocusEmulationEnabled"];

pub(super) fn raw_cdp_allowed(method: &str) -> bool {
    let domain = method.split('.').next().unwrap_or("");
    RAW_CDP_DOMAINS.contains(&domain) && !RAW_CDP_DENIED.contains(&method) && method.contains('.')
}

/// RFC 6265 domain and path match, plus `secure` on non-https URLs.
fn cookie_matches(cookie: &Value, url: &url::Url) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    let domain = cookie["domain"].as_str().unwrap_or("");
    let domain_ok = match domain.strip_prefix('.') {
        Some(base) => host == base || host.ends_with(&format!(".{base}")),
        None => host == domain,
    };
    let path = cookie["path"].as_str().unwrap_or("/");
    let url_path = url.path();
    let path_ok = url_path == path
        || (url_path.starts_with(path)
            && (path.ends_with('/') || url_path[path.len()..].starts_with('/')));
    let secure_ok =
        cookie["secure"].as_bool() != Some(true) || url.scheme() == "https" || host == "localhost";
    domain_ok && path_ok && secure_ok
}

/// CDP cookie -> Playwright cookie (`storageState` shape).
fn playwright_cookie(cookie: &Value) -> Value {
    json!({
        "name": cookie["name"],
        "value": cookie["value"],
        "domain": cookie["domain"],
        "path": cookie["path"],
        "expires": if cookie["session"].as_bool() == Some(true) { json!(-1) } else { cookie["expires"].clone() },
        "httpOnly": cookie["httpOnly"].as_bool().unwrap_or(false),
        "secure": cookie["secure"].as_bool().unwrap_or(false),
        "sameSite": cookie["sameSite"].as_str().unwrap_or("Lax"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_cdp_allows_inspection_domains_only() {
        assert!(raw_cdp_allowed("DOM.getDocument"));
        assert!(raw_cdp_allowed("Runtime.evaluate"));
        for refused in [
            "Page.navigate",
            "Network.getAllCookies",
            "Fetch.disable",
            "Storage.getCookies",
            "Target.closeTarget",
            "Browser.close",
            "Runtime.disable",
            "IO.read",
            "Page.setDownloadBehavior",
            "DOM",
        ] {
            assert!(!raw_cdp_allowed(refused), "{refused}");
        }
    }

    #[test]
    fn cookies_match_host_only_domains_paths_and_secure() {
        let url = url::Url::parse("https://app.example.com/account/settings").unwrap();
        let cookie = |domain: &str, path: &str, secure: bool| json!({"domain": domain, "path": path, "secure": secure});
        assert!(cookie_matches(&cookie(".example.com", "/", true), &url));
        assert!(cookie_matches(&cookie("app.example.com", "/account", false), &url));
        assert!(
            !cookie_matches(&cookie("example.com", "/", false), &url),
            "host-only cookies do not match subdomains"
        );
        assert!(!cookie_matches(&cookie("app.example.com", "/acc", false), &url));
        let plain = url::Url::parse("http://app.example.com/").unwrap();
        assert!(!cookie_matches(&cookie("app.example.com", "/", true), &plain));
    }

    #[test]
    fn cookies_convert_to_the_playwright_shape() {
        let cdp = json!({"name": "a", "value": "b", "domain": "x.test", "path": "/", "expires": -1, "size": 2, "httpOnly": true, "secure": false, "session": true, "priority": "Medium"});
        assert_eq!(
            playwright_cookie(&cdp),
            json!({"name": "a", "value": "b", "domain": "x.test", "path": "/", "expires": -1, "httpOnly": true, "secure": false, "sameSite": "Lax"})
        );
    }
}
