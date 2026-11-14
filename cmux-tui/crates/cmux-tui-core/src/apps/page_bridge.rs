//! The `cmuxPage` bridge of an app web pane (`render: web`,
//! plans/cmux-next/extensibility-DESIGN.md section 4, decision 3): every call
//! a `cmux-app://<id>/` page sends is decided here before the daemon runs it.
//!
//! - **Async only.** A call is `{"id", "op", "params"?}`; its answer is a
//!   later message carrying the same `id`. There is no synchronous form, so a
//!   page can never block the main thread with a call.
//! - **Bounded.** A message is at most [`MAX_MESSAGE_BYTES`] (256 KiB); a page
//!   makes at most [`MAX_CALLS_PER_SECOND`] (200) calls in any one second.
//!   Over either limit the call is answered with an error and never runs
//!   (`bridge.message_too_large`, `rate.limited`). Large data goes by handle.
//! - **Scoped.** The page sees exactly the catalog ops its app's granted
//!   scopes allow ([`ScopeTable::allowed_ops`], the same table and grant as
//!   the app's QuickJS host), and each call is checked against the grant
//!   ([`ScopeTable::check`]), so a page can do nothing its app could not.
//!
//! The clock is injected (`now`), so the limiter is tested without sleeping.
//! The supervisor's gesture, idempotency and routing rules (`calls.rs`) still
//! apply to an admitted call; this module only decides admission.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::grants::{Decision, Grant, OpClass, ScopeTable};

/// The largest bridge message a page may send (decision 3: 256 KiB).
pub const MAX_MESSAGE_BYTES: usize = 256 * 1024;
/// Calls a page may make in any one second (decision 3).
pub const MAX_CALLS_PER_SECOND: usize = 200;
const WINDOW: Duration = Duration::from_secs(1);
/// The longest call id a page may use (it is echoed in the answer).
const MAX_ID_LEN: usize = 128;

/// A call the bridge admitted: the daemon runs it and answers `id`.
#[derive(Debug, Clone, PartialEq)]
pub struct PageCall {
    pub id: String,
    pub op: String,
    pub params: Value,
    pub class: OpClass,
}

/// Why a call was refused; the page gets `{id, ok: false, error}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeRefusal {
    /// The call's id when the message had one (a page can match the answer).
    pub id: Option<String>,
    pub code: &'static str,
    pub message: String,
    pub retryable: bool,
}

impl BridgeRefusal {
    fn new(id: Option<String>, code: &'static str, message: impl Into<String>) -> Self {
        Self { id, code, message: message.into(), retryable: false }
    }

    /// The answer the page receives.
    pub fn to_answer(&self) -> Value {
        json!({
            "id": self.id,
            "ok": false,
            "error": { "code": self.code, "message": self.message, "retryable": self.retryable },
        })
    }
}

/// One page's bridge: its app's grant and its own call window. One per open
/// page (a second tab of the same app has its own budget).
#[derive(Debug)]
pub struct PageBridge {
    grant: Grant,
    /// When each call of the last second was admitted, oldest first. Holds at
    /// most [`MAX_CALLS_PER_SECOND`] entries, so its cost is constant.
    window: VecDeque<Instant>,
    /// Calls refused with `rate.limited` since the page opened (app.logs and
    /// the Slowed step of the host ladder read it).
    rate_limited: u64,
}

impl PageBridge {
    pub fn new(grant: Grant) -> Self {
        Self { grant, window: VecDeque::with_capacity(MAX_CALLS_PER_SECOND), rate_limited: 0 }
    }

    /// The app's grant changed (a scope revoked, the app disabled).
    pub fn set_grant(&mut self, grant: Grant) {
        self.grant = grant;
    }

    /// The ops the page may call: exactly those its grant allows. Sent to the
    /// page as `cmuxPage.ops` when it loads.
    pub fn allowed_ops(&self) -> Vec<String> {
        ScopeTable::get().allowed_ops(&self.grant)
    }

    pub fn rate_limited_count(&self) -> u64 {
        self.rate_limited
    }

    /// Decides one raw bridge message received at `now`. Size first (nothing
    /// is parsed past the limit), then shape, then rate (a malformed call
    /// still spends budget, so a flood of junk is limited too), then scope.
    pub fn admit(&mut self, raw: &str, now: Instant) -> Result<PageCall, BridgeRefusal> {
        if raw.len() > MAX_MESSAGE_BYTES {
            return Err(BridgeRefusal::new(
                None,
                "bridge.message_too_large",
                format!(
                    "a bridge message is at most {MAX_MESSAGE_BYTES} bytes; this one is {}: pass large data by handle",
                    raw.len()
                ),
            ));
        }
        let parsed: Option<Value> = serde_json::from_str(raw).ok();
        let id = parsed
            .as_ref()
            .and_then(|v| v.get("id"))
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty() && id.len() <= MAX_ID_LEN)
            .map(str::to_string);
        if !self.spend(now) {
            self.rate_limited += 1;
            return Err(BridgeRefusal {
                id,
                code: "rate.limited",
                message: format!("a page makes at most {MAX_CALLS_PER_SECOND} calls per second"),
                retryable: true,
            });
        }
        let Some(message) = parsed.as_ref().and_then(Value::as_object) else {
            return Err(BridgeRefusal::new(id, "bridge.bad_message", "a call is a JSON object"));
        };
        let Some(id) = id else {
            // No id: the call could only be synchronous or fire-and-forget.
            return Err(BridgeRefusal::new(
                None,
                "bridge.bad_message",
                format!(
                    "a call needs an id of 1 to {MAX_ID_LEN} characters; its answer comes later"
                ),
            ));
        };
        let Some(op) = message.get("op").and_then(Value::as_str) else {
            return Err(BridgeRefusal::new(Some(id), "bridge.bad_message", "a call needs an op"));
        };
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        if !(params.is_null() || params.is_object()) {
            return Err(BridgeRefusal::new(Some(id), "bridge.bad_message", "params is an object"));
        }
        match ScopeTable::get().check(op, &params, &self.grant) {
            Decision::Allow(class) => Ok(PageCall { id, op: op.to_string(), params, class }),
            Decision::Unsupported => Err(BridgeRefusal::new(
                Some(id),
                "operation.unsupported",
                format!("{op} is not an operation of this cmux version"),
            )),
            Decision::ScopeMissing(reason) => {
                Err(BridgeRefusal::new(Some(id), "scope.missing", reason))
            }
        }
    }

    /// Takes one call from the sliding one-second window, or false when the
    /// page already made [`MAX_CALLS_PER_SECOND`] calls in the last second.
    fn spend(&mut self, now: Instant) -> bool {
        while let Some(&oldest) = self.window.front() {
            if now.saturating_duration_since(oldest) >= WINDOW {
                self.window.pop_front();
            } else {
                break;
            }
        }
        if self.window.len() >= MAX_CALLS_PER_SECOND {
            return false;
        }
        self.window.push_back(now);
        true
    }
}

#[cfg(test)]
mod tests;
