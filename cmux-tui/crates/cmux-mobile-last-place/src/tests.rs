use super::*;

use std::sync::atomic::{AtomicU64, Ordering};

/// A fresh directory under the system temp dir, removed when dropped.
struct Dir(PathBuf);

impl Dir {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("cmux-last-place-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn file(&self) -> PathBuf {
        self.0.join("state").join("last-place.json")
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn chat(workspace: &str, item: &str, row: &str, offset: f64) -> LastPlace {
    LastPlace {
        workspace: workspace.into(),
        screen: Some(Screen::Chat),
        item: Some(item.into()),
        scroll: Some(ScrollAnchor { row: row.into(), offset }),
        selection: Some(item.into()),
    }
}

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|id| (*id).to_owned()).collect()
}

#[test]
fn save_then_read_round_trips() {
    let dir = Dir::new();
    let place = chat("w1", "c7", "msg-42", 12.5);
    write(&dir.file(), Some(&place)).unwrap();
    assert_eq!(read(&dir.file()), (Some(place), ReadOutcome::Read));

    let terminal = LastPlace {
        workspace: "w2".into(),
        screen: Some(Screen::Terminal),
        item: Some("t3".into()),
        scroll: Some(ScrollAnchor { row: "9001".into(), offset: 0.0 }),
        selection: None,
    };
    write(&dir.file(), Some(&terminal)).unwrap();
    assert_eq!(read(&dir.file()), (Some(terminal), ReadOutcome::Read));
    assert!(!tmp_path(&dir.file()).exists(), "the temp file is renamed away");
}

#[test]
fn the_list_is_a_place_too() {
    let dir = Dir::new();
    write(&dir.file(), Some(&chat("w1", "c1", "r", 0.0))).unwrap();
    write(&dir.file(), None).unwrap();
    assert_eq!(read(&dir.file()), (None, ReadOutcome::Read));
}

#[test]
fn missing_file_is_no_place() {
    let dir = Dir::new();
    assert_eq!(read(&dir.file()), (None, ReadOutcome::Missing));
    let store = Store::open(dir.file(), 300, 2000);
    assert_eq!(store.read_outcome(), ReadOutcome::Missing);
    assert_eq!(store.restore(&ids(&["w1"]), None), Restore::List);
}

#[test]
fn corrupt_files_are_no_place() {
    let dir = Dir::new();
    fs::create_dir_all(dir.file().parent().unwrap()).unwrap();
    for body in [
        &b""[..],
        b"{",
        b"\x00\xff garbage",
        b"[]",
        b"{\"place\":{\"workspace\":\"w1\"}}",
        b"{\"v\":\"1\",\"place\":{\"workspace\":\"w1\"}}",
        b"{\"v\":1,\"place\":{\"workspace\":\"\"}}",
        b"{\"v\":1,\"place\":{\"screen\":\"chat\"}}",
        b"{\"v\":1,\"place\":{\"workspace\":\"w1\",\"screen\":\"browser\"}}",
        b"{\"v\":1,\"place\":{\"workspace\":7}}",
    ] {
        fs::write(dir.file(), body).unwrap();
        assert_eq!(
            read(&dir.file()),
            (None, ReadOutcome::Corrupt),
            "{}",
            String::from_utf8_lossy(body)
        );
    }

    // The next save replaces a corrupt file.
    let mut store = Store::open(dir.file(), 0, 0);
    assert_eq!(store.read_outcome(), ReadOutcome::Corrupt);
    let place = chat("w1", "c1", "r1", 3.0);
    assert_eq!(store.note(Some(place.clone()), 10), Note::Written);
    assert_eq!(read(&dir.file()), (Some(place), ReadOutcome::Read));
}

#[test]
fn newer_version_and_oversized_files_are_no_place() {
    let dir = Dir::new();
    fs::create_dir_all(dir.file().parent().unwrap()).unwrap();
    fs::write(dir.file(), br#"{"v":2,"place":{"workspace":"w1"}}"#).unwrap();
    assert_eq!(read(&dir.file()), (None, ReadOutcome::OtherVersion));

    let mut big = br#"{"v":1,"place":{"workspace":"w1","selection":""#.to_vec();
    big.extend(std::iter::repeat_n(b'a', MAX_FILE_BYTES as usize));
    big.extend(br#""}}"#);
    fs::write(dir.file(), big).unwrap();
    assert_eq!(read(&dir.file()), (None, ReadOutcome::TooLarge));
}

#[test]
fn unknown_fields_and_bad_parts_are_dropped_not_fatal() {
    let dir = Dir::new();
    fs::create_dir_all(dir.file().parent().unwrap()).unwrap();
    fs::write(
        dir.file(),
        br#"{"v":1,"extra":true,"place":{"workspace":"w1","item":"","selection":"","scroll":{"row":"","offset":4.0},"later":1}}"#,
    )
    .unwrap();
    let (place, outcome) = read(&dir.file());
    assert_eq!(outcome, ReadOutcome::Read);
    assert_eq!(
        place,
        Some(LastPlace {
            workspace: "w1".into(),
            screen: None,
            item: None,
            scroll: None,
            selection: None,
        })
    );
}

#[test]
fn stale_workspace_falls_back_to_the_list() {
    let place = chat("gone", "c1", "r1", 0.0);
    assert_eq!(resolve(Some(&place), &ids(&["w1", "w2"]), None), Restore::List);
    // Nothing cached to check against: the list, never a screen that then disappears.
    assert_eq!(resolve(Some(&place), &[], None), Restore::List);
    assert_eq!(resolve(None, &ids(&["w1"]), None), Restore::List);
}

#[test]
fn live_workspace_restores_whole() {
    let place = chat("w2", "c1", "r1", 8.0);
    assert_eq!(
        resolve(Some(&place), &ids(&["w1", "w2"]), Some(&ids(&["c0", "c1"]))),
        Restore::Place(place.clone())
    );
    // The cache does not know the workspace's items: keep the item.
    assert_eq!(resolve(Some(&place), &ids(&["w2"]), None), Restore::Place(place));
}

#[test]
fn stale_item_keeps_the_workspace_and_drops_its_scroll_and_selection() {
    let place = chat("w2", "closed-chat", "r1", 8.0);
    assert_eq!(
        resolve(Some(&place), &ids(&["w2"]), Some(&ids(&["c0"]))),
        Restore::Place(LastPlace {
            workspace: "w2".into(),
            screen: Some(Screen::Chat),
            item: None,
            scroll: None,
            selection: None,
        })
    );
}

#[test]
fn store_restores_what_the_last_session_saved() {
    let dir = Dir::new();
    let place = chat("w1", "c1", "m9", 40.0);
    {
        let mut store = Store::open(dir.file(), 300, 2000);
        store.note(Some(place.clone()), 0);
        assert!(store.flush().unwrap());
    }
    let store = Store::open(dir.file(), 300, 2000);
    assert_eq!(store.saved(), Some(&place));
    assert_eq!(store.restore(&ids(&["w1"]), None), Restore::Place(place));
}

#[test]
fn scrolling_writes_once_per_quiet_period() {
    let dir = Dir::new();
    let mut store = Store::open(dir.file(), 300, 2000);
    assert_eq!(store.note(Some(chat("w1", "c1", "r1", 0.0)), 1000), Note::Due { at_ms: 1300 });
    assert_eq!(store.note(Some(chat("w1", "c1", "r1", 5.0)), 1100), Note::Due { at_ms: 1400 });
    assert_eq!(store.tick(1399), Note::Due { at_ms: 1400 });
    assert!(!dir.file().exists(), "nothing written inside the quiet period");
    assert_eq!(store.tick(1400), Note::Written);
    assert_eq!(read(&dir.file()).0, Some(chat("w1", "c1", "r1", 5.0)));
    assert_eq!(store.tick(5000), Note::Unchanged);
    // The same place again writes nothing.
    assert_eq!(store.note(Some(chat("w1", "c1", "r1", 5.0)), 6000), Note::Unchanged);
}

#[test]
fn a_long_scroll_still_saves_by_its_longest_wait() {
    let dir = Dir::new();
    let mut store = Store::open(dir.file(), 300, 2000);
    let mut written = 0;
    for step in 0..100u32 {
        let now = 1000 + u64::from(step) * 50;
        if store.note(Some(chat("w1", "c1", "r1", f64::from(step))), now) == Note::Written {
            written += 1;
        }
    }
    // 5 s of changes every 50 ms: one write per 2 s of longest wait, none per quiet period.
    assert_eq!(written, 2);
    assert!(store.flush().unwrap());
    assert_eq!(read(&dir.file()).0, Some(chat("w1", "c1", "r1", 99.0)));
}

#[test]
fn going_back_to_the_saved_place_cancels_the_write() {
    let dir = Dir::new();
    let mut store = Store::open(dir.file(), 300, 2000);
    let saved = chat("w1", "c1", "r1", 0.0);
    store.note(Some(saved.clone()), 0);
    store.flush().unwrap();
    let modified = fs::metadata(dir.file()).unwrap().modified().unwrap();
    store.note(Some(chat("w2", "c2", "r2", 0.0)), 100);
    assert_eq!(store.note(Some(saved.clone()), 150), Note::Unchanged);
    assert!(!store.flush().unwrap());
    assert_eq!(fs::metadata(dir.file()).unwrap().modified().unwrap(), modified);
    assert_eq!(store.latest(), Some(&saved));
}

#[test]
fn leaving_for_the_list_is_saved() {
    let dir = Dir::new();
    let mut store = Store::open(dir.file(), 0, 0);
    store.note(Some(chat("w1", "c1", "r1", 0.0)), 0);
    assert_eq!(store.note(None, 10), Note::Written);
    let store = Store::open(dir.file(), 0, 0);
    assert_eq!(store.read_outcome(), ReadOutcome::Read);
    assert_eq!(store.restore(&ids(&["w1"]), None), Restore::List);
}

#[test]
fn a_failed_write_stays_pending() {
    let dir = Dir::new();
    // The file's directory is a file: every write fails.
    fs::write(dir.0.join("state"), b"not a dir").unwrap();
    let mut store = Store::open(dir.file(), 0, 0);
    assert_eq!(store.read_outcome(), ReadOutcome::Unreadable);
    let place = chat("w1", "c1", "r1", 0.0);
    assert_eq!(store.note(Some(place.clone()), 10), Note::Failed { at_ms: 10 });
    assert!(store.flush().is_err());
    assert_eq!(store.latest(), Some(&place));
    fs::remove_file(dir.0.join("state")).unwrap();
    assert!(store.flush().unwrap());
    assert_eq!(read(&dir.file()).0, Some(place));
}

#[test]
fn launch_read_is_small_and_constant() {
    // The launch read is one file of at most MAX_FILE_BYTES, whatever the number of workspaces.
    let dir = Dir::new();
    write(&dir.file(), Some(&chat("w1", "c1", "r1", 0.0))).unwrap();
    assert!(fs::metadata(dir.file()).unwrap().len() < 512);
    let many: Vec<String> = (0..10_000).map(|n| format!("w{n}")).collect();
    let store = Store::open(dir.file(), 300, 2000);
    assert!(matches!(store.restore(&many, None), Restore::Place(_)));
}

#[test]
fn a_new_location_keeps_the_scroll_of_the_same_item_only() {
    let dir = Dir::new();
    let mut store = Store::open(dir.file(), 0, 0);
    store.note_location(Some("w1".into()), Some(Screen::Chat), Some("c1".into()), 0);
    let anchor = ScrollAnchor { row: "m3".into(), offset: 7.0 };
    assert_eq!(store.note_scroll("w1", "c1", Some(anchor.clone()), 10), Note::Written);
    assert_eq!(store.saved().unwrap().selection.as_deref(), Some("c1"));
    // The same tab again (a relaunch's restore, a rebuilt page): the anchor stays.
    store.note_location(Some("w1".into()), Some(Screen::Chat), Some("c1".into()), 20);
    assert_eq!(store.scroll_for("w1", "c1"), Some(&anchor));
    // Another tab starts at its default.
    store.note_location(Some("w1".into()), Some(Screen::Terminal), Some("t1".into()), 30);
    assert_eq!(store.saved().unwrap().scroll, None);
    assert_eq!(store.scroll_for("w1", "c1"), None);
}

#[test]
fn a_scroll_elsewhere_is_not_the_place() {
    let dir = Dir::new();
    let mut store = Store::open(dir.file(), 0, 0);
    store.note_location(Some("w1".into()), Some(Screen::Chat), Some("c1".into()), 0);
    let anchor = ScrollAnchor { row: "m3".into(), offset: 0.0 };
    assert_eq!(store.note_scroll("w1", "c2", Some(anchor.clone()), 10), Note::Unchanged);
    assert_eq!(store.note_scroll("w2", "c1", Some(anchor), 10), Note::Unchanged);
    store.note_location(None, None, None, 20);
    assert_eq!(
        store.note_scroll("w1", "c1", Some(ScrollAnchor { row: "m".into(), offset: 0.0 }), 30),
        Note::Unchanged
    );
}

#[test]
fn the_launch_anchor_survives_the_first_screens() {
    let dir = Dir::new();
    let anchor = ScrollAnchor { row: "m9".into(), offset: 22.0 };
    write(&dir.file(), Some(&chat("w1", "c1", "m9", 22.0))).unwrap();
    let mut store = Store::open(dir.file(), 300, 2000);
    // The app shows Home, then the list, before the restore opens the chat.
    store.note_location(None, None, None, 0);
    store.note_location(Some("w1".into()), Some(Screen::Chat), Some("c1".into()), 5);
    assert_eq!(store.scroll_for("w1", "c1"), Some(&anchor));
    assert_eq!(store.latest().unwrap().scroll.as_ref(), Some(&anchor));
    // Following the newest row now: the saved anchor goes.
    store.note_scroll("w1", "c1", None, 50);
    assert_eq!(store.scroll_for("w1", "c1"), None);
    store.flush().unwrap();
    assert_eq!(read(&dir.file()).0.unwrap().scroll, None);
}

/// The cost this adds to launch (open + restore) and to a scroll rest (note + write), printed
/// idle and under duress (every core busy plus a writer thrashing the same disk). Run with
/// `cargo test -p cmux-mobile-last-place --lib -- --ignored --nocapture timing`.
#[test]
#[ignore = "timing, prints numbers"]
fn timing_launch_read_and_save_idle_and_under_duress() {
    use std::sync::Arc;
    use std::sync::atomic::AtomicBool;
    use std::time::Instant;

    fn pct(mut v: Vec<f64>) -> (f64, f64, f64) {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let at = |p: f64| v[((v.len() - 1) as f64 * p).round() as usize];
        (at(0.5), at(0.95), at(0.99))
    }
    fn run(label: &str) {
        let dir = Dir::new();
        let workspaces: Vec<String> = (0..200).map(|n| format!("w{n}")).collect();
        let items = ids(&["c1", "c2", "c3", "c4"]);
        let (mut launch, mut save) = (Vec::new(), Vec::new());
        for n in 0..400u64 {
            let t = Instant::now();
            let mut store = Store::open(dir.file(), 400, 2000);
            let restored = store.restore(&workspaces, Some(&items));
            launch.push(t.elapsed().as_secs_f64() * 1e6);
            if n > 0 {
                assert!(matches!(restored, Restore::Place(_)));
            }
            let t = Instant::now();
            store.note_location(
                Some("w7".into()),
                Some(Screen::Chat),
                Some("c2".into()),
                n * 10_000,
            );
            store.note_scroll(
                "w7",
                "c2",
                Some(ScrollAnchor { row: format!("m{n}"), offset: 12.5 }),
                n * 10_000 + 1,
            );
            store.tick(n * 10_000 + 5_000);
            save.push(t.elapsed().as_secs_f64() * 1e6);
        }
        let (l50, l95, l99) = pct(launch);
        let (s50, s95, s99) = pct(save);
        println!(
            "LASTPLACE_TIMING {label}: launch open+restore p50 {l50:.1} us p95 {l95:.1} us p99 {l99:.1} us; \
             scroll rest note+write p50 {s50:.1} us p95 {s95:.1} us p99 {s99:.1} us (n=400)"
        );
    }

    run("idle");
    let stop = Arc::new(AtomicBool::new(false));
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let mut load = Vec::new();
    for _ in 0..cores * 2 {
        let stop = stop.clone();
        load.push(std::thread::spawn(move || {
            let mut x = 0u64;
            while !stop.load(Ordering::Relaxed) {
                x = x.wrapping_mul(6364136223846793005).wrapping_add(1);
            }
            x
        }));
    }
    let disk = Dir::new();
    let disk_path = disk.0.join("thrash.bin");
    {
        let stop = stop.clone();
        load.push(std::thread::spawn(move || {
            let block = vec![7u8; 1 << 20];
            while !stop.load(Ordering::Relaxed) {
                let _ = fs::write(&disk_path, &block);
                if let Ok(f) = fs::File::open(&disk_path) {
                    let _ = f.sync_all();
                }
            }
            0
        }));
    }
    run(&format!("duress ({} busy threads on {cores} cores + 1 MiB write/fsync loop)", cores * 2));
    stop.store(true, Ordering::Relaxed);
    for t in load {
        let _ = t.join();
    }
}
