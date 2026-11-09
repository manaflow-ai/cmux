//! A session's registry record holds its whole advertised capability list
//! (P-AUSTIN B7a). A daemon advertised 5,765 bytes of capabilities on
//! 2026-10-29 while `put-session` refused any capabilities JSON over 4,096
//! bytes, so no session was recorded and the next launch could not restore
//! the machines it had connected.

use std::path::PathBuf;

use serde_json::{Value, json};

use super::read_sessions;
use crate::workspace_registry::WorkspaceRegistry;

/// The size of the capability list in the failing report, in bytes of JSON.
const REPORTED_CAPABILITY_BYTES: usize = 5_765;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir()
        .join(format!("cmux-session-record-{label}-{}", crate::workspace_registry::new_uuid_v4()))
}

/// This daemon's own advertised list, grown with tokens of the same shape
/// until it is at least `bytes` long as JSON.
fn capabilities_of_at_least(bytes: usize) -> Value {
    let mut names: Vec<String> =
        crate::server::static_capabilities().into_iter().map(str::to_owned).collect();
    let mut index = 0;
    while serde_json::to_string(&names).unwrap().len() < bytes {
        names.push(format!("restore-size-probe-{index}-v1"));
        index += 1;
    }
    json!(names)
}

/// Removes the test's registry folder also when an assertion fails.
struct RemoveOnDrop(PathBuf);

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn a_session_with_its_whole_capability_list_of_5765_bytes_restores_after_reopen() {
    let capabilities = capabilities_of_at_least(REPORTED_CAPABILITY_BYTES);
    assert!(serde_json::to_string(&capabilities).unwrap().len() >= REPORTED_CAPABILITY_BYTES);
    let root = temp_root("capabilities");
    let _cleanup = RemoveOnDrop(root.clone());
    {
        let mut registry = WorkspaceRegistry::open(&root, "session-record").unwrap();
        let (record, created) = registry
            .put_session(
                "remote-1",
                Some("build-box"),
                Some("main"),
                &json!({"kind":"ssh","host":"build-box"}),
                Some(&capabilities),
                None,
            )
            .expect("put-session records the session's whole capability list");
        assert!(created);
        assert_eq!(record.capabilities.as_ref(), Some(&capabilities));
    }
    let registry = WorkspaceRegistry::open(&root, "session-record").unwrap();
    let sessions = read_sessions(&registry.connection.get()).unwrap();
    let restored = sessions
        .iter()
        .find(|session| session.session_id == "remote-1")
        .expect("the recorded session is in the registry after a reopen");
    assert_eq!(restored.capabilities.as_ref(), Some(&capabilities));
    assert_eq!(restored.transport, json!({"kind":"ssh","host":"build-box"}));
}

/// Unique tokens `cap-<n>-v1`, as many as fit in `bytes` of JSON (or one
/// more when `over`).
fn token_list(bytes: usize, over: bool) -> Value {
    let mut names: Vec<String> = Vec::new();
    let mut index = 0;
    loop {
        names.push(format!("cap-{index:08}-v1"));
        let length = serde_json::to_string(&names).unwrap().len();
        if length > bytes {
            if !over {
                names.pop();
            }
            return json!(names);
        }
        index += 1;
    }
}

#[test]
fn a_session_capability_list_is_bounded_by_the_journal_event_budget() {
    let mut registry = WorkspaceRegistry::in_memory("session-record-bound").unwrap();
    let transport = json!({"kind":"ssh","host":"build-box"});
    let largest = token_list(super::MAX_SESSION_CAPABILITIES_BYTES, false);
    let (record, _) = registry
        .put_session("remote-1", None, None, &transport, Some(&largest), None)
        .expect("a list at the bound is recorded");
    assert_eq!(record.capabilities.as_ref(), Some(&largest));
    let error = registry
        .put_session(
            "remote-2",
            None,
            None,
            &transport,
            Some(&token_list(super::MAX_SESSION_CAPABILITIES_BYTES, true)),
            None,
        )
        .unwrap_err()
        .to_string();
    assert!(error.contains("bad request: capabilities is"), "{error}");
}

#[test]
fn a_session_capability_list_holds_only_unique_capability_tokens() {
    let mut registry = WorkspaceRegistry::in_memory("session-record-tokens").unwrap();
    let transport = json!({"kind":"ssh","host":"build-box"});
    for (capabilities, refusal) in [
        (json!({"profiles-v1": true}), "must be an array of strings"),
        (json!(["profiles-v1", 1]), "must be an array of strings"),
        (json!(["Profiles-v1"]), "must be 1-64"),
        (json!(["profiles v1"]), "must be 1-64"),
        (json!(["1profiles"]), "must be 1-64"),
        (json!([""]), "must be 1-64"),
        (json!(["a".repeat(65)]), "must be 1-64"),
        (json!(["profiles-v1", "profiles-v1"]), "listed twice"),
    ] {
        let error = registry
            .put_session("remote-1", None, None, &transport, Some(&capabilities), None)
            .unwrap_err()
            .to_string();
        assert!(error.contains(refusal), "{capabilities}: {error}");
    }
}

/// Same workload before/after the fix: an app syncing 32 connected
/// machines repeatedly. Count real WAL commits and changed SQLite rows,
/// rather than timing an in-memory stand-in for the durable registry.
#[test]
fn repeated_session_puts_do_not_commit() {
    const MACHINES: usize = 32;
    const PUTS: usize = 1_024;
    let root = temp_root("idle-puts");
    let _cleanup = RemoveOnDrop(root.clone());
    let mut registry = WorkspaceRegistry::open(&root, "idle-puts").unwrap();
    let capabilities = capabilities_of_at_least(REPORTED_CAPABILITY_BYTES);
    let transport = json!({"kind":"ssh","host":"build-box"});
    let sessions: Vec<_> = (0..MACHINES).map(|i| format!("remote-{i}")).collect();
    for session in &sessions {
        registry
            .put_session(
                session,
                Some("build-box"),
                Some("main"),
                &transport,
                Some(&capabilities),
                None,
            )
            .unwrap();
    }
    // A timestamp far in the past makes a mistaken heartbeat update
    // observable without depending on sleeps or the clock's resolution.
    registry.connection.get().execute("UPDATE sessions SET last_seen_ms = 1", []).unwrap();
    let before = registry.personal_snapshot().unwrap();
    let commits = registry.connection.durability_counts().0;
    let rows = registry.connection.get().total_changes();
    let started = std::time::Instant::now();
    for i in 0..PUTS {
        let (_, created) = registry
            .put_session(
                &sessions[i % MACHINES],
                Some("build-box"),
                Some("main"),
                &transport,
                Some(&capabilities),
                None,
            )
            .unwrap();
        assert!(!created);
    }
    let elapsed = started.elapsed();
    let commits = registry.connection.durability_counts().0 - commits;
    let rows = registry.connection.get().total_changes() - rows;
    println!(
        "session_put_workload: machines={MACHINES} puts={PUTS} wal_commits={commits} changed_rows={rows} elapsed_ms={:.3}",
        elapsed.as_secs_f64() * 1_000.0
    );
    assert_eq!(commits, 0, "unchanged registrations must not append WAL frames");
    assert_eq!(rows, 0, "unchanged registrations must not write any table");
    assert_eq!(registry.personal_snapshot().unwrap(), before);
}

#[test]
fn a_session_put_compares_effective_fields_and_preserves_personal_state() {
    let mut registry = WorkspaceRegistry::in_memory("session-put-fields").unwrap();
    let transport = json!({"kind":"ssh","host":"build-box"});
    let capabilities = json!(["profiles-v1"]);
    registry
        .put_session(
            "remote-1",
            Some("build-box"),
            Some("main"),
            &transport,
            Some(&capabilities),
            None,
        )
        .unwrap();
    registry.set_session_icon("remote-1", Some("🧪")).unwrap();
    registry.import_session_organization("remote-1", &[], &[]).unwrap();
    let before = registry.personal_snapshot().unwrap();
    let (same, created) =
        registry.put_session("remote-1", None, None, &transport, None, None).unwrap();
    assert!(!created);
    assert_eq!(same.icon.as_deref(), Some("🧪"));
    assert!(same.migrated);
    assert_eq!(registry.personal_snapshot().unwrap(), before);
    // Validation still applies to a would-be no-op.
    assert!(
        registry
            .put_session("remote-1", None, None, &transport, None, Some("prof_missing"))
            .is_err()
    );
    assert!(
        registry
            .put_session("remote-1", None, None, &transport, Some(&json!(["Bad"])), None)
            .is_err()
    );
    assert_eq!(registry.personal_snapshot().unwrap(), before);

    let revisions = registry.personal_revision().unwrap() + 1..;
    for (revision, (machine, session, transport, capabilities)) in revisions.zip([
        (Some("renamed-box"), None, transport.clone(), None),
        (None, Some("renamed-session"), transport.clone(), None),
        (None, None, json!({"kind":"ssh","host":"new-host"}), None),
        (None, None, json!({"kind":"ssh","host":"new-host"}), Some(json!([]))),
    ]) {
        let (record, created) = registry
            .put_session("remote-1", machine, session, &transport, capabilities.as_ref(), None)
            .unwrap();
        assert!(!created);
        assert_eq!(record.icon.as_deref(), Some("🧪"));
        assert!(record.migrated);
        assert_eq!(registry.personal_revision().unwrap(), revision);
        let before_retry = registry.personal_snapshot().unwrap();
        let (retry, _) = registry
            .put_session("remote-1", machine, session, &transport, capabilities.as_ref(), None)
            .unwrap();
        assert_eq!(retry, record);
        assert_eq!(registry.personal_snapshot().unwrap(), before_retry);
    }
    drop(registry);
}

/// A session whose transport flaps writes one fact per put. Each fact names
/// the capability list by hash instead of carrying it: Leo's registry took
/// 5.57M such puts in a week at 6.4-7.0 KB each (2026-11-09).
#[test]
fn a_flapping_session_put_journals_the_capability_hash_not_the_list() {
    const PUTS: usize = 256;
    let mut registry = WorkspaceRegistry::in_memory("session-put-fact").unwrap();
    let capabilities = capabilities_of_at_least(REPORTED_CAPABILITY_BYTES);
    let list_bytes = serde_json::to_string(&capabilities).unwrap().len();
    for i in 0..PUTS {
        let transport = json!({"kind":"ssh","host":format!("build-box-{}", i % 2)});
        registry
            .put_session("remote-1", Some("build-box"), None, &transport, Some(&capabilities), None)
            .unwrap();
    }
    let (count, bytes, first, last): (i64, i64, String, String) = registry
        .connection
        .get()
        .query_row(
            "SELECT COUNT(*), SUM(length(payload_json)),
                    (SELECT payload_json FROM session_journal WHERE kind = 'personal.session.put' ORDER BY sequence LIMIT 1),
                    (SELECT payload_json FROM session_journal WHERE kind = 'personal.session.put' ORDER BY sequence DESC LIMIT 1)
             FROM session_journal WHERE kind = 'personal.session.put'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap();
    let per_put = usize::try_from(bytes).unwrap() / usize::try_from(count).unwrap();
    println!(
        "session_put_fact: puts={count} journal_bytes={bytes} per_put={per_put} capability_list_bytes={list_bytes}"
    );
    assert_eq!(usize::try_from(count).unwrap(), PUTS);
    assert!(per_put < 1_024, "a put journals {per_put} bytes; the list is {list_bytes}");
    let first: Value = serde_json::from_str(&first).unwrap();
    let last: Value = serde_json::from_str(&last).unwrap();
    assert_eq!(first["capabilities_changed"], json!(true));
    assert_eq!(last["capabilities_changed"], json!(false));
    assert_eq!(first["capabilities_sha256"], last["capabilities_sha256"]);
    assert_eq!(last["session"]["capabilities"], Value::Null);
    // The row keeps the whole list for restore.
    let stored = super::read_session(registry.connection.get(), "remote-1").unwrap().unwrap();
    assert_eq!(stored.capabilities.as_ref(), Some(&capabilities));
}
