use super::*;
use std::sync::{Arc, Mutex};

const MEMINFO: &str = "MemTotal:        4028856 kB\nMemFree:          120000 kB\nCached:          2500000 kB\nDirty:              4096 kB\n";

fn proc_dir() -> (tempfile::TempDir, Proc) {
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::create_dir_all(dir.path().join("sys/vm")).expect("sys/vm");
    std::fs::write(dir.path().join("sys/vm/drop_caches"), "").expect("drop_caches");
    std::fs::write(dir.path().join("meminfo"), MEMINFO).expect("meminfo");
    let proc = Proc {
        meminfo: dir.path().join("meminfo"),
        drop_caches: dir.path().join("sys/vm/drop_caches"),
    };
    (dir, proc)
}

#[test]
fn parses_cached_and_dirty() {
    assert_eq!(parse_meminfo(MEMINFO), Some(CacheSize { cached_kb: 2_500_000, dirty_kb: 4096 }));
    // `SwapCached:` is not `Cached:`.
    assert_eq!(parse_meminfo("SwapCached: 9 kB\nDirty: 1 kB\n"), None);
}

#[test]
fn syncs_before_it_drops_the_clean_cache() {
    let (dir, proc) = proc_dir();
    let target = dir.path().join("sys/vm/drop_caches");
    // What the drop file held when sync ran: empty means sync came first.
    let seen = Arc::new(Mutex::new(None));
    let at_sync = seen.clone();
    let read = target.clone();
    let answer = drop_page_cache(
        &proc,
        move || *at_sync.lock().unwrap() = Some(std::fs::read_to_string(&read).unwrap()),
        Duration::from_secs(5),
    );
    assert_eq!(seen.lock().unwrap().as_deref(), Some(""), "sync ran before the drop");
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "1", "clean page cache only");
    assert_eq!(answer["dropped"], true);
    assert_eq!(answer["cached_kb_before"], 2_500_000);
    assert_eq!(answer["dirty_kb_before"], 4096);
}

#[test]
fn a_slow_sync_answers_by_the_deadline_and_drops_nothing() {
    let (dir, proc) = proc_dir();
    let started = Instant::now();
    let answer = drop_page_cache(
        &proc,
        || std::thread::sleep(Duration::from_secs(30)),
        Duration::from_millis(100),
    );
    let took = started.elapsed();
    assert!(took < Duration::from_secs(2), "answered in {took:?}, past its deadline");
    assert_eq!(answer["dropped"], false);
    assert_eq!(answer["why"], "deadline");
    assert_eq!(std::fs::read_to_string(dir.path().join("sys/vm/drop_caches")).unwrap(), "");
}

#[test]
fn a_refused_write_is_an_answer_not_a_failure() {
    let (dir, proc) = proc_dir();
    std::fs::remove_dir_all(dir.path().join("sys")).unwrap();
    let answer = drop_page_cache(&proc, || {}, Duration::from_secs(5));
    assert_eq!(answer["dropped"], false);
    assert!(answer["why"].as_str().unwrap().contains("drop_caches"));
}

#[test]
fn deadline_argument_is_bounded() {
    assert_eq!(parse_deadline(&[]), Ok(DEFAULT_DEADLINE));
    let args = |v: &str| vec!["--deadline-ms".to_owned(), v.to_owned()];
    assert_eq!(parse_deadline(&args("250")), Ok(Duration::from_millis(250)));
    assert_eq!(parse_deadline(&args("999999")), Ok(MAX_DEADLINE));
    assert!(parse_deadline(&args("soon")).is_err());
    assert!(parse_deadline(&["--other".to_owned()]).is_err());
}
