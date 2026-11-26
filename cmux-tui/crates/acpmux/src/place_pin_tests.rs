use super::*;

fn machine(id: &str) -> PlaceMode {
    PlaceMode::Machine { id: id.into() }
}

/// A chat with no pin made before the cutoff is pinned where it is; one made after, Auto.
#[test]
fn no_pin_reads_pinned_when_older_than_the_cutoff_and_auto_after() {
    assert_eq!(effective(None, "mac", 10, 20), machine("mac"));
    assert_eq!(effective(None, "mac", 20, 20), PlaceMode::Auto);
    assert_eq!(effective(None, "mac", 10, 0), PlaceMode::Auto, "no cutoff: Auto");
    assert_eq!(effective(Some(PlaceMode::Cloud), "mac", 10, 20), PlaceMode::Cloud);
    assert_eq!(effective(Some(machine("studio")), "mac", 30, 20), machine("studio"));
}

/// A pin a chat has stays; an older pick wins over this machine; else this machine.
#[test]
fn the_migration_keeps_every_pick_and_pins_the_rest_here() {
    assert_eq!(plan(Some(&PlaceMode::Auto), Some(&machine("studio")), "mac"), None);
    assert_eq!(plan(Some(&PlaceMode::Cloud), None, "mac"), None);
    assert_eq!(plan(None, Some(&PlaceMode::Auto), "mac"), Some(PlaceMode::Auto));
    assert_eq!(plan(None, Some(&machine("studio")), "mac"), Some(machine("studio")));
    assert_eq!(plan(None, None, "mac"), Some(machine("mac")));
}

/// The older pin file reads as `place_set` wrote it; a missing or broken one is no picks.
#[test]
fn the_older_pin_file_reads_and_retires_beside_the_marker() {
    let home = std::env::temp_dir().join(format!("place-pin-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&home).unwrap();
    assert!(read_legacy(&home).is_empty());
    std::fs::write(home.join(LEGACY_PINS), b"not json").unwrap();
    assert!(read_legacy(&home).is_empty());
    std::fs::write(
        home.join(LEGACY_PINS),
        br#"{"a": {"mode": "cloud"}, "b": {"mode": "machine", "machine": "studio"}}"#,
    )
    .unwrap();
    let picks = read_legacy(&home);
    assert_eq!(picks.get("a"), Some(&PlaceMode::Cloud));
    assert_eq!(picks.get("b"), Some(&machine("studio")));

    assert_eq!(read_marker(&home), None);
    assert_eq!(start(&home, 7), Some(7), "not migrated yet: the migration runs with now");
    assert_eq!(cutoff(), 7);
    let report =
        Report { here: "mac".into(), at: 1, pinned: 3, from_legacy: 2, kept: 1, failed: 0 };
    write_marker(&home, &report).unwrap();
    assert_eq!(read_marker(&home), Some(report));
    assert_eq!(start(&home, 99), None, "migrated: no second run");
    assert_eq!(cutoff(), 1, "the cutoff stays the first run's");
    assert!(!home.join(LEGACY_PINS).exists());
    assert!(home.join("place-modes.json.migrated").exists(), "the older file is kept, renamed");
    let _ = std::fs::remove_dir_all(&home);
}
