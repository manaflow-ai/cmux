use super::*;

#[test]
fn request_path_note_outside_a_scope_counts_nothing() {
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let other = RequestPathStats::new(RequestPathMode::OFF);
    {
        let _scope = RequestPathScope::enter(&stats);
        assert_eq!(note(BlockingKind::Sqlite), Noted::Recorded);
    }
    // The scope ended: the same note reaches no stats.
    assert!(!in_scope());
    assert_eq!(note(BlockingKind::Sqlite), Noted::Outside);
    {
        let _other = RequestPathScope::enter(&other);
        assert_eq!(note(BlockingKind::Sqlite), Noted::Counted);
    }
    assert_eq!(stats.count(BlockingKind::Sqlite), 1, "only the note inside its scope");
    assert_eq!(stats.handler_runs(), 1);
    assert_eq!(stats.sites().len(), 1);
    assert_eq!(other.count(BlockingKind::Sqlite), 1);
}

#[test]
fn request_path_note_feeds_the_thread_blocking_detector_at_the_same_site() {
    // This test reads the recorded site, so it must not depend on the Debug
    // default (a panic) or on CMUX_DAEMON_BLOCKING.
    cmux_threads::blocking::set_mode(cmux_threads::blocking::BlockingMode::Record);
    let stats = RequestPathStats::new(RequestPathMode::OFF);
    let (line, hold_line) = std::thread::spawn(move || {
        let _scope = RequestPathScope::enter(&stats);
        cmux_threads::blocking::disallow_blocking();
        let line = line!() + 1;
        note(BlockingKind::Sqlite);
        let hold_line = line!() + 1;
        note(BlockingKind::LockHoldOver1ms);
        assert_eq!(stats.count(BlockingKind::Sqlite), 1);
        (line, hold_line)
    })
    .join()
    .expect("note thread");
    let snapshot = cmux_threads::blocking::snapshot();
    let site = snapshot.site(file!(), line).expect("a violation at the note's caller");
    assert!(site.kinds.contains(cmux_threads::blocking::BlockingKind::Sqlite));
    assert!(snapshot.site(file!(), hold_line).is_none(), "a lock hold is not a blocking call");
}

#[test]
fn request_path_sleep_reaches_the_thread_blocking_detector_once_at_its_caller() {
    cmux_threads::blocking::set_mode(cmux_threads::blocking::BlockingMode::Record);
    let stats = RequestPathStats::new(RequestPathMode::OFF);
    let line = cmux_threads::spawn("request-path-sleep-probe", cmux_threads::ThreadQos::Utility, {
        let stats = stats.clone();
        move || {
            let _scope = RequestPathScope::enter(&stats);
            cmux_threads::blocking::disallow_blocking();
            let line = line!() + 1;
            sleep(Duration::ZERO);
            line
        }
    })
    .expect("sleep thread")
    .join()
    .expect("sleep thread");
    assert_eq!(stats.count(BlockingKind::Sleep), 1);
    let snapshot = cmux_threads::blocking::snapshot();
    let site = snapshot.site(file!(), line).expect("a violation at the sleep's caller");
    assert!(site.kinds.contains(cmux_threads::blocking::BlockingKind::Sleep));
    assert_eq!(site.count, 1, "one check per sleep");
}

#[test]
fn request_path_sleep_is_noted_at_its_caller() {
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let line = line!() + 1;
    sleep(Duration::ZERO);
    assert_eq!(stats.count(BlockingKind::Sleep), 1);
    let site = stats.sites()[0];
    assert_eq!(
        (site.kind, site.site.file(), site.site.line()),
        (BlockingKind::Sleep, file!(), line)
    );
}

#[test]
fn request_path_counts_per_kind_and_records_the_caller() {
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let line;
    {
        let _scope = RequestPathScope::enter(&stats);
        assert!(in_scope());
        line = line!() + 1;
        note(BlockingKind::ProcScan);
        note(BlockingKind::Sqlite);
    }
    assert!(!in_scope());
    assert_eq!(stats.handler_runs(), 1);
    assert_eq!(stats.count(BlockingKind::ProcScan), 1);
    assert_eq!(stats.count(BlockingKind::Sqlite), 1);
    assert_eq!(stats.count(BlockingKind::JournalWait), 0);
    let sites = stats.sites();
    assert_eq!(sites.len(), 2);
    assert_eq!(sites[0].kind, BlockingKind::Sqlite, "newest first");
    assert_eq!(sites[1].kind, BlockingKind::ProcScan);
    assert_eq!(sites[1].site.file(), file!());
    assert_eq!(sites[1].site.line(), line);
}

#[track_caller]
fn wrapper_that_blocks() {
    note(BlockingKind::ChildProcess);
}

#[test]
fn request_path_track_caller_wrapper_records_its_caller() {
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let line = line!() + 1;
    wrapper_that_blocks();
    let site = stats.sites()[0].site;
    assert_eq!((site.file(), site.line()), (file!(), line));
}

#[test]
fn request_path_off_mode_counts_without_the_ring() {
    let stats = RequestPathStats::new(RequestPathMode::OFF);
    let _scope = RequestPathScope::enter(&stats);
    note(BlockingKind::Network);
    assert_eq!(stats.count(BlockingKind::Network), 1);
    assert!(stats.sites().is_empty());
}

#[test]
fn request_path_nested_scopes_count_one_handler_run_and_restore() {
    let outer = RequestPathStats::new(RequestPathMode::OFF);
    let other = RequestPathStats::new(RequestPathMode::OFF);
    let _outer = RequestPathScope::enter(&outer);
    {
        let _same = RequestPathScope::enter(&outer);
        let _other = RequestPathScope::enter(&other);
        note(BlockingKind::Sleep);
    }
    note(BlockingKind::Sleep);
    assert_eq!(outer.handler_runs(), 1);
    assert_eq!(other.handler_runs(), 1);
    assert_eq!(other.count(BlockingKind::Sleep), 1);
    assert_eq!(outer.count(BlockingKind::Sleep), 1);
}

#[test]
fn request_path_scope_is_per_thread() {
    let stats = RequestPathStats::new(RequestPathMode::OFF);
    let _scope = RequestPathScope::enter(&stats);
    std::thread::spawn(|| {
        assert!(!in_scope());
        note(BlockingKind::FsWrite);
    })
    .join()
    .expect("note thread");
    assert_eq!(stats.count(BlockingKind::FsWrite), 0);
}

#[test]
fn request_path_ring_keeps_the_newest_entries() {
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    for _ in 0..SITE_RING_LEN + 5 {
        note(BlockingKind::HostWait);
    }
    assert_eq!(stats.sites().len(), SITE_RING_LEN);
    assert_eq!(stats.count(BlockingKind::HostWait), (SITE_RING_LEN + 5) as u64);
}

#[test]
fn request_path_mode_parses_record_and_panic_lists() {
    assert_eq!(RequestPathMode::parse(""), Ok(RequestPathMode::OFF));
    assert_eq!(RequestPathMode::parse("record"), Ok(RequestPathMode::RECORD));
    let mode = RequestPathMode::parse("panic:journal_wait, process_spawn,sleep").expect("mode");
    assert!(mode.records());
    assert_eq!(
        mode.panic_kinds(),
        [BlockingKind::JournalWait, BlockingKind::ProcessSpawn, BlockingKind::Sleep]
    );
    assert_eq!(
        RequestPathMode::parse("panic:disk"),
        Err(RequestPathModeError::UnknownKind("disk".into()))
    );
    assert_eq!(RequestPathMode::parse("panic:"), Err(RequestPathModeError::EmptyPanicList));
    assert_eq!(
        RequestPathMode::parse("loud"),
        Err(RequestPathModeError::UnknownMode("loud".into()))
    );
    for kind in BlockingKind::ALL {
        assert_eq!(BlockingKind::parse(kind.name()), Some(kind));
    }
}

#[test]
fn request_path_panic_mode_panics_only_on_listed_kinds() {
    let stats = RequestPathStats::new(RequestPathMode::panic_on(&[BlockingKind::JournalWait]));
    let _scope = RequestPathScope::enter(&stats);
    note(BlockingKind::Sqlite);
    let panicked = std::panic::catch_unwind(|| note(BlockingKind::JournalWait));
    // Tests build with debug assertions; a release test run only records.
    assert_eq!(panicked.is_err(), cfg!(debug_assertions));
    assert_eq!(stats.count(BlockingKind::JournalWait), 1);
    assert_eq!(stats.count(BlockingKind::Sqlite), 1);
    assert!(in_scope(), "the scope survives the unwind");
}

thread_local! {
    static HEARD: RefCell<Vec<&'static str>> = const { RefCell::new(Vec::new()) };
}

/// Keeps what the thread's observer hears: notes, scope starts and ends.
struct KeepingObserver;

impl BlockingObserver for KeepingObserver {
    fn noted(&self, kind: BlockingKind) {
        HEARD.with(|heard| heard.borrow_mut().push(kind.name()));
    }
    fn scope_started(&self) {
        HEARD.with(|heard| heard.borrow_mut().push("started"));
    }
    fn scope_ended(&self) {
        HEARD.with(|heard| heard.borrow_mut().push("ended"));
    }
}

#[test]
fn the_blocking_observer_hears_notes_and_will_block_scopes_on_its_thread() {
    static OBSERVER: KeepingObserver = KeepingObserver;
    let heard = std::thread::spawn(|| {
        // No observer: will_block only runs its closure.
        assert_eq!(will_block(|| 3), 3);
        assert!(set_blocking_observer(Some(&OBSERVER)).is_none());
        note(BlockingKind::Network);
        // Measured after the hold: never a reason to compensate.
        note(BlockingKind::LockHoldOver1ms);
        assert_eq!(will_block(|| 4), 4);
        let unwound = std::panic::catch_unwind(|| will_block(|| panic!("the scope unwinds")));
        assert!(unwound.is_err());
        assert!(set_blocking_observer(None).is_some());
        note(BlockingKind::Network);
        HEARD.with(RefCell::take)
    })
    .join()
    .unwrap();
    assert_eq!(heard, ["network", "started", "ended", "started", "ended"]);
}
