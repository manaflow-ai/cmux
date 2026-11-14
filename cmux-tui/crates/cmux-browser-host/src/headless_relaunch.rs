//! A crash of the shared headless browser costs its sessions nothing (Leo,
//! 2026-11-14: "separate the health of the overall process from the
//! falliability of crash prone bits").
//!
//! One Chromium serves every session of a profile (`headless_source.rs`).
//! When it dies (a renderer bug, out of memory, a kill), the next call
//! relaunches it and reopens the dead browser's tabs of the profile's store
//! at their last URLs, which the driver still holds. Chromium gives the
//! reopened tabs new target ids; sessions keep the ids they know: the host
//! maps them ([`TabIds`]) at the driver boundary, in both directions. A
//! call the crash cut short is sent again only when that is safe (reads and
//! navigations, [`RETRY_SAFE`]); a click or typed input never goes twice.
//!
//! Not carried over: tabs of a private, proxy or incognito store (their
//! store died with the browser; reopening them in the profile's store would
//! give them its cookies). They close, with `tab.closed`, as before.

use crate::cdp::CdpDriver;
use crate::driver::Driver;
use crate::headless_source::{HeadlessSource, Live};
use crate::protocol::{DriverError, DriverEvent};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::{Arc, PoisonError};

/// What a call learns when the browser died and could not start again.
pub(crate) const CLOSED: &str = "the headless browser closed";

/// Calls sent again after a relaunch when the crash cut them short: they
/// read, or navigate to a URL the call names. Input, script and opening
/// tabs are not here: their effect may have happened once already.
const RETRY_SAFE: &[&str] = &[
    "tabs.list",
    "tab.info",
    "tab.navigate",
    "tab.reload",
    "frames.list",
    "frame.observe",
    "frame.ownerBox",
    "frame.focused",
    "frame.contentFrame",
    "frame.contentFrames",
    "tab.screenshot",
    "tab.pdf",
    "cookies.get",
];

/// The ids sessions know for tabs reopened after a relaunch, and the
/// browser's ids for them. Empty until a relaunch; an entry goes with its
/// tab's `tab.closed` or the next relaunch.
#[derive(Debug, Default)]
pub(crate) struct TabIds {
    /// Session id -> the running browser's target id.
    real: HashMap<String, String>,
    /// The running browser's target id -> session id.
    stable: HashMap<String, String>,
}

impl TabIds {
    pub(crate) fn real<'a>(&'a self, id: &'a str) -> &'a str {
        self.real.get(id).map_or(id, String::as_str)
    }

    pub(crate) fn stable<'a>(&'a self, id: &'a str) -> &'a str {
        self.stable.get(id).map_or(id, String::as_str)
    }

    /// Every string of `value` that is a session's tab id (a target id or a
    /// main frame id, which Chromium makes the same) as the browser's.
    pub(crate) fn to_real(&self, value: &mut Value) {
        if !self.real.is_empty() {
            map_strings(value, &self.real);
        }
    }

    /// Every browser target id in `value` as the id the sessions know.
    pub(crate) fn to_stable(&self, value: &mut Value) {
        if !self.stable.is_empty() {
            map_strings(value, &self.stable);
        }
    }

    /// The tab is gone: its ids are no longer mapped.
    pub(crate) fn closed(&mut self, stable: &str) {
        if let Some(real) = self.real.remove(stable) {
            self.stable.remove(&real);
        }
    }

    /// After a relaunch: the reopened tabs, as (session id, new target id).
    /// The dead browser's ids are dropped.
    pub(crate) fn relaunched(&mut self, moved: Vec<(String, String)>) {
        self.real.clear();
        self.stable.clear();
        for (stable, real) in moved {
            if stable != real {
                self.stable.insert(real.clone(), stable.clone());
                self.real.insert(stable, real);
            }
        }
    }
}

fn map_strings(value: &mut Value, ids: &HashMap<String, String>) {
    match value {
        Value::String(s) => {
            if let Some(id) = ids.get(s.as_str()) {
                s.clone_from(id);
            }
        }
        Value::Array(items) => items.iter_mut().for_each(|item| map_strings(item, ids)),
        Value::Object(fields) => fields.values_mut().for_each(|item| map_strings(item, ids)),
        _ => {}
    }
}

impl HeadlessSource {
    pub(crate) fn ids(&self) -> std::sync::MutexGuard<'_, TabIds> {
        self.ids.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The browser's id of a tab the sessions name `id`.
    pub(crate) fn real_id(&self, id: &str) -> String {
        self.ids().real(id).to_owned()
    }

    /// The running browser, relaunched first when it died. A browser that
    /// cannot start again fails as the dead one did.
    pub(crate) fn live_or_relaunch(&self) -> Result<Arc<Live>, DriverError> {
        let live = self.driver();
        if live.is_open() {
            return Ok(live);
        }
        self.relaunch(&live).map_err(|_| DriverError::closed(CLOSED))
    }

    /// A driver call with the sessions' tab ids, on the running browser: a
    /// dead browser is relaunched first, and a call the crash cut short is
    /// sent again on the new one when it is [`RETRY_SAFE`].
    pub(crate) fn on_live<R>(
        &self,
        method: &str,
        params: &Value,
        mut call: impl FnMut(&CdpDriver, &Value) -> Result<R, DriverError>,
    ) -> Result<R, DriverError> {
        let live = self.live_or_relaunch()?;
        let mut real = params.clone();
        self.ids().to_real(&mut real);
        match call(&live, &real) {
            Err(error) if !live.is_open() => {
                // Relaunched for the next call either way.
                let Ok(live) = self.relaunch(&live) else { return Err(error) };
                if !RETRY_SAFE.contains(&method) {
                    return Err(error);
                }
                let mut real = params.clone();
                self.ids().to_real(&mut real);
                call(&live, &real)
            }
            result => result,
        }
    }

    /// Launches the browser again after `dead` died, once for every caller
    /// that saw it die, and reopens its tabs of the profile's store.
    pub(crate) fn relaunch(&self, dead: &Arc<Live>) -> Result<Arc<Live>, DriverError> {
        let _turn = self.relaunching.lock().unwrap_or_else(PoisonError::into_inner);
        let current = self.driver();
        if !Arc::ptr_eq(&current, dead) || current.is_open() {
            return Ok(current);
        }
        // The new browser's own events (its start tab, the reopened tabs
        // loading) are not the sessions'.
        self.quiet.store(true, Ordering::SeqCst);
        let result = self.reopen(dead);
        self.quiet.store(false, Ordering::SeqCst);
        let (live, gone) = result?;
        // Each tab that did not come back closes for the sessions.
        for stable in gone {
            self.publish(DriverEvent {
                name: "tab.closed".into(),
                payload: json!({"targetId": stable}),
            });
        }
        Ok(live)
    }

    fn reopen(&self, dead: &Arc<Live>) -> Result<(Arc<Live>, Vec<String>), DriverError> {
        let live = Arc::new(Live::start(&self.options, self.agent_source.clone(), &self.me)?);
        // The sessions' request filters and popups, before a tab loads. A
        // reopened tab no session names yet follows every session's filter.
        let me = self.me.get().and_then(std::sync::Weak::upgrade);
        if let Some(me) = &me {
            me.install_popup_hook(&live);
            me.sync_filter_on(&live);
        }
        // The dead driver still holds each tab's last URL.
        let tabs = dead.call("tabs.list", &json!({})).unwrap_or_default();
        let mut moved = Vec::new();
        let mut gone = Vec::new();
        for tab in tabs.as_array().into_iter().flatten() {
            let Some(old) = tab["targetId"].as_str() else { continue };
            let stable = self.ids().stable(old).to_owned();
            let url = tab["url"].as_str().filter(|u| !u.is_empty()).unwrap_or("about:blank");
            // Chromium names the profile's store too: only the host's own
            // stores stay behind.
            let reopened = if dead.tab_context(old).is_some_and(|c| self.is_host_store(&c)) {
                None
            } else {
                live.call("tabs.open", &json!({"url": url, "background": true}))
                    .ok()
                    .and_then(|v| v["targetId"].as_str().map(str::to_owned))
            };
            match reopened {
                Some(real) => moved.push((stable, real)),
                None => gone.push(stable),
            }
        }
        self.ids().relaunched(moved);
        *self.live.lock().unwrap_or_else(PoisonError::into_inner) = live.clone();
        self.configure_relaunched();
        Ok((live, gone))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reopened_tabs_keep_their_ids_both_ways() {
        let mut ids = TabIds::default();
        let mut params = json!({"targetId": "A", "frameId": "A", "url": "A?"});
        ids.to_real(&mut params);
        assert_eq!(params["targetId"], "A", "no relaunch, no mapping");
        ids.relaunched(vec![("A".into(), "B".into()), ("C".into(), "C".into())]);
        ids.to_real(&mut params);
        assert_eq!(params, json!({"targetId": "B", "frameId": "B", "url": "A?"}));
        let mut rows = json!([{"targetId": "B", "openerTargetId": "D"}]);
        ids.to_stable(&mut rows);
        assert_eq!(rows, json!([{"targetId": "A", "openerTargetId": "D"}]));
        // A second relaunch maps from the first one's ids.
        ids.relaunched(vec![(ids.stable("B").to_owned(), "E".into())]);
        assert_eq!(ids.real("A"), "E");
        assert_eq!(ids.stable("B"), "B", "the dead browser's ids are dropped");
        ids.closed("A");
        assert_eq!(ids.real("A"), "A");
        assert_eq!(ids.stable("E"), "E");
    }
}
