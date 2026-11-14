use super::*;

const MB: u64 = 1024 * 1024;

fn with(key: &str, record: KeyStats) -> Stats {
    let mut stats = Stats::default();
    stats.keys.insert(key.into(), record);
    stats
}

#[test]
fn restores_without_a_cold_record() {
    assert_eq!(Stats::default().choose("k"), Choice::Restore);
    let s = with("k", KeyStats { archive_bytes: Some(200 * MB), ..KeyStats::default() });
    assert_eq!(s.choose("k"), Choice::Restore);
}

#[test]
fn a_fast_cold_install_beats_a_big_download() {
    // The bench VM: bun's 185 MB archive against a 0.7 s cold install.
    let s = with(
        "bun-x",
        KeyStats { cold_ms: Some(710), archive_bytes: Some(185 * MB), ..KeyStats::default() },
    );
    assert!(matches!(s.choose("bun-x"), Choice::Cold { cold_ms: 710, .. }));
}

#[test]
fn a_slow_cold_install_restores() {
    let s = with(
        "cargo-x",
        KeyStats { cold_ms: Some(40_000), archive_bytes: Some(111 * MB), ..KeyStats::default() },
    );
    assert_eq!(s.choose("cargo-x"), Choice::Restore);
}

#[test]
fn a_measured_restore_wins_over_the_estimate() {
    let s = with(
        "k",
        KeyStats {
            cold_ms: Some(2_000),
            warm_ms: Some(3_000),
            archive_bytes: Some(MB),
            ..KeyStats::default()
        },
    );
    assert!(matches!(s.choose("k"), Choice::Cold { expected_ms: 3_000, .. }));
    let s = with(
        "k",
        KeyStats {
            cold_ms: Some(2_000),
            warm_ms: Some(1_000),
            archive_bytes: Some(500 * MB),
            ..KeyStats::default()
        },
    );
    assert_eq!(s.choose("k"), Choice::Restore);
}

#[test]
fn the_measured_speed_is_used() {
    let mut s = Stats { download_bps: Some(10.0 * MB as f64), ..Stats::default() };
    s.unpack_bps = Some(1_000.0 * MB as f64);
    // 100 MB at 10 MB/s plus 0.1 s unpack.
    assert_eq!(s.expected_restore_ms(100 * MB), 10_100);
}

#[test]
fn a_slow_download_is_given_up() {
    let s = Stats::default();
    // 10 MB of 200 MB in 1 s: 20 s to go, against a 5 s cold install.
    assert!(s.too_slow("bun-x", 5_000, 10 * MB, 200 * MB, 1_000));
    // 100 MB of 200 MB in 1 s: 1 s more, 0.7 s to unpack, 0.25 s to install.
    assert!(!s.too_slow("bun-x", 5_000, 100 * MB, 200 * MB, 1_000));
    // Against a 3 s cold Cargo fetch, its offline fetch (65%) tips that download over.
    assert!(s.too_slow("cargo-x", 3_000, 100 * MB, 200 * MB, 1_000));
    assert!(!s.too_slow("bun-x", 3_000, 100 * MB, 200 * MB, 1_000));
}

#[test]
fn the_uploaders_record_decides_on_a_new_machine() {
    let s = Stats::default();
    assert!(matches!(s.choose_from("bun-x", 710, 185 * MB), Choice::Cold { cold_ms: 710, .. }));
    assert_eq!(s.choose_from("cargo-x", 40_000, 111 * MB), Choice::Restore);
}

#[test]
fn the_install_after_a_restore_counts() {
    // The bench VM's Cargo: 2.67 s cold, a 106 MB archive (1.4 s to fetch and
    // unpack) and a 1.67 s offline fetch after it: cold is faster.
    let mut s = Stats::default();
    assert!(matches!(s.choose_from("cargo-x", 2_670, 106 * MB), Choice::Cold { .. }));
    // Where the offline fetch measured fast, the restore wins.
    s.learn_after_restore("cargo-y", 100, 2_670);
    assert_eq!(s.choose_from("cargo-x", 2_670, 106 * MB), Choice::Restore);
    assert_eq!(s.after_restore_ms("bun-x", 1_000), 50);
}

#[test]
fn trims_to_the_newest_keys() {
    let mut s = Stats::default();
    for i in 0..(MAX_KEYS + 5) {
        s.keys.insert(format!("k{i}"), KeyStats { updated: i as u64, ..KeyStats::default() });
    }
    s.trim();
    assert_eq!(s.keys.len(), MAX_KEYS);
    assert!(!s.keys.contains_key("k0"));
    assert!(s.keys.contains_key(&format!("k{}", MAX_KEYS + 4)));
}
