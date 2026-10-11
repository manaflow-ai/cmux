//! `session.configure` user agent and extra headers on CDP tabs: set per
//! tab (`Emulation.setUserAgentOverride`, `Network.setExtraHTTPHeaders`),
//! kept in the tab's state so a popup starts with its opener's before its
//! first request (`set_up_page`).

use super::driver::{INTERNAL_TIMEOUT, Inner};
use super::state::TabOverrides;
use crate::protocol::DriverError;
use serde_json::{Value, json};
use std::sync::Arc;

impl Inner {
    /// The browser's own user agent, read once.
    pub(super) fn default_ua(&self) -> String {
        if let Some(ua) = self.default_ua.get() {
            return ua.clone();
        }
        let ua = self
            .conn
            .call(None, "Browser.getVersion", json!({}), INTERNAL_TIMEOUT)
            .ok()
            .and_then(|version| version.get("userAgent").and_then(Value::as_str).map(str::to_owned))
            .unwrap_or_default();
        self.default_ua.get_or_init(|| ua).clone()
    }

    pub(super) fn set_tab_overrides(
        &self,
        target_id: &str,
        overrides: Option<TabOverrides>,
    ) -> Result<(), DriverError> {
        let session = self.session(&json!({"targetId": target_id}))?;
        let overrides = overrides.map(Arc::new);
        if let Some(tab) = self.lock().tabs.get_mut(target_id) {
            tab.overrides = overrides.clone();
        }
        let steps = TabOverrides::steps(overrides.as_deref(), &self.default_ua());
        self.conn
            .call_batch(Some(&session.session_id), steps, INTERNAL_TIMEOUT)
            .into_iter()
            .find_map(Result::err)
            .map_or(Ok(()), Err)
    }

    /// Setup steps for a new tab that inherited its opener's options; none
    /// for a tab without (the browser's own apply).
    pub(super) fn inherited_override_steps(&self, target_id: &str) -> Vec<(&'static str, Value)> {
        let overrides = self.lock().tabs.get(target_id).and_then(|tab| tab.overrides.clone());
        match overrides {
            Some(overrides) => TabOverrides::steps(Some(overrides.as_ref()), &self.default_ua()),
            None => Vec::new(),
        }
    }
}

/// The CPU slowdown of a throttled tab (`headless_activity.rs`): Chromium's
/// own "low-end device" setting.
const THROTTLED_CPU_RATE: f64 = 4.0;

impl super::CdpDriver {
    /// Throttles a tab (a quiet one: its main thread runs at 1/4 speed, so
    /// its scripts and rendering stop taking a full core) or lets it run at
    /// full rate again.
    pub fn set_tab_throttled(&self, target_id: &str, throttled: bool) {
        let session = self.inner.lock().tabs.get(target_id).map(|tab| tab.session_id.clone());
        if let Some(session) = session {
            let rate = if throttled { THROTTLED_CPU_RATE } else { 1.0 };
            let _ = self.inner.conn.call(
                Some(&session),
                "Emulation.setCPUThrottlingRate",
                serde_json::json!({"rate": rate}),
                INTERNAL_TIMEOUT,
            );
        }
    }
}
