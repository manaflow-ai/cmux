//! The C ABI end to end: start on a store, change it in a burst, get one
//! coalesced report on the sync's thread, commit, see the store go, free.
//! Waits are on a condition variable with generous deadlines, never a
//! fixed sleep that the test's outcome depends on.

mod common;

use cmux_cookie_sync::ffi::{
    CMUX_COOKIE_SYNC_ABI_VERSION, cmux_cookie_sync_abi_version, cmux_cookie_sync_commit,
    cmux_cookie_sync_free, cmux_cookie_sync_new,
};
use common::{MODERN, create, insert};
use serde_json::Value;
use std::ffi::c_void;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Default)]
struct Inbox {
    reports: Mutex<Vec<Value>>,
    arrived: Condvar,
}

impl Inbox {
    /// Waits until `count` reports arrived (at most `deadline`); all reports so far.
    fn wait_for(&self, count: usize, deadline: Duration) -> Vec<Value> {
        let end = Instant::now() + deadline;
        let mut reports = self.reports.lock().unwrap();
        while reports.len() < count {
            let left = end.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "timed out waiting for report {count}; got {reports:?}");
            reports = self.arrived.wait_timeout(reports, left).unwrap().0;
        }
        reports.clone()
    }
}

unsafe extern "C" fn on_report(ctx: *mut c_void, json: *const u8, len: usize) {
    // SAFETY: ctx is the test's Inbox, alive until free returns; json is len bytes.
    let (inbox, bytes) = unsafe { (&*ctx.cast::<Inbox>(), std::slice::from_raw_parts(json, len)) };
    let value: Value = serde_json::from_slice(bytes).expect("a report is JSON");
    inbox.reports.lock().unwrap().push(value);
    inbox.arrived.notify_all();
}

#[test]
fn a_burst_of_commits_is_one_report_and_free_joins() {
    assert_eq!(cmux_cookie_sync_abi_version(), CMUX_COOKIE_SYNC_ABI_VERSION);
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("Cookies");
    let conn = create(&database, MODERN);
    insert(&conn, ".github.com", "user_session", b"v10-aaaa", "");
    insert(&conn, ".example.com", "id", b"v10-bbbb", "");
    let config = serde_json::json!({
        "state_dir": dir.path().join("state"),
        "debounce_ms": 400,
        "min_interval_ms": 0,
        "sources": [{"id": "chrome:Default", "database": database}],
    })
    .to_string();
    let inbox = Inbox::default();
    let ctx = (&raw const inbox).cast_mut().cast::<c_void>();
    // SAFETY: the config is readable; the inbox outlives the handle.
    let sync = unsafe { cmux_cookie_sync_new(config.as_ptr(), config.len(), Some(on_report), ctx) };
    assert!(!sync.is_null());

    // The launch check of a store with no baseline takes it as the baseline.
    let reports = inbox.wait_for(1, Duration::from_secs(30));
    assert_eq!(reports[0]["kind"], "scanned");
    assert_eq!(reports[0]["reason"], "baseline");
    assert_eq!(reports[0]["rows"], 2);

    // A burst of five commits, then an access-time-only one.
    for n in 0..5u8 {
        conn.execute(
            "UPDATE cookies SET encrypted_value = ?1 WHERE host_key = '.github.com'",
            [vec![n]],
        )
        .unwrap();
    }
    conn.execute("UPDATE cookies SET last_access_utc = last_access_utc + 1", []).unwrap();
    let reports = inbox.wait_for(2, Duration::from_secs(60));
    assert_eq!(reports[1]["kind"], "changed", "{reports:?}");
    assert_eq!(reports[1]["source"], "chrome:Default");
    assert_eq!(reports[1]["changed"], serde_json::json!(["github.com"]));
    assert_eq!(reports[1]["removed"], serde_json::json!([]));
    assert_eq!(reports[1]["reason"], "watch");
    assert!(reports[1]["scan_ms"].is_number());

    let id = "chrome:Default";
    let generation = reports[1]["generation"].as_u64().expect("a generation");
    // SAFETY: a live handle and a readable id.
    assert!(!unsafe { cmux_cookie_sync_commit(sync, id.as_ptr(), id.len(), generation + 1) });
    // SAFETY: as above.
    assert!(unsafe { cmux_cookie_sync_commit(sync, id.as_ptr(), id.len(), generation) });
    // SAFETY: as above.
    assert!(
        !unsafe { cmux_cookie_sync_commit(sync, id.as_ptr(), id.len(), generation) },
        "nothing pending"
    );

    // The profile goes: one `gone`, then nothing more from it.
    drop(conn);
    std::fs::remove_file(&database).unwrap();
    let reports = inbox.wait_for(3, Duration::from_secs(60));
    let gone = reports.iter().skip(2).find(|r| r["kind"] == "gone");
    assert!(gone.is_some(), "{reports:?}");
    assert!(
        reports.iter().skip(2).all(|r| r["kind"] == "gone" || r["kind"] == "scanned"),
        "the burst was one report: {reports:?}"
    );

    let freeing = Instant::now();
    // SAFETY: the live handle, freed once; it joins the thread.
    unsafe { cmux_cookie_sync_free(sync) };
    assert!(freeing.elapsed() < Duration::from_secs(10));
    let after = inbox.reports.lock().unwrap().len();
    assert_eq!(
        inbox.reports.lock().unwrap().iter().filter(|r| r["kind"] == "changed").count(),
        1,
        "one coalesced change"
    );
    assert_eq!(inbox.reports.lock().unwrap().iter().filter(|r| r["kind"] == "gone").count(), 1);
    assert_eq!(after, inbox.reports.lock().unwrap().len(), "no report after free returned");
}

#[test]
fn a_change_while_closed_is_reported_at_launch() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("Cookies");
    let conn = create(&database, MODERN);
    insert(&conn, ".github.com", "user_session", b"v10-aaaa", "");
    let config = serde_json::json!({
        "state_dir": dir.path().join("state"),
        "sources": [{"id": "chrome:Default", "database": database}],
    })
    .to_string();
    let start = |inbox: &Inbox| {
        let ctx = std::ptr::from_ref(inbox).cast_mut().cast::<c_void>();
        // SAFETY: the config is readable; the inbox outlives the handle.
        unsafe { cmux_cookie_sync_new(config.as_ptr(), config.len(), Some(on_report), ctx) }
    };
    let first = Inbox::default();
    let sync = start(&first);
    assert_eq!(first.wait_for(1, Duration::from_secs(30))[0]["reason"], "baseline");
    // SAFETY: the live handle, freed once.
    unsafe { cmux_cookie_sync_free(sync) };

    insert(&conn, "news.ycombinator.com", "user", b"v10-cccc", "");
    let second = Inbox::default();
    let sync = start(&second);
    let report = &second.wait_for(1, Duration::from_secs(30))[0];
    assert_eq!(report["kind"], "changed");
    assert_eq!(report["reason"], "launch");
    assert_eq!(report["changed"], serde_json::json!(["news.ycombinator.com"]));
    // SAFETY: the live handle, freed once.
    unsafe { cmux_cookie_sync_free(sync) };
}

#[test]
fn a_bad_config_or_no_callback_is_null() {
    let inbox = Inbox::default();
    let ctx = std::ptr::from_ref(&inbox).cast_mut().cast::<c_void>();
    let bad = br#"{"state_dir": "relative", "sources": []}"#;
    // SAFETY: readable bytes.
    assert!(
        unsafe { cmux_cookie_sync_new(bad.as_ptr(), bad.len(), Some(on_report), ctx) }.is_null()
    );
    let good = br#"{"state_dir": "/tmp/x", "sources": []}"#;
    // SAFETY: readable bytes.
    assert!(unsafe { cmux_cookie_sync_new(good.as_ptr(), good.len(), None, ctx) }.is_null());
    // SAFETY: null is ignored.
    unsafe { cmux_cookie_sync_free(std::ptr::null_mut()) };
    // SAFETY: null handle is refused.
    assert!(!unsafe { cmux_cookie_sync_commit(std::ptr::null(), b"a".as_ptr(), 1, 1) });
}

#[test]
fn commits_that_only_reach_a_new_wal_are_seen() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("Cookies");
    let conn = create(&database, MODERN);
    insert(&conn, ".github.com", "user_session", b"v10-aaaa", "");
    let config = serde_json::json!({
        "state_dir": dir.path().join("state"),
        "debounce_ms": 300,
        "min_interval_ms": 0,
        "sources": [{"id": "chrome:Default", "database": database}],
    })
    .to_string();
    let inbox = Inbox::default();
    let ctx = std::ptr::from_ref(&inbox).cast_mut().cast::<c_void>();
    // SAFETY: the config is readable; the inbox outlives the handle.
    let sync = unsafe { cmux_cookie_sync_new(config.as_ptr(), config.len(), Some(on_report), ctx) };
    assert!(!sync.is_null());
    assert_eq!(inbox.wait_for(1, Duration::from_secs(30))[0]["reason"], "baseline");

    // WAL mode: from here a commit appends to Cookies-wal, created now, and
    // leaves the database file alone until a checkpoint.
    let mode: String = conn.query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0)).unwrap();
    assert_eq!(mode, "wal");
    conn.execute_batch("PRAGMA wal_autocheckpoint = 0").unwrap();
    insert(&conn, "first.example", "a", b"v10-bbbb", "");
    // Waits for a `changed` report naming `domain` after the first `from`
    // reports; the count of reports by then.
    let seen = |domain: &str, from: usize| -> usize {
        let end = Instant::now() + Duration::from_secs(60);
        let mut want = from + 1;
        loop {
            let reports = inbox.wait_for(want, end.saturating_duration_since(Instant::now()));
            let named =
                |r: &Value| r["kind"] == "changed" && r["changed"].to_string().contains(domain);
            if reports.iter().skip(from).any(named) {
                return reports.len();
            }
            want = reports.len() + 1;
        }
    };
    let after_first = seen("first.example", 1);
    assert!(std::fs::metadata(dir.path().join("Cookies-wal")).is_ok());
    insert(&conn, "second.example", "b", b"v10-cccc", "");
    seen("second.example", after_first);

    // SAFETY: the live handle, freed once.
    unsafe { cmux_cookie_sync_free(sync) };
}
