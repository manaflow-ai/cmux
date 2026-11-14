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
    // An offset is read as the time it names: 13:58+02:00 is 11:58Z.
    assert_eq!(parse(&file("2026-10-25T13:58:00.5+02:00", json!([])), NOW), json!([]));
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
    // The same wall time at +02:00 is two hours earlier: stale.
    let east = parse(&file("2026-10-25T11:58:00+02:00", json!([])), NOW);
    assert_eq!(east[0]["check"], "loop", "{east}");
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
fn a_known_severity_passes_and_any_other_is_dropped() {
    let bytes = file(
        "2026-10-25T11:59:00Z",
        json!([
            {"check": "disk", "detail": "low", "severity": "warning"},
            {"check": "disk", "detail": "full", "severity": "critical"},
            {"check": "disk", "detail": "odd", "severity": "PANIC"},
            {"check": "cmux", "detail": "unit", "severity": 3},
        ]),
    );
    assert_eq!(
        parse(&bytes, NOW),
        json!([
            {"check": "disk", "detail": "low", "severity": "warning"},
            {"check": "disk", "detail": "full", "severity": "critical"},
            {"check": "disk", "detail": "odd"},
            {"check": "cmux", "detail": "unit"},
        ])
    );
}

#[test]
fn only_a_strict_rfc3339_time_reads() {
    assert_eq!(rfc3339_ms("2026-10-25T12:00:00Z"), Some(NOW));
    assert_eq!(rfc3339_ms("2026-10-25T12:00:00.123456Z"), Some(NOW + 123));
    assert_eq!(rfc3339_ms("2026-10-25T14:30:00+02:30"), Some(NOW));
    assert_eq!(rfc3339_ms("2026-10-25T11:00:00-01:00"), Some(NOW));
    assert_eq!(rfc3339_ms("2024-02-29T00:00:00Z"), Some(1_709_164_800_000));
    for bad in [
        "2026-10-25 12:00:00Z",
        "2026-10-25t12:00:00Z",
        "2026-10-25T12:00:00",
        "2026-10-25T12:00:00z",
        "2026-10-25T12:00:00+0200",
        "2026-10-25T12:00:00+24:00",
        "2026-10-25T12:00:00+02:60",
        "2026-10-25T12:00:00.Z",
        "2026-10-25T24:00:00Z",
        "2026-10-25T12:00:60Z",
        "2026-02-29T12:00:00Z",
        "2026-04-31T12:00:00Z",
        "2026-13-01T12:00:00Z",
        "2026-00-01T12:00:00Z",
        "1969-12-31T23:59:59Z",
        "+026-10-25T12:00:00Z",
        "2026-10-25T12:00:00Zjunk",
        "",
    ] {
        assert_eq!(rfc3339_ms(bad), None, "{bad}");
    }
}

#[test]
fn entries_are_capped_cleaned_and_a_bad_one_skipped() {
    let long = "d".repeat(500);
    let mut list = vec![
        json!({"check": "disk"}),
        json!({"detail": "no check"}),
        json!({"check": "", "detail": "empty check"}),
        json!({"check": "\u{1b}[31mdns", "detail": "an escape in the check"}),
        json!({"check": "dns", "detail": " \n\t "}),
        json!({"check": "RAM", "detail": "line one\nline two\u{1b}[0m", "since": "garbage"}),
        json!({"check": "peer", "detail": long}),
    ];
    list.extend((0..20).map(|i| json!({"check": "acpmux", "detail": format!("n{i}")})));
    let got = sanitize(&Value::Array(list));
    let got = got.as_array().unwrap();
    assert_eq!(got.len(), MAX_PROBLEMS);
    assert_eq!(got[0], json!({"check": "ram", "detail": "line one line two [0m"}));
    assert_eq!(got[1]["detail"].as_str().unwrap().chars().count(), MAX_DETAIL);
    assert_eq!(got[2]["detail"], "n0");
    assert_eq!(sanitize(&json!("dns")), json!([]));
    assert_eq!(sanitize(&Value::Null), json!([]));
}
