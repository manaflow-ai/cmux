use super::*;

const GRACE: Duration = Duration::from_secs(600);

fn grace(_: bool) -> Duration {
    GRACE
}

fn facts<'a>(owner: RootOwner, held: Option<&'a HeldHost>) -> HostFacts<'a> {
    HostFacts {
        owner,
        liveness: TerminalHostLiveness::Live,
        incarnation: "i1",
        held,
        reference: Reference::None,
        shell_ended: false,
        unowned_for: None,
    }
}

fn placed(connected: bool) -> HeldHost {
    HeldHost {
        incarnation: "i1".into(),
        surfaces: vec![7],
        connected,
        placements: vec![Placement {
            surface: 7,
            pane: "pane:1".into(),
            pane_name: None,
            workspace: Some("workspace:1".into()),
            workspace_name: Some("main".into()),
        }],
        last_output_ms: None,
    }
}

#[test]
fn a_host_this_daemon_adopted_and_shows_is_in_use_and_never_a_candidate() {
    // The host's argv still names the dead daemon that launched it; nothing
    // here reads argv: the answering daemon holds its stream.
    let held = placed(true);
    let verdict = classify(&facts(RootOwner::ThisDaemon, Some(&held)), grace);
    assert_eq!(verdict.state, HostState::InUse);
    assert!(verdict.stream_held);
    assert!(!verdict.gc.candidate);
    assert_eq!(verdict.gc.refusal.as_deref(), Some("a live daemon holds its stream"));
}

#[test]
fn a_held_host_no_pane_shows_is_idle_and_refused() {
    let held = HeldHost { placements: Vec::new(), ..placed(true) };
    let verdict = classify(&facts(RootOwner::ThisDaemon, Some(&held)), grace);
    assert_eq!(verdict.state, HostState::Idle);
    assert!(verdict.stream_held);
    assert!(!verdict.gc.candidate);
}

#[test]
fn a_reconnecting_surface_does_not_hold_the_stream_but_still_refuses_gc() {
    let held = placed(false);
    let verdict = classify(&facts(RootOwner::ThisDaemon, Some(&held)), grace);
    assert_eq!(verdict.state, HostState::InUse);
    assert!(!verdict.stream_held);
    assert!(!verdict.gc.candidate);
}

#[test]
fn another_incarnation_held_reads_unknown() {
    let held = HeldHost { incarnation: "i0".into(), ..placed(true) };
    let verdict = classify(&facts(RootOwner::ThisDaemon, Some(&held)), grace);
    assert_eq!(verdict.state, HostState::Unknown);
    assert!(!verdict.stream_held);
    assert!(!verdict.gc.candidate);
}

#[test]
fn referenced_but_not_held_reads_unknown_and_is_refused() {
    let verdict = classify(
        &HostFacts { reference: Reference::Referenced, ..facts(RootOwner::ThisDaemon, None) },
        grace,
    );
    assert_eq!(verdict.state, HostState::Unknown);
    assert_eq!(verdict.gc.refusal.as_deref(), Some("a live workspace references it"));
}

#[test]
fn an_unnamed_host_in_a_live_daemons_root_is_orphaned_but_refused() {
    let verdict = classify(&facts(RootOwner::ThisDaemon, None), grace);
    assert_eq!(verdict.state, HostState::Orphaned);
    assert!(!verdict.gc.candidate);
    assert_eq!(verdict.gc.refusal.as_deref(), Some("a live daemon owns its root"));
}

#[test]
fn a_root_another_live_daemon_owns_is_in_use() {
    let verdict = classify(
        &HostFacts { unowned_for: Some(GRACE * 10), ..facts(RootOwner::LiveDaemon, None) },
        grace,
    );
    assert_eq!(verdict.state, HostState::InUse);
    assert!(!verdict.gc.candidate);
}

#[test]
fn a_root_with_no_provable_owner_is_unknown() {
    for owner in [RootOwner::NoGuard, RootOwner::Unnamed] {
        let verdict =
            classify(&HostFacts { unowned_for: Some(GRACE * 10), ..facts(owner, None) }, grace);
        assert_eq!(verdict.state, HostState::Unknown, "{owner:?}");
        assert!(!verdict.gc.candidate, "{owner:?}");
    }
}

#[test]
fn an_indeterminate_lease_is_never_a_candidate() {
    for owner in [RootOwner::Free, RootOwner::ThisDaemon, RootOwner::NoGuard, RootOwner::Unnamed] {
        let verdict = classify(
            &HostFacts {
                liveness: TerminalHostLiveness::Indeterminate,
                unowned_for: Some(GRACE * 10),
                ..facts(owner, None)
            },
            grace,
        );
        assert_eq!(verdict.state, HostState::Unknown, "{owner:?}");
        assert_eq!(verdict.gc.refusal.as_deref(), Some("its lease is indeterminate"));
    }
}

#[test]
fn an_adopted_legacy_host_a_live_daemon_holds_or_owns_reads_in_use_with_an_unreadable_lease() {
    // A v1 host has no lease the census can read; the daemon that adopted it
    // holds its stream and shows it, so it is in use, not unknown.
    let held = placed(true);
    let shown = classify(
        &HostFacts {
            liveness: TerminalHostLiveness::Indeterminate,
            ..facts(RootOwner::ThisDaemon, Some(&held))
        },
        grace,
    );
    assert_eq!(shown.state, HostState::InUse);
    assert!(shown.stream_held);
    assert!(!shown.gc.candidate);
    assert!(shown.reason.contains("lease cannot be read"), "{}", shown.reason);

    let idle_held = HeldHost { placements: Vec::new(), ..placed(true) };
    let idle = classify(
        &HostFacts {
            liveness: TerminalHostLiveness::Indeterminate,
            ..facts(RootOwner::ThisDaemon, Some(&idle_held))
        },
        grace,
    );
    assert_eq!(idle.state, HostState::Idle);
    assert!(!idle.gc.candidate);

    let other = classify(
        &HostFacts {
            liveness: TerminalHostLiveness::Indeterminate,
            ..facts(RootOwner::LiveDaemon, None)
        },
        grace,
    );
    assert_eq!(other.state, HostState::InUse);
    assert!(!other.gc.candidate);
}

#[test]
fn an_unreadable_registry_of_this_daemon_reads_unknown_never_orphaned() {
    let verdict = classify(
        &HostFacts {
            reference: Reference::Unreadable("disk I/O error"),
            ..facts(RootOwner::ThisDaemon, None)
        },
        grace,
    );
    assert_eq!(verdict.state, HostState::Unknown);
    assert!(!verdict.gc.candidate);
    assert!(verdict.reason.contains("disk I/O error"), "{}", verdict.reason);
    // Still in use when held: a held host needs no registry to prove it.
    let held = placed(true);
    let shown = classify(
        &HostFacts {
            reference: Reference::Unreadable("disk I/O error"),
            ..facts(RootOwner::ThisDaemon, Some(&held))
        },
        grace,
    );
    assert_eq!(shown.state, HostState::InUse);
}

#[test]
fn a_free_root_host_its_stored_registry_references_is_refused() {
    let referenced = classify(
        &HostFacts {
            reference: Reference::Referenced,
            unowned_for: Some(GRACE * 10),
            ..facts(RootOwner::Free, None)
        },
        grace,
    );
    assert_eq!(referenced.state, HostState::Orphaned);
    assert!(!referenced.gc.candidate);
    assert_eq!(referenced.gc.refusal.as_deref(), Some("referenced by an unrestored workspace"));

    let unreadable = classify(
        &HostFacts {
            reference: Reference::Unreadable("locked"),
            unowned_for: Some(GRACE * 10),
            ..facts(RootOwner::Free, None)
        },
        grace,
    );
    assert_eq!(unreadable.state, HostState::Unknown);
    assert!(!unreadable.gc.candidate);
}

#[test]
fn a_free_root_host_is_a_candidate_only_past_its_grace() {
    let fresh = classify(
        &HostFacts { unowned_for: Some(GRACE / 2), ..facts(RootOwner::Free, None) },
        grace,
    );
    assert_eq!(fresh.state, HostState::Orphaned);
    assert!(!fresh.gc.candidate);
    assert!(fresh.gc.refusal.as_deref().is_some_and(|why| why.starts_with("in its grace")));

    let unknown = classify(&facts(RootOwner::Free, None), grace);
    assert_eq!(unknown.state, HostState::Orphaned);
    assert!(!unknown.gc.candidate);
    assert_eq!(
        unknown.gc.refusal.as_deref(),
        Some("first seen unowned now: its grace of 600 s starts now")
    );
    assert_eq!(unknown.gc.unowned_for_ms, Some(0));

    let due =
        classify(&HostFacts { unowned_for: Some(GRACE), ..facts(RootOwner::Free, None) }, grace);
    assert_eq!(due.state, HostState::Orphaned);
    assert!(due.gc.candidate);
    assert_eq!(due.gc.refusal, None);
    assert_eq!(due.gc.grace_ms, Some(600_000));
}

#[test]
fn the_grace_shortens_once_the_shell_ended() {
    let short = |ended: bool| if ended { Duration::from_secs(60) } else { GRACE };
    let base =
        HostFacts { unowned_for: Some(Duration::from_secs(120)), ..facts(RootOwner::Free, None) };
    assert!(!classify(&base, short).gc.candidate);
    assert!(classify(&HostFacts { shell_ended: true, ..base }, short).gc.candidate);
}

#[test]
fn scan_names_each_roots_owner_from_its_session_guard() {
    let dir = std::env::temp_dir().join(format!("census-owners-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let own = crate::terminal_host_runtime::terminal_host_root(&dir, "mine");
    let held = crate::terminal_host_runtime::terminal_host_root(&dir, "cmux-app-held");
    let free = crate::terminal_host_runtime::terminal_host_root(&dir, "cmux-app-free");
    let nameless = crate::terminal_host_runtime::terminal_host_root(&dir, "gone");
    for root in [&own, &held, &free, &nameless] {
        std::fs::create_dir_all(root).unwrap();
    }
    let _guard =
        crate::workspace_registry::start_session_guard_for_test(&dir, "cmux-app-held").unwrap();
    let free_component = crate::workspace_registry::session_guard_component("cmux-app-free");
    std::fs::write(dir.join("session-locks").join(format!("{free_component}.lock")), b"").unwrap();

    let owners = |view: Option<&OwnView>, probe: Probe| {
        list_roots(&dir, view)
            .into_iter()
            .map(|listed| scan_root(listed, probe, &CensusOps::REAL))
            .map(|root| (root.record_root.clone(), root.owner))
            .collect::<HashMap<_, _>>()
    };
    for probe in [Probe::Peek, Probe::Lease] {
        let offline = owners(None, probe);
        assert_eq!(offline.get(&held), Some(&RootOwner::LiveDaemon));
        assert_eq!(offline.get(&free), Some(&RootOwner::Free));
        assert_eq!(offline.get(&nameless), Some(&RootOwner::Unnamed));
        assert_eq!(offline.get(&own), Some(&RootOwner::Unnamed));
    }

    let view = OwnView { record_root: own.clone(), ..OwnView::default() };
    let daemon = owners(Some(&view), Probe::Peek);
    assert_eq!(daemon.get(&own), Some(&RootOwner::ThisDaemon));
    assert_eq!(daemon.get(&held), Some(&RootOwner::LiveDaemon));
    assert_eq!(daemon.len(), 4, "{daemon:?}");

    // A dropped scan lets go of the free root: its session can start.
    let session = crate::workspace_registry::start_session_guard_for_test(&dir, "cmux-app-free");
    assert!(session.is_ok(), "{:?}", session.as_ref().err());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_answering_daemons_root_is_listed_once_as_its_own() {
    let dir = std::env::temp_dir().join(format!("census-dedup-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    // Named `aaa` so that its path sorts before the other root's.
    let own = crate::terminal_host_runtime::terminal_host_root(&dir, "aaa");
    let other = crate::terminal_host_runtime::terminal_host_root(&dir, "zzz");
    for root in [&own, &other] {
        std::fs::create_dir_all(root).unwrap();
    }
    let view = OwnView { record_root: own.clone(), ..OwnView::default() };
    let listed = list_roots(&dir, Some(&view));
    let own_entries = listed.iter().filter(|entry| entry.1 == own).collect::<Vec<_>>();
    assert_eq!(own_entries.len(), 1, "{listed:?}");
    assert!(own_entries[0].3, "the root's entry must be the daemon's own: {listed:?}");
    assert_eq!(listed.len(), 2, "{listed:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_peek_never_holds_the_guard_a_starting_session_needs() {
    let dir = std::env::temp_dir().join(format!("census-peek-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("session-locks")).unwrap();
    let component = crate::workspace_registry::session_guard_component("cmux-app-peek");
    std::fs::write(dir.join("session-locks").join(format!("{component}.lock")), b"").unwrap();
    assert_eq!(peek_session_owner(&dir, &component), SessionOwnerPeek::Unowned);
    let session = crate::workspace_registry::start_session_guard_for_test(&dir, "cmux-app-peek");
    assert!(session.is_ok(), "{:?}", session.as_ref().err());
    assert_eq!(peek_session_owner(&dir, &component), SessionOwnerPeek::Owned);
    drop(session);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn gc_on_roots_with_no_records_ends_nothing() {
    let dir = std::env::temp_dir().join(format!("census-gc-empty-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(crate::terminal_host_runtime::terminal_host_root(&dir, "a")).unwrap();
    let ended = std::cell::Cell::new(0);
    let end = |_: &TerminalHostRecord, _: &Path| {
        ended.set(ended.get() + 1);
        HostEnd::Done(true)
    };
    let ops = CensusOps { end: &end, ..CensusOps::REAL };
    let report = gc_with(&dir, true, &ops);
    assert!(report.applied);
    assert!(report.candidates.is_empty());
    assert_eq!(ended.get(), 0);
    let _ = std::fs::remove_dir_all(&dir);
}

const FREE_SESSION: &str = "cmux-app-free";

/// A state root with one session, `FREE_SESSION`, whose guard file exists
/// and is free: (state root, its record root, its guard component).
fn free_state(name: &str) -> (PathBuf, PathBuf, String) {
    let dir = std::env::temp_dir().join(format!("census-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let root = crate::terminal_host_runtime::terminal_host_root(&dir, FREE_SESSION);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(dir.join("session-locks")).unwrap();
    let component = crate::workspace_registry::session_guard_component(FREE_SESSION);
    std::fs::write(dir.join("session-locks").join(format!("{component}.lock")), b"").unwrap();
    (dir, root, component)
}

fn host_record(root: &Path, id: &str) -> (PathBuf, TerminalHostRecord) {
    let record = TerminalHostRecord {
        record_version: 4,
        terminal_id: id.into(),
        incarnation: "i1".into(),
        host_pid: 4242,
        ..Default::default()
    };
    (root.join(format!("{id}.json")), record)
}

fn live(_: &Path, _: &TerminalHostRecord) -> TerminalHostLiveness {
    TerminalHostLiveness::Live
}

fn no_grace(_: bool) -> Duration {
    Duration::ZERO
}

fn gc_log_events(dir: &Path) -> Vec<(String, String)> {
    std::fs::read_to_string(dir.join(crate::terminal_loss_log::GC_LOG_FILE))
        .unwrap_or_default()
        .lines()
        .map(|line| {
            let value: serde_json::Value = serde_json::from_str(line).unwrap();
            (
                value["event"].as_str().unwrap_or_default().to_string(),
                value["terminal_id"].as_str().unwrap_or_default().to_string(),
            )
        })
        .collect()
}

#[test]
fn gc_apply_ends_a_free_roots_host_past_grace_once_and_logs_intent_then_outcome() {
    let (dir, root, _) = free_state("gc-apply");
    let load = |at: &Path| -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        Ok(if at == root { vec![host_record(at, "t1")] } else { Vec::new() })
    };
    let ended = std::cell::RefCell::new(Vec::new());
    let end = |record: &TerminalHostRecord, _: &Path| {
        ended.borrow_mut().push(record.terminal_id.clone());
        HostEnd::Done(true)
    };
    let ops = CensusOps { load: &load, liveness: &live, end: &end, grace: &no_grace };
    let report = gc_with(&dir, true, &ops);
    assert_eq!(*ended.borrow(), vec!["t1".to_string()]);
    assert_eq!(report.ended, 1);
    assert_eq!(report.failed, 0);
    assert_eq!(report.candidates.len(), 1, "{report:?}");
    assert_eq!(report.candidates[0].outcome.as_deref(), Some("ended"));
    assert!(report.errors.is_empty(), "{:?}", report.errors);
    assert_eq!(
        gc_log_events(&dir),
        vec![
            ("host_gc_ending".to_string(), "t1".to_string()),
            ("host_gc_ended".to_string(), "t1".to_string()),
        ]
    );
    assert_eq!(
        report.logs,
        vec![dir.join(crate::terminal_loss_log::GC_LOG_FILE).display().to_string()]
    );
    // gc let go of the root's guard: its session can start now.
    let session = crate::workspace_registry::start_session_guard_for_test(&dir, FREE_SESSION);
    assert!(session.is_ok(), "{:?}", session.as_ref().err());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_dry_run_lists_the_candidate_but_never_ends_or_logs() {
    let (dir, root, _) = free_state("gc-dry");
    let load = |at: &Path| -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        Ok(if at == root { vec![host_record(at, "t1")] } else { Vec::new() })
    };
    let ended = std::cell::Cell::new(0);
    let end = |_: &TerminalHostRecord, _: &Path| {
        ended.set(ended.get() + 1);
        HostEnd::Done(true)
    };
    let ops = CensusOps { load: &load, liveness: &live, end: &end, grace: &no_grace };
    let report = gc_with(&dir, false, &ops);
    assert!(!report.applied);
    assert_eq!(report.candidates.len(), 1, "{report:?}");
    assert_eq!(report.candidates[0].outcome, None);
    assert_eq!(ended.get(), 0);
    assert!(gc_log_events(&dir).is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_guard_replaced_by_one_end_skips_the_rest_of_its_root() {
    let (dir, root, component) = free_state("gc-replaced");
    let guard = dir.join("session-locks").join(format!("{component}.lock"));
    let load = |at: &Path| -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        Ok(if at == root { vec![host_record(at, "t1"), host_record(at, "t2")] } else { Vec::new() })
    };
    // The first end deletes and remakes the guard file, as a session
    // starting on a fresh guard would.
    let ended = std::cell::Cell::new(0);
    let end = |_: &TerminalHostRecord, _: &Path| {
        ended.set(ended.get() + 1);
        std::fs::remove_file(&guard).unwrap();
        std::fs::write(&guard, b"").unwrap();
        HostEnd::Done(true)
    };
    let ops = CensusOps { load: &load, liveness: &live, end: &end, grace: &no_grace };
    let report = gc_with(&dir, true, &ops);
    assert_eq!(ended.get(), 1);
    let outcomes =
        report.candidates.iter().map(|candidate| candidate.outcome.clone()).collect::<Vec<_>>();
    assert_eq!(
        outcomes,
        vec![Some("ended".into()), Some("skipped: its session guard was replaced".into())]
    );
    let events = gc_log_events(&dir).into_iter().map(|(event, _)| event).collect::<Vec<_>>();
    assert_eq!(events, ["host_gc_ending", "host_gc_ended", "host_gc_ending", "host_gc_skipped"]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn end_candidate_reports_each_outcome() {
    let (dir, root, component) = free_state("gc-outcomes");
    let (record_path, record) = host_record(&root, "t1");
    let verdict = classify(&facts(RootOwner::Free, None), grace);
    let scan = |lease: Option<SessionLease>| RootScan {
        state_root: dir.clone(),
        record_root: root.clone(),
        component: Some(component.clone()),
        owner: RootOwner::Free,
        lease,
        owner_last_active: None,
        owner_mark: Some(String::new()),
        stored: Ok(HashSet::new()),
        records: Vec::new(),
        error: None,
    };
    let lease = || match probe_session_owner(&dir, &component) {
        SessionOwnerProbe::Unowned(lease) => Some(lease),
        _ => panic!("the guard is free"),
    };
    let outcome = |root: &RootScan, ops: &CensusOps<'_>| {
        let host = ScannedHost {
            root,
            record_path: &record_path,
            record: &record,
            liveness: TerminalHostLiveness::Live,
            shell_ended: false,
            verdict: verdict.clone(),
        };
        end_candidate(&host, ops)
    };
    let ends_cell = std::cell::Cell::new(0);
    let ends = &ends_cell;
    let counted = |answer: fn() -> HostEnd| {
        move |_: &TerminalHostRecord, _: &Path| {
            ends.set(ends.get() + 1);
            answer()
        }
    };
    let done_true = counted(|| HostEnd::Done(true));
    let done_false = counted(|| HostEnd::Done(false));
    let waits_ended = counted(|| HostEnd::Requested(Box::new(|| true)));
    let waits_failed = counted(|| HostEnd::Requested(Box::new(|| false)));
    let dead = |_: &Path, _: &TerminalHostRecord| TerminalHostLiveness::Dead;
    let with = |end: &dyn Fn(&TerminalHostRecord, &Path) -> HostEnd| -> String {
        let scanned = scan(lease());
        let ops = CensusOps { liveness: &live, end, ..CensusOps::REAL };
        outcome(&scanned, &ops)
    };
    assert_eq!(with(&done_true), "ended");
    assert_eq!(with(&done_false), "failed");
    assert_eq!(with(&waits_ended), "ended");
    assert_eq!(with(&waits_failed), "failed");
    assert_eq!(ends.get(), 4);

    // No lease, or a host that no longer proves live: end is never asked.
    let unleased = scan(None);
    let ops_live = CensusOps { liveness: &live, end: &done_true, ..CensusOps::REAL };
    assert_eq!(outcome(&unleased, &ops_live), "skipped: its session guard is no longer held here");
    let leased = scan(lease());
    let ops_dead = CensusOps { liveness: &dead, end: &done_true, ..CensusOps::REAL };
    assert_eq!(outcome(&leased, &ops_dead), "skipped: the host no longer proves live");
    drop(leased);
    assert_eq!(ends.get(), 4);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Sets the newest file of the free session's directory far in the past.
fn quiet_session_dir(dir: &Path, component: &str, age: Duration) {
    let session = dir.join(component);
    std::fs::create_dir_all(&session).unwrap();
    let file = std::fs::File::create(session.join("startup-timings.jsonl")).unwrap();
    file.set_modified(SystemTime::now() - age).unwrap();
}

#[test]
fn a_long_quiet_session_is_no_head_start_its_grace_counts_from_the_first_sighting() {
    let (dir, root, component) = free_state("gc-clock");
    // The session's last write was a week ago: the old clock made every host
    // an instant candidate.
    quiet_session_dir(&dir, &component, Duration::from_secs(7 * 24 * 60 * 60));
    let load = |at: &Path| -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        Ok(if at == root { vec![host_record(at, "t1")] } else { Vec::new() })
    };
    let ended = std::cell::Cell::new(0);
    let end = |_: &TerminalHostRecord, _: &Path| {
        ended.set(ended.get() + 1);
        HostEnd::Done(true)
    };
    let fixed = |_: bool| GRACE;
    let ops = CensusOps { load: &load, liveness: &live, end: &end, grace: &fixed };

    let first = gc_with(&dir, true, &ops);
    assert!(first.candidates.is_empty(), "{first:?}");
    assert_eq!(first.refused.len(), 1, "{first:?}");
    assert!(first.refused[0].refusal.starts_with("first seen unowned now"), "{first:?}");
    assert_eq!(ended.get(), 0);

    // The census reads the clock gc started.
    let census = census_with(&dir, None, &ops);
    assert_eq!(census.hosts.len(), 1);
    assert!(!census.hosts[0].gc.candidate);
    assert!(
        census.hosts[0].gc.refusal.as_deref().is_some_and(|why| why.starts_with("in its grace"))
    );

    // Seen unowned for longer than the grace (as saved by an earlier gc):
    // now it is a candidate.
    let path = dir.join(super::super::unowned_hosts::SIGHTINGS_FILE);
    let mut saved: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let key = sighting_key(&root, "t1", "i1");
    let seen = &mut saved["hosts"][key.as_str()];
    let at = seen["first_seen_ms"].as_u64().unwrap();
    seen["first_seen_ms"] = serde_json::json!(at - millis(GRACE * 2));
    std::fs::write(&path, saved.to_string()).unwrap();
    let due = gc_with(&dir, false, &ops);
    assert_eq!(due.candidates.len(), 1, "{due:?}");

    // An owner ran since (its session directory changed): the grace restarts.
    std::fs::write(dir.join(&component).join("workspace-registry.sqlite3-wal"), b"x").unwrap();
    let restarted = gc_with(&dir, false, &ops);
    assert!(restarted.candidates.is_empty(), "{restarted:?}");
    assert_eq!(ended.get(), 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_reapers_saved_sighting_is_the_same_clock_for_gc() {
    let (dir, root, component) = free_state("gc-shared-clock");
    let load = |at: &Path| -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        Ok(if at == root { vec![host_record(at, "t1")] } else { Vec::new() })
    };
    let fixed = |_: bool| GRACE;
    let ops =
        CensusOps { load: &load, liveness: &live, end: &|_, _| HostEnd::Done(true), grace: &fixed };
    // Another session's reaper saw the host unowned twice the grace ago.
    let reaper_session = dir.join("reaper-session");
    std::fs::create_dir_all(&reaper_session).unwrap();
    let mark = session_owner_mark(&dir, &component);
    let key = sighting_key(&root, "t1", "i1");
    let store = serde_json::json!({
        "hosts": { key: { "first_seen_ms": now_ms() - millis(GRACE * 2), "owner_mark": mark } }
    });
    std::fs::write(reaper_session.join(super::super::unowned_hosts::STORE_FILE), store.to_string())
        .unwrap();
    let report = gc_with(&dir, false, &ops);
    assert_eq!(report.candidates.len(), 1, "{report:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn gc_refuses_a_host_an_unrestored_workspace_of_a_free_session_references() {
    let (dir, root, component) = free_state("gc-referenced");
    let session = dir.join(&component);
    std::fs::create_dir_all(&session).unwrap();
    {
        let db = rusqlite::Connection::open(session.join("workspace-registry.sqlite3")).unwrap();
        db.execute_batch(
            "CREATE TABLE terminal_hosts(terminal_id TEXT, lifecycle TEXT);
             INSERT INTO terminal_hosts VALUES ('t1', 'running'), ('t2', 'tombstoned');",
        )
        .unwrap();
    }
    let load = |at: &Path| -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        Ok(if at == root { vec![host_record(at, "t1"), host_record(at, "t2")] } else { Vec::new() })
    };
    let ended = std::cell::RefCell::new(Vec::new());
    let end = |record: &TerminalHostRecord, _: &Path| {
        ended.borrow_mut().push(record.terminal_id.clone());
        HostEnd::Done(true)
    };
    let ops = CensusOps { load: &load, liveness: &live, end: &end, grace: &no_grace };
    let report = gc_with(&dir, true, &ops);
    assert_eq!(*ended.borrow(), vec!["t2".to_string()], "{report:?}");
    assert_eq!(report.refused.len(), 1, "{report:?}");
    assert_eq!(report.refused[0].terminal_id, "t1");
    assert_eq!(report.refused[0].refusal, "referenced by an unrestored workspace");

    // A registry that cannot be read refuses every host of its root.
    std::fs::write(session.join("workspace-registry.sqlite3"), b"not a database").unwrap();
    ended.borrow_mut().clear();
    let report = gc_with(&dir, true, &ops);
    assert!(ended.borrow().is_empty(), "{report:?}");
    assert!(report.candidates.is_empty(), "{report:?}");
    assert!(
        report
            .refused
            .iter()
            .all(|host| host.refusal == "its session's workspace registry cannot be read"),
        "{report:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_census_of_this_daemon_with_an_unreadable_registry_reports_unknown() {
    let dir = std::env::temp_dir().join(format!("census-own-unreadable-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let own = crate::terminal_host_runtime::terminal_host_root(&dir, "mine");
    std::fs::create_dir_all(&own).unwrap();
    let load = |at: &Path| -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        Ok(if at == own { vec![host_record(at, "t1")] } else { Vec::new() })
    };
    let ops = CensusOps { load: &load, liveness: &live, ..CensusOps::REAL };
    let view = OwnView {
        daemon_pid: std::process::id(),
        record_root: own.clone(),
        referenced_error: Some("database is locked".into()),
        ..OwnView::default()
    };
    let census = census_with(&dir, Some(&view), &ops);
    assert_eq!(census.hosts.len(), 1, "{census:?}");
    assert_eq!(census.hosts[0].state, HostState::Unknown);
    assert!(census.hosts[0].reason.contains("database is locked"));
    let _ = std::fs::remove_dir_all(&dir);
}

fn session_files(session: &Path) -> Vec<String> {
    let mut names = std::fs::read_dir(session)
        .unwrap()
        .flatten()
        .map(|entry| {
            let meta = entry.metadata().unwrap();
            format!(
                "{} {} {:?}",
                entry.file_name().to_string_lossy(),
                meta.len(),
                meta.modified().ok()
            )
        })
        .collect::<Vec<_>>();
    names.sort();
    names
}

#[test]
fn reading_a_wal_registry_leaves_the_owner_mark_and_the_gc_clock_alone() {
    // The registry is in WAL mode: a read-only open leaves `-shm` and an
    // empty `-wal` behind and writes `-shm` on each read. None of that is an
    // owner run, so the grace must keep counting across reads.
    let (dir, root, component) = free_state("gc-wal");
    let session = dir.join(&component);
    std::fs::create_dir_all(&session).unwrap();
    {
        let db = rusqlite::Connection::open(session.join("workspace-registry.sqlite3")).unwrap();
        db.execute_batch(
            "PRAGMA journal_mode=WAL;
             CREATE TABLE terminal_hosts(terminal_id TEXT, lifecycle TEXT);
             INSERT INTO terminal_hosts VALUES ('t0', 'running');",
        )
        .unwrap();
    }
    let load = |at: &Path| -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        Ok(if at == root { vec![host_record(at, "t1")] } else { Vec::new() })
    };
    let ended = std::cell::Cell::new(0);
    let end = |_: &TerminalHostRecord, _: &Path| {
        ended.set(ended.get() + 1);
        HostEnd::Done(true)
    };
    let fixed = |_: bool| GRACE;
    let ops = CensusOps { load: &load, liveness: &live, end: &end, grace: &fixed };

    let before = session_owner_mark(&dir, &component);
    for _ in 0..2 {
        let census = census_with(&dir, None, &ops);
        assert_eq!(census.hosts.len(), 1, "{census:?}");
    }
    assert_eq!(
        session_owner_mark(&dir, &component),
        before,
        "reading the registry changed the owner mark: {:?}",
        session_files(&session)
    );

    // gc starts the clock, then (as if the grace passed) finds it due.
    let first = gc_with(&dir, false, &ops);
    assert!(first.candidates.is_empty(), "{first:?}");
    let path = dir.join(super::super::unowned_hosts::SIGHTINGS_FILE);
    let mut saved: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let key = sighting_key(&root, "t1", "i1");
    let seen = &mut saved["hosts"][key.as_str()];
    let at = seen["first_seen_ms"].as_u64().unwrap();
    seen["first_seen_ms"] = serde_json::json!(at - millis(GRACE * 2));
    std::fs::write(&path, saved.to_string()).unwrap();
    let due = gc_with(&dir, true, &ops);
    assert_eq!(due.candidates.len(), 1, "{due:?} {:?}", session_files(&session));
    assert_eq!(due.ended, 1, "{due:?}");
    assert_eq!(ended.get(), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_census_records_no_sightings() {
    let (dir, root, _) = free_state("census-no-write");
    let load = |at: &Path| -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        Ok(if at == root { vec![host_record(at, "t1")] } else { Vec::new() })
    };
    let fixed = |_: bool| GRACE;
    let ops =
        CensusOps { load: &load, liveness: &live, end: &|_, _| HostEnd::Done(true), grace: &fixed };
    let census = census_with(&dir, None, &ops);
    assert_eq!(census.hosts.len(), 1, "{census:?}");
    assert!(!dir.join(super::super::unowned_hosts::SIGHTINGS_FILE).exists());
    assert!(!dir.join("unowned-terminal-host-sightings.lock").exists());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_unwritable_intent_log_never_ends_the_host() {
    let (dir, root, _) = free_state("gc-no-log");
    // A directory where the gc log goes: no line can be appended.
    std::fs::create_dir_all(dir.join(crate::terminal_loss_log::GC_LOG_FILE)).unwrap();
    let load = |at: &Path| -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        Ok(if at == root { vec![host_record(at, "t1")] } else { Vec::new() })
    };
    let ended = std::cell::Cell::new(0);
    let end = |_: &TerminalHostRecord, _: &Path| {
        ended.set(ended.get() + 1);
        HostEnd::Done(true)
    };
    let ops = CensusOps { load: &load, liveness: &live, end: &end, grace: &no_grace };
    let report = gc_with(&dir, true, &ops);
    assert_eq!(ended.get(), 0, "{report:?}");
    assert_eq!(report.ended, 0);
    assert_eq!(report.candidates.len(), 1, "{report:?}");
    assert!(
        report.candidates[0]
            .outcome
            .as_deref()
            .is_some_and(|outcome| outcome.starts_with("skipped: its gc log cannot be written")),
        "{report:?}"
    );
    assert!(report.errors.iter().any(|error| error.starts_with("gc log for t1")), "{report:?}");
    assert!(report.logs.is_empty(), "{report:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_sightings_file_that_cannot_be_saved_is_reported() {
    let (dir, root, _) = free_state("gc-no-save");
    // A directory where the temporary sightings file goes: the save fails.
    std::fs::create_dir_all(
        dir.join(super::super::unowned_hosts::SIGHTINGS_FILE).with_extension("json.tmp"),
    )
    .unwrap();
    let load = |at: &Path| -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        Ok(if at == root { vec![host_record(at, "t1")] } else { Vec::new() })
    };
    let fixed = |_: bool| GRACE;
    let ops =
        CensusOps { load: &load, liveness: &live, end: &|_, _| HostEnd::Done(true), grace: &fixed };
    let report = gc_with(&dir, false, &ops);
    assert!(
        report.errors.iter().any(|error| error.starts_with("saving the unowned-host sightings")),
        "{report:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
