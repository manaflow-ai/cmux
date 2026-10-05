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

/// Classic main's text for a fetch its cell's timeout cancelled (no
/// `cancelled` protocol code yet: the error is Timeout).
pub const CELL_TIMED_OUT: &str = "fetch: cancelled because the cell that started it timed out";

/// Idle limit of a fetch without `timeoutMs`: classic's URLSession
/// `timeoutIntervalForRequest` (no bytes for this long fails the fetch;
/// there is no total limit).
const IDLE_TIMEOUT_MS: u64 = 60_000;

/// The session's fetch slots.
#[derive(Debug, Default)]
pub(super) struct FetchSlots {
    pub(super) running: usize,
    ended: bool,
    /// Running fetches: engine fetch id -> the VM cell that started it
    /// (0: none).
    live: std::collections::HashMap<String, u64>,
    /// Cells whose timeout cancelled their fetches.
    cancelled: std::collections::HashSet<u64>,
    /// Fetches waiting for a slot, per cell.
    waiting: std::collections::HashMap<u64, usize>,
    next_id: u64,
}

impl FetchSlots {
    /// Cells kept as timed out (a test bound).
    #[cfg(test)]
    pub(super) fn cancelled_cells(&self) -> usize {
        self.cancelled.len()
    }

    /// Fetches of `cell` that wait for a slot (tests).
    #[cfg(test)]
    pub(super) fn waiting(&self, cell: u64) -> usize {
        self.waiting.get(&cell).copied().unwrap_or(0)
    }

    /// Why a fetch of `cell` may not run, if it may not.
    fn refusal(&self, cell: u64) -> Option<DriverError> {
        if self.ended {
            return Some(DriverError::closed("fetch: the session ended"));
        }
        (cell != 0 && self.cancelled.contains(&cell)).then(|| DriverError::timeout(CELL_TIMED_OUT))
    }

    /// True while `cell` has a queued or running fetch.
    fn busy(&self, cell: u64) -> bool {
        self.waiting.contains_key(&cell) || self.live.values().any(|c| *c == cell)
    }

    /// A timed-out cell is kept only while it has a queued or running
    /// fetch (no per-session set that only grows).
    fn forget_if_idle(&mut self, cell: u64) {
        if self.cancelled.contains(&cell) && !self.busy(cell) {
            self.cancelled.remove(&cell);
        }
    }

    fn stop_waiting(&mut self, cell: u64) {
        if let Some(count) = self.waiting.get_mut(&cell) {
            *count -= 1;
            if *count == 0 {
                self.waiting.remove(&cell);
            }
        }
        self.forget_if_idle(cell);
    }
}

/// One running fetch: holds a slot and keeps the request filter installed.
struct Fetching<'a> {
    gate: &'a Gate,
    id: String,
    cell: u64,
}

impl<'a> Fetching<'a> {
    /// Takes a slot, waiting until `deadline` while all are taken.
    fn start(gate: &'a Gate, deadline: Instant, cell: u64) -> Result<Fetching<'a>, DriverError> {
        let mut slots = gate.fetches.lock().unwrap_or_else(PoisonError::into_inner);
        *slots.waiting.entry(cell).or_default() += 1;
        let waited = loop {
            if let Some(refusal) = slots.refusal(cell) {
                break Err(refusal);
            }
            if slots.running < MAX_FETCHES {
                break Ok(());
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break Err(DriverError::timeout(format!(
                    "fetch: {MAX_FETCHES} fetches of this session are running and none ended in time"
                )));
            }
            slots = gate
                .fetch_slot_free
                .wait_timeout(slots, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        };
        slots.stop_waiting(cell);
        waited?;
        slots.running += 1;
        slots.next_id += 1;
        let id = format!("fetch-{}", slots.next_id);
        slots.live.insert(id.clone(), cell);
        drop(slots);
        gate.sync_request_filter();
        Ok(Fetching { gate, id, cell })
    }
}

impl Drop for Fetching<'_> {
    fn drop(&mut self) {
        {
            let mut slots = self.gate.fetches.lock().unwrap_or_else(PoisonError::into_inner);
            slots.running -= 1;
            slots.live.remove(&self.id);
            slots.forget_if_idle(self.cell);
        }
        self.gate.fetch_slot_free.notify_all();
        self.gate.sync_request_filter();
    }
}

impl Gate {
    /// The session ends: no fetch starts any more, also none that waits,
    /// and the running ones are cancelled in the engine (classic close()).
    pub(super) fn end_fetches(&self) {
        let ids: Vec<String> = {
            let mut slots = self.fetches.lock().unwrap_or_else(PoisonError::into_inner);
            slots.ended = true;
            slots.live.keys().cloned().collect()
        };
        self.fetch_slot_free.notify_all();
        self.cancel_in_engine(ids);
    }

    /// Cell `cell` timed out: its queued fetches fail and its running ones
    /// are cancelled in the engine, which frees their slots at once
    /// (classic `cancelFetches(ofEval:)`).
    pub(crate) fn cancel_cell_fetches(&self, cell: u64) {
        if cell == 0 {
            return;
        }
        let ids: Vec<String> = {
            let mut slots = self.fetches.lock().unwrap_or_else(PoisonError::into_inner);
            if slots.busy(cell) {
                slots.cancelled.insert(cell);
            }
            slots.live.iter().filter(|(_, c)| **c == cell).map(|(id, _)| id.clone()).collect()
        };
        self.fetch_slot_free.notify_all();
        self.cancel_in_engine(ids);
    }

    fn cancel_in_engine(&self, ids: Vec<String>) {
        for id in ids {
            let _ = self.driver.call("net.fetch.cancel", &json!({"fetchId": id}));
        }
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
        // The VM names the cell (agent code cannot); the engine never sees it.
        let cell = params.get("cell").and_then(Value::as_u64).unwrap_or(0);
        let mut call = params.clone();
        if let Some(object) = call.as_object_mut() {
            object.remove("cell");
        }
        call["maxBytes"] = json!(MAX_BODY_BYTES);
        call["idleTimeoutMs"] = json!(IDLE_TIMEOUT_MS);
        // Classic has no total limit: only a given `timeoutMs` (0: none) is
        // one, a single deadline from the call that the wait for a slot
        // spends too; the engine gets what is left.
        let limit = params.get("timeoutMs").map(|_| crate::protocol::timeout_of(params));
        let deadline = Instant::now() + limit.unwrap_or(crate::protocol::NO_TIMEOUT);
        let (result, cancel) = {
            let fetching = Fetching::start(self, deadline, cell)?;
            call["fetchId"] = json!(fetching.id);
            match limit {
                Some(_) => {
                    let left = deadline.saturating_duration_since(Instant::now()).as_millis();
                    call["timeoutMs"] = json!(left.max(1) as u64);
                }
                None => call["timeoutMs"] = json!(0),
            }
            let result = self.driver.call("net.fetch", &call);
            // A cancel wins over the engine's own error (classic's text);
            // read while the fetch still holds its cell.
            let cancel = result
                .is_err()
                .then(|| self.fetches.lock().unwrap_or_else(PoisonError::into_inner).refusal(cell))
                .flatten();
            (result, cancel)
        };
        if let Some(refusal) = cancel {
            return Err(refusal);
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
