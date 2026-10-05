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
use std::sync::atomic::Ordering;

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

/// Keeps the request filter installed while a fetch runs.
struct Fetching<'a>(&'a Gate);

impl<'a> Fetching<'a> {
    fn start(gate: &'a Gate) -> Fetching<'a> {
        gate.fetches.fetch_add(1, Ordering::SeqCst);
        gate.sync_request_filter();
        Fetching(gate)
    }
}

impl Drop for Fetching<'_> {
    fn drop(&mut self) {
        self.0.fetches.fetch_sub(1, Ordering::SeqCst);
        self.0.sync_request_filter();
    }
}

impl Gate {
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
        let start = self
            .filtered
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .back()
            .map_or(0, |entry| entry.0);
        let mut call = params.clone();
        call["maxBytes"] = json!(MAX_BODY_BYTES);
        // No current tab (a lazy page): the fetch runs in a background tab of
        // the session's profile, closed after it (main's storage-state way).
        let opened = if params.get("targetId").is_some_and(Value::is_string) {
            None
        } else {
            let tab = self.driver.call("tabs.open", &json!({"url": "about:blank", "background": true}))?;
            let target = tab.get("targetId").and_then(Value::as_str).map(str::to_owned).ok_or_else(|| {
                DriverError::invalid("fetch: no tab to run the fetch in; open a page first")
            })?;
            call["targetId"] = json!(target);
            Some(target)
        };
        let result = {
            let _fetching = Fetching::start(self);
            self.driver.call("net.fetch", &call)
        };
        if let Some(target) = opened {
            let _ = self.driver.call("tabs.close", &json!({"targetId": target}));
        }
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
        if let Some(ip) = remote_ip.as_ref().and_then(Value::as_str)
            && let Ok(address) = ip.trim_matches(|c| c == '[' || c == ']').parse()
        {
            let final_url = value["url"].as_str().unwrap_or(&url).to_owned();
            if let Ok(parsed) = url::Url::parse(&final_url) {
                let reason = self
                    .policy
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .range_refusal(&parsed, ip_range(address), self.grants.remote);
                if let Some(reason) = reason {
                    return Err(self.refuse_fetch(
                        &final_url,
                        format!("fetch: {final_url} resolved to {ip}, which is blocked: {reason}"),
                    ));
                }
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
}
