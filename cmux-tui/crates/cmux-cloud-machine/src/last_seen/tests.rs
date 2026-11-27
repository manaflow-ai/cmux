use super::*;
use serde_json::json;

const NOW: i64 = 1_800_000_000_000;

fn row(id: &str) -> Row {
    Row {
        id: id.into(),
        name: format!("{id}-name"),
        stage: "ready".into(),
        evict_at: None,
        size: None,
    }
}

#[test]
fn round_trips_for_the_same_account() {
    let rows = vec![row("a"), Row { evict_at: Some(5), size: Some(json!({"cpu": 4})), ..row("b") }];
    let text = encode("u1", Some("t1"), NOW - 1000, &rows).unwrap();
    let back = decode(&text, "u1", Some("t1"), NOW).unwrap();
    assert_eq!(back.machines, rows);
    assert_eq!(back.at, NOW - 1000);
}

#[test]
fn another_user_or_team_never_reads_it() {
    let text = encode("u1", Some("t1"), NOW, &[row("a")]).unwrap();
    assert!(decode(&text, "u2", Some("t1"), NOW).is_none());
    assert!(decode(&text, "u1", Some("t2"), NOW).is_none());
    assert!(decode(&text, "u1", None, NOW).is_none());
    assert!(decode(&text, "", Some("t1"), NOW).is_none());
}

#[test]
fn signed_out_keeps_nothing() {
    assert!(encode("", Some("t1"), NOW, &[row("a")]).is_none());
}

#[test]
fn too_old_or_too_far_ahead_is_not_shown() {
    let old = encode("u", None, NOW - MAX_AGE_MS - 1, &[row("a")]).unwrap();
    assert!(decode(&old, "u", None, NOW).is_none());
    let edge = encode("u", None, NOW - MAX_AGE_MS, &[row("a")]).unwrap();
    assert!(decode(&edge, "u", None, NOW).is_some());
    let ahead = encode("u", None, NOW + MAX_SKEW_MS + 1, &[row("a")]).unwrap();
    assert!(decode(&ahead, "u", None, NOW).is_none());
}

#[test]
fn another_version_or_garbage_is_ignored() {
    let text =
        encode("u", None, NOW, &[row("a")]).unwrap().replace("\"version\":1", "\"version\":2");
    assert!(decode(&text, "u", None, NOW).is_none());
    assert!(decode("not json", "u", None, NOW).is_none());
    assert!(decode("{}", "u", None, NOW).is_none());
}

#[test]
fn an_empty_list_is_a_list() {
    let text = encode("u", None, NOW, &[]).unwrap();
    assert_eq!(decode(&text, "u", None, NOW).unwrap().machines, vec![]);
}

#[test]
fn unusable_rows_and_extra_rows_are_dropped() {
    let mut rows: Vec<Row> = (0..MAX_ROWS + 5).map(|i| row(&i.to_string())).collect();
    rows.insert(0, Row { name: String::new(), ..row("x") });
    let text = encode("u", None, NOW, &rows).unwrap();
    let back = decode(&text, "u", None, NOW).unwrap();
    assert_eq!(back.machines.len(), MAX_ROWS);
    assert_eq!(back.machines[0].id, "0");
}

#[test]
fn file_names_differ_by_account_and_are_recognised() {
    let a = file_name("u", Some("t"));
    assert_ne!(a, file_name("u", None));
    assert_ne!(a, file_name("u", Some("")));
    assert_ne!(a, file_name("ut", None));
    assert_eq!(a, file_name("u", Some("t")));
    assert!(is_file_name(&a));
    assert!(!is_file_name("machines-xyz.json"));
    assert!(!is_file_name("machine-credential.json"));
    assert!(!is_file_name("machines-0123456789abcdef.json.tmp"));
}

#[test]
fn temp_files_of_kept_lists_are_recognised() {
    let kept = file_name("u1", Some("t1"));
    assert!(is_temp_file_name(&format!("{kept}.123.tmp")));
    assert!(!is_temp_file_name(&format!("{kept}.tmp")));
    assert!(!is_temp_file_name(&format!("{kept}.12a.tmp")));
    assert!(!is_temp_file_name(&format!("{kept}.123")));
    assert!(!is_temp_file_name("notes.json.123.tmp"));
    assert!(!is_temp_file_name(&kept));
}

#[test]
fn an_unchanged_list_is_not_written_again_within_the_hour() {
    let rows = vec![row("a"), row("b")];
    let text = encode("u1", Some("t1"), NOW, &rows).unwrap();
    assert!(unchanged(&text, "u1", Some("t1"), NOW + 1, &rows));
    // Rows left out of the file anyway (no id) do not make it a change.
    let with_blank = vec![row("a"), Row { id: String::new(), ..row("x") }, row("b")];
    assert!(unchanged(&text, "u1", Some("t1"), NOW + 1, &with_blank));
    // Any change, another account, an hour on, or a clock moved back writes it.
    assert!(!unchanged(&text, "u1", Some("t1"), NOW + 1, &[row("a")]));
    assert!(!unchanged(
        &text,
        "u1",
        Some("t1"),
        NOW + 1,
        &[Row { stage: "paused".into(), ..row("a") }, row("b")]
    ));
    assert!(!unchanged(&text, "u2", Some("t1"), NOW + 1, &rows));
    assert!(!unchanged(&text, "u1", None, NOW + 1, &rows));
    assert!(!unchanged(&text, "u1", Some("t1"), NOW + REWRITE_AFTER_MS, &rows));
    assert!(!unchanged(&text, "u1", Some("t1"), NOW - 1, &rows));
    assert!(!unchanged("not json", "u1", Some("t1"), NOW, &rows));
    assert!(!unchanged(&text, "", Some("t1"), NOW + 1, &rows));
}

#[test]
fn failed_refreshes_back_off_doubling_to_a_cap() {
    assert_eq!(refresh_backoff_ms(0), 0);
    assert_eq!(refresh_backoff_ms(1), REFRESH_BACKOFF_MIN_MS);
    assert_eq!(refresh_backoff_ms(2), 2 * REFRESH_BACKOFF_MIN_MS);
    assert_eq!(refresh_backoff_ms(3), 4 * REFRESH_BACKOFF_MIN_MS);
    assert_eq!(refresh_backoff_ms(40), REFRESH_BACKOFF_MAX_MS);
    assert_eq!(refresh_backoff_ms(u32::MAX), REFRESH_BACKOFF_MAX_MS);
    assert!(refresh_due(0, None));
    assert!(refresh_due(5, None));
    assert!(refresh_due(0, Some(0)));
    assert!(!refresh_due(1, Some(REFRESH_BACKOFF_MIN_MS - 1)));
    assert!(refresh_due(1, Some(REFRESH_BACKOFF_MIN_MS)));
    assert!(!refresh_due(3, Some(4 * REFRESH_BACKOFF_MIN_MS - 1)));
    assert!(!refresh_due(1, Some(-10_000)));
}
