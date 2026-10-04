//! Navigation, history, reload, tab info and viewport.

use super::driver::{INTERNAL_TIMEOUT, Inner};
use super::state::TabState;
use crate::protocol::{DriverError, WaitUntil, required_f64, required_str, timeout_of};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

/// Whether the tab's current document reached `wait_until`.
fn reached(tab: &TabState, wait_until: WaitUntil) -> bool {
    match wait_until {
        WaitUntil::Commit => true,
        WaitUntil::DomContentLoaded => {
            tab.lifecycle.contains("DOMContentLoaded") || tab.lifecycle.contains("load")
        }
        WaitUntil::Load => tab.lifecycle.contains("load"),
        WaitUntil::NetworkIdle => tab.lifecycle.contains("networkIdle"),
    }
}

impl Inner {
    pub(super) fn navigate(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let url = required_str(params, "url")?;
        let wait_until = WaitUntil::parse(params.get("waitUntil").and_then(Value::as_str))?;
        let deadline = Instant::now() + timeout_of(params);
        let (before, downloads) = self.begin_navigation(&session.target_id);
        let result = self.send_until(&session, "Page.navigate", json!({"url": url}), deadline)?;
        if let Some(error) =
            result.get("errorText").and_then(Value::as_str).filter(|e| !e.is_empty())
        {
            return Err(DriverError::invalid(format!("{error} at {url}")));
        }
        if result.get("loaderId").and_then(Value::as_str).is_none() {
            // Same-document navigation: committed when Page.navigate returns.
            let url = self.lock().tabs.get(&session.target_id).map(|tab| tab.url.clone());
            return Ok(json!({"url": url.unwrap_or_else(|| url_string(params))}));
        }
        // Any document committed after this call counts, so a client redirect
        // continues the navigation instead of stranding the wait.
        let what = format!("navigation to {url}");
        let landed = self.wait_for(&session.target_id, deadline, &what, |tab| {
            if tab.download_seq > downloads {
                return Some(Err(DriverError::invalid(format!("Download is starting: {url}"))));
            }
            (tab.nav_seq > before && !tab.last_nav_same_document && reached(tab, wait_until))
                .then(|| Ok(json!({"url": tab.url})))
        })?;
        if self.shows_browser_page(&session.target_id) {
            return Err(self.leave_browser_page(&session, deadline));
        }
        Ok(self.with_status(&session, landed))
    }

    /// Adds the main document's HTTP status (`status`, as Playwright's
    /// Response) when the document came from HTTP. Read from the
    /// document's navigation timing entry in the agent world, which agent
    /// code can change: the status is a report, not a guard.
    fn with_status(&self, session: &super::driver::Session, mut answer: Value) -> Value {
        let context = {
            let state = self.lock();
            state.tabs.get(&session.target_id).and_then(|tab| {
                // Only an HTTP document has a status (Chromium reports 200 for
                // data: URLs; Playwright answers no response there).
                let http = tab.committed_url.starts_with("http://")
                    || tab.committed_url.starts_with("https://");
                if !http {
                    return None;
                }
                let frame = tab.main_frame.clone()?;
                tab.contexts.get(&(frame, super::state::World::Agent)).cloned()
            })
        };
        let Some((context_session, context)) = context else {
            return answer;
        };
        let reply = self.conn.call(
            Some(&context_session),
            "Runtime.evaluate",
            json!({
                "expression": "(() => { const e = performance.getEntriesByType('navigation')[0]; return e && e.responseStatus ? e.responseStatus : 0; })()",
                "contextId": context,
                "returnByValue": true,
            }),
            Duration::from_secs(2),
        );
        if let Ok(reply) = reply
            && let Some(status) = reply["result"]["value"].as_u64().filter(|s| *s > 0)
        {
            answer["status"] = json!(status);
        }
        answer
    }

    /// Clears a crash (navigation starts a new renderer) and returns the
    /// navigation and download counters to wait past.
    fn begin_navigation(&self, target_id: &str) -> (u64, u64) {
        let mut state = self.lock();
        match state.tabs.get_mut(target_id) {
            Some(tab) => {
                tab.crashed = false;
                (tab.nav_seq, tab.download_seq)
            }
            None => (0, 0),
        }
    }

    /// Waits for the main-frame navigation that follows `after_seq`, then its load state.
    fn wait_for_next_load(
        &self,
        target_id: &str,
        after_seq: u64,
        wait_until: WaitUntil,
        deadline: Instant,
    ) -> Result<Value, DriverError> {
        self.wait_for(target_id, deadline, "navigation", |tab| {
            (tab.nav_seq > after_seq && (tab.last_nav_same_document || reached(tab, wait_until)))
                .then(|| Ok(json!({"url": tab.url})))
        })
    }

    pub(super) fn reload(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let wait_until = WaitUntil::parse(params.get("waitUntil").and_then(Value::as_str))?;
        let deadline = Instant::now() + timeout_of(params);
        let (before, _) = self.begin_navigation(&session.target_id);
        self.send_until(&session, "Page.reload", json!({}), deadline)?;
        self.wait_for_next_load(&session.target_id, before, wait_until, deadline)?;
        Ok(self.with_status(&session, json!({})))
    }

    pub(super) fn history(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let delta = required_f64(params, "delta")? as i64;
        if delta != -1 && delta != 1 {
            return Err(DriverError::invalid("delta: expected -1 or 1"));
        }
        let wait_until = WaitUntil::parse(params.get("waitUntil").and_then(Value::as_str))?;
        let deadline = Instant::now() + timeout_of(params);
        let history = self.send(&session, "Page.getNavigationHistory", json!({}))?;
        let entries = history["entries"].as_array().cloned().unwrap_or_default();
        let current = history["currentIndex"].as_i64().unwrap_or(0);
        let index = current + delta;
        if index < 0 || index as usize >= entries.len() {
            return Ok(Value::Null);
        }
        let entry = &entries[index as usize];
        // The blank page a tab opened on is not an entry (driver-protocol.md).
        if index == 0 && delta < 0 && entry["url"].as_str() == Some("about:blank") {
            return Ok(Value::Null);
        }
        if let Some(url) = entry["url"].as_str().filter(|url| crate::policy::is_browser_page(url)) {
            return Err(DriverError::new(
                crate::protocol::ErrorCode::Forbidden,
                format!("tab.history: {url} is a browser page, not available to agents"),
            ));
        }
        let entry_id =
            entry["id"].as_i64().ok_or_else(|| DriverError::invalid("history entry has no id"))?;
        let (before, _) = self.begin_navigation(&session.target_id);
        self.send_until(
            &session,
            "Page.navigateToHistoryEntry",
            json!({"entryId": entry_id}),
            deadline,
        )?;
        self.wait_for_next_load(&session.target_id, before, wait_until, deadline)
    }

    pub(super) fn info(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let dialog_open =
            self.lock().tabs.get(&session.target_id).is_some_and(|tab| tab.open_dialogs > 0);
        if !dialog_open
            && let Ok(metrics) = self.conn.call(
                Some(&session.session_id),
                "Page.getLayoutMetrics",
                json!({}),
                Duration::from_secs(2).min(INTERNAL_TIMEOUT),
            )
        {
            let css = &metrics["cssLayoutViewport"];
            let device = &metrics["layoutViewport"];
            if let (Some(width), Some(height)) =
                (css["clientWidth"].as_f64(), css["clientHeight"].as_f64())
            {
                let scale =
                    device["clientWidth"].as_f64().filter(|_| width > 0.0).map(|d| d / width);
                if let Some(tab) = self.lock().tabs.get_mut(&session.target_id) {
                    tab.viewport = (width, height);
                    if let Some(scale) = scale.filter(|s| s.is_finite() && *s > 0.0) {
                        tab.device_scale_factor = scale;
                    }
                }
            }
        }
        // The driver's own title read does not run in a browser page.
        if !dialog_open && !self.shows_browser_page(&session.target_id) {
            self.refresh_title(&session);
        }
        let state = self.lock();
        let tab = state
            .tabs
            .get(&session.target_id)
            .ok_or_else(|| DriverError::closed(format!("Tab {} closed", session.target_id)))?;
        Ok(json!({
            "url": tab.url,
            "title": tab.title,
            "loadState": tab.load_state(),
            "viewport": {"width": tab.viewport.0, "height": tab.viewport.1},
            "deviceScaleFactor": tab.device_scale_factor,
        }))
    }

    pub(super) fn set_viewport(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        if params.get("reset").and_then(Value::as_bool) == Some(true) {
            self.send(&session, "Emulation.clearDeviceMetricsOverride", json!({}))?;
            return Ok(Value::Null);
        }
        let width = required_f64(params, "width")?;
        let height = required_f64(params, "height")?;
        if width < 1.0 || height < 1.0 {
            return Err(DriverError::invalid("width and height must be at least 1"));
        }
        self.send(
            &session,
            "Emulation.setDeviceMetricsOverride",
            json!({"width": width as i64, "height": height as i64, "deviceScaleFactor": 0, "mobile": false}),
        )?;
        Ok(Value::Null)
    }
}

impl Inner {
    /// Reads `document.title` in the main frame's agent world: the target's
    /// title from `Target.targetInfoChanged` can lag the document.
    fn refresh_title(&self, session: &super::driver::Session) {
        let context = {
            let state = self.lock();
            let Some(tab) = state.tabs.get(&session.target_id) else {
                return;
            };
            tab.main_frame.as_ref().and_then(|frame| {
                tab.contexts.get(&(frame.clone(), super::state::World::Agent)).cloned()
            })
        };
        let Some((context_session, context)) = context else {
            return;
        };
        let reply = self.conn.call(
            Some(&context_session),
            "Runtime.evaluate",
            json!({"expression": "document.title", "contextId": context, "returnByValue": true}),
            Duration::from_secs(2),
        );
        if let Ok(reply) = reply
            && let Some(title) = reply["result"]["value"].as_str()
            && let Some(tab) = self.lock().tabs.get_mut(&session.target_id)
        {
            tab.title = title.to_owned();
        }
    }
}

fn url_string(params: &Value) -> String {
    params.get("url").and_then(Value::as_str).unwrap_or("").to_owned()
}
