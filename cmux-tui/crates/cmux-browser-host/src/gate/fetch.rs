//! `net.fetch` (HOST-FETCH, a9 2026-10-04): the REPL's `fetch()` runs in
//! the engine (its cookie jar, proxy and TLS); the host checks the URL, the
//! headers, every redirect hop (the request filter stays installed while a
//! fetch runs) and the address the response came from (DNS rebinding,
//! after the fact), and masks secrets in the body.

use super::{Gate, now_ms, push_log};
use crate::policy::egress::ip_range;
use crate::protocol::{DriverError, ErrorCode};
use crate::vm::VmHost;
use serde_json::{Value, json};
use std::sync::PoisonError;
use std::time::Instant;

/// Main's maxBodyBytes.
pub const MAX_BODY_BYTES: u64 = 64 * 1024 * 1024;

/// Headers agent code may not set (stricter than main, which passed them
/// to URLSession).
fn forbidden_header(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    matches!(name.as_str(), "host" | "content-length" | "cookie2")
        || name.starts_with("sec-")
        || name.starts_with("proxy-")
}

/// Fetches of one session that run at once (a9 shell-tab condition d; a
/// shell fetch counts too). One more waits for a slot.
pub const MAX_FETCHES: usize = 16;

/// The session's fetch slots.
#[derive(Debug, Default)]
pub(super) struct FetchSlots {
    pub(super) running: usize,
    ended: bool,
}

/// One running fetch: holds a slot and keeps the request filter installed.
struct Fetching<'a>(&'a Gate);

impl<'a> Fetching<'a> {
    /// Takes a slot, waiting until `deadline` while all are taken.
    fn start(gate: &'a Gate, deadline: Instant) -> Result<Fetching<'a>, DriverError> {
        let mut slots = gate.fetches.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if slots.ended {
                return Err(DriverError::closed("fetch: the session ended"));
            }
            if slots.running < MAX_FETCHES {
                break;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(DriverError::timeout(format!(
                    "fetch: {MAX_FETCHES} fetches of this session are running and none ended in time"
                )));
            }
            slots = gate
                .fetch_slot_free
                .wait_timeout(slots, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
        slots.running += 1;
        drop(slots);
        gate.sync_request_filter();
        Ok(Fetching(gate))
    }
}

impl Drop for Fetching<'_> {
    fn drop(&mut self) {
        self.0.fetches.lock().unwrap_or_else(PoisonError::into_inner).running -= 1;
        self.0.fetch_slot_free.notify_all();
        self.0.sync_request_filter();
    }
}

impl Gate {
    /// The session ends: no fetch starts any more, also none that waits.
    pub(super) fn end_fetches(&self) {
        self.fetches.lock().unwrap_or_else(PoisonError::into_inner).ended = true;
        self.fetch_slot_free.notify_all();
    }

    /// DNS rebinding (a9 v1, after the fact; fetch and navigations share
    /// it): why a response from `url` that came from `ip` is refused.
    pub(super) fn rebinding_refusal(&self, url: &str, ip: &str) -> Option<String> {
        let address = ip.trim_matches(|c| c == '[' || c == ']').parse().ok()?;
        let parsed = url::Url::parse(url).ok()?;
        let reason = self.policy.lock().unwrap_or_else(PoisonError::into_inner).range_refusal(
            &parsed,
            ip_range(address),
            self.grants.remote,
        )?;
        Some(format!("{url} resolved to {ip}, which is blocked: {reason}"))
    }

    fn refuse_fetch(&self, url: &str, message: String) -> DriverError {
        push_log(
            &self.log,
            json!({"url": url, "reason": message, "at": now_ms(), "blocked": "before"}),
        );
        DriverError::new(ErrorCode::Forbidden, message)
    }

    pub(super) fn fetch(&self, params: &Value) -> Result<Value, DriverError> {
        let url = params
            .get("url")
            .and_then(Value::as_str)
            .ok_or_else(|| DriverError::invalid("fetch: url: expected a string"))?
            .to_owned();
        for pair in params.get("headers").and_then(Value::as_array).into_iter().flatten() {
            if let Some(name) = pair.get(0).and_then(Value::as_str)
                && forbidden_header(name)
            {
                return Err(DriverError::invalid(format!(
                    "fetch: the {name} header cannot be set"
                )));
            }
        }
        if let Some(reason) = self.url_refusal(&url) {
            return Err(self.refuse_fetch(&url, format!("fetch: {url} is blocked: {reason}")));
        }
        // a9 shell-tab condition (e): a shell tab would enter a signed-in
        // profile's history; the page's own tab runs the fetch instead.
        if self.grants.signed_in_profile && !params.get("targetId").is_some_and(Value::is_string) {
            return Err(DriverError::new(
                ErrorCode::Forbidden,
                "fetch: open a page first; on a signed-in profile fetch runs in the page's tab",
            ));
        }
        let start = self
            .filtered
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .back()
            .map_or(0, |entry| entry.0);
        let mut call = params.clone();
        call["maxBytes"] = json!(MAX_BODY_BYTES);
        let result = {
            let deadline = Instant::now() + crate::protocol::timeout_of(params);
            let _fetching = Fetching::start(self, deadline)?;
            self.driver.call("net.fetch", &call)
        };
        let mut value = match result {
            Ok(value) => value,
            Err(error) => {
                // A hop the filter refused: name it (main's text).
                let hop = self
                    .filtered
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .iter()
                    .find(|entry| entry.0 > start)
                    .map(|entry| (entry.1.clone(), entry.2.clone()));
                return Err(match hop {
                    Some((hop, reason)) if hop == url => {
                        self.refuse_fetch(&hop, format!("fetch: {hop} is blocked: {reason}"))
                    }
                    Some((hop, reason)) => self.refuse_fetch(
                        &hop,
                        format!("fetch: redirect to {hop} is blocked: {reason}"),
                    ),
                    None => error,
                });
            }
        };
        // DNS rebinding (v1, after the fact): a name that resolved into a
        // refused range fails the fetch.
        let remote_ip = value.as_object_mut().and_then(|object| object.remove("remoteIPAddress"));
        if let Some(ip) = remote_ip.as_ref().and_then(Value::as_str) {
            let final_url = value["url"].as_str().unwrap_or(&url).to_owned();
            if let Some(reason) = self.rebinding_refusal(&final_url, ip) {
                return Err(self.refuse_fetch(&final_url, format!("fetch: {reason}")));
            }
        }
        // HOST-FETCH-CORS relaxations the engine made for this fetch.
        if let Some(Value::Array(relaxed)) =
            value.as_object_mut().and_then(|object| object.remove("corsRelaxed"))
        {
            for entry in relaxed {
                push_log(
                    &self.cors_log,
                    json!({"url": entry["url"], "what": entry["what"], "at": now_ms()}),
                );
            }
        }
        // Secrets in the body are masked by their bytes (text or binary).
        if let Some(body) = value.get("bodyBase64").and_then(Value::as_str)
            && let Some(bytes) = crate::fs_sandbox::base64_decode(body)
        {
            value["bodyBase64"] = json!(crate::fs_sandbox::base64_encode(&self.mask_bytes(&bytes)));
        }
        Ok(value)
    }

    /// Navigations and page requests: a response that came from a refused
    /// address stops the tab's load and is logged (`blocked: after`). The
    /// stop runs off the event thread (a WebKit provider's events arrive on
    /// its reader).
    pub(super) fn check_rebinding(&self, payload: &Value) {
        let (Some(url), Some(ip), Some(target)) = (
            payload.get("url").and_then(Value::as_str),
            payload.get("remoteIPAddress").and_then(Value::as_str),
            payload.get("targetId").and_then(Value::as_str),
        ) else {
            return;
        };
        let Some(reason) = self.rebinding_refusal(url, ip) else { return };
        push_log(
            &self.log,
            json!({"url": url, "reason": reason, "at": now_ms(), "blocked": "after"}),
        );
        let driver = self.driver.clone();
        let stop = json!({"targetId": target});
        let _ = std::thread::Builder::new().name("cmux-browser-host-rebinding-stop".into()).spawn(
            move || {
                let _ = driver.call("tab.stop", &stop);
            },
        );
    }
}
