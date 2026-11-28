//! The daemon's side of the Mac's own calendars (`system_calendar.*`, provider
//! family `system_calendar`, answered by the Mac app's CalendarAppOps from
//! EventKit).
//!
//! The Mac app reads EventKit; what an app may ask for is decided here before
//! the call reaches it:
//! - `system_calendar.events {days?, limit?}`: `days` is a whole number in
//!   `1..=`[`MAX_DAYS`] (default [`DEFAULT_DAYS`]), `limit` in
//!   `1..=`[`MAX_LIMIT`] (default [`DEFAULT_LIMIT`]). Unknown fields are
//!   refused. The provider gets both, filled in.
//! - `system_calendar.request_access {}`: shows the system Calendars prompt.
//!   It takes no params, needs a live gesture
//!   (`cmux_app_manifest::capabilities::SYSTEM_PROMPT_OPS`) and gets the long
//!   user deadline: the person may read the prompt for longer than a read's.
//!
//! Granted answers are cached for [`CACHE_TTL`] by their normalized params, so
//! every calendar widget on New Tab and in the sidebar of every window, each
//! on its own tick, costs one EventKit read per window of time. An access
//! answer and a `system_calendar.changed` from the Mac app (EventKit's
//! EKEventStoreChanged, `cmux.watch("system_calendar.events")`) clear the
//! cache. Not-granted answers are never cached: the first
//! read after the person allows access sees the events.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

/// The provider family.
pub const FAMILY: &str = "system_calendar";
/// The event read.
pub const EVENTS: &str = "system_calendar.events";
/// The permission prompt.
pub const REQUEST_ACCESS: &str = "system_calendar.request_access";

/// Days a read covers when the app names none.
pub const DEFAULT_DAYS: u64 = 7;
/// The most days one read may cover (a month view).
pub const MAX_DAYS: u64 = 31;
/// Events per answer when the app names no limit.
pub const DEFAULT_LIMIT: u64 = 20;
/// The most events one answer carries.
pub const MAX_LIMIT: u64 = 50;
/// How long a granted answer is reused.
pub const CACHE_TTL: Duration = Duration::from_secs(30);
/// Distinct reads kept (each widget size reads one shape).
pub const CACHE_ENTRIES: usize = 16;

/// Validates and normalizes a `system_calendar.*` call's params. Returns the
/// params the provider gets, or the ABI error body.
pub fn normalize(op: &str, params: &Value) -> Result<Value, Value> {
    let empty = Map::new();
    let fields = match params {
        Value::Null => &empty,
        Value::Object(fields) => fields,
        _ => return Err(invalid("params must be an object")),
    };
    match op {
        REQUEST_ACCESS => {
            if let Some(unknown) = fields.keys().next() {
                return Err(invalid(format!("{REQUEST_ACCESS} takes no params, got {unknown}")));
            }
            Ok(json!({}))
        }
        EVENTS => {
            if let Some(unknown) = fields.keys().find(|k| !matches!(k.as_str(), "days" | "limit")) {
                return Err(invalid(format!("{EVENTS} has no field {unknown}")));
            }
            let days = whole(fields, "days", DEFAULT_DAYS, MAX_DAYS)?;
            let limit = whole(fields, "limit", DEFAULT_LIMIT, MAX_LIMIT)?;
            Ok(json!({ "days": days, "limit": limit }))
        }
        _ => Err(json!({
            "code": "operation.unsupported",
            "message": format!("{op} is not an operation of this cmux version"),
            "details": { "op": op },
            "retryable": false,
        })),
    }
}

/// The whole-number field `name` in `1..=max`, `fallback` when absent or null.
fn whole(fields: &Map<String, Value>, name: &str, fallback: u64, max: u64) -> Result<u64, Value> {
    match fields.get(name) {
        None | Some(Value::Null) => Ok(fallback),
        Some(value) => value
            .as_u64()
            .filter(|n| (1..=max).contains(n))
            .ok_or_else(|| invalid(format!("{name} is a whole number from 1 to {max}"))),
    }
}

fn invalid(message: impl Into<String>) -> Value {
    json!({ "code": "validation.invalid", "message": message.into(), "retryable": false })
}

/// The cache key of a normalized events read (None for any other op).
pub fn cache_key(op: &str, normalized: &Value) -> Option<String> {
    (op == EVENTS).then(|| normalized.to_string())
}

/// Granted `system_calendar.events` answers by normalized params, newest last.
#[derive(Default)]
pub struct Cache {
    entries: VecDeque<(String, Instant, Value)>,
}

impl Cache {
    /// A fresh answer for `key`, if one is kept.
    pub fn hit(&mut self, key: &str, now: Instant) -> Option<Value> {
        self.entries.retain(|(_, at, _)| now.duration_since(*at) < CACHE_TTL);
        self.entries.iter().find(|(k, _, _)| k == key).map(|(_, _, body)| body.clone())
    }

    /// Forgets every answer: the calendar changed (`system_calendar.changed`).
    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// Records a provider answer: a granted events answer is kept, an access
    /// answer clears every entry.
    pub fn record(&mut self, op: &str, key: Option<&str>, ok: bool, body: &Value, now: Instant) {
        if op == REQUEST_ACCESS {
            self.entries.clear();
            return;
        }
        let Some(key) = key else { return };
        let granted = body.pointer("/value/access").or_else(|| body.get("access"))
            == Some(&Value::String("granted".into()));
        if !ok || !granted {
            return;
        }
        self.entries.retain(|(k, _, _)| k != key);
        if self.entries.len() >= CACHE_ENTRIES {
            self.entries.pop_front();
        }
        self.entries.push_back((key.to_string(), now, body.clone()));
    }
}

#[cfg(test)]
#[path = "system_calendar_tests.rs"]
mod tests;
