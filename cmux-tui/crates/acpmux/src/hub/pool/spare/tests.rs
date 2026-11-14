use super::*;

fn r(harness: &str, cwd: &str, at: u64) -> Remembered {
    Remembered {
        harness: harness.into(),
        preset: None,
        cwd: cwd.into(),
        model: None,
        used_at_ms: at,
    }
}

#[test]
fn each_harness_is_remembered_once_with_its_newest_folder() {
    let mut list = vec![r("claude", "/a", 1), r("codex", "/a", 2)];
    remember(&mut list, r("claude", "/b", 3));
    assert_eq!(list, vec![r("codex", "/a", 2), r("claude", "/b", 3)]);
}

#[test]
fn an_older_shape_arriving_late_never_replaces_a_newer_one() {
    let mut list = vec![r("claude", "/b", 5)];
    remember(&mut list, r("claude", "/a", 4));
    assert_eq!(list, vec![r("claude", "/b", 5)]);
}

#[test]
fn only_a_harness_used_in_the_last_week_starts_a_spare() {
    let week = u64::try_from(RECENT.as_millis()).unwrap();
    let list = vec![r("claude", "/a", 10), r("codex", "/a", week + 20)];
    assert_eq!(recent(&list, week + 30), vec![r("codex", "/a", week + 20)]);
}

#[test]
fn the_file_round_trips_and_a_bad_file_reads_as_none() {
    let dir = std::env::temp_dir().join(format!("acpmux-spares-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(FILE);
    assert!(read_file(&path).is_empty());
    write_file(&path, vec![r("claude", "/a", 1)]).unwrap();
    assert_eq!(read_file(&path), vec![r("claude", "/a", 1)]);
    std::fs::write(&path, b"{not json").unwrap();
    assert!(read_file(&path).is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}
