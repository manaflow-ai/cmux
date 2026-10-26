//! Request-path notes at the daemon's blocking sites: the registry connection,
//! the process sampler behind `terminal-resources`, and the `server-stats`
//! section.

use super::*;
use crate::WorkspaceRegistry;

#[test]
fn request_path_registry_read_records_the_handler_site() {
    let registry = WorkspaceRegistry::in_memory("request-path").expect("registry");
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let line = line!() + 1;
    registry.terminal_revision().expect("terminal revision");
    assert_eq!(stats.count(BlockingKind::Sqlite), 1);
    let sites = stats.sites();
    let sqlite = sites.iter().find(|noted| noted.kind == BlockingKind::Sqlite).expect("sqlite");
    assert_eq!(
        (sqlite.site.file(), sqlite.site.line()),
        (file!(), line),
        "the read's caller, not registry_connection.rs or workspace_registry.rs"
    );
}

#[test]
fn request_path_registry_read_outside_a_scope_notes_nothing() {
    let registry = WorkspaceRegistry::in_memory("request-path-outside").expect("registry");
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    registry.terminal_revision().expect("terminal revision");
    assert_eq!(stats.count(BlockingKind::Sqlite), 0);
    assert!(!in_scope());
}

#[test]
fn request_path_terminal_resources_sampler_is_a_proc_scan() {
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let line = line!() + 1;
    let _sampler = crate::process_resources::Sampler::new();
    assert_eq!(stats.count(BlockingKind::ProcScan), 1);
    let site = stats.sites()[0];
    assert_eq!(site.kind, BlockingKind::ProcScan);
    assert_eq!((site.site.file(), site.site.line()), (file!(), line));
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
    assert_eq!(snapshot.lock_hold_over_1ms, 1);
    assert_eq!(snapshot.sqlite, 0);
    assert_eq!(snapshot.sites.len(), 2);
    assert_eq!(snapshot.sites[0].kind, "lock_hold_over_1ms");
    assert!(snapshot.sites[0].site.starts_with(file!()), "{}", snapshot.sites[0].site);
    let json = serde_json::to_value(&snapshot).expect("json");
    assert_eq!(json["journal_wait"], 1);
    assert_eq!(json["proc_scan"], 0);
}

#[test]
fn request_path_off_snapshot_counts_without_sites() {
    let stats = RequestPathStats::new(RequestPathMode::OFF);
    {
        let _scope = RequestPathScope::enter(&stats);
        note(BlockingKind::ChildProcess);
    }
    let snapshot = RequestPathIoSnapshot::of(&stats);
    assert!(!snapshot.recording);
    assert_eq!(snapshot.child_process, 1);
    assert!(snapshot.sites.is_empty());
}
