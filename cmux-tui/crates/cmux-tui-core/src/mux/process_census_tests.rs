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
        referenced: false,
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
    let verdict =
        classify(&HostFacts { referenced: true, ..facts(RootOwner::ThisDaemon, None) }, grace);
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
    for owner in [RootOwner::Free, RootOwner::ThisDaemon, RootOwner::LiveDaemon] {
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

    let owners = |view: Option<&OwnView>| {
        scan_roots(&dir, view, false)
            .into_iter()
            .map(|root| (root.record_root, root.owner))
            .collect::<HashMap<_, _>>()
    };
    let offline = owners(None);
    assert_eq!(offline.get(&held), Some(&RootOwner::LiveDaemon));
    assert_eq!(offline.get(&free), Some(&RootOwner::Free));
    assert_eq!(offline.get(&nameless), Some(&RootOwner::Unnamed));
    assert_eq!(offline.get(&own), Some(&RootOwner::Unnamed));

    let view = OwnView { record_root: own.clone(), ..OwnView::default() };
    let daemon = owners(Some(&view));
    assert_eq!(daemon.get(&own), Some(&RootOwner::ThisDaemon));
    assert_eq!(daemon.get(&held), Some(&RootOwner::LiveDaemon));
    assert_eq!(daemon.len(), 4, "{daemon:?}");

    // The probe of a free root lets go of its lease: the session can start.
    assert!(matches!(
        crate::workspace_registry::probe_session_owner(&dir, &free_component),
        SessionOwnerProbe::Unowned(_)
    ));
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
    let report = gc_with(&dir, true, &end);
    assert!(report.applied);
    assert!(report.candidates.is_empty());
    assert_eq!(ended.get(), 0);
    let _ = std::fs::remove_dir_all(&dir);
}
