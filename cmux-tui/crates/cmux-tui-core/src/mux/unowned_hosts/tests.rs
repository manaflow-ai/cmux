use super::*;

#[test]
fn other_roots_name_their_session_guard_by_the_shared_hash() {
    let dir = std::env::temp_dir().join(format!("unowned-roots-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let own = crate::terminal_host_runtime::terminal_host_root(&dir, "mine");
    let other = crate::terminal_host_runtime::terminal_host_root(&dir, "cmux-app-other");
    let nameless = crate::terminal_host_runtime::terminal_host_root(&dir, "gone");
    for root in [&own, &other, &nameless] {
        std::fs::create_dir_all(root).unwrap();
    }
    std::fs::create_dir_all(dir.join("session-locks")).unwrap();
    let component = crate::workspace_registry::session_guard_component("cmux-app-other");
    std::fs::write(dir.join("session-locks").join(format!("{component}.lock")), b"").unwrap();

    let roots = other_session_roots(&own);
    assert_eq!(roots.len(), 2, "{roots:?}");
    assert!(roots.contains(&(dir.clone(), other, Some(component))));
    assert!(roots.contains(&(dir.clone(), nameless, None)));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn state_roots_cover_every_build_and_the_shared_root_on_the_app_layout() {
    let base = std::env::temp_dir().join(format!("unowned-layout-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let tags = base.join("cmux").join("tags");
    for tag in ["cmux-next", "nightly", "old-dev"] {
        std::fs::create_dir_all(tags.join(tag).join("tui")).unwrap();
    }
    std::fs::create_dir_all(tags.join("no-state")).unwrap();
    let shared = base.join("cmux-tui").join("sessions");
    std::fs::create_dir_all(&shared).unwrap();
    let mut expected = vec![
        shared.clone(),
        tags.join("cmux-next").join("tui"),
        tags.join("nightly").join("tui"),
        tags.join("old-dev").join("tui"),
    ];
    expected.sort();
    assert_eq!(state_roots(&tags.join("cmux-next").join("tui")), expected);
    assert_eq!(state_roots(&shared), expected);
    // Any other layout (Linux, a test's own state) has no siblings.
    let lone = base.join("elsewhere").join("sessions");
    std::fs::create_dir_all(&lone).unwrap();
    assert_eq!(state_roots(&lone), vec![lone]);
    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn state_roots_cover_the_builds_of_their_key_on_the_app_layout() {
    // `BuildIdentity` (CmuxNextCompat `daemonStateDirectory`): a build
    // with kept names in `tags/<tag>/tui`, any other bundled build (the
    // untagged DEV build, an unknown bundle such as `cmux_NIGHTLY`) in
    // `builds/<key>/tui`, and release, unbundled and adopted legacy
    // channel builds in the shared default root.
    let base = std::env::temp_dir().join(format!("unowned-builds-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let cmux = base.join("cmux");
    let mut expected = Vec::new();
    for dir in [
        cmux.join("tags").join("cmux-next").join("tui"),
        cmux.join("tags").join("nightly").join("tui"),
        cmux.join("builds").join("cmux_NIGHTLY").join("tui"),
        cmux.join("builds").join("com.cmuxterm.app.debug").join("tui"),
        base.join("cmux-tui").join("sessions"),
    ] {
        std::fs::create_dir_all(&dir).unwrap();
        expected.push(dir);
    }
    // A build directory with no daemon state is not a root.
    std::fs::create_dir_all(cmux.join("builds").join("no-state")).unwrap();
    expected.sort();
    for own in &expected {
        assert_eq!(&state_roots(own), &expected, "from {}", own.display());
    }
    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn a_guard_replaced_after_the_check_keeps_every_host_of_its_root() {
    let (dir, own, roots) = state_with_sessions("guard-replaced", &["cmux-app-back"]);
    let root = roots[0].clone();
    let component = crate::workspace_registry::session_guard_component("cmux-app-back");
    let guard = dir.join("session-locks").join(format!("{component}.lock"));
    let records =
        |_: &Path| -> LoadedRecords { Ok((0..2).map(|index| fake_record(&root, index)).collect()) };
    // After the reaper took the guard, the file is deleted and made
    // again (a daemon starting the session would lock the new one).
    let liveness = |_: &Path, _: &crate::terminal_host_runtime::TerminalHostRecord| {
        if std::fs::remove_file(&guard).is_ok() {
            std::fs::write(&guard, b"").unwrap();
        }
        TerminalHostLiveness::Live
    };
    let ended = std::cell::Cell::new(0);
    let end = |_: &crate::terminal_host_runtime::TerminalHostRecord, _: &Path| {
        ended.set(ended.get() + 1);
        HostEnd::Done(true)
    };
    let hosts = HostOps { load: &records, liveness: &liveness, end: &end, remove: &|_, _| true };
    let never = || false;
    reap_pass_with(&hosts, &own, &dir.join(STORE_FILE), 1_000_000, NO_GRACE, &never);
    assert_eq!(ended.get(), 0, "a host was ended under a guard that no longer guards its root");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn no_daemon_can_take_a_session_between_the_guard_check_and_the_end() {
    use crate::workspace_registry::start_session_guard_for_test;

    let dir = std::env::temp_dir().join(format!("unowned-guard-race-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let own = crate::terminal_host_runtime::terminal_host_root(&dir, "mine");
    let root = crate::terminal_host_runtime::terminal_host_root(&dir, "cmux-app-race");
    std::fs::create_dir_all(&own).unwrap();
    std::fs::create_dir_all(&root).unwrap();
    // The session ran once: its guard exists and is free.
    drop(start_session_guard_for_test(&dir, "cmux-app-race").unwrap());
    let component = crate::workspace_registry::session_guard_component("cmux-app-race");
    let guard = dir.join("session-locks").join(format!("{component}.lock"));
    let records = |_: &Path| -> LoadedRecords { Ok(vec![fake_record(&root, 0)]) };
    // Right after the reaper checked its guard, the guard file goes and
    // a daemon starts the session, which would make a new one.
    let daemon = std::cell::RefCell::new(Vec::new());
    let end = |_: &crate::terminal_host_runtime::TerminalHostRecord, _: &Path| {
        std::fs::remove_file(&guard).unwrap();
        daemon.borrow_mut().push(start_session_guard_for_test(&dir, "cmux-app-race").is_ok());
        HostEnd::Done(true)
    };
    let hosts = HostOps {
        load: &records,
        liveness: &|_, _| TerminalHostLiveness::Live,
        end: &end,
        remove: &|_, _| true,
    };
    let never = || false;
    reap_pass_with(&hosts, &own, &dir.join(STORE_FILE), 1_000_000, NO_GRACE, &never);
    assert_eq!(
        daemon.into_inner(),
        vec![false],
        "a daemon took the session while the reaper was ending its host"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_root_whose_listing_failed_keeps_its_entries_when_the_store_is_pruned() {
    let (dir, own, roots) = state_with_sessions("listing-failed", &["cmux-app-flaky"]);
    let flaky = roots[0].clone();
    let store_path = dir.join(STORE_FILE);
    let mut store = Store::default();
    for index in 0..=MAX_STORE_ENTRIES {
        store.hosts.insert(
            format!("{}|t{index}|i", flaky.display()),
            Seen { first_seen_ms: index as u64, owner_mark: String::new(), failed_ms: None },
        );
    }
    // Its listing fails once, then reads back nothing (a partial read).
    let calls = std::cell::Cell::new(0);
    let records = |_: &Path| -> LoadedRecords {
        calls.set(calls.get() + 1);
        if calls.get() == 1 { Err(anyhow::anyhow!("listing failed")) } else { Ok(Vec::new()) }
    };
    let hosts = HostOps {
        load: &records,
        liveness: &|_, _| TerminalHostLiveness::Live,
        end: &|_, _| panic!("nothing to end"),
        remove: &|_, _| panic!("nothing to remove"),
    };
    // A store over its cap, as a pass leaves it before it saves.
    let bytes = serde_json::to_vec(&store).unwrap();
    std::fs::write(&store_path, bytes).unwrap();
    let never = || false;
    reap_pass_with(&hosts, &own, &store_path, 10_000_000, Timing::STANDARD, &never);
    assert_eq!(
        load_store(&store_path).hosts.len(),
        MAX_STORE_ENTRIES,
        "the times of a root whose listing failed were dropped"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn entries_of_an_empty_root_past_the_root_cap_leave_before_they_drop_new_hosts() {
    let sessions =
        (0..=MAX_ROOTS_PER_PASS).map(|index| format!("cmux-app-{index:03}")).collect::<Vec<_>>();
    let names = sessions.iter().map(String::as_str).collect::<Vec<_>>();
    let (dir, own, roots) = state_with_sessions("past-cap", &names);
    // The last root in order is empty and holds a full store's entries;
    // a pass reaches the root cap before it.
    let empty = roots[MAX_ROOTS_PER_PASS].clone();
    let store_path = dir.join(STORE_FILE);
    let mut store = Store::default();
    for index in 0..MAX_STORE_ENTRIES {
        store.hosts.insert(
            format!("{}|t{index}|i", empty.display()),
            Seen { first_seen_ms: index as u64, owner_mark: String::new(), failed_ms: None },
        );
    }
    save_store(&store_path, &store);
    let records = |root: &Path| -> LoadedRecords {
        Ok(if *root == *empty { Vec::new() } else { vec![fake_record(root, 0)] })
    };
    let hosts = HostOps {
        load: &records,
        liveness: &|_, _| TerminalHostLiveness::Live,
        end: &|_, _| panic!("ended in its grace"),
        remove: &|_, _| panic!("removed in its grace"),
    };
    let never = || false;
    let first = 10_000_000;
    let report = reap_pass_with(&hosts, &own, &store_path, first, Timing::STANDARD, &never);
    assert!(report.capped, "{report:?}");
    let saved = load_store(&store_path);
    let key = format!("{}|t000|i", roots[0].display());
    assert_eq!(
        saved.hosts.get(&key).map(|seen| seen.first_seen_ms),
        Some(first),
        "a new host's time was dropped for an empty root's: {} entries kept",
        saved.hosts.len()
    );
    assert_eq!(saved.hosts.len(), MAX_ROOTS_PER_PASS, "stale entries kept");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A state root with an own record root and one free-guarded record
/// root per session in `sessions`; returns (own root, other roots).
fn state_with_sessions(name: &str, sessions: &[&str]) -> (PathBuf, PathBuf, Vec<PathBuf>) {
    let dir = std::env::temp_dir().join(format!("unowned-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let own = crate::terminal_host_runtime::terminal_host_root(&dir, "mine");
    std::fs::create_dir_all(&own).unwrap();
    std::fs::create_dir_all(dir.join("session-locks")).unwrap();
    let mut others = Vec::new();
    for session in sessions {
        let root = crate::terminal_host_runtime::terminal_host_root(&dir, session);
        std::fs::create_dir_all(&root).unwrap();
        let component = crate::workspace_registry::session_guard_component(session);
        std::fs::write(dir.join("session-locks").join(format!("{component}.lock")), b"").unwrap();
        others.push(root);
    }
    others.sort();
    (dir, own, others)
}

fn fake_record(
    root: &Path,
    index: usize,
) -> (PathBuf, crate::terminal_host_runtime::TerminalHostRecord) {
    let terminal_id = format!("t{index:03}");
    let record = crate::terminal_host_runtime::TerminalHostRecord {
        record_version: 4,
        terminal_id: terminal_id.clone(),
        incarnation: "i".into(),
        ..Default::default()
    };
    (root.join(format!("{terminal_id}.json")), record)
}

const NO_GRACE: Timing =
    Timing { live_grace: Duration::ZERO, ended_grace: Duration::ZERO, ..Timing::STANDARD };

#[test]
fn hosts_that_fail_to_end_do_not_keep_later_hosts_and_roots_from_their_turn() {
    // The first root's 6 live hosts never end; the second root's host does.
    let (dir, own, roots) = state_with_sessions("failing", &["cmux-app-a", "cmux-app-b"]);
    let (stuck, free) = (roots[0].clone(), roots[1].clone());
    let records = |root: &Path| -> LoadedRecords {
        let count = if root == stuck {
            6
        } else if root == free {
            1
        } else {
            0
        };
        Ok((0..count).map(|index| fake_record(root, index)).collect())
    };
    let tried = std::cell::RefCell::new(Vec::<PathBuf>::new());
    let end = |_: &crate::terminal_host_runtime::TerminalHostRecord, path: &Path| {
        tried.borrow_mut().push(path.to_path_buf());
        HostEnd::Done(!path.starts_with(&stuck))
    };
    let hosts = HostOps {
        load: &records,
        liveness: &|_, _| TerminalHostLiveness::Live,
        end: &end,
        remove: &|_, _| true,
    };
    let store = dir.join(STORE_FILE);
    let never = || false;
    let mut now = 1_000_000;
    for _ in 0..4 {
        reap_pass_with(&hosts, &own, &store, now, NO_GRACE, &never);
        now += CATCH_UP_INTERVAL.as_millis() as u64;
    }
    let tried = tried.into_inner();
    let stuck_tried = tried.iter().filter(|path| path.starts_with(&stuck)).collect::<HashSet<_>>();
    assert_eq!(stuck_tried.len(), 6, "hosts past the failing ones never tried: {tried:?}");
    assert!(
        tried.iter().any(|path| path.starts_with(&free)),
        "the next root was never reached past the failing hosts: {tried:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn entries_of_gone_and_empty_roots_leave_the_store_before_its_cap_drops_new_hosts() {
    let (dir, own, _) = state_with_sessions("stale", &["cmux-app-live", "cmux-app-empty"]);
    let live = crate::terminal_host_runtime::terminal_host_root(&dir, "cmux-app-live");
    let empty = crate::terminal_host_runtime::terminal_host_root(&dir, "cmux-app-empty");
    let store_path = dir.join(STORE_FILE);
    // A full store of hosts in a root since deleted and in one now empty.
    let mut store = Store::default();
    for index in 0..MAX_STORE_ENTRIES {
        let root = if index % 2 == 0 { dir.join("terminal-hosts-deleted") } else { empty.clone() };
        store.hosts.insert(
            format!("{}|t{index}|i", root.display()),
            Seen { first_seen_ms: index as u64, owner_mark: String::new(), failed_ms: None },
        );
    }
    save_store(&store_path, &store);
    let records = |root: &Path| -> LoadedRecords {
        Ok(if root == live { vec![fake_record(root, 0)] } else { Vec::new() })
    };
    let hosts = HostOps {
        load: &records,
        liveness: &|_, _| TerminalHostLiveness::Live,
        end: &|_, _| panic!("ended in its grace"),
        remove: &|_, _| panic!("removed in its grace"),
    };
    let never = || false;
    let first = 10_000_000;
    reap_pass_with(&hosts, &own, &store_path, first, Timing::STANDARD, &never);
    reap_pass_with(&hosts, &own, &store_path, first + 60_000, Timing::STANDARD, &never);
    let saved = load_store(&store_path);
    let key = format!("{}|t000|i", live.display());
    assert_eq!(
        saved.hosts.get(&key).map(|seen| seen.first_seen_ms),
        Some(first),
        "the new host's grace did not build up: {} entries kept",
        saved.hosts.len()
    );
    assert_eq!(saved.hosts.len(), 1, "stale entries kept");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_replacement_shell_keeps_the_live_grace_past_an_older_incarnations_exit_sidecar() {
    use crate::terminal_host::{HostIncarnation, TerminalId};
    use crate::terminal_host_runtime::{TerminalHostExitRecord, TerminalHostIdentity};
    use std::os::unix::fs::PermissionsExt as _;

    let (dir, own, roots) = state_with_sessions("sidecar", &["cmux-app-replaced"]);
    let root = roots[0].clone();
    let terminal_id = TerminalId::random().unwrap().to_hex();
    let current = HostIncarnation::random().unwrap().to_hex();
    let record_path = root.join(format!("{terminal_id}.json"));
    let record = crate::terminal_host_runtime::TerminalHostRecord {
        record_version: 4,
        terminal_id: terminal_id.clone(),
        incarnation: current.clone(),
        ..Default::default()
    };
    let write_sidecar = |incarnation: &str| {
        let exit = TerminalHostExitRecord::new(
            &TerminalHostIdentity {
                terminal_id: terminal_id.clone(),
                incarnation: incarnation.to_string(),
            },
            TerminalExit {
                outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
                exited_at_ms: 1,
            },
        );
        let path = record_path.with_extension("exit");
        std::fs::write(&path, serde_json::to_vec(&exit).unwrap()).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    };
    let ended = std::cell::Cell::new(0);
    let records = |_: &Path| -> LoadedRecords { Ok(vec![(record_path.clone(), record.clone())]) };
    let end = |_: &crate::terminal_host_runtime::TerminalHostRecord, _: &Path| {
        ended.set(ended.get() + 1);
        HostEnd::Done(true)
    };
    let hosts = HostOps {
        load: &records,
        liveness: &|_, _| TerminalHostLiveness::Live,
        end: &end,
        remove: &|_, _| true,
    };
    let timing = Timing { ended_grace: Duration::ZERO, ..Timing::STANDARD };
    let store = dir.join(STORE_FILE);
    let never = || false;

    // The shell of an older incarnation ended; the running one did not.
    write_sidecar(&HostIncarnation::random().unwrap().to_hex());
    reap_pass_with(&hosts, &own, &store, 1_000_000, timing, &never);
    reap_pass_with(&hosts, &own, &store, 1_000_000 + 11 * 60_000, timing, &never);
    assert_eq!(ended.get(), 0, "a live replacement shell was ended on an old exit sidecar");

    // The current incarnation's own sidecar does take the shorter grace.
    write_sidecar(&current);
    reap_pass_with(&hosts, &own, &store, 1_000_000 + 12 * 60_000, timing, &never);
    assert_eq!(ended.get(), 1, "the current shell's end did not take the ended-shell grace");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn passes_resume_after_the_last_root_so_every_root_is_seen_past_the_cap() {
    let roots = (0..MAX_ROOTS_PER_PASS + 6)
        .map(|index| PathBuf::from(format!("/roots/r{index:03}")))
        .collect::<Vec<_>>();
    let never = || false;
    let mut seen = HashSet::new();
    let walk = |cursor: Option<&Path>| {
        let mut visited = Vec::new();
        let result = walk_roots(
            &roots,
            |root| root.as_path(),
            cursor,
            &never,
            |root| {
                visited.push(root.clone());
                Visit::Done
            },
        );
        (result, visited)
    };
    let ((cursor, capped), first) = walk(None);
    assert!(capped);
    assert_eq!(first.len(), MAX_ROOTS_PER_PASS);
    assert_eq!(cursor.as_ref(), Some(&roots[MAX_ROOTS_PER_PASS - 1]));
    seen.extend(first);
    let ((_, capped), second) = walk(cursor.as_deref());
    assert!(capped);
    // The second pass starts at the first root the first one left out.
    assert_eq!(second.first(), Some(&roots[MAX_ROOTS_PER_PASS]));
    seen.extend(second);
    assert_eq!(seen.len(), roots.len(), "a root no pass reached");

    // A root a cap left part way is the next pass's first.
    let ((cursor, capped), _) = {
        let mut visited = Vec::new();
        let result = walk_roots(
            &roots,
            |root| root.as_path(),
            None,
            &never,
            |root| {
                visited.push(root.clone());
                if visited.len() == 3 { Visit::Unfinished } else { Visit::Done }
            },
        );
        (result, visited)
    };
    assert!(capped);
    assert_eq!(cursor.as_ref(), Some(&roots[1]));
}

#[test]
fn the_store_keeps_the_oldest_first_seen_times_past_its_cap() {
    let dir = std::env::temp_dir().join(format!("unowned-store-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(STORE_FILE);
    let hosts = (0..MAX_STORE_ENTRIES as u64 + 2)
        .map(|index| {
            (
                format!("root/{index}"),
                Seen { first_seen_ms: index, owner_mark: "-".into(), failed_ms: None },
            )
        })
        .collect::<BTreeMap<_, _>>();
    save_store(&path, &Store { cursor: None, hosts });
    let loaded = load_store(&path).hosts;
    assert_eq!(loaded.len(), MAX_STORE_ENTRIES);
    assert_eq!(loaded.get("root/0").map(|seen| seen.first_seen_ms), Some(0));
    assert!(!loaded.contains_key(&format!("root/{}", MAX_STORE_ENTRIES + 1)));
    let _ = std::fs::remove_dir_all(&dir);
}
