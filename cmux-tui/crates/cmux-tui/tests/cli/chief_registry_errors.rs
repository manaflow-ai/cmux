//! cx-8mla8: `cmux chief list` printed only "operation.failed: internal:
//! internal" when the daemon's Chief registry failed; the cause was in the
//! error's details, which the CLI dropped. The CLI shows the daemon's own
//! words for any internal failure.

use super::*;

/// The directory of the daemon's session state (where `chiefs.sqlite3` goes):
/// the one that holds its workspace registry.
fn session_state_dir(dir: &std::path::Path) -> Option<PathBuf> {
    for entry in fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if path.file_name().is_some_and(|n| n == "workspace-registry.sqlite3") {
            return Some(dir.to_path_buf());
        }
        if path.is_dir()
            && let Some(found) = session_state_dir(&path)
        {
            return Some(found);
        }
    }
    None
}

#[test]
fn chief_list_shows_the_daemons_words_for_an_internal_failure() {
    let mut server = HeadlessServer::start_with_options("chief-list-internal", None, None, &[]);
    // A registry file from a future build: the daemon cannot open it.
    // The daemon writes its workspace registry while it starts (bounded wait).
    let deadline = Instant::now() + Duration::from_secs(15);
    let state = loop {
        if let Some(found) = session_state_dir(&server.state) {
            break found;
        }
        assert!(
            Instant::now() < deadline,
            "no session state directory under {}",
            server.state.display()
        );
        std::thread::sleep(Duration::from_millis(25));
    };
    let db = rusqlite::Connection::open(state.join("chiefs.sqlite3")).unwrap();
    db.execute_batch(
        "CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
         INSERT INTO meta (key, value) VALUES ('schema_version', '99');",
    )
    .unwrap();
    drop(db);

    let output = chief_cli(&server, &["list"], "");
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("chief registry has an unknown schema version"), "{stderr}");
    assert!(!stderr.contains("internal: internal"), "{stderr}");
    // A Request ID the person can quote; the daemon's log names the same id
    // with the cause.
    let request_id = stderr
        .split("Request ID ")
        .nth(1)
        .and_then(|rest| rest.split(|c: char| !c.is_ascii_alphanumeric() && c != '_').next())
        .filter(|id| id.starts_with("req_"))
        .unwrap_or_else(|| panic!("no Request ID in {stderr}"))
        .to_owned();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let log = server.stderr_tail();
        let cause = "chief registry has an unknown schema version";
        if log.contains(&request_id) && log.contains(cause) {
            break;
        }
        assert!(Instant::now() < deadline, "the daemon log has no {request_id}: {log}");
        std::thread::sleep(Duration::from_millis(25));
    }

    let daemon = i32::try_from(server.child.id()).unwrap();
    // SAFETY: the test's own daemon child.
    unsafe { libc::kill(daemon, libc::SIGTERM) };
    let _ = server.child.wait();
}
