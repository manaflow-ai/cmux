//! The machine's own health problems for `_acpmux/host_health`'s `problems`
//! (`peer_status.rs`): what the machine health loop wrote to
//! `/run/cmux/machine-health.json` as wrong now and not fixed, so `host ls`,
//! `host status` and cmux NEXT's machine rows show a machine whose DNS, disk,
//! RAM, daemon or peer link is down without anyone logging in to look.
//!
//! Read once per `host_health` call (the file is a few hundred bytes); no
//! timer or watcher of its own. A machine without the loop has no file and
//! its reply has no `problems`. A file older than [`STALE_MS`] is one `loop`
//! problem (the loop stopped, so its list says nothing about now), and a file
//! that is not the contract's JSON is one `loop` problem saying so: neither
//! reads as healthy. The list is capped at [`MAX_PROBLEMS`] and each detail at
//! [`MAX_DETAIL`] characters, one line each, since a peer and the app print it.

use serde_json::{Value, json};
use std::io::Read;
use std::path::PathBuf;

/// Where the machine health loop writes.
const PATH: &str = "/run/cmux/machine-health.json";
/// Another file instead (tests, a machine whose loop writes elsewhere).
const PATH_ENV: &str = "ACPMUX_MACHINE_HEALTH_FILE";
/// A reading older than this means the loop stopped.
const STALE_MS: u64 = 5 * 60 * 1000;
pub(super) const MAX_PROBLEMS: usize = 8;
pub(super) const MAX_DETAIL: usize = 200;
/// A check name is a word (`dns`, `disk`, ...); longer is not the contract's.
const MAX_CHECK: usize = 32;
/// Read no more than this: the contract's file is far smaller.
const MAX_FILE: u64 = 64 * 1024;

/// The machine's problems now, or `None` when it runs no health loop.
pub(super) fn problems() -> Option<Value> {
    let path = std::env::var_os(PATH_ENV).map(PathBuf::from).unwrap_or_else(|| PATH.into());
    let mut bytes = Vec::new();
    match std::fs::File::open(&path) {
        Ok(f) => {
            if f.take(MAX_FILE + 1).read_to_end(&mut bytes).is_err() {
                return Some(json!([loop_problem("machine health file cannot be read", None)]));
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
        Err(_) => return Some(json!([loop_problem("machine health file cannot be read", None)])),
    }
    Some(parse(&bytes, crate::store::now_ms()))
}

/// The `problems` a file's bytes give at `now` (ms).
pub(super) fn parse(bytes: &[u8], now: u64) -> Value {
    let malformed = || json!([loop_problem("machine health file is not valid", None)]);
    if bytes.len() as u64 > MAX_FILE {
        return malformed();
    }
    let Ok(Value::Object(file)) = serde_json::from_slice::<Value>(bytes) else {
        return malformed();
    };
    let Some(checked) = file.get("checkedAt").and_then(Value::as_str).and_then(time_ms) else {
        return malformed();
    };
    if now.saturating_sub(checked) > STALE_MS {
        let at = super::iso(checked);
        let detail = format!("machine health check has not run since {at}");
        return json!([loop_problem(&detail, Some(at))]);
    }
    let list = match file.get("problems") {
        None | Some(Value::Null) => return json!([]),
        Some(Value::Array(list)) => list,
        Some(_) => return malformed(),
    };
    // An entry that is not the contract's is skipped, never shown made up.
    Value::Array(list.iter().filter_map(entry).take(MAX_PROBLEMS).collect())
}

/// One `{check, detail, since?}`, or `None` for an entry without a check or a detail.
fn entry(v: &Value) -> Option<Value> {
    let check = v.get("check")?.as_str()?.trim();
    let detail = one_line(v.get("detail")?.as_str()?, MAX_DETAIL);
    if check.is_empty() || check.chars().count() > MAX_CHECK || detail.is_empty() {
        return None;
    }
    let mut out = json!({"check": check, "detail": detail});
    if let Some(ms) = v.get("since").and_then(Value::as_str).and_then(time_ms) {
        out["since"] = json!(super::iso(ms));
    }
    Some(out)
}

fn loop_problem(detail: &str, since: Option<String>) -> Value {
    let mut p = json!({"check": "loop", "detail": detail});
    if let Some(at) = since {
        p["since"] = json!(at);
    }
    p
}

/// `text` on one line (control characters as spaces), trimmed, at most `max` characters.
fn one_line(text: &str, max: usize) -> String {
    let flat: String =
        text.chars().map(|c| if c.is_control() { ' ' } else { c }).take(max).collect();
    flat.trim().to_owned()
}

fn time_ms(text: &str) -> Option<u64> {
    cmux_chat_index::parse_rfc3339_ms(text).and_then(|ms| u64::try_from(ms).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2026-10-25T12:00:00Z.
    const NOW: u64 = 1_792_929_600_000;

    fn file(checked: &str, problems: Value) -> Vec<u8> {
        json!({"schema": 1, "checkedAt": checked, "problems": problems, "fixed": []})
            .to_string()
            .into_bytes()
    }

    #[test]
    fn a_fresh_file_gives_its_problems_and_a_healthy_one_none() {
        assert_eq!(super::super::iso(NOW), "2026-10-25T12:00:00.000Z");
        let bytes = file(
            "2026-10-25T11:58:00Z",
            json!([{"check": "dns", "detail": "DNS: github.com does not resolve",
                    "since": "2026-10-25T11:40:00Z"}]),
        );
        assert_eq!(
            parse(&bytes, NOW),
            json!([{"check": "dns", "detail": "DNS: github.com does not resolve",
                    "since": "2026-10-25T11:40:00.000Z"}])
        );
        assert_eq!(parse(&file("2026-10-25T11:58:00Z", json!([])), NOW), json!([]));
        let no_list = br#"{"schema": 1, "checkedAt": "2026-10-25T11:58:00Z"}"#;
        assert_eq!(parse(no_list, NOW), json!([]));
    }

    #[test]
    fn a_stale_file_is_one_loop_problem() {
        let bytes = file("2026-10-25T11:50:00Z", json!([{"check": "dns", "detail": "x"}]));
        assert_eq!(
            parse(&bytes, NOW),
            json!([{"check": "loop",
                    "detail": "machine health check has not run since 2026-10-25T11:50:00.000Z",
                    "since": "2026-10-25T11:50:00.000Z"}])
        );
    }

    #[test]
    fn a_malformed_file_is_one_problem_saying_so() {
        let said = json!([{"check": "loop", "detail": "machine health file is not valid"}]);
        for bad in [
            &b"{not json"[..],
            b"[]",
            br#"{"schema": 1}"#,
            br#"{"checkedAt": "yesterday", "problems": []}"#,
            br#"{"checkedAt": "2026-10-25T11:58:00Z", "problems": "dns"}"#,
        ] {
            assert_eq!(parse(bad, NOW), said, "{}", String::from_utf8_lossy(bad));
        }
        let huge = vec![b' '; MAX_FILE as usize + 1];
        assert_eq!(parse(&huge, NOW), said);
    }

    #[test]
    fn entries_are_capped_flattened_and_a_bad_one_skipped() {
        let long = "d".repeat(500);
        let mut list = vec![
            json!({"check": "disk"}),
            json!({"detail": "no check"}),
            json!({"check": "", "detail": "empty check"}),
            json!({"check": "ram", "detail": "line one\nline two", "since": "garbage"}),
            json!({"check": "peer", "detail": long}),
        ];
        list.extend((0..20).map(|i| json!({"check": "acpmux", "detail": format!("n{i}")})));
        let got = parse(&file("2026-10-25T11:59:00Z", Value::Array(list)), NOW);
        let got = got.as_array().unwrap();
        assert_eq!(got.len(), MAX_PROBLEMS);
        assert_eq!(got[0], json!({"check": "ram", "detail": "line one line two"}));
        assert_eq!(got[1]["detail"].as_str().unwrap().chars().count(), MAX_DETAIL);
        assert_eq!(got[2]["detail"], "n0");
    }
}
