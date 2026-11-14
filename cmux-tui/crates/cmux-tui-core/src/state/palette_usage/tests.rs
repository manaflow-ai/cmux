use super::*;

const T0: u64 = 1_800_000_000_000;

#[test]
fn a_use_adds_one_and_decays_by_the_half_life() {
    let one = record(&Document::default(), "action:newColumn", "", T0).unwrap();
    assert_eq!(one.revision, 1);
    assert_eq!(one.entries["action:newColumn"], Entry { score: 1.0, last_used_ms: T0 });
    let two = record(&one, "action:newColumn", "", T0 + HALF_LIFE_MS).unwrap();
    assert!((two.entries["action:newColumn"].score - 1.5).abs() < 1e-9);
    assert!((decayed(&two.entries["action:newColumn"], T0 + 2 * HALF_LIFE_MS) - 0.75).abs() < 1e-9);
    assert!(two.picks.is_empty(), "no query, no learned pick");
}

#[test]
fn a_query_records_learned_picks_for_each_query_start() {
    let doc =
        record(&Document::default(), "action:palette.newAgentChat", "  New   Agent chat ", T0)
            .unwrap();
    let prefixes: Vec<&str> = doc.picks.keys().map(String::as_str).collect();
    assert_eq!(prefixes, ["n", "ne", "new", "new a", "new ag", "new age", "new agen"]);
    assert_eq!(doc.picks["new"].rows["action:palette.newAgentChat"].score, 1.0);
    assert_eq!(doc.picks["new"].last, "action:palette.newAgentChat");
    let other = record(&doc, "action:newWindow", "new w", T0 + 1).unwrap();
    assert_eq!(other.picks["new"].last, "action:newWindow");
    assert_eq!(other.picks["new"].rows.len(), 2);
    let week = record(&Document::default(), "action:x", "x", T0).unwrap();
    assert!(
        (decayed_pick(&week.picks["x"].rows["action:x"], T0 + PICK_HALF_LIFE_MS) - 0.5).abs()
            < 1e-9
    );
}

#[test]
fn rows_and_picks_are_bounded_least_recent_first() {
    let mut doc = Document::default();
    for index in 0..(MAX_ENTRIES + 3) {
        doc = record(&doc, &format!("action:a{index}"), "x", T0 + index as u64).unwrap();
    }
    assert_eq!(doc.entries.len(), MAX_ENTRIES);
    assert!(!doc.entries.contains_key("action:a0"));
    assert!(doc.entries.contains_key(&format!("action:a{}", MAX_ENTRIES + 2)));
    assert_eq!(doc.picks["x"].rows.len(), MAX_PICKS_PER_PREFIX);
    let mut doc = Document::default();
    for index in 0..(MAX_PICK_PREFIXES + 5) {
        doc = record(&doc, "action:a", &format!("q{index:05}"), T0 + index as u64).unwrap();
    }
    assert!(doc.picks.len() <= MAX_PICK_PREFIXES);
    assert!(doc.picks.contains_key(&format!("q{:05}", MAX_PICK_PREFIXES + 4)[..6]));
}

#[test]
fn faded_rows_and_picks_are_forgotten_at_the_next_use() {
    let old = record(&Document::default(), "action:old", "o", T0).unwrap();
    let later = T0 + 30 * HALF_LIFE_MS;
    let next = record(&old, "action:new", "n", later).unwrap();
    assert!(!next.entries.contains_key("action:old"), "a row 30 half-lives old is gone");
    assert!(next.picks.contains_key("o"), "a pick fades slower (7-day half-life)");
    let much_later = record(&next, "action:new", "n", T0 + 30 * PICK_HALF_LIFE_MS).unwrap();
    assert!(!much_later.picks.contains_key("o"));
}

#[test]
fn rejects_empty_or_huge_keys() {
    assert_eq!(record(&Document::default(), " ", "", T0), Err(Reject::KeyRequired));
    let long = "k".repeat(MAX_KEY_CHARS + 1);
    assert_eq!(record(&Document::default(), &long, "", T0), Err(Reject::KeyTooLong));
    assert_eq!(import(&Document::default(), "", &[], T0), Err(Reject::SourceRequired));
}

#[test]
fn an_import_merges_once_per_source() {
    let used = record(&Document::default(), "action:newColumn", "", T0).unwrap();
    let old = vec![
        ("action:newColumn".to_string(), Entry { score: 4.0, last_used_ms: T0 - HALF_LIFE_MS }),
        ("action:splitRight".to_string(), Entry { score: 2.0, last_used_ms: T0 }),
        ("".to_string(), Entry { score: 9.0, last_used_ms: T0 }),
        ("action:nan".to_string(), Entry { score: f64::NAN, last_used_ms: T0 }),
    ];
    let merged = import(&used, "com.cmuxterm.app.debug.nxdog70.v1", &old, T0).unwrap();
    assert_eq!(merged.revision, used.revision + 1);
    assert!((merged.entries["action:newColumn"].score - 3.0).abs() < 1e-9, "1 + 4 halved");
    assert_eq!(merged.entries["action:newColumn"].last_used_ms, T0);
    assert_eq!(merged.entries["action:splitRight"].score, 2.0);
    assert_eq!(merged.entries.len(), 2, "invalid rows are skipped");
    let again = import(&merged, "com.cmuxterm.app.debug.nxdog70.v1", &old, T0 + 5).unwrap();
    assert_eq!(again, merged, "a source imports once");
}

#[test]
fn a_newer_daemons_keys_survive_a_round_trip() {
    let text = r#"{"revision":3,"entries":{},"picks":{},"imported":[],"aliases":{"x":1}}"#;
    let doc: Document = serde_json::from_str(text).unwrap();
    let next = record(&doc, "action:x", "", T0).unwrap();
    assert_eq!(serde_json::to_value(&next).unwrap()["aliases"], serde_json::json!({"x": 1}));
}
