use super::*;

const GIB: u64 = 1 << 30;

fn reader(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let map: BTreeMap<String, String> =
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    move |k| map.get(k).cloned()
}

#[test]
fn the_default_is_an_eighth_of_the_disk_budget_clamped() {
    assert_eq!(store_default(8 * GIB), GIB);
    assert_eq!(store_default(GIB), FLOOR);
    assert_eq!(store_default(640 * GIB), CEILING);
    assert_eq!(store_default(0), UNSIZED);
}

#[test]
fn the_knob_overrides_and_zero_turns_it_off() {
    assert_eq!(budget_from(&reader(&[]), 8 * GIB), GIB);
    assert_eq!(budget_from(&reader(&[("ACPMUX_SESSION_STORE_MB", "300")]), 8 * GIB), 300 << 20);
    assert_eq!(budget_from(&reader(&[("ACPMUX_SESSION_STORE_MB", "0")]), 8 * GIB), 0);
    assert!(compress_from(&reader(&[])));
    assert!(compress_from(&reader(&[("ACPMUX_SESSION_STORE_COMPRESS", "1")])));
    assert!(!compress_from(&reader(&[("ACPMUX_SESSION_STORE_COMPRESS", "0")])));
}

fn watch(budget: u64) -> Watch {
    Watch { budget, compress: true, ..Watch::default() }
}

#[test]
fn a_chat_over_its_budget_is_compressed_each_pass_and_told_once_then_at_each_doubling() {
    let mut w = watch(100);
    assert_eq!(w.apply(vec![("a".into(), 99, false)]), vec![]);
    assert_eq!(
        w.apply(vec![("a".into(), 100, false)]),
        vec![("a".into(), Action::Compress), ("a".into(), Action::Warn { bytes: 100 })]
    );
    // Still over, not doubled: compressed again, not told again.
    assert_eq!(w.apply(vec![("a".into(), 150, false)]), vec![("a".into(), Action::Compress)]);
    assert_eq!(
        w.apply(vec![("a".into(), 200, false)]),
        vec![("a".into(), Action::Compress), ("a".into(), Action::Warn { bytes: 200 })]
    );
    // Back between 90% and the budget: quiet, still armed off the last reading.
    assert_eq!(w.apply(vec![("a".into(), 95, false)]), vec![]);
    assert_eq!(w.apply(vec![("a".into(), 120, false)]), vec![("a".into(), Action::Compress)]);
    // Under 90%: re-armed, so the next crossing is told.
    assert_eq!(w.apply(vec![("a".into(), 50, false)]), vec![]);
    assert_eq!(
        w.apply(vec![("a".into(), 101, false)]),
        vec![("a".into(), Action::Compress), ("a".into(), Action::Warn { bytes: 101 })]
    );
}

#[test]
fn off_does_nothing_and_compress_off_only_warns() {
    let mut off = watch(0);
    assert_eq!(off.apply(vec![("a".into(), u64::MAX, false)]), vec![]);
    let mut warn_only = Watch { compress: false, ..watch(10) };
    assert_eq!(
        warn_only.apply(vec![("a".into(), 10, false)]),
        vec![("a".into(), Action::Warn { bytes: 10 })]
    );
}

#[test]
fn a_chat_no_longer_loaded_is_forgotten() {
    let mut w = watch(10);
    w.apply(vec![("a".into(), 20, false), ("b".into(), 1, false)]);
    w.apply(vec![("b".into(), 1, false)]);
    assert_eq!(w.sessions.keys().collect::<Vec<_>>(), vec!["b"]);
    // `a` back over: told again, as a new chat.
    assert_eq!(
        w.apply(vec![("a".into(), 20, false)]),
        vec![("a".into(), Action::Compress), ("a".into(), Action::Warn { bytes: 20 })]
    );
}

#[test]
fn status_lists_the_largest_and_every_one_over() {
    let mut w = watch(1000);
    let mut readings: Vec<(String, u64, bool)> =
        (0..20).map(|i| (format!("s{i:02}"), i as u64, false)).collect();
    readings.push(("big".into(), 5000, true));
    w.apply(readings);
    w.sessions.get_mut("big").unwrap().saved = 7;
    let v = w.json(true);
    assert_eq!(v["on"], true);
    assert_eq!(v["budgetBytes"], 1000);
    assert_eq!(v["sessions"], 21);
    assert_eq!(v["over"], 1);
    assert_eq!(v["totalBytes"], 5000 + (0..20).sum::<u64>());
    assert_eq!(v["tickSeconds"], TICK.as_secs());
    let rows = v["use"].as_array().unwrap();
    assert_eq!(rows.len(), LISTED);
    assert_eq!(rows[0]["session"], "big");
    assert_eq!(rows[0]["state"], "over");
    assert_eq!(rows[0]["partial"], true);
    assert_eq!(rows[0]["savedBytes"], 7);
    assert_eq!(rows[1]["session"], "s19");
    assert_eq!(watch(0).json(true)["on"], false);
}

#[test]
fn the_measure_counts_the_log_and_background_output_and_stops_at_its_bound() {
    let dir = tempfile::tempdir().unwrap();
    let chat = dir.path().join("sessions").join("c");
    std::fs::create_dir_all(chat.join("events")).unwrap();
    std::fs::write(chat.join("session.json"), vec![0u8; 100]).unwrap();
    std::fs::write(chat.join("events").join("000001.ndjson"), vec![0u8; 1000]).unwrap();
    let bg = dir.path().join("bg").join("c");
    std::fs::create_dir_all(&bg).unwrap();
    std::fs::write(bg.join("out.log"), vec![0u8; 10]).unwrap();
    assert_eq!(measure(Some(&chat), &bg), (1110, false));
    assert_eq!(measure(None, &bg), (10, false));
    assert_eq!(measure(Some(&chat), &dir.path().join("missing")), (1100, false));
    let mut left = 1;
    let (_, partial) = dir_bytes(&chat, &mut left);
    assert!(partial);
}
