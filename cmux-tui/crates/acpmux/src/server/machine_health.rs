//! The machine's own health problems for `_acpmux/host_health`'s `problems`
//! (`peer_status.rs`): what the machine health loop wrote to
//! `/run/cmux/machine-health.json` as wrong now and not fixed, so `host ls`,
//! `host status` and cmux NEXT's machine rows show a machine whose DNS, disk,
//! RAM, daemon or peer link is down without anyone logging in to look.
//!
//! Read once per `host_health` call (the file is a few hundred bytes), off the
//! runtime's worker threads; no timer or watcher of its own. A machine without
//! the loop has no file and its reply has no `problems`. A file older than
//! [`STALE_MS`] is one `loop` problem (the loop stopped, so its list says
//! nothing about now), and a file that is not the contract's JSON is one
//! `loop` problem saying so: neither reads as healthy.
//!
//! The same [`sanitize`] runs on this machine's file and on what a peer
//! answers (`peer_status.rs`, `peer_health.rs`), so whatever a terminal or the
//! app prints is at most [`MAX_PROBLEMS`] entries, each a short lowercase check
//! name and one line of at most [`MAX_DETAIL`] characters with no control
//! characters, a `since` only when it is a valid RFC 3339 time, and a
//! `severity` only when it is `warning` or `critical` (the disk floors).

use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::path::PathBuf;
use tokio::io::AsyncReadExt;

/// Where the machine health loop writes.
const PATH: &str = "/run/cmux/machine-health.json";
/// Another file instead (tests, a machine whose loop writes elsewhere).
const PATH_ENV: &str = "ACPMUX_MACHINE_HEALTH_FILE";
/// A reading older than this means the loop stopped.
const STALE_MS: u64 = 5 * 60 * 1000;
const MAX_PROBLEMS: usize = 8;
const MAX_DETAIL: usize = 200;
/// A check name is a short word (`dns`, `disk`, ...).
const MAX_CHECK: usize = 32;
/// Read no more than this: the contract's file is far smaller.
const MAX_FILE: u64 = 64 * 1024;

/// The machine's problems now, or `None` when it runs no health loop.
pub(super) async fn problems() -> Option<Value> {
    let path = std::env::var_os(PATH_ENV).map(PathBuf::from).unwrap_or_else(|| PATH.into());
    let unreadable = || Some(json!([loop_problem("machine health file cannot be read", None)]));
    let file = match tokio::fs::File::open(&path).await {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
        Err(_) => return unreadable(),
    };
    let mut bytes = Vec::new();
    if file.take(MAX_FILE + 1).read_to_end(&mut bytes).await.is_err() {
        return unreadable();
    }
    Some(parse(&bytes, crate::store::now_ms()))
}

/// The `problems` a file's bytes give at `now` (ms).
fn parse(bytes: &[u8], now: u64) -> Value {
    let malformed = || json!([loop_problem("machine health file is not valid", None)]);
    if bytes.len() as u64 > MAX_FILE {
        return malformed();
    }
    let Ok(Value::Object(file)) = serde_json::from_slice::<Value>(bytes) else {
        return malformed();
    };
    let Some(checked) = file.get("checkedAt").and_then(Value::as_str).and_then(rfc3339_ms) else {
        return malformed();
    };
    if now.saturating_sub(checked) > STALE_MS {
        let at = super::iso(checked);
        let detail = format!("machine health check has not run since {at}");
        return json!([loop_problem(&detail, Some(at))]);
    }
    match file.get("problems") {
        None | Some(Value::Null) => json!([]),
        Some(list @ Value::Array(_)) => sanitize(list),
        Some(_) => malformed(),
    }
}

/// `problems` as this daemon passes them on, from its own file or a peer's
/// answer: the well-formed entries only (an entry without a check or a detail
/// is skipped, never shown made up), capped and cleaned (module docs). Not a
/// list: none.
pub(crate) fn sanitize(problems: &Value) -> Value {
    let list = problems.as_array().map(Vec::as_slice).unwrap_or_default();
    Value::Array(list.iter().filter_map(entry).take(MAX_PROBLEMS).collect())
}

/// One `{check, detail, since?, severity?}`, or `None` for an entry that is not the contract's.
fn entry(v: &Value) -> Option<Value> {
    let check = v.get("check")?.as_str()?.trim().to_ascii_lowercase();
    let word = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_';
    if check.is_empty() || check.len() > MAX_CHECK || !check.chars().all(word) {
        return None;
    }
    let detail = one_line(v.get("detail")?.as_str()?, MAX_DETAIL);
    if detail.is_empty() {
        return None;
    }
    let mut out = json!({"check": check, "detail": detail});
    if let Some(ms) = v.get("since").and_then(Value::as_str).and_then(rfc3339_ms) {
        out.set("since", json!(super::iso(ms)));
    }
    if let Some(level @ ("warning" | "critical")) = v.get("severity").and_then(Value::as_str) {
        out.set("severity", json!(level));
    }
    Some(out)
}

fn loop_problem(detail: &str, since: Option<String>) -> Value {
    let mut p = json!({"check": "loop", "detail": detail});
    if let Some(at) = since {
        p.set("since", json!(at));
    }
    p
}

/// `text` on one line (control characters as spaces), trimmed, at most `max` characters.
fn one_line(text: &str, max: usize) -> String {
    let flat: String =
        text.chars().map(|c| if c.is_control() { ' ' } else { c }).take(max).collect();
    flat.trim().to_owned()
}

/// A strict RFC 3339 time in ms since the epoch: `YYYY-MM-DDTHH:MM:SS`, an
/// optional fraction, then `Z` or `+HH:MM`/`-HH:MM`; a real calendar date at
/// or after 1970. Anything else is `None`.
pub(crate) fn rfc3339_ms(text: &str) -> Option<u64> {
    let b = text.as_bytes();
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        let d = b.get(r)?;
        d.iter()
            .all(u8::is_ascii_digit)
            .then(|| d.iter().fold(0, |n, c| n * 10 + i64::from(c - b'0')))
    };
    let sep = |i: usize, c: u8| b.get(i) == Some(&c);
    if !(sep(4, b'-') && sep(7, b'-') && sep(10, b'T') && sep(13, b':') && sep(16, b':')) {
        return None;
    }
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, s) = (num(11..13)?, num(14..16)?, num(17..19)?);
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let days_in = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if !(1..=12).contains(&mo)
        || d < 1
        || days_in.get((mo - 1) as usize).is_none_or(|&last| d > last)
        || h > 23
        || mi > 59
        || s > 59
    {
        return None;
    }
    let mut rest = b.get(19..).unwrap_or_default();
    let mut ms = 0;
    if let Some((b'.', frac)) = rest.split_first() {
        let n = frac.iter().take_while(|c| c.is_ascii_digit()).count();
        if n == 0 {
            return None;
        }
        let scale = match n.min(3) {
            1 => 100,
            2 => 10,
            _ => 1,
        };
        ms = frac.iter().take(n.min(3)).fold(0, |m, c| m * 10 + i64::from(c - b'0')) * scale;
        rest = frac.get(n..).unwrap_or_default();
    }
    let offset = match rest {
        b"Z" => 0,
        [sign @ (b'+' | b'-'), h1, h2, b':', m1, m2] => {
            let digits = [*h1, *h2, *m1, *m2];
            if !digits.iter().all(u8::is_ascii_digit) {
                return None;
            }
            let (oh, om) = (
                i64::from(h1 - b'0') * 10 + i64::from(h2 - b'0'),
                i64::from(m1 - b'0') * 10 + i64::from(m2 - b'0'),
            );
            if oh > 23 || om > 59 {
                return None;
            }
            if *sign == b'-' { -(oh * 60 + om) } else { oh * 60 + om }
        }
        _ => return None,
    };
    // Days since 1970-01-01 (H. Hinnant's days_from_civil).
    let yy = if mo <= 2 { y - 1 } else { y };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let doy = (153 * ((mo + 9) % 12) + 2) / 5 + d - 1;
    let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468;
    let secs = days * 86_400 + h * 3_600 + mi * 60 + s - offset * 60;
    u64::try_from(secs * 1_000 + ms).ok()
}

#[cfg(test)]
mod tests;
