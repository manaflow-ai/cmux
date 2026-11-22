//! The `system_calendar.*` app ops' rules for the macOS app
//! (`include/cmux_system_calendar.h`, Swift module `CCmuxSystemCalendarFFI`):
//! the `days` and `limit` params, the window the app reads, and the answer an
//! app gets (which occurrences, in what order, how many, text capped). The
//! app's `CalendarAppOps` keeps only what needs EventKit: the access status,
//! the prompt, and reading the occurrences in the window.
//!
//! Two JSON ops of `cmux_system_calendar_call`:
//! - `window` `{params, now}` answers `{days, limit, start, end}`, or
//!   `{error: {code: "invalid_params", message}}` for a bad param.
//! - `answer` `{access, records, now, days, limit}` answers `{access, events}`:
//!   the records with `end > now` and `start < now + days`, sorted by start
//!   (then end, title, id), at most `limit`; no events unless `access` is
//!   `granted`.
//!
//! Times are seconds since 1970 (a Swift `Date`'s `timeIntervalSince1970`),
//! as the app reads them; an event's `start` and `end` go out as epoch
//! milliseconds, rounded.

use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use unicode_segmentation::UnicodeSegmentation;

/// Bumped on any change to a type, a function or an op.
pub const CMUX_SYSTEM_CALENDAR_ABI_VERSION: u32 = 1;
/// The op ran; `*out` holds its reply.
pub const CMUX_SYSTEM_CALENDAR_OK: i32 = 0;
/// A null pointer where one is required.
pub const CMUX_SYSTEM_CALENDAR_ERR_NULL: i32 = -1;
/// Not UTF-8, or not the JSON the op takes.
pub const CMUX_SYSTEM_CALENDAR_ERR_INVALID: i32 = -2;
/// The op is not one of the header's.
pub const CMUX_SYSTEM_CALENDAR_ERR_UNKNOWN_OP: i32 = -3;
/// A panic inside, caught.
pub const CMUX_SYSTEM_CALENDAR_ERR_PANIC: i32 = -4;

const DEFAULT_DAYS: i64 = 7;
const MAX_DAYS: i64 = 31;
const DEFAULT_LIMIT: i64 = 20;
const MAX_LIMIT: i64 = 50;
/// The most characters (grapheme clusters, as Swift counts) of an id, a title,
/// a calendar or a location an app gets.
const MAX_TEXT: usize = 200;
/// The longest link an app gets; a longer one is dropped.
const MAX_URL: usize = 2_000;
const DAY_SECONDS: f64 = 86_400.0;

/// A reply buffer owned by the caller (JSON, UTF-8). `ptr` is null when `len`
/// is 0.
#[repr(C)]
pub struct CmuxSystemCalendarBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

/// One occurrence as the app read it from the system calendar.
#[derive(Debug, Clone, Deserialize)]
pub struct Record {
    pub id: String,
    #[serde(default)]
    pub title: String,
    /// Seconds since 1970.
    pub start: f64,
    /// Seconds since 1970.
    pub end: f64,
    #[serde(default, rename = "allDay")]
    pub all_day: bool,
    #[serde(default)]
    pub calendar: String,
    #[serde(default)]
    pub location: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub color: Option<String>,
}

/// `invalid_params` and its message, as `AppHostCapabilityError` carries it.
#[derive(Debug, PartialEq, Eq)]
pub struct Invalid(pub String);

/// The days and limit of a `system_calendar.events` call (`params` is its JSON
/// params): each absent or null takes its default.
pub fn window_params(op: &str, params: &Value) -> Result<(i64, i64), Invalid> {
    if !params.is_null() && !params.is_object() {
        return Err(Invalid(format!("{op} takes an object")));
    }
    let days = integer(params, "days", DEFAULT_DAYS, 1, MAX_DAYS)?;
    let limit = integer(params, "limit", DEFAULT_LIMIT, 1, MAX_LIMIT)?;
    Ok((days, limit))
}

fn integer(params: &Value, key: &str, fallback: i64, low: i64, high: i64) -> Result<i64, Invalid> {
    let value = match params.get(key) {
        None | Some(Value::Null) => return Ok(fallback),
        Some(value) => value,
    };
    match value.as_f64() {
        Some(n) if n.round() == n && n >= low as f64 && n <= high as f64 => Ok(n as i64),
        _ => Err(Invalid(format!("{key} is a whole number from {low} to {high}"))),
    }
}

/// `system_calendar.events`' answer for `records` read at `now` (seconds).
pub fn answer(access: &str, mut records: Vec<Record>, now: f64, days: i64, limit: i64) -> Value {
    if access != "granted" {
        return json!({ "access": access, "events": [] });
    }
    let end = now + days as f64 * DAY_SECONDS;
    records.retain(|r| r.end > now && r.start < end);
    records.sort_by(|a, b| {
        a.start
            .total_cmp(&b.start)
            .then(a.end.total_cmp(&b.end))
            .then_with(|| a.title.cmp(&b.title))
            .then_with(|| a.id.cmp(&b.id))
    });
    let events: Vec<Value> = records.iter().take(limit.max(0) as usize).map(event).collect();
    json!({ "access": access, "events": events })
}

/// One event as the app sees it (`CmuxCalendarEvent`): epoch ms, capped text,
/// no empty optionals.
fn event(record: &Record) -> Value {
    let mut event = Map::new();
    event.insert("id".into(), capped(&record.id).into());
    event.insert("title".into(), capped(&record.title).into());
    event.insert("start".into(), json!(milliseconds(record.start)));
    event.insert("end".into(), json!(milliseconds(record.end)));
    event.insert("allDay".into(), record.all_day.into());
    event.insert("calendar".into(), capped(&record.calendar).into());
    if let Some(location) = record.location.as_deref().map(str::trim).filter(|l| !l.is_empty()) {
        event.insert("location".into(), capped(location).into());
    }
    if let Some(url) =
        record.url.as_deref().filter(|u| !u.is_empty() && u.graphemes(true).count() <= MAX_URL)
    {
        event.insert("url".into(), url.into());
    }
    if let Some(color) = record.color.as_deref().filter(|c| is_hex_color(c)) {
        event.insert("color".into(), color.into());
    }
    Value::Object(event)
}

/// Epoch milliseconds for `seconds`, rounded half away from zero.
pub fn milliseconds(seconds: f64) -> f64 {
    (seconds * 1_000.0).round()
}

fn capped(text: &str) -> String {
    text.graphemes(true).take(MAX_TEXT).collect()
}

/// Whether `text` is a `#rrggbb` color, the only form an app gets.
pub fn is_hex_color(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 7 && bytes[0] == b'#' && bytes[1..].iter().all(u8::is_ascii_hexdigit)
}

#[derive(Debug)]
enum OpError {
    Unknown,
    Invalid,
}

fn call(op: &str, request: &Value) -> Result<Value, OpError> {
    match op {
        "window" => {
            let now = request.get("now").and_then(Value::as_f64).ok_or(OpError::Invalid)?;
            let null = Value::Null;
            let params = request.get("params").unwrap_or(&null);
            Ok(match window_params("system_calendar.events", params) {
                Ok((days, limit)) => json!({
                    "days": days,
                    "limit": limit,
                    "start": now,
                    "end": now + days as f64 * DAY_SECONDS,
                }),
                Err(Invalid(message)) => {
                    json!({ "error": { "code": "invalid_params", "message": message } })
                }
            })
        }
        "answer" => {
            #[derive(Deserialize)]
            struct Request {
                access: String,
                #[serde(default)]
                records: Vec<Record>,
                now: f64,
                // Whole numbers from `window`; the app's JSON may write them as 7.0.
                days: f64,
                limit: f64,
            }
            let request = Request::deserialize(request).map_err(|_| OpError::Invalid)?;
            Ok(answer(
                &request.access,
                request.records,
                request.now,
                request.days as i64,
                request.limit as i64,
            ))
        }
        _ => Err(OpError::Unknown),
    }
}

/// `CMUX_SYSTEM_CALENDAR_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_system_calendar_abi_version() -> u32 {
    CMUX_SYSTEM_CALENDAR_ABI_VERSION
}

/// Runs one JSON op: `op` (NUL-terminated, `window` or `answer`) on `request`
/// (a JSON object, UTF-8); `*out` gets the reply's JSON, which the caller
/// frees with `cmux_system_calendar_bytes_free`.
///
/// # Safety
///
/// `op` is a NUL-terminated string; `request_ptr` with `request_len` is
/// readable; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_system_calendar_call(
    op: *const c_char,
    request_ptr: *const u8,
    request_len: usize,
    out: *mut CmuxSystemCalendarBytes,
) -> i32 {
    if op.is_null() || out.is_null() || (request_ptr.is_null() && request_len != 0) {
        return CMUX_SYSTEM_CALENDAR_ERR_NULL;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Ok(op) = unsafe { CStr::from_ptr(op) }.to_str() else {
            return Err(CMUX_SYSTEM_CALENDAR_ERR_INVALID);
        };
        let bytes: &[u8] = if request_len == 0 {
            &[]
        } else {
            // SAFETY: readable for `request_len` bytes per the contract.
            unsafe { std::slice::from_raw_parts(request_ptr, request_len) }
        };
        let request = match serde_json::from_slice::<Value>(bytes) {
            Ok(value @ Value::Object(_)) => value,
            _ => return Err(CMUX_SYSTEM_CALENDAR_ERR_INVALID),
        };
        match call(op, &request) {
            Ok(reply) => Ok(serde_json::to_vec(&reply).unwrap_or_default()),
            Err(OpError::Unknown) => Err(CMUX_SYSTEM_CALENDAR_ERR_UNKNOWN_OP),
            Err(OpError::Invalid) => Err(CMUX_SYSTEM_CALENDAR_ERR_INVALID),
        }
    }));
    let reply = match result {
        Ok(Ok(reply)) => reply,
        Ok(Err(code)) => return code,
        Err(_) => return CMUX_SYSTEM_CALENDAR_ERR_PANIC,
    };
    let boxed = reply.into_boxed_slice();
    let len = boxed.len();
    let ptr = if len == 0 { std::ptr::null_mut() } else { Box::into_raw(boxed).cast::<u8>() };
    // SAFETY: `out` is writable per the contract.
    unsafe { out.write(CmuxSystemCalendarBytes { ptr, len }) };
    CMUX_SYSTEM_CALENDAR_OK
}

/// Frees a reply buffer. A null `ptr` is ignored.
///
/// # Safety
///
/// `bytes` came from `cmux_system_calendar_call` and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_system_calendar_bytes_free(bytes: CmuxSystemCalendarBytes) {
    if bytes.ptr.is_null() {
        return;
    }
    // SAFETY: a boxed slice of `len` bytes from `cmux_system_calendar_call`.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(id: &str, start: f64, end: f64) -> Record {
        Record {
            id: id.into(),
            title: format!("t-{id}"),
            start,
            end,
            all_day: false,
            calendar: "Work".into(),
            location: None,
            url: None,
            color: None,
        }
    }

    fn run(op: &str, request: Value) -> Result<Value, i32> {
        let op = std::ffi::CString::new(op).unwrap();
        let bytes = serde_json::to_vec(&request).unwrap();
        let mut out = CmuxSystemCalendarBytes { ptr: std::ptr::null_mut(), len: 0 };
        // SAFETY: valid pointers for the call.
        let code = unsafe {
            cmux_system_calendar_call(op.as_ptr(), bytes.as_ptr(), bytes.len(), &mut out)
        };
        if code != CMUX_SYSTEM_CALENDAR_OK {
            return Err(code);
        }
        // SAFETY: from the call, freed once below.
        let reply = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
        unsafe { cmux_system_calendar_bytes_free(out) };
        Ok(serde_json::from_slice(&reply).unwrap())
    }

    #[test]
    fn the_window_defaults_and_refuses_bad_params() {
        let reply = run("window", json!({"now": 1000.0})).unwrap();
        assert_eq!(
            reply,
            json!({"days": 7, "limit": 20, "start": 1000.0, "end": 1000.0 + 7.0 * 86_400.0})
        );
        let reply =
            run("window", json!({"now": 0.0, "params": {"days": 31, "limit": null}})).unwrap();
        assert_eq!((reply["days"].clone(), reply["limit"].clone()), (json!(31), json!(20)));
        for (params, message) in [
            (json!({"days": 0}), "days is a whole number from 1 to 31"),
            (json!({"days": 32}), "days is a whole number from 1 to 31"),
            (json!({"days": 1.5}), "days is a whole number from 1 to 31"),
            (json!({"days": "3"}), "days is a whole number from 1 to 31"),
            (json!({"limit": 51}), "limit is a whole number from 1 to 50"),
            (json!({"limit": true}), "limit is a whole number from 1 to 50"),
            (json!([1]), "system_calendar.events takes an object"),
        ] {
            let reply = run("window", json!({"now": 0.0, "params": params})).unwrap();
            assert_eq!(
                reply,
                json!({"error": {"code": "invalid_params", "message": message}}),
                "{params}"
            );
        }
        assert_eq!(run("window", json!({})), Err(CMUX_SYSTEM_CALENDAR_ERR_INVALID));
        assert_eq!(run("nope", json!({})), Err(CMUX_SYSTEM_CALENDAR_ERR_UNKNOWN_OP));
    }

    #[test]
    fn only_granted_access_gets_events() {
        for access in ["denied", "restricted", "notDetermined", "unavailable"] {
            let reply = answer(access, vec![record("a", 10.0, 20.0)], 0.0, 7, 20);
            assert_eq!(reply, json!({"access": access, "events": []}));
        }
    }

    #[test]
    fn events_are_windowed_sorted_and_limited() {
        let now = 1_000_000.0;
        let records = vec![
            record("ended", now - 100.0, now),
            record("later", now + 50.0, now + 60.0),
            record("running", now - 10.0, now + 10.0),
            record("b", now + 50.0, now + 60.0),
            record("too-far", now + 2.0 * DAY_SECONDS, now + 2.0 * DAY_SECONDS + 1.0),
            record("shorter", now + 50.0, now + 55.0),
        ];
        let reply = answer("granted", records.clone(), now, 1, 20);
        let ids: Vec<&str> =
            reply["events"].as_array().unwrap().iter().map(|e| e["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["running", "shorter", "b", "later"]);
        let reply = answer("granted", records, now, 1, 2);
        assert_eq!(reply["events"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn an_event_has_capped_text_and_no_empty_optionals() {
        let mut long = record(&"i".repeat(300), 1.0005, 2.0);
        long.title = "\u{1F44D}\u{1F3FD}".repeat(250);
        long.location = Some("  Room 1 \n".into());
        long.url = Some("https://x".into());
        long.color = Some("#a1B2c3".into());
        long.all_day = true;
        let event = event(&long);
        assert_eq!(event["id"].as_str().unwrap().len(), MAX_TEXT);
        assert_eq!(event["title"].as_str().unwrap().graphemes(true).count(), MAX_TEXT);
        assert_eq!(event["start"], json!(1001.0));
        assert_eq!(event["end"], json!(2000.0));
        assert_eq!(event["allDay"], json!(true));
        assert_eq!(event["location"], json!("Room 1"));
        assert_eq!(event["url"], json!("https://x"));
        assert_eq!(event["color"], json!("#a1B2c3"));

        let mut empty = record("e", 1.0, 2.0);
        empty.location = Some(" \n".into());
        empty.url = Some(format!("https://{}", "x".repeat(MAX_URL)));
        empty.color = Some("red".into());
        let event = super::event(&empty);
        for key in ["location", "url", "color"] {
            assert!(event.get(key).is_none(), "{key}");
        }
    }

    #[test]
    fn the_answer_op_reads_the_apps_records() {
        let reply = run(
            "answer",
            json!({"access": "granted", "now": 0.0, "days": 7, "limit": 20, "records": [
                {"id": "x@1", "title": "T", "start": 1.0, "end": 2.0, "allDay": false, "calendar": "C"}
            ]}),
        )
        .unwrap();
        assert_eq!(
            reply,
            json!({"access": "granted", "events": [
                {"id": "x@1", "title": "T", "start": 1000.0, "end": 2000.0, "allDay": false, "calendar": "C"}
            ]})
        );
    }
}
