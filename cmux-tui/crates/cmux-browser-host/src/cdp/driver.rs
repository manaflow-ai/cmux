//! The CDP driver: driver protocol methods on a Chromium browser connection.
//!
//! Tabs are page targets auto-attached with flat sessions
//! (`Target.setAutoAttach {waitForDebuggerOnStart, flatten}`), so every page
//! gets its domains and the agent world before its first script runs.
//! Threads: CDP events are applied on the transport's reader thread under the
//! state lock; CDP calls are made only from caller threads and short-lived
//! setup threads, never while the state lock is held.

use super::connection::{CdpConnection, CdpEvent};
use super::state::{AGENT_WORLD, FollowUp, State, TabState};
use crate::driver::{Driver, EventSink};
use crate::protocol::{DriverError, ErrorCode, timeout_of};
use serde_json::{Value, json};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, Weak};
use std::time::{Duration, Instant};

/// Deadline for the per-tab setup calls and other internal calls.
pub(super) const INTERNAL_TIMEOUT: Duration = Duration::from_secs(10);

pub struct CdpDriver {
    pub(super) inner: Arc<Inner>,
}

pub(super) struct Inner {
    pub(super) conn: Arc<CdpConnection>,
    pub(super) agent_source: Arc<str>,
    events: EventSink,
    state: Mutex<State>,
    changed: Condvar,
}

impl CdpDriver {
    /// Takes over a browser-level CDP connection (headless Chromium over the
    /// pipe). `agent_source` is the page agent bundle installed in every
    /// frame's `cmux-agent` world.
    pub fn attach_browser(
        conn: Arc<CdpConnection>,
        agent_source: impl Into<Arc<str>>,
        events: EventSink,
    ) -> Result<CdpDriver, DriverError> {
        let inner = Arc::new(Inner {
            conn: conn.clone(),
            agent_source: agent_source.into(),
            events,
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
        });
        let weak: Weak<Inner> = Arc::downgrade(&inner);
        conn.set_event_handler(Arc::new(move |event| {
            if let Some(inner) = weak.upgrade() {
                inner.handle_event(event);
            }
        }));
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
        Ok(CdpDriver { inner })
    }
}

impl Driver for CdpDriver {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        let inner = &self.inner;
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
            "frame.evaluate" => inner.evaluate(params),
            "frame.contentFrame" => inner.content_frame(params),
            "frame.contentFrames" => inner.content_frames(params),
            "frame.ownerBox" => inner.owner_box(params),
            "input.mouse" => inner.mouse(params),
            "input.key" => inner.key(params),
            "input.insertText" => inner.insert_text(params),
            "tab.screenshot" => inner.screenshot(params),
            "dialog.respond" => inner.dialog_respond(params),
            "cookies.get" => inner.cookies_get(params),
            "cookies.set" => inner.cookies_set(params),
            "cookies.clear" => inner.cookies_clear(),
            "cdp" => inner.raw_cdp(params),
            _ => Err(DriverError::unsupported_method(method)),
        }
    }

    fn capabilities(&self) -> Vec<&'static str> {
        vec!["cdp"]
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
        let applied = self.lock().apply(&event);
        self.changed.notify_all();
        for event in applied.events {
            (self.events)(event);
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
                let _ = self.conn.call(
                    Some(&session_id),
                    "Runtime.runIfWaitingForDebugger",
                    json!({}),
                    INTERNAL_TIMEOUT,
                );
            }
            FollowUp::SetUpPage { target_id, session_id } => {
                let result = self.set_up_page(&target_id, &session_id);
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
        let call = |method: &str, params: Value| {
            self.conn.call(Some(session_id), method, params, INTERNAL_TIMEOUT)
        };
        call("Page.enable", json!({}))?;
        let tree = call("Page.getFrameTree", json!({}))?;
        let frame = &tree["frameTree"]["frame"];
        {
            let mut state = self.lock();
            if let Some(tab) = state.tabs.get_mut(target_id)
                && tab.main_frame.is_none()
            {
                tab.main_frame = frame.get("id").and_then(Value::as_str).map(str::to_owned);
                tab.loader = frame.get("loaderId").and_then(Value::as_str).map(str::to_owned);
                tab.url = super::state::frame_url(frame);
            }
        }
        call("Page.setLifecycleEventsEnabled", json!({"enabled": true}))?;
        call("Runtime.enable", json!({}))?;
        call(
            "Page.addScriptToEvaluateOnNewDocument",
            json!({"source": &*self.agent_source, "worldName": AGENT_WORLD, "runImmediately": true}),
        )?;
        call("Emulation.setFocusEmulationEnabled", json!({"enabled": true}))?;
        call("Runtime.runIfWaitingForDebugger", json!({}))?;
        Ok(())
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

    fn tabs_open(&self, params: &Value) -> Result<Value, DriverError> {
        let deadline = Instant::now() + timeout_of(params);
        let background = params.get("background").and_then(Value::as_bool).unwrap_or(false);
        let created = self.conn.call(
            None,
            "Target.createTarget",
            json!({"url": "about:blank", "background": true}),
            INTERNAL_TIMEOUT,
        )?;
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
            if !background {
                state.active = Some(target_id.clone());
            }
        }
        if let Some(url) = params.get("url").and_then(Value::as_str).filter(|url| !url.is_empty()) {
            let left = deadline.saturating_duration_since(Instant::now()).as_millis() as u64;
            self.navigate(&json!({"targetId": target_id, "url": url, "waitUntil": "commit", "timeoutMs": left}))?;
        }
        Ok(json!({"targetId": target_id}))
    }

    fn tabs_close(&self, params: &Value) -> Result<Value, DriverError> {
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
        let target_id = self
            .lock()
            .dialogs
            .remove(dialog_id)
            .ok_or_else(|| DriverError::not_found(format!("Dialog {dialog_id} is gone")))?;
        let session = self.session(&json!({"targetId": target_id}))?;
        let accept = params.get("accept").and_then(Value::as_bool).unwrap_or(false);
        let mut args = json!({"accept": accept});
        if let Some(text) = params.get("promptText").and_then(Value::as_str) {
            args["promptText"] = json!(text);
        }
        self.send(&session, "Page.handleJavaScriptDialog", args)?;
        Ok(Value::Null)
    }

    fn cookies_get(&self, params: &Value) -> Result<Value, DriverError> {
        let cookies = self.conn.call(None, "Storage.getCookies", json!({}), INTERNAL_TIMEOUT)?;
        let all = cookies["cookies"].as_array().cloned().unwrap_or_default();
        let Some(urls) =
            params.get("urls").and_then(Value::as_array).filter(|urls| !urls.is_empty())
        else {
            return Ok(Value::Array(all));
        };
        let hosts: Vec<String> = urls
            .iter()
            .filter_map(Value::as_str)
            .filter_map(|url| url.split_once("://").map(|(_, rest)| rest))
            .map(|rest| {
                rest.split(['/', '?', '#'])
                    .next()
                    .unwrap_or("")
                    .split(':')
                    .next()
                    .unwrap_or("")
                    .to_owned()
            })
            .collect();
        let matching = all
            .into_iter()
            .filter(|cookie| {
                let domain = cookie["domain"].as_str().unwrap_or("").trim_start_matches('.');
                hosts.iter().any(|host| host == domain || host.ends_with(&format!(".{domain}")))
            })
            .collect();
        Ok(Value::Array(matching))
    }

    fn cookies_set(&self, params: &Value) -> Result<Value, DriverError> {
        let cookies = params.get("cookies").cloned().unwrap_or_else(|| json!([]));
        self.conn.call(
            None,
            "Storage.setCookies",
            json!({"cookies": cookies}),
            INTERNAL_TIMEOUT,
        )?;
        Ok(Value::Null)
    }

    fn cookies_clear(&self) -> Result<Value, DriverError> {
        self.conn.call(None, "Storage.clearCookies", json!({}), INTERNAL_TIMEOUT)?;
        Ok(Value::Null)
    }

    /// Raw CDP on a tab's session (capability `cdp`). The host grants it per
    /// session; the driver only routes it.
    fn raw_cdp(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let method = crate::protocol::required_str(params, "method")?;
        if method.starts_with("Target.") || method.starts_with("Browser.") {
            return Err(DriverError::new(
                ErrorCode::Forbidden,
                format!("{method}: browser-level CDP is not available to sessions"),
            ));
        }
        let args = params.get("params").cloned().unwrap_or_else(|| json!({}));
        self.send_until(&session, method, args, Instant::now() + timeout_of(params))
    }
}
