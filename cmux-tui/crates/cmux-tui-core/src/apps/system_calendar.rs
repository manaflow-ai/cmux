//! The Mac's own calendars for apps (`system_calendar.*`, provider family
//! `system_calendar`, answered by the Mac app from EventKit).
//!
//! The Mac app reads EventKit; everything an app could abuse is decided here
//! before the call reaches it:
//! - `system_calendar.events.list {from, to, limit?, calendars?}`: `from` and
//!   `to` are Unix milliseconds, `to` after `from`, at most [`MAX_SPAN_MS`]
//!   apart; `limit` is clamped to `1..=`[`MAX_LIMIT`] (default
//!   [`DEFAULT_LIMIT`]); `calendars` names at most [`MAX_CALENDARS`] calendar
//!   ids. Unknown fields are refused. The answer is
//!   `{access, events: [...], calendars: [...]}`; `access` is `granted`,
//!   `not_determined`, `denied` or `restricted`, and only a `granted` answer
//!   carries events.
//! - `system_calendar.access.request {}`: shows the system Calendars prompt
//!   (or, after a refusal, opens Privacy & Security > Calendars) and answers
//!   `{access}`. It opens system UI, so it needs a live gesture
//!   (`cmux_app_manifest::capabilities::PANEL_OPS`) and gets the long
//!   user deadline.
//!
//! Granted answers are cached for [`CACHE_TTL`] by their normalized params, so
//! every widget on New Tab and in the sidebar of every window, each refreshing
//! on its own timer, costs one EventKit read per window of time. An access
//! answer clears the cache. Not-granted answers are never cached: the first
//! read after the person allows access sees the events.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

/// The provider family.
pub const FAMILY: &str = "system_calendar";
/// The event read.
pub const EVENTS_LIST: &str = "system_calendar.events.list";
/// The permission prompt.
pub const ACCESS_REQUEST: &str = "system_calendar.access.request";

/// The widest window one read may cover (32 days: a month view).
pub const MAX_SPAN_MS: i64 = 32 * 24 * 60 * 60 * 1000;
/// Events per answer when the app names no limit.
pub const DEFAULT_LIMIT: u64 = 50;
/// The most events one answer carries.
pub const MAX_LIMIT: u64 = 200;
/// The most calendar ids one read may name.
pub const MAX_CALENDARS: usize = 64;
/// The longest calendar id, in bytes.
pub const MAX_CALENDAR_ID_BYTES: usize = 256;
/// How long a granted answer is reused.
pub const CACHE_TTL: Duration = Duration::from_secs(30);
/// Distinct windows kept (each open widget size reads one window).
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
        ACCESS_REQUEST => {
            if let Some(unknown) = fields.keys().next() {
                return Err(invalid(format!("{ACCESS_REQUEST} takes no params, got {unknown}")));
            }
            Ok(json!({}))
        }
        EVENTS_LIST => events_list(fields),
        _ => Err(json!({
            "code": "operation.unsupported",
            "message": format!("{op} is not an operation of this cmux version"),
            "details": { "op": op },
            "retryable": false,
        })),
    }
}

fn events_list(fields: &Map<String, Value>) -> Result<Value, Value> {
    if let Some(unknown) =
        fields.keys().find(|k| !matches!(k.as_str(), "from" | "to" | "limit" | "calendars"))
    {
        return Err(invalid(format!("{EVENTS_LIST} has no field {unknown}")));
    }
    let millis = |name: &str| {
        fields
            .get(name)
            .and_then(Value::as_i64)
            .ok_or_else(|| invalid(format!("{name} must be an integer of Unix milliseconds")))
    };
    let (from, to) = (millis("from")?, millis("to")?);
    if to <= from {
        return Err(invalid("to must be after from"));
    }
    if to - from > MAX_SPAN_MS {
        return Err(invalid("from and to may be at most 32 days apart"));
    }
    let limit = match fields.get("limit") {
        None => DEFAULT_LIMIT,
        Some(v) => v
            .as_u64()
            .filter(|n| *n >= 1)
            .ok_or_else(|| invalid("limit must be a positive integer"))?
            .min(MAX_LIMIT),
    };
    let mut out = json!({ "from": from, "to": to, "limit": limit });
    if let Some(list) = fields.get("calendars") {
        let ids = list.as_array().ok_or_else(|| invalid("calendars must be a list of ids"))?;
        if ids.len() > MAX_CALENDARS {
            return Err(invalid(format!("calendars may name at most {MAX_CALENDARS} ids")));
        }
        let mut names = Vec::with_capacity(ids.len());
        for id in ids {
            let id = id
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= MAX_CALENDAR_ID_BYTES)
                .ok_or_else(|| invalid("each calendar id is a non-empty string"))?;
            names.push(id.to_string());
        }
        names.sort();
        names.dedup();
        out["calendars"] = json!(names);
    }
    Ok(out)
}

fn invalid(message: impl Into<String>) -> Value {
    json!({ "code": "validation.invalid", "message": message.into(), "retryable": false })
}

/// The cache key of a normalized events read (None for any other op).
pub fn cache_key(op: &str, normalized: &Value) -> Option<String> {
    (op == EVENTS_LIST).then(|| normalized.to_string())
}

/// Granted `events.list` answers by normalized params, newest last.
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

    /// Records a provider answer: a granted events answer is kept, an access
    /// answer clears every entry.
    pub fn record(&mut self, op: &str, key: Option<&str>, ok: bool, body: &Value, now: Instant) {
        if op == ACCESS_REQUEST {
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
mod tests {
    use super::*;

    const HOUR: i64 = 60 * 60 * 1000;

    #[test]
    fn events_list_is_normalized_and_bounded() {
        assert_eq!(
            normalize(EVENTS_LIST, &json!({ "from": 0, "to": HOUR })).unwrap(),
            json!({ "from": 0, "to": HOUR, "limit": DEFAULT_LIMIT })
        );
        assert_eq!(
            normalize(
                EVENTS_LIST,
                &json!({ "from": 0, "to": HOUR, "limit": 5000, "calendars": ["b", "a", "b"] })
            )
            .unwrap(),
            json!({ "from": 0, "to": HOUR, "limit": MAX_LIMIT, "calendars": ["a", "b"] })
        );
        for bad in [
            json!({ "to": HOUR }),
            json!({ "from": HOUR, "to": HOUR }),
            json!({ "from": 0, "to": MAX_SPAN_MS + 1 }),
            json!({ "from": "today", "to": HOUR }),
            json!({ "from": 0, "to": HOUR, "limit": 0 }),
            json!({ "from": 0, "to": HOUR, "calendars": [""] }),
            json!({ "from": 0, "to": HOUR, "calendars": vec!["x"; MAX_CALENDARS + 1] }),
            json!({ "from": 0, "to": HOUR, "query": "dentist" }),
            json!([0, HOUR]),
        ] {
            assert_eq!(
                normalize(EVENTS_LIST, &bad).unwrap_err()["code"],
                "validation.invalid",
                "{bad}"
            );
        }
    }

    #[test]
    fn access_request_takes_no_params() {
        assert_eq!(normalize(ACCESS_REQUEST, &Value::Null).unwrap(), json!({}));
        assert!(normalize(ACCESS_REQUEST, &json!({ "silent": true })).is_err());
        assert_eq!(
            normalize("system_calendar.event.create", &json!({})).unwrap_err()["code"],
            "operation.unsupported"
        );
    }

    #[test]
    fn only_granted_answers_are_cached_and_access_clears_them() {
        let mut cache = Cache::default();
        let now = Instant::now();
        let key = cache_key(EVENTS_LIST, &json!({ "from": 0, "to": HOUR })).unwrap();
        let denied = json!({ "value": { "access": "not_determined", "events": [] } });
        cache.record(EVENTS_LIST, Some(&key), true, &denied, now);
        assert_eq!(cache.hit(&key, now), None, "a not-granted answer is read again");
        let granted = json!({ "value": { "access": "granted", "events": [] } });
        cache.record(EVENTS_LIST, Some(&key), true, &granted, now);
        assert_eq!(cache.hit(&key, now + Duration::from_secs(1)), Some(granted.clone()));
        assert_eq!(cache.hit(&key, now + CACHE_TTL), None, "stale after the TTL");
        cache.record(EVENTS_LIST, Some(&key), true, &granted, now);
        cache.record(ACCESS_REQUEST, None, true, &json!({ "value": { "access": "denied" } }), now);
        assert_eq!(cache.hit(&key, now), None, "an access change clears the cache");
    }

    #[test]
    fn the_cache_keeps_a_bounded_number_of_windows() {
        let mut cache = Cache::default();
        let now = Instant::now();
        let granted = json!({ "value": { "access": "granted", "events": [] } });
        for i in 0..(CACHE_ENTRIES as i64 + 4) {
            let key = cache_key(EVENTS_LIST, &json!({ "from": i, "to": HOUR })).unwrap();
            cache.record(EVENTS_LIST, Some(&key), true, &granted, now);
        }
        assert_eq!(cache.entries.len(), CACHE_ENTRIES);
        let first = cache_key(EVENTS_LIST, &json!({ "from": 0, "to": HOUR })).unwrap();
        assert_eq!(cache.hit(&first, now), None, "the oldest window went first");
    }
}
