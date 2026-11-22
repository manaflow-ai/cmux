use super::{HiddenHistory, HiddenRange, hidden_id};

const NOW: i64 = 1_800_000_000_000;

#[test]
fn clear_hides_the_range_but_not_later_activity() {
    let mut hidden = HiddenHistory::new();
    hidden.hide_range(Some(NOW - 3_600_000), NOW, None);
    assert!(hidden.hides("a", NOW - 60_000, None));
    assert!(!hidden.hides("a", NOW - 7_200_000, None));
    assert!(!hidden.hides("a", NOW + 60_000, None));
    hidden.hide_range(None, NOW, None);
    assert!(hidden.hides("b", HiddenHistory::DISTANT_PAST_MS + 1_000, None));
}

#[test]
fn single_entries_stay_hidden_and_round_trip() {
    let mut hidden = HiddenHistory::new();
    hidden.hide_entry("local/claude/x");
    hidden.hide_entry("local/claude/x");
    assert_eq!(hidden.entries(), ["local/claude/x"]);
    let json = serde_json::to_string(&hidden).unwrap();
    let decoded: HiddenHistory = serde_json::from_str(&json).unwrap();
    assert!(decoded.hides("local/claude/x", NOW + 1_000_000_000, None));
    assert_eq!(decoded, hidden);
}

#[test]
fn a_kinded_clear_hides_only_that_kind() {
    let mut hidden = HiddenHistory::new();
    hidden.hide_range(None, NOW, Some("command"));
    assert!(hidden.hides("c", NOW - 5_000, Some("command")));
    assert!(!hidden.hides("a", NOW - 5_000, Some("agent")));
}

#[test]
fn merge_keeps_every_clear() {
    let mut a = HiddenHistory::new();
    a.hide_entry("one");
    let mut b = HiddenHistory::new();
    b.hide_range(Some(NOW - 10_000), NOW, None);
    let merged = a.merged(&b);
    assert!(merged.hides("one", HiddenHistory::DISTANT_PAST_MS, None));
    assert!(merged.hides("two", NOW - 5_000, None));
}

#[test]
fn limits_drop_the_oldest() {
    let mut hidden = HiddenHistory::new();
    for n in 0..70 {
        hidden.hide_range(Some(n), n + 1, None);
    }
    assert_eq!(hidden.ranges().len(), HiddenHistory::RANGE_LIMIT);
    assert_eq!(hidden.ranges()[0].from_ms, 6);
    for n in 0..2_005 {
        hidden.hide_entry(&format!("id{n}"));
    }
    assert_eq!(hidden.entries().len(), HiddenHistory::ENTRY_LIMIT);
    assert_eq!(hidden.entries()[0], "id5");
}

#[test]
fn decodes_the_swift_document() {
    // Swift JSONEncoder output: Dates as seconds since 2001-01-01.
    let json = r#"{"ranges":[{"from":821689200,"until":821692800,"kind":"agent"},
        {"from":-63114076800,"until":821692800}],"entries":["home/codex/s"]}"#;
    let hidden: HiddenHistory = serde_json::from_str(json).unwrap();
    assert_eq!(
        hidden.ranges()[0],
        HiddenRange { from_ms: NOW - 3_600_000, until_ms: NOW, kind: Some("agent".to_owned()) }
    );
    assert_eq!(hidden.ranges()[1].from_ms, HiddenHistory::DISTANT_PAST_MS);
    let back = serde_json::to_value(&hidden).unwrap();
    assert_eq!(back["ranges"][0]["from"], 821_689_200.0);
    assert!(back["ranges"][1].get("kind").is_none());
}

#[test]
fn hidden_ids_strip_the_kind_prefix() {
    assert_eq!(hidden_id("agent:home/claude/s"), Some("home/claude/s"));
    assert_eq!(hidden_id("command:home/t/1"), Some("home/t/1"));
    assert_eq!(hidden_id("page:default:1"), None);
}
