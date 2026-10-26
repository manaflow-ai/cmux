//! Request-path notes at the daemon's blocking sites: the registry connection
//! (sites, re-entries, long holds, pinned flows), the setting, the
//! `server-stats` section, and the `#[track_caller]` chain of every direct
//! connection caller.

use std::sync::mpsc::channel;
use std::time::Duration;

use super::*;
use crate::WorkspaceRegistry;

fn registry(name: &str) -> WorkspaceRegistry {
    WorkspaceRegistry::in_memory(name).expect("registry")
}

fn sites_of(stats: &RequestPathStats, kind: BlockingKind) -> Vec<(&'static str, u32)> {
    stats
        .sites()
        .into_iter()
        .filter(|noted| noted.kind == kind)
        .map(|noted| (noted.site.file(), noted.site.line()))
        .collect()
}

#[test]
fn request_path_registry_read_records_the_handler_site() {
    let registry = registry("request-path");
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let line = line!() + 1;
    registry.terminal_revision().expect("terminal revision");
    assert_eq!(stats.count(BlockingKind::Sqlite), 1);
    assert_eq!(
        sites_of(&stats, BlockingKind::Sqlite),
        [(file!(), line)],
        "the read's caller, not registry_connection.rs or workspace_registry.rs"
    );
}

#[test]
fn request_path_registry_snapshot_is_one_acquisition() {
    let registry = registry("request-path-snapshot");
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let line = line!() + 1;
    registry.snapshot().expect("snapshot");
    assert_eq!(sites_of(&stats, BlockingKind::Sqlite), [(file!(), line)]);
}

#[test]
fn request_path_registry_read_outside_a_scope_notes_nothing() {
    let registry = registry("request-path-outside");
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    {
        let _scope = RequestPathScope::enter(&stats);
        registry.terminal_revision().expect("terminal revision");
    }
    assert!(!in_scope());
    registry.terminal_revision().expect("terminal revision after the scope");
    assert_eq!(stats.count(BlockingKind::Sqlite), 1, "only the read inside the scope");
    let _scope = RequestPathScope::enter(&stats);
    let connection = registry.connection;
    std::thread::spawn(move || drop(connection.get())).join().expect("reader thread");
    assert_eq!(stats.count(BlockingKind::Sqlite), 1, "another thread's read is not this scope's");
}

#[test]
fn request_path_reentry_adds_no_sqlite_note() {
    let registry = registry("request-path-reentry");
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let outer = registry.connection.get();
    let inner = registry.connection.get();
    let pin = registry.connection.pin();
    drop((pin, inner, outer));
    assert_eq!(stats.count(BlockingKind::Sqlite), 1);
}

#[test]
fn request_path_long_hold_is_noted_once_at_the_caller() {
    let registry = registry("request-path-hold");
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let line = line!() + 1;
    let guard = registry.connection.get();
    std::thread::sleep(Duration::from_millis(3));
    drop(guard);
    assert_eq!(stats.count(BlockingKind::LockHoldOver1ms), 1);
    assert_eq!(sites_of(&stats, BlockingKind::LockHoldOver1ms), [(file!(), line)]);
}

#[test]
fn request_path_long_wait_is_not_a_long_hold() {
    let registry = registry("request-path-wait");
    let connection = registry.connection.clone();
    let (held, release) = (channel(), channel::<()>());
    let holder = std::thread::spawn(move || {
        let guard = connection.get();
        held.0.send(()).expect("held");
        release.1.recv().expect("release");
        std::thread::sleep(Duration::from_millis(5));
        drop(guard);
    });
    held.1.recv().expect("the other thread holds the connection");
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    release.0.send(()).expect("release");
    // Waits about 5 ms for the lock, then releases at once.
    drop(registry.connection.get());
    holder.join().expect("holder");
    assert_eq!(stats.count(BlockingKind::Sqlite), 1);
    assert_eq!(stats.count(BlockingKind::LockHoldOver1ms), 0, "the wait is not the hold");
}

#[test]
fn request_path_holds_are_not_timed_unless_the_setting_records() {
    let registry = registry("request-path-hold-off");
    let stats = RequestPathStats::new(RequestPathMode::OFF);
    let _scope = RequestPathScope::enter(&stats);
    let guard = registry.connection.get();
    std::thread::sleep(Duration::from_millis(3));
    drop(guard);
    assert_eq!(stats.count(BlockingKind::Sqlite), 1);
    assert_eq!(stats.count(BlockingKind::LockHoldOver1ms), 0);
    assert_eq!(RequestPathIoSnapshot::of(&stats).lock_hold_over_1ms, None);
}

#[test]
fn request_path_pinned_flow_records_the_caller_site() {
    let mux = crate::Mux::new_for_test("request-path-pinned", crate::SurfaceOptions::default());
    let registry = mux.workspace_registry.lock().expect("registry");
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let line = line!() + 1;
    let pinned = mux.lock_state_pinned(&registry).expect("pinned state");
    drop(pinned);
    let sites = sites_of(&stats, BlockingKind::Sqlite);
    assert_eq!(sites.last(), Some(&(file!(), line)), "not signaled_mutex.rs: {sites:?}");
}

#[test]
fn request_path_mux_registry_read_records_the_caller_site() {
    let mux = crate::Mux::new_for_test("request-path-mux-read", crate::SurfaceOptions::default());
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let line = line!() + 1;
    mux.terminal_registry_snapshot().expect("terminal snapshot");
    let sites = sites_of(&stats, BlockingKind::Sqlite);
    assert!(!sites.is_empty());
    assert!(
        sites.iter().all(|site| *site == (file!(), line)),
        "not mux/frontend_projection.rs or workspace_registry.rs: {sites:?}"
    );
}

#[test]
fn request_path_setting_parses_or_counts_only() {
    assert_eq!(mode_from_setting(None), RequestPathMode::OFF);
    assert_eq!(mode_from_setting(Some("")), RequestPathMode::OFF);
    assert_eq!(mode_from_setting(Some("record")), RequestPathMode::RECORD);
    assert_eq!(
        mode_from_setting(Some("panic:sleep,journal_wait")).panic_kinds(),
        [BlockingKind::JournalWait, BlockingKind::Sleep]
    );
    assert_eq!(mode_from_setting(Some("panic:disk")), RequestPathMode::OFF, "unknown kind");
    assert_eq!(mode_from_setting(Some("loud")), RequestPathMode::OFF, "unknown mode");
}

#[test]
fn request_path_server_stats_section_reports_counts_and_sites() {
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    {
        let _scope = RequestPathScope::enter(&stats);
        note(BlockingKind::JournalWait);
        note(BlockingKind::LockHoldOver1ms);
    }
    let snapshot = RequestPathIoSnapshot::of(&stats);
    assert!(snapshot.recording);
    assert_eq!(snapshot.scopes, 1);
    assert_eq!(snapshot.journal_wait, 1);
    assert_eq!(snapshot.lock_hold_over_1ms, Some(1));
    assert_eq!(snapshot.sqlite, 0);
    assert_eq!(snapshot.sites.len(), 2);
    assert_eq!(snapshot.sites[0].kind, "lock_hold_over_1ms");
    assert!(snapshot.sites[0].site.starts_with(file!()), "{}", snapshot.sites[0].site);
    let json = serde_json::to_value(&snapshot).expect("json");
    assert_eq!(json["journal_wait"], 1);
    assert_eq!(json["proc_scan"], 0);
    assert_eq!(json["lock_hold_over_1ms"], 1);
}

/// A lock wait of 2 ms or more shows in the section's `lock_waits`, with the
/// holder, the waiter and the waiter's line.
#[test]
fn request_path_server_stats_section_reports_lock_waits() {
    const HOLD: Duration = Duration::from_millis(20);
    cmux_threads::set_holder_tracking(true);
    let shared = Arc::new((std::sync::Mutex::new(()), cmux_threads::LockHolder::default()));
    let (held_tx, held_rx) = channel();
    let holder = {
        let shared = Arc::clone(&shared);
        std::thread::Builder::new()
            .name("section-lock-holder-test".into())
            .spawn(move || {
                let (lock, holder) = &*shared;
                let guard = holder.lock_mutex("test.section", std::panic::Location::caller(), lock);
                held_tx.send(()).expect("held");
                while holder.waiting() == 0 {
                    std::thread::yield_now();
                }
                std::thread::sleep(HOLD);
                drop(guard);
            })
            .expect("spawn holder")
    };
    held_rx.recv().expect("the holder took the lock");
    let line = std::thread::Builder::new()
        .name("section-lock-waiter-test".into())
        .spawn(move || {
            let site = std::panic::Location::caller();
            drop(shared.1.lock_mutex("test.section", site, &shared.0));
            site.line()
        })
        .expect("spawn waiter")
        .join()
        .expect("waiter");
    holder.join().expect("holder");
    let stats = RequestPathStats::new(RequestPathMode::OFF);
    let json = serde_json::to_value(RequestPathIoSnapshot::of(&stats)).expect("json");
    let waits = &json["lock_waits"];
    assert!(waits["long_waits"].as_u64().is_some_and(|count| count >= 1), "{waits}");
    let wait = waits["recent"]
        .as_array()
        .and_then(|recent| recent.iter().find(|wait| wait["waiter"] == "section-lock-waiter-test"))
        .unwrap_or_else(|| panic!("the wait is in the section: {waits}"));
    assert_eq!(wait["lock"], "test.section");
    assert_eq!(wait["holder"], "section-lock-holder-test");
    assert!(wait["waited_us"].as_u64().is_some_and(|us| us >= 20_000), "{wait}");
    assert_eq!(wait["site"], format!("{}:{line}", file!()));
}

#[test]
fn request_path_off_snapshot_counts_without_sites_or_hold_times() {
    let stats = RequestPathStats::new(RequestPathMode::OFF);
    {
        let _scope = RequestPathScope::enter(&stats);
        note(BlockingKind::ChildProcess);
    }
    let snapshot = RequestPathIoSnapshot::of(&stats);
    assert!(!snapshot.recording);
    assert_eq!(snapshot.child_process, 1);
    assert!(snapshot.sites.is_empty());
    let json = serde_json::to_value(&snapshot).expect("json");
    assert!(json.get("lock_hold_over_1ms").is_none(), "not measured, so absent: {json}");
}

/// The modules whose functions sit between a handler and the registry
/// connection. A direct `connection.get()` or `connection.pin()` in a
/// function without `#[track_caller]` records that function's line instead
/// of its caller's. (A call inside a closure takes `get_at(site)` with the
/// site captured before the closure; this scan cannot see closures.)
const CONNECTION_CALLER_ROOTS: [&str; 5] =
    ["workspace_registry.rs", "workspace_registry", "state", "mux.rs", "mux"];

fn rust_sources(path: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    if path.is_dir() {
        for entry in std::fs::read_dir(path).expect("source directory").flatten() {
            rust_sources(&entry.path(), out);
        }
    } else if path.extension().is_some_and(|extension| extension == "rs") {
        out.push(path.to_path_buf());
    }
}

fn is_test_source(path: &std::path::Path) -> bool {
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
    name == "tests.rs"
        || name.ends_with("_tests.rs")
        || path.components().any(|part| part.as_os_str() == "tests")
}

/// The functions in `source` that call the connection directly without
/// `#[track_caller]`, as `name:line`. Stops at the first `#[cfg(test)]`
/// module.
fn untracked_connection_callers(source: &str) -> Vec<String> {
    let lines: Vec<&str> = source.lines().collect();
    let mut missing = Vec::new();
    let mut current: Option<(String, usize, bool)> = None;
    let mut joined = String::new();
    for (index, line) in lines.iter().enumerate() {
        let text = line.trim();
        if text == "#[cfg(test)]"
            && lines.get(index + 1).is_some_and(|next| next.trim_start().starts_with("mod "))
        {
            break;
        }
        if let Some(name) = fn_name(text) {
            let tracked = lines[..index]
                .iter()
                .rev()
                .map(|line| line.trim())
                .take_while(|line| line.starts_with("#[") || line.starts_with("///"))
                // A test-only helper never runs on a request path.
                .any(|line| line == "#[track_caller]" || line == "#[cfg(test)]");
            current = Some((name, index + 1, tracked));
        }
        // Join a chain split over lines (`self.connection\n    .get()`).
        joined.clear();
        joined.push_str(text);
        if text.ends_with("connection")
            && let Some(next) = lines.get(index + 1)
        {
            joined.push_str(next.trim());
        }
        let calls = joined.contains("connection.get()") || joined.contains("connection.pin()");
        if calls
            && let Some((name, line, false)) = &current
            && !missing.iter().any(|entry: &String| entry.starts_with(&format!("{name}:")))
        {
            missing.push(format!("{name}:{line}"));
        }
    }
    missing
}

fn fn_name(text: &str) -> Option<String> {
    let at = text.find("fn ")?;
    let before = &text[..at];
    let modifiers = ["pub", "pub(crate)", "pub(super)", "pub(in", "unsafe", "const", "async"];
    let plain = before.split_whitespace().all(|word| {
        modifiers.iter().any(|modifier| word.starts_with(modifier)) || word.ends_with(')')
    });
    if !plain {
        return None;
    }
    let rest = &text[at + 3..];
    let end = rest.find(|ch: char| !(ch.is_alphanumeric() || ch == '_'))?;
    (end > 0).then(|| rest[..end].to_string())
}

#[test]
fn request_path_every_direct_connection_caller_is_track_caller() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    for part in CONNECTION_CALLER_ROOTS {
        rust_sources(&root.join(part), &mut files);
    }
    assert!(files.len() > 50, "the scan found the sources: {}", files.len());
    let mut missing = Vec::new();
    for file in files.iter().filter(|file| !is_test_source(file)) {
        let source = std::fs::read_to_string(file).expect("source");
        for function in untracked_connection_callers(&source) {
            missing
                .push(format!("{}:{function}", file.strip_prefix(&root).unwrap_or(file).display()));
        }
    }
    assert!(
        missing.is_empty(),
        "mark these #[track_caller] so the registry's sqlite note names the handler:\n{}",
        missing.join("\n")
    );
}

#[test]
fn request_path_connection_caller_scan_sees_a_missing_attribute() {
    let source = "impl R {\n    #[track_caller]\n    pub(crate) fn tracked(&self) {\n        \
                  self.connection.get();\n    }\n    fn untracked(&self) {\n        \
                  self.connection\n            .pin();\n    }\n}\n";
    assert_eq!(untracked_connection_callers(source), ["untracked:6"]);
}
