//! The fingerprint, the diff and the baseline rules on Chrome-schema stores.

mod common;

use cmux_cookie_sync::{Config, Core, Reason, Report, ScanError, Source, diff, fingerprint};
use common::{MODERN, OLD, create, insert, insert_at};
use std::path::{Path, PathBuf};

fn changed(report: Option<Report>) -> (Vec<String>, Vec<String>, Reason) {
    let (changed, removed, reason, _) = changed_at(report);
    (changed, removed, reason)
}

/// A `changed` report's lists, reason and generation.
fn changed_at(report: Option<Report>) -> (Vec<String>, Vec<String>, Reason, u64) {
    match report {
        Some(Report::Changed { changed, removed, reason, generation, .. }) => {
            (changed, removed, reason, generation)
        }
        other => panic!("expected a change, got {other:?}"),
    }
}

fn scanned(report: Option<Report>) -> Reason {
    match report {
        Some(Report::Scanned { reason, .. }) => reason,
        other => panic!("expected a scan with no change, got {other:?}"),
    }
}

fn config(state_dir: &Path, database: &Path) -> Config {
    Config {
        state_dir: state_dir.to_path_buf(),
        debounce_ms: 2000,
        min_interval_ms: 30_000,
        sources: vec![Source { id: "chrome:Default".to_owned(), database: database.to_path_buf() }],
    }
}

fn store(dir: &Path) -> (PathBuf, rusqlite::Connection) {
    let path = dir.join("Cookies");
    let conn = create(&path, MODERN);
    insert(&conn, ".github.com", "user_session", b"v10-aaaa", "");
    insert(&conn, "github.com", "_gh_sess", b"v10-bbbb", "");
    insert(&conn, ".example.com", "id", b"v10-cccc", "");
    (path, conn)
}

#[test]
fn an_access_time_only_commit_reports_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let (path, conn) = store(dir.path());
    let before = fingerprint(&path).unwrap();
    conn.execute(
        "UPDATE cookies SET last_access_utc = last_access_utc + 999, last_update_utc = 7",
        [],
    )
    .unwrap();
    conn.execute("UPDATE cookies SET creation_utc = creation_utc + 1", []).unwrap();
    let after = fingerprint(&path).unwrap();
    assert_eq!(before.fingerprint, after.fingerprint);
    assert!(diff(&before.fingerprint, &after.fingerprint).is_empty());
}

#[test]
fn a_value_change_reports_its_domain_without_the_dot() {
    let dir = tempfile::tempdir().unwrap();
    let (path, conn) = store(dir.path());
    let before = fingerprint(&path).unwrap();
    conn.execute(
        "UPDATE cookies SET encrypted_value = x'763130ff' WHERE name = 'user_session'",
        [],
    )
    .unwrap();
    let after = fingerprint(&path).unwrap();
    let d = diff(&before.fingerprint, &after.fingerprint);
    assert_eq!(d.changed, vec!["github.com"]);
    assert!(d.removed.is_empty());
}

#[test]
fn each_hashed_field_counts() {
    let dir = tempfile::tempdir().unwrap();
    let (path, conn) = store(dir.path());
    let base = fingerprint(&path).unwrap().fingerprint;
    for (set, undo) in [
        ("expires_utc = 1", "expires_utc = 13400000000000000"),
        ("has_expires = 0", "has_expires = 1"),
        ("is_secure = 0", "is_secure = 1"),
        ("is_httponly = 0", "is_httponly = 1"),
        ("samesite = 2", "samesite = 1"),
        ("path = '/x'", "path = '/'"),
        ("value = 'plain'", "value = ''"),
        ("name = 'id2'", "name = 'id'"),
    ] {
        conn.execute(&format!("UPDATE cookies SET {set} WHERE host_key = '.example.com'"), [])
            .unwrap();
        let d = diff(&base, &fingerprint(&path).unwrap().fingerprint);
        assert_eq!(d.changed, vec!["example.com"], "{set}");
        conn.execute(&format!("UPDATE cookies SET {undo} WHERE host_key = '.example.com'"), [])
            .unwrap();
        assert_eq!(fingerprint(&path).unwrap().fingerprint, base, "{undo}");
    }
}

#[test]
fn added_and_removed_hosts() {
    let dir = tempfile::tempdir().unwrap();
    let (path, conn) = store(dir.path());
    let before = fingerprint(&path).unwrap();
    assert_eq!((before.rows, before.fingerprint.len()), (3, 3));
    conn.execute("DELETE FROM cookies WHERE host_key = '.example.com'", []).unwrap();
    insert_at(&conn, "news.ycombinator.com", "user", b"v10-dddd", "", 1);
    let after = fingerprint(&path).unwrap();
    let d = diff(&before.fingerprint, &after.fingerprint);
    assert_eq!(d.changed, vec!["news.ycombinator.com"]);
    assert_eq!(d.removed, vec!["example.com"]);
}

#[test]
fn a_domain_with_a_host_key_left_is_changed_not_removed() {
    let dir = tempfile::tempdir().unwrap();
    let (path, conn) = store(dir.path());
    let before = fingerprint(&path).unwrap();
    conn.execute("DELETE FROM cookies WHERE host_key = '.github.com'", []).unwrap();
    let d = diff(&before.fingerprint, &fingerprint(&path).unwrap().fingerprint);
    assert_eq!(d.changed, vec!["github.com"]);
    assert!(d.removed.is_empty());
}

#[test]
fn partitioned_cookies_are_skipped() {
    let dir = tempfile::tempdir().unwrap();
    let (path, conn) = store(dir.path());
    let before = fingerprint(&path).unwrap();
    insert_at(&conn, ".github.com", "user_session", b"v10-zzzz", "https://example.org", 2);
    insert_at(&conn, "partitioned.example", "p", b"v10-zzzz", "https://example.org", 3);
    let after = fingerprint(&path).unwrap();
    assert_eq!(before.fingerprint, after.fingerprint);
    assert_eq!((after.rows, after.partitioned), (3, 2));
}

#[test]
fn an_old_schema_reads_through_the_column_fallbacks() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("Cookies");
    let conn = create(&path, OLD);
    conn.execute(
        "INSERT INTO cookies(creation_utc, host_key, name, value, path, expires_utc, secure, httponly, last_access_utc, encrypted_value) \
         VALUES(1, '.old.example', 'a', '', '/', 5, 1, 0, 1, x'01')",
        [],
    )
    .unwrap();
    let before = fingerprint(&path).unwrap();
    assert_eq!(before.rows, 1);
    assert!(before.fingerprint.contains_key(".old.example"));
    conn.execute("UPDATE cookies SET last_access_utc = 99", []).unwrap();
    assert_eq!(fingerprint(&path).unwrap().fingerprint, before.fingerprint);
    conn.execute("UPDATE cookies SET secure = 0", []).unwrap();
    assert_eq!(
        diff(&before.fingerprint, &fingerprint(&path).unwrap().fingerprint).changed,
        vec!["old.example"]
    );
}

#[test]
fn a_store_that_is_not_a_cookie_table_is_unreadable_with_a_short_reason() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("Cookies");
    create(&path, "CREATE TABLE cookies(id INTEGER);");
    let Err(ScanError::Unreadable(reason)) = fingerprint(&path) else { panic!("not unreadable") };
    assert_eq!(reason, "not a Chromium cookies table");
    std::fs::write(&path, b"this is not sqlite at all, just some bytes that are long enough")
        .unwrap();
    let Err(ScanError::Unreadable(reason)) = fingerprint(&path) else { panic!("not unreadable") };
    assert!(!reason.contains('/'), "{reason}");
    assert_eq!(fingerprint(&dir.path().join("Nope")), Err(ScanError::Missing));
}

#[test]
fn an_uncommitted_journal_is_rolled_back_in_the_copy() {
    let dir = tempfile::tempdir().unwrap();
    let (path, conn) = store(dir.path());
    let before = fingerprint(&path).unwrap();
    // A write transaction left open: its hot journal is beside the file.
    conn.execute_batch("PRAGMA cache_size = 1; BEGIN; UPDATE cookies SET encrypted_value = x'00';")
        .unwrap();
    let during = fingerprint(&path).unwrap();
    conn.execute_batch("ROLLBACK;").unwrap();
    assert_eq!(during.fingerprint, before.fingerprint);
}

#[test]
fn the_first_scan_is_the_baseline_and_a_change_is_reported_until_committed() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let (path, conn) = store(dir.path());
    let config = config(&state, &path);

    let mut core = Core::new(&config);
    assert_eq!(scanned(core.check(0, Reason::Launch)), Reason::Baseline);
    assert!(!core.commit("chrome:Default", 0), "nothing pending");
    assert_eq!(scanned(core.check(0, Reason::Watch)), Reason::Watch);

    // Chrome changed while the app was closed: the launch check reports it.
    conn.execute("UPDATE cookies SET encrypted_value = x'02' WHERE host_key = '.example.com'", [])
        .unwrap();
    let mut core = Core::new(&config);
    assert_eq!(
        changed(core.check(0, Reason::Launch)),
        (vec!["example.com".to_owned()], vec![], Reason::Launch)
    );

    // Not committed: reported again on the next launch.
    let mut core = Core::new(&config);
    let (domains, _, _, generation) = changed_at(core.check(0, Reason::Launch));
    assert_eq!(domains, vec!["example.com"]);
    assert!(!core.commit("chrome:Other", generation));
    assert!(core.commit("chrome:Default", generation));
    assert_eq!(scanned(core.check(0, Reason::Watch)), Reason::Watch);

    // Committed: the next launch has nothing to report.
    let mut core = Core::new(&config);
    assert_eq!(scanned(core.check(0, Reason::Launch)), Reason::Launch);

    // A change that goes back to the baseline before the commit is still
    // reported (the app may have imported the value in between), then done.
    conn.execute("UPDATE cookies SET encrypted_value = x'03' WHERE host_key = '.example.com'", [])
        .unwrap();
    let first = changed_at(core.check(0, Reason::Watch)).3;
    conn.execute("UPDATE cookies SET encrypted_value = x'02' WHERE host_key = '.example.com'", [])
        .unwrap();
    let (domains, _, _, second) = changed_at(core.check(0, Reason::Watch));
    assert_eq!(domains, vec!["example.com"]);
    assert!(!core.commit("chrome:Default", first));
    assert!(core.commit("chrome:Default", second));
    assert_eq!(scanned(core.check(0, Reason::Watch)), Reason::Watch);

    let files: Vec<_> =
        std::fs::read_dir(&state).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(files.len(), 1, "{files:?}");
    let saved = std::fs::read_to_string(state.join(&files[0])).unwrap();
    assert!(!saved.contains("v10"), "the baseline holds hashes only");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(state.join(&files[0])).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}

#[test]
fn a_disappearing_store_is_gone_once_and_then_not_scanned() {
    let dir = tempfile::tempdir().unwrap();
    let (path, conn) = store(dir.path());
    let mut core = Core::new(&config(&dir.path().join("state"), &path));
    scanned(core.check(0, Reason::Launch));
    drop(conn);
    std::fs::remove_file(&path).unwrap();
    assert_eq!(
        core.check(0, Reason::Watch),
        Some(Report::Gone { source: "chrome:Default".to_owned() })
    );
    assert_eq!(core.database(0), None);
    assert_eq!(core.check(0, Reason::Watch), None);
}

#[test]
fn an_unreadable_store_fails_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("Cookies");
    create(&path, "CREATE TABLE other(id INTEGER);");
    let mut core = Core::new(&config(&dir.path().join("state"), &path));
    assert_eq!(
        core.check(0, Reason::Launch),
        Some(Report::Failed {
            source: "chrome:Default".to_owned(),
            reason: "not a Chromium cookies table".to_owned()
        })
    );
    assert_eq!(core.check(0, Reason::Watch), None);
}

#[test]
fn the_config_needs_absolute_paths_and_unique_ids() {
    let ok =
        br#"{"state_dir": "/s", "sources": [{"id": "chrome:Default", "database": "/p/Cookies"}]}"#;
    let config = Config::parse(ok).unwrap();
    assert_eq!((config.debounce_ms, config.min_interval_ms), (2000, 30_000));
    for bad in [
        &br#"{"state_dir": "s", "sources": []}"#[..],
        br#"{"state_dir": "/s", "sources": [{"id": "", "database": "/p/Cookies"}]}"#,
        br#"{"state_dir": "/s", "sources": [{"id": "a", "database": "p/Cookies"}]}"#,
        br#"{"state_dir": "/s", "sources": [{"id": "a", "database": "/p/C"}, {"id": "a", "database": "/q/C"}]}"#,
        br#"{"sources": []}"#,
        b"not json",
    ] {
        assert!(Config::parse(bad).is_none(), "{}", String::from_utf8_lossy(bad));
    }
}

#[test]
fn reports_serialize_to_the_documented_json() {
    let report = Report::Changed {
        source: "chrome:Default".to_owned(),
        generation: 7,
        changed: vec!["github.com".to_owned()],
        removed: vec![],
        rows: 3,
        hosts: 2,
        scan_ms: 1.5,
        cpu_ms: None,
        reason: Reason::Watch,
    };
    assert_eq!(
        serde_json::to_string(&report).unwrap(),
        r#"{"kind":"changed","source":"chrome:Default","generation":7,"changed":["github.com"],"removed":[],"rows":3,"hosts":2,"scan_ms":1.5,"cpu_ms":null,"reason":"watch"}"#
    );
    assert_eq!(
        serde_json::to_string(&Report::Gone { source: "a".to_owned() }).unwrap(),
        r#"{"kind":"gone","source":"a"}"#
    );
}

#[test]
fn a_commit_of_an_earlier_report_does_not_save_a_later_one() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let (path, conn) = store(dir.path());
    let config = config(&state, &path);
    let mut core = Core::new(&config);
    scanned(core.check(0, Reason::Launch));

    conn.execute("UPDATE cookies SET encrypted_value = x'05' WHERE host_key = '.example.com'", [])
        .unwrap();
    let first = changed_at(core.check(0, Reason::Watch)).3;
    // A second change is reported before the app commits the first.
    conn.execute("UPDATE cookies SET encrypted_value = x'06' WHERE host_key = 'github.com'", [])
        .unwrap();
    let (domains, _, _, second) = changed_at(core.check(0, Reason::Watch));
    assert_eq!(
        domains,
        vec!["example.com", "github.com"],
        "a report holds every change since the baseline"
    );
    assert!(second > first);
    assert!(!core.commit("chrome:Default", first), "the earlier report is not the latest");
    // Its import failed, say: the next launch still reports both domains.
    let mut relaunched = Core::new(&config);
    assert_eq!(changed(relaunched.check(0, Reason::Launch)).0, vec!["example.com", "github.com"]);
    assert!(core.commit("chrome:Default", second));
    let mut relaunched = Core::new(&config);
    assert_eq!(scanned(relaunched.check(0, Reason::Launch)), Reason::Launch);
}

#[test]
fn a_domain_stays_reported_until_a_commit_even_after_it_reverts() {
    let dir = tempfile::tempdir().unwrap();
    let (path, conn) = store(dir.path());
    let mut core = Core::new(&config(&dir.path().join("state"), &path));
    scanned(core.check(0, Reason::Launch));

    conn.execute("UPDATE cookies SET encrypted_value = x'09' WHERE host_key = '.example.com'", [])
        .unwrap();
    assert_eq!(changed(core.check(0, Reason::Watch)).0, vec!["example.com"]);
    // example.com goes back to its baseline value while github.com changes and
    // a new host comes and goes: every domain since the commit is named.
    conn.execute(
        "UPDATE cookies SET encrypted_value = ?1 WHERE host_key = '.example.com'",
        [b"v10-cccc".to_vec()],
    )
    .unwrap();
    conn.execute("UPDATE cookies SET encrypted_value = x'0a' WHERE host_key = 'github.com'", [])
        .unwrap();
    insert_at(&conn, "brief.example", "t", b"v10-eeee", "", 4);
    assert_eq!(
        changed(core.check(0, Reason::Watch)).0,
        vec!["brief.example", "example.com", "github.com"]
    );
    conn.execute("DELETE FROM cookies WHERE host_key = 'brief.example'", []).unwrap();
    let (changed_domains, removed, _, generation) = changed_at(core.check(0, Reason::Watch));
    assert_eq!(changed_domains, vec!["example.com", "github.com"]);
    assert_eq!(removed, vec!["brief.example"]);
    assert!(core.commit("chrome:Default", generation));
    assert_eq!(scanned(core.check(0, Reason::Watch)), Reason::Watch);
}
