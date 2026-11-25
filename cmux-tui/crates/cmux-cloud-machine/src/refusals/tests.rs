//! The detector for the platform's refusal table: the copy is current, and each code's
//! handling is the platform's answer.

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;

use super::*;

/// Days since 1970-01-01 of a `YYYY-MM-DD` day (Howard Hinnant's `days_from_civil`).
fn days(date: &str) -> i64 {
    let mut parts = date.split('-').map(|part| part.parse::<i64>().expect("YYYY-MM-DD"));
    let (y, m, d) = (parts.next().unwrap(), parts.next().unwrap(), parts.next().unwrap());
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[test]
fn the_days_are_counted_from_the_epoch() {
    assert_eq!(days("1970-01-01"), 0);
    assert_eq!(days("2000-03-01"), 11_017);
    assert_eq!(days("2026-11-10"), 20_767);
}

/// The platform repository is private, so CI cannot read its list: a copy older than
/// MAX_COPY_AGE_DAYS fails here instead, since the platform's list may have grown since.
#[test]
fn the_copy_of_the_platforms_refusals_is_current() {
    let today = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() / 86_400;
    let age = i64::try_from(today).unwrap() - days(COPIED_ON);
    assert!(
        (0..=i64::try_from(MAX_COPY_AGE_DAYS).unwrap()).contains(&age),
        "PLATFORM was copied from {SOURCE} on {COPIED_ON} ({age} days ago, at {SOURCE_COMMIT}): \
         copy CLOUD_REFUSALS again from its main, then set SOURCE_COMMIT and COPIED_ON \
         (CMUX_PLATFORM_REFUSALS_TS=<that file> runs the exact comparison)"
    );
}

/// `CLOUD_REFUSALS` of a Refusals.ts text: each code's status and `retryable`.
fn parse_platform(text: &str) -> BTreeMap<String, (u16, bool)> {
    let start = text.find("CLOUD_REFUSALS").expect("CLOUD_REFUSALS");
    let body = &text[start..];
    let body = &body[..body.find("\n}").expect("the table's end")];
    let mut rows = BTreeMap::new();
    for line in body.lines().map(str::trim) {
        let Some(rest) = line.strip_prefix('"') else { continue };
        let Some((code, answer)) = rest.split_once("\":") else { continue };
        let answer = answer.trim().trim_end_matches(',');
        let row = if answer == "OUTAGE" {
            (503, true)
        } else if let Some(args) = answer.strip_prefix("refusal(").and_then(|a| a.strip_suffix(')'))
        {
            let mut args = args.split(',').map(str::trim);
            let status = args.next().unwrap().parse().expect("a status");
            (status, args.next() == Some("true"))
        } else {
            let status = answer
                .split("status:")
                .nth(1)
                .and_then(|s| s.trim().split(',').next())
                .and_then(|s| s.trim().parse().ok())
                .unwrap_or_else(|| panic!("an answer this test cannot read: {line}"));
            (status, answer.contains("retryable: true"))
        };
        rows.insert(code.to_owned(), row);
    }
    rows
}

fn copied() -> BTreeMap<String, (u16, bool)> {
    PLATFORM.iter().map(|r| (r.code.to_owned(), (r.status, r.retryable))).collect()
}

#[test]
fn the_platforms_table_reads_every_answer_shape() {
    let text = r#"
export const CLOUD_REFUSALS: Readonly<Record<string, RefusalAnswer>> = {
  // A comment.
  "validation.invalid": refusal(400),
  "cloud.machine.busy": refusal(409, true),
  "cloud.rate_limited": { status: 429, retryable: true },
  "cloud.provider.refused": { status: 503, retryable: false },
  "owner.unreachable": OUTAGE,
}
"#;
    let rows = parse_platform(text);
    assert_eq!(rows["validation.invalid"], (400, false));
    assert_eq!(rows["cloud.machine.busy"], (409, true));
    assert_eq!(rows["cloud.rate_limited"], (429, true));
    assert_eq!(rows["cloud.provider.refused"], (503, false));
    assert_eq!(rows["owner.unreachable"], (503, true));
    assert_eq!(rows.len(), 5);
}

/// With `CMUX_PLATFORM_REFUSALS_TS` naming a cmux-platform checkout's Refusals.ts, the copy is
/// exactly its table: a code the platform added, dropped or answers differently fails here.
#[test]
fn the_copy_is_the_platforms_table_when_it_is_readable() {
    let Ok(path) = std::env::var("CMUX_PLATFORM_REFUSALS_TS") else { return };
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    assert_eq!(copied(), parse_platform(&text), "PLATFORM differs from {path}");
}

#[test]
fn the_copy_has_each_code_once() {
    assert_eq!(copied().len(), PLATFORM.len());
}

/// Every code of the platform's table, as a client handles it: a 429 waits its Retry-After, a
/// retryable code is sent again, every other code is final.
#[test]
fn every_platform_code_has_its_handling() {
    for refusal in PLATFORM {
        let expected = match (refusal.status, refusal.retryable) {
            (429, true) => Handling::RetryAfter,
            (_, true) => Handling::Retry,
            (_, false) => Handling::Final,
        };
        let code = Some(refusal.code);
        assert_eq!(refusal.handling(), expected, "{}", refusal.code);
        // The body's own flag, as #1192 sends it.
        assert_eq!(
            handling(refusal.status, code, Some(refusal.retryable)),
            expected,
            "{}",
            refusal.code
        );
        // An answer with no flag: the code's row decides, not the status.
        assert_eq!(handling(refusal.status, code, None), expected, "{}", refusal.code);
        if is_cap(refusal.code) {
            assert_eq!(expected, Handling::Final, "a cap is final: {}", refusal.code);
            assert_eq!(refusal.status, 403, "{}", refusal.code);
        }
    }
}

#[test]
fn the_bodys_flag_comes_first_and_the_status_last() {
    assert_eq!(handling(503, Some("machine.unavailable"), Some(false)), Handling::Final);
    assert_eq!(handling(409, Some("anything"), Some(true)), Handling::Retry);
    assert_eq!(handling(429, None, Some(true)), Handling::RetryAfter);
    assert_eq!(handling(429, None, None), Handling::RetryAfter);
    for status in [502, 503, 504] {
        assert_eq!(handling(status, None, None), Handling::Retry, "{status}");
    }
    for status in [400, 401, 403, 404, 409] {
        assert_eq!(handling(status, None, None), Handling::Final, "{status}");
    }
}

#[test]
fn the_vm_limit_names_its_limit_and_the_vms_that_hold_it() {
    let body = json!({
        "_tag": "MachineForbidden", "code": "cloud.quota.vm_limit", "retryable": false,
        "message": "VM API: this team has its limit of 20 machines (paused ones count); delete one to make another",
        "details": {"limit": 20, "team_vms": 20, "orphans": 3, "oldest_vm_age_s": 259_200, "complete": true},
    });
    let facts = Facts::read(Some(&body), None);
    assert_eq!(
        facts,
        Facts {
            retryable: Some(false),
            retry_after_s: None,
            limit: Some(20),
            used: Some(20),
            orphans: Some(3),
            oldest_vm_age_s: Some(259_200),
        }
    );
    let why = reason("cloud.quota.vm_limit", &facts).unwrap();
    assert!(why.contains("20 of 20 machines"), "{why}");
    assert!(why.contains("3 of them left over"), "{why}");
    assert!(why.contains("delete one"), "{why}");
    // A census that failed sends nulls: the reason still says what to do.
    let unread = Facts::read(
        Some(&json!({"details": {"limit": 20, "team_vms": null, "orphans": null}})),
        None,
    );
    let why = reason("cloud.quota.vm_limit", &unread).unwrap();
    assert!(why.contains("its limit is 20 machines"), "{why}");
}

#[test]
fn a_rate_limit_waits_its_window() {
    let body = json!({"_tag": "MachineRateLimited", "code": "cloud.rate_limited", "retryable": true, "retryAfterSeconds": 42});
    assert_eq!(Facts::read(Some(&body), Some("7")).retry_after_s, Some(42), "the body's own");
    assert_eq!(Facts::read(Some(&json!({})), Some("7")).retry_after_s, Some(7), "the header");
    let ms = json!({"error": {"code": "cloud.rate_limited", "details": {"retry_after_ms": 1500}}});
    assert_eq!(Facts::read(Some(&ms), None).retry_after_s, Some(2), "the window, rounded up");
    assert_eq!(Facts::read(None, None).wait_s(), DEFAULT_RETRY_AFTER_SECONDS);
    let why = reason("cloud.rate_limited", &Facts::read(Some(&body), None)).unwrap();
    assert!(why.contains("42 s"), "{why}");
}

#[test]
fn every_cap_has_a_reason_and_other_codes_keep_the_callers_words() {
    for refusal in PLATFORM {
        let has = reason(refusal.code, &Facts::default()).is_some();
        let expected = is_cap(refusal.code) || refusal.code == "cloud.rate_limited";
        assert_eq!(has, expected, "{}", refusal.code);
    }
}
