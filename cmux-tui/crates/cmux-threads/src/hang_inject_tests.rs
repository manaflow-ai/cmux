//! The injection page: an arm is taken once, by its own lane in its own
//! process, inside the scope it hangs; stale and bad arms are refused.

use std::sync::Arc;
use std::time::Duration;

use super::*;

const BLOCK: Duration = Duration::from_millis(3000);

#[test]
fn an_armed_lane_is_taken_once_by_its_own_name_and_process() {
    let page = Page::new();
    page.arm("mux-conn", 7, BLOCK).unwrap();
    assert_eq!(page.take("mux-conn", 8), None, "another process");
    assert_eq!(page.take("mux-conn-x", 7), None, "a longer name is another lane");
    assert_eq!(page.take("mux", 7), None, "a prefix is another lane");
    assert_eq!(page.take("mux-conn", 7), Some(BLOCK));
    assert_eq!(page.take("mux-conn", 7), None, "taken once");
    assert_eq!(page.armed.load(Ordering::Relaxed), 0);
    assert_eq!(
        page.entries(),
        vec![EntryState { lane: "mux-conn".into(), pid: 7, block_ms: 3000, taken: true }]
    );
}

#[test]
fn a_lane_armed_twice_is_refused_until_taken_or_disarmed() {
    let page = Page::new();
    page.arm("holder-loop", 1, BLOCK).unwrap();
    assert!(matches!(page.arm("holder-loop", 1, BLOCK), Err(InjectError::AlreadyArmed)));
    page.arm("holder-loop", 2, BLOCK).unwrap();
    assert_eq!(page.disarm("holder-loop", 1), 1);
    assert_eq!(page.armed.load(Ordering::Relaxed), 1);
    page.arm("holder-loop", 1, BLOCK).unwrap();
    assert!(page.take("holder-loop", 1).is_some());
    page.arm("holder-loop", 1, BLOCK).unwrap();
}

#[test]
fn bad_names_blocks_and_pids_are_refused() {
    let page = Page::new();
    for lane in ["", "Mux-Conn", "mux conn", "lane\"", &"x".repeat(NAME_BYTES + 1)] {
        assert!(matches!(page.arm(lane, 1, BLOCK), Err(InjectError::BadLane)), "{lane:?}");
    }
    page.arm(&"x".repeat(NAME_BYTES), 1, BLOCK).unwrap();
    for block in [Duration::ZERO, MAX_BLOCK + Duration::from_millis(1)] {
        assert!(matches!(page.arm("lane", 1, block), Err(InjectError::BadBlock)));
    }
    assert!(matches!(page.arm("lane", 0, BLOCK), Err(InjectError::BadPid)));
}

#[test]
fn an_expired_arm_is_never_taken_and_frees_its_entry() {
    let page = Page::new();
    page.arm_at("journal-writer", 5, BLOCK, 1_000).unwrap();
    let after = 1_000 + millis(ARM_TTL) + 1;
    assert_eq!(page.take_armed("journal-writer", 5, after), None);
    assert_eq!(page.armed.load(Ordering::Relaxed), 0, "the fast path is quiet again");
    assert!(page.entries().is_empty());
}

#[test]
fn a_full_page_refuses_and_a_taken_entry_is_reused() {
    let page = Page::new();
    for index in 0..ENTRIES {
        page.arm(&format!("lane-{index}"), 1, BLOCK).unwrap();
    }
    assert!(matches!(page.arm("one-more", 1, BLOCK), Err(InjectError::Full)));
    assert!(page.take("lane-3", 1).is_some());
    page.arm("one-more", 1, BLOCK).unwrap();
    assert_eq!(page.armed.load(Ordering::Relaxed), ENTRIES as u64);
}

#[test]
fn concurrent_takers_take_an_entry_once() {
    let page = Arc::new(Page::new());
    page.arm("mux-line-out", 9, BLOCK).unwrap();
    let takers: Vec<_> = (0..8)
        .map(|_| {
            let page = Arc::clone(&page);
            crate::spawn("hang-inject-taker", crate::ThreadQos::Utility, move || {
                page.take("mux-line-out", 9).is_some()
            })
            .unwrap()
        })
        .collect();
    let taken = takers.into_iter().map(|taker| taker.join().unwrap());
    assert_eq!(taken.filter(|taken| *taken).count(), 1);
}

#[test]
fn a_registration_is_published_once_per_lane_and_process() {
    let page = Page::new();
    let live = |_pid| true;
    page.register_with("host-pty", 7, live).unwrap();
    page.register_with("host-pty", 7, live).unwrap();
    page.register_with("host-pty", 8, live).unwrap();
    page.register_with("host-parser", 7, live).unwrap();
    let lanes: Vec<_> =
        page.registrations_with(live).into_iter().map(|r| (r.lane, r.pid)).collect();
    assert_eq!(
        lanes,
        [("host-pty".to_owned(), 7), ("host-pty".to_owned(), 8), ("host-parser".to_owned(), 7)]
    );
    assert!(matches!(page.register_with("Bad Lane", 7, live), Err(InjectError::BadLane)));
    assert!(matches!(page.register_with("host-pty", 0, live), Err(InjectError::BadPid)));
}

#[test]
fn a_full_registry_refuses_until_a_registered_process_exits() {
    let page = Page::new();
    for pid in 1..=REGISTRATIONS as u32 {
        page.register_with("acpmux-sync", pid, |_| true).unwrap();
    }
    let all_live = |_pid| true;
    assert!(matches!(page.register_with("acpmux-sync", 500, all_live), Err(InjectError::Full)));
    let three_exited = |pid| pid != 3;
    assert!(!page.registrations_with(three_exited).iter().any(|r| r.pid == 3), "an exited process");
    page.register_with("acpmux-runtime", 500, three_exited).unwrap();
    let lanes = page.registrations_with(three_exited);
    assert!(lanes.contains(&Registered { lane: "acpmux-runtime".into(), pid: 500 }), "{lanes:?}");
    assert_eq!(lanes.len(), REGISTRATIONS, "the exited process's registration was reused");
}

/// A watcher's own page (an injected seam) is the only one it takes from.
#[test]
fn hold_if_armed_on_takes_only_from_the_page_it_is_given() {
    let mine = Page::new();
    let other = Page::new();
    other.arm("seam-lane", std::process::id(), Duration::from_millis(1)).unwrap();
    hold_if_armed_on(Some(&mine), "seam-lane");
    hold_if_armed_on(None, "seam-lane");
    assert!(!other.entries()[0].taken, "another page's arm stays");
    mine.arm("seam-lane", std::process::id(), Duration::from_millis(1)).unwrap();
    hold_if_armed_on(Some(&mine), "seam-lane");
    assert!(mine.entries()[0].taken);
}

/// The page as a mapped file, and the process's own page under a watcher.
#[cfg(unix)]
mod unix {
    use std::sync::mpsc::channel;
    use std::time::Instant;

    use super::*;
    use crate::{HangSite, HangWatcher};

    #[test]
    fn a_mapped_page_is_shared_by_two_mappings_of_its_file() {
        let dir =
            std::env::temp_dir().join(format!("cmux-hang-inject-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("page");
        let _ = std::fs::remove_file(&path);
        let first = map(&path).unwrap();
        let second = map(&path).unwrap();
        first.arm("holder-loop", 4, BLOCK).unwrap();
        assert_eq!(second.take("holder-loop", 4), Some(BLOCK), "another mapping sees the arm");
        assert!(first.entries()[0].taken);
        std::fs::write(&path, [0xAB; PAGE_BYTES]).unwrap();
        assert!(matches!(map(&path), Err(InjectError::Format)));
        let shared = dir.join("shared");
        std::fs::write(&shared, []).unwrap();
        std::fs::set_permissions(&shared, std::os::unix::fs::PermissionsExt::from_mode(0o666))
            .unwrap();
        assert!(matches!(map(&shared), Err(InjectError::NotOwned)), "others may write it");
        let link = dir.join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(matches!(map(&link), Err(InjectError::Io(_))), "never through a link");
        let _ = std::fs::remove_dir_all(&dir);
    }

    static INJECTED: HangSite = HangSite::new("hang-inject-test", Duration::from_millis(100));

    /// The process's own page, armed for its own pid: the watcher records the
    /// lane's real site once, inside the scope the injection blocked.
    #[test]
    fn an_armed_site_blocks_inside_its_scope_and_is_recorded_once() {
        let page = page().expect("the process page maps in /tmp");
        let (sink, records) = channel();
        let watcher = HangWatcher::start(Box::new(move |record| {
            let _ = sink.send(record.clone());
        }))
        .unwrap();
        page.arm("hang-inject-test", std::process::id(), Duration::from_millis(400)).unwrap();
        let started = Instant::now();
        drop(watcher.scope(&INJECTED));
        assert!(started.elapsed() >= Duration::from_millis(400), "{:?}", started.elapsed());
        let record = records.recv_timeout(Duration::from_secs(5)).expect("one hang record");
        assert_eq!((record.site, record.deadline_ms), ("hang-inject-test", 100));
        let started = Instant::now();
        drop(watcher.scope(&INJECTED));
        assert!(started.elapsed() < Duration::from_millis(100), "the arm was taken once");
        assert!(records.recv_timeout(Duration::from_millis(400)).is_err(), "no second record");
    }
}
