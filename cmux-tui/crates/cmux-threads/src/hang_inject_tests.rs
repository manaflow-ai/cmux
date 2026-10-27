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
