//! How long the file that a swap replaced stays: the rule of 7 days AND 3
//! full starts, with the clock given by the test.

use std::path::PathBuf;
use std::time::Instant;

use rusqlite::Connection;

use super::*;

const DAY_MS: u64 = 24 * 60 * 60 * 1_000;
/// The time of the swap in each registry of these tests.
const SWAPPED_AT_MS: u64 = 1_700_000_000_000;

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("cmux-output-cleanup-backup-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn registry_with_meta(path: &Path, entries: &[(&str, &str)]) {
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        .unwrap();
    for (key, value) in entries {
        connection.execute("INSERT INTO meta(key, value) VALUES(?1, ?2)", [key, value]).unwrap();
    }
}

/// A registry that a swap made at [`SWAPPED_AT_MS`], with `full_starts`
/// counted on it. The file the swap replaced is at `backup`.
fn swapped(name: &str, full_starts: u64, backup: fn(&Path) -> PathBuf) -> PathBuf {
    let db_path = temp_dir(name).join("workspace-registry.sqlite3");
    registry_with_meta(
        &db_path,
        &[
            ("registry_id", "r1"),
            (DONE_META_KEY, &format!("{{\"at_ms\":\"{SWAPPED_AT_MS}\",\"kept\":\"5\"}}")),
            (FULL_STARTS_META_KEY, &full_starts.to_string()),
        ],
    );
    registry_with_meta(&backup(&db_path), &[("registry_id", "r1"), ("old", "1")]);
    db_path
}

/// One open of the registry at the time `now_ms`.
fn open_at(db_path: &Path, now_ms: u64) {
    NOW_MS_FOR_TEST.with(|now| now.set(Some(now_ms)));
    keep_or_remove_previous_registry(db_path);
    NOW_MS_FOR_TEST.with(|now| now.set(None));
}

fn wait_until_gone(path: &Path) -> bool {
    let deadline = Instant::now() + Duration::from_secs(20);
    while path.exists() && Instant::now() < deadline {
        std::thread::yield_now();
    }
    !path.exists()
}

#[test]
fn the_kept_file_stays_at_6_days_with_3_full_starts() {
    let db_path = swapped("six-days", 3, kept_path);
    let now = SWAPPED_AT_MS + 6 * DAY_MS;
    assert_eq!(kept_file_due(&db_path, now), None, "6 days is under the 7 days of the rule");
    open_at(&db_path, now);
    assert!(kept_path(&db_path).is_file(), "an open at 6 days removed the kept file");
    // One millisecond before the 7 days: still kept.
    assert_eq!(kept_file_due(&db_path, SWAPPED_AT_MS + 7 * DAY_MS - 1), None);
    fs::remove_dir_all(db_path.parent().unwrap()).unwrap();
}

#[test]
fn the_kept_file_stays_at_7_days_with_2_full_starts() {
    let db_path = swapped("two-starts", 2, kept_path);
    let now = SWAPPED_AT_MS + 7 * DAY_MS;
    assert_eq!(kept_file_due(&db_path, now), None, "2 full starts are under the 3 of the rule");
    open_at(&db_path, now);
    assert!(kept_path(&db_path).is_file(), "an open after 2 full starts removed the kept file");
    // No count of days replaces the third start.
    assert_eq!(kept_file_due(&db_path, SWAPPED_AT_MS + 400 * DAY_MS), None);
    fs::remove_dir_all(db_path.parent().unwrap()).unwrap();
}

#[test]
fn the_kept_file_goes_at_7_days_with_3_full_starts() {
    let db_path = swapped("due", 3, kept_path);
    let now = SWAPPED_AT_MS + 7 * DAY_MS;
    assert_eq!(kept_file_due(&db_path, now), Some(kept_path(&db_path)));
    // A read of the kept file can leave SQLite sidecars: they go with it.
    fs::write(sidecar_path(&kept_path(&db_path), "-shm"), b"shm").unwrap();
    open_at(&db_path, now);
    assert!(
        wait_until_gone(&kept_path(&db_path)),
        "the kept file stays after 7 days and 3 full starts"
    );
    assert!(wait_until_gone(&sidecar_path(&kept_path(&db_path), "-shm")));
    assert!(db_path.is_file(), "the registry went with its kept file");
    fs::remove_dir_all(db_path.parent().unwrap()).unwrap();
}

#[test]
fn a_clock_behind_the_swap_keeps_the_file() {
    let db_path = swapped("clock-back", 9, kept_path);
    assert_eq!(kept_file_due(&db_path, SWAPPED_AT_MS - DAY_MS), None);
    assert_eq!(kept_file_due(&db_path, 0), None, "a clock that cannot be read is time 0");
    fs::remove_dir_all(db_path.parent().unwrap()).unwrap();
}

#[test]
fn a_kept_file_of_another_registry_is_never_removed() {
    let db_path = swapped("other", 9, kept_path);
    fs::remove_file(kept_path(&db_path)).unwrap();
    registry_with_meta(&kept_path(&db_path), &[("registry_id", "r2")]);
    assert_eq!(kept_file_due(&db_path, SWAPPED_AT_MS + 400 * DAY_MS), None);

    // A registry with no swap record (made again in this place).
    let plain = temp_dir("other-plain").join("workspace-registry.sqlite3");
    registry_with_meta(&plain, &[("registry_id", "r1")]);
    registry_with_meta(&kept_path(&plain), &[("registry_id", "r1")]);
    assert_eq!(kept_file_due(&plain, SWAPPED_AT_MS + 400 * DAY_MS), None);
    fs::remove_dir_all(db_path.parent().unwrap()).unwrap();
    fs::remove_dir_all(plain.parent().unwrap()).unwrap();
}

/// The first name is for the rollback window only. After one full start the
/// file gets the second name, at any time of the clock, and no start puts a
/// file of that name back in the registry's place.
#[test]
fn the_file_gets_the_kept_name_after_one_full_start_and_no_start_restores_it() {
    // No full start yet: the rollback still needs the first name.
    let db_path = swapped("window", 0, previous_path);
    open_at(&db_path, SWAPPED_AT_MS + 400 * DAY_MS);
    assert!(previous_path(&db_path).is_file(), "the file left the rollback's name too early");
    assert!(!kept_path(&db_path).exists());
    assert!(backup_held(&db_path));
    fs::remove_dir_all(db_path.parent().unwrap()).unwrap();

    let db_path = swapped("renamed", 1, previous_path);
    let old = fs::read(previous_path(&db_path)).unwrap();
    open_at(&db_path, SWAPPED_AT_MS + 400 * DAY_MS);
    assert!(!previous_path(&db_path).exists(), "the file keeps the name that a start restores");
    assert_eq!(fs::read(kept_path(&db_path)).unwrap(), old, "the kept file is not the old file");
    assert!(backup_held(&db_path));

    // The registry is gone (deleted, or moved aside by hand). A start that
    // finds `.pre-output-cleanup` alone takes it for an interrupted swap and
    // renames it in. The kept file is never taken.
    fs::remove_file(&db_path).unwrap();
    restore_interrupted_swap(&db_path);
    assert!(!db_path.exists(), "a start put the kept file back as the registry");
    assert_eq!(fs::read(kept_path(&db_path)).unwrap(), old);
    refuse_open_beside_backup(&db_path).unwrap();
    fs::remove_dir_all(db_path.parent().unwrap()).unwrap();
}

#[test]
fn a_second_previous_file_never_replaces_the_kept_one() {
    let db_path = swapped("two", 1, previous_path);
    fs::write(kept_path(&db_path), b"the older and larger file").unwrap();
    open_at(&db_path, SWAPPED_AT_MS + 400 * DAY_MS);
    assert_eq!(fs::read(kept_path(&db_path)).unwrap(), b"the older and larger file");
    assert!(previous_path(&db_path).is_file(), "the newer file was lost");
    fs::remove_dir_all(db_path.parent().unwrap()).unwrap();
}

/// A full start past the rollback window is counted for the kept file's
/// rule, and what `server-stats` says about the file follows the count.
#[test]
fn full_starts_are_counted_for_the_kept_file_and_shown() {
    let db_path = swapped("count", 1, kept_path);
    let bytes = fs::metadata(kept_path(&db_path)).unwrap().len();
    let held = held_backup(&db_path).unwrap();
    assert_eq!(
        held,
        HeldBackup {
            name: "workspace-registry.sqlite3.kept-before-cleanup".into(),
            bytes,
            swapped_at_ms: Some(SWAPPED_AT_MS),
            kept_until_ms: Some(SWAPPED_AT_MS + 7 * DAY_MS),
            full_starts: 1,
            full_starts_left: 2,
        }
    );
    note_full_start(&db_path).unwrap();
    note_full_start(&db_path).unwrap();
    let held = held_backup(&db_path).unwrap();
    assert_eq!((held.full_starts, held.full_starts_left), (3, 0));
    assert_eq!(kept_file_due(&db_path, SWAPPED_AT_MS + 7 * DAY_MS), Some(kept_path(&db_path)));

    // In the rollback window the file is shown under its first name.
    let window = swapped("count-window", 0, previous_path);
    let held = held_backup(&window).unwrap();
    assert_eq!(held.name, "workspace-registry.sqlite3.pre-output-cleanup");
    assert_eq!((held.full_starts, held.full_starts_left), (0, 3));
    // No file is held: nothing to show.
    fs::remove_file(previous_path(&window)).unwrap();
    assert_eq!(held_backup(&window), None);
    assert!(!backup_held(&window));
    fs::remove_dir_all(db_path.parent().unwrap()).unwrap();
    fs::remove_dir_all(window.parent().unwrap()).unwrap();
}
