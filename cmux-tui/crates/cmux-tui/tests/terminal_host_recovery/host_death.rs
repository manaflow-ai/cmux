//! Invariant 3 of plans/cmux-next/OWNERSHIP-PRINCIPLES.md: a terminal host's
//! death never closes a workspace or removes a tab; the tab becomes dead.
//! Covers hosts that die under a running daemon or while no daemon runs,
//! and signal exits during a session shutdown (`session-shutdown`),
//! including the logout race.

use super::*;

/// Invariant 3 of plans/cmux-next/OWNERSHIP-PRINCIPLES.md: a terminal host's
/// death never closes a workspace or removes a tab. Hosts that die while no
/// daemon owns them leave no exit status (no sidecar), so the next daemon
/// must keep every workspace, screen, pane and tab and show the tabs dead.
#[test]
fn host_death_keeps_tabs_across_daemon_restart() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("dead-hosts-keep-tabs");
    let names = ["one", "two", "three"];
    let terminals = names
        .iter()
        .enumerate()
        .map(|(index, name)| run_cat_workspace(&harness.socket, index + 1, name).0)
        .collect::<Vec<_>>();
    let records = wait_for_host_records(&harness.host_root(), names.len());
    let before = request(&harness.socket, serde_json::json!({"id":10,"cmd":"list-workspaces"}));

    // Stop the mux first so it observes no Exit, then kill every host: no
    // host lives to write an exit sidecar, which is a host death with an
    // unknown outcome, not a process end.
    harness.signal_daemon(libc::SIGSTOP);
    for (_, record) in &records {
        // SAFETY: the record PIDs are the harness-owned terminal hosts.
        assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    }
    harness.sigkill();
    harness.restart();

    for terminal_id in &terminals {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let resolved = request(
                &harness.socket,
                serde_json::json!({"id":11,"cmd":"resolve-terminal","terminal_id":terminal_id}),
            );
            if resolved["lifecycle"] == "exited" {
                break;
            }
            assert!(Instant::now() < deadline, "dead host {terminal_id} was not marked exited");
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    wait_for_no_host_records(&harness.host_root());
    let after = request(&harness.socket, serde_json::json!({"id":12,"cmd":"list-workspaces"}));
    for name in names {
        let find = |tree: &serde_json::Value| {
            tree["workspaces"]
                .as_array()
                .unwrap()
                .iter()
                .find(|workspace| workspace["name"] == name)
                .cloned()
                .unwrap_or_else(|| panic!("workspace {name} is missing: {tree}"))
        };
        let (old, new) = (find(&before), find(&after));
        assert_eq!(new["resource_id"], old["resource_id"]);
        let screens = new["screens"].as_array().unwrap();
        assert_eq!(screens.len(), 1, "workspace {name} lost its screen: {new}");
        assert_eq!(screens[0]["resource_id"], old["screens"][0]["resource_id"]);
        let panes = screens[0]["panes"].as_array().unwrap();
        assert_eq!(panes.len(), 1, "workspace {name} lost its pane: {new}");
        let tabs = panes[0]["tabs"].as_array().unwrap();
        assert_eq!(tabs.len(), 1, "workspace {name} lost its tab: {new}");
        assert_eq!(
            tabs[0]["tab_resource_id"],
            old["screens"][0]["panes"][0]["tabs"][0]["tab_resource_id"]
        );
        assert_eq!(tabs[0]["dead"], true, "a tab of a dead host came back live: {new}");
    }
}

/// Logout or reboot: the daemon and every terminal host stop together, with
/// no exit sidecar. Whichever the daemon observes first (a lost host or no
/// daemon at all), the next start keeps every workspace's screen, pane and
/// tab, dead.
#[test]
fn host_death_keeps_layout_when_daemon_and_hosts_stop_together() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("logout-keeps-layout");
    let names = ["left", "right"];
    for (index, name) in names.iter().enumerate() {
        run_cat_workspace(&harness.socket, index + 1, name);
    }
    let records = wait_for_host_records(&harness.host_root(), names.len());
    let daemon = harness.child.as_ref().unwrap().id() as libc::pid_t;
    // SAFETY: the daemon and the record PIDs are harness-owned processes.
    assert_eq!(unsafe { libc::kill(daemon, libc::SIGKILL) }, 0);
    for (_, record) in &records {
        // SAFETY: as above.
        assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    }
    harness.sigkill();
    harness.restart();

    let deadline = Instant::now() + Duration::from_secs(15);
    let tree = loop {
        let tree = request(&harness.socket, serde_json::json!({"id":10,"cmd":"list-workspaces"}));
        let tabs = names
            .iter()
            .filter_map(|name| {
                tree["workspaces"].as_array().unwrap().iter().find(|w| w["name"] == *name)
            })
            .filter_map(first_tab)
            .filter(|tab| tab["dead"] == true)
            .count();
        if tabs == names.len() {
            break tree;
        }
        assert!(Instant::now() < deadline, "dead hosts lost their tabs: {tree}");
        std::thread::sleep(Duration::from_millis(25));
    };
    for name in names {
        let workspace = tree["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .find(|workspace| workspace["name"] == name)
            .unwrap();
        assert_eq!(workspace["screens"].as_array().unwrap().len(), 1, "{workspace}");
    }
}

/// Run `/bin/sh` (which records its pid, then execs `cat`) in a new
/// workspace named `name`; returns its terminal id and the shell's pid.
fn run_recorded_shell(harness: &RecoveryHarness, id: usize, name: &str) -> (String, libc::pid_t) {
    let pid_file = harness.dir.join(format!("{name}.pid"));
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": id,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", format!("echo $$ > '{}'; exec cat", pid_file.display())],
            "new_workspace": true,
            "name": name,
        }),
    );
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let pid = loop {
        if let Some(pid) = fs::read_to_string(&pid_file)
            .ok()
            .and_then(|text| text.trim().parse::<libc::pid_t>().ok())
        {
            break pid;
        }
        assert!(Instant::now() < deadline, "shell {name} never recorded its pid");
        std::thread::sleep(Duration::from_millis(20));
    };
    (created["terminal_id"].as_str().unwrap().to_string(), pid)
}

fn workspace_named(tree: &serde_json::Value, name: &str) -> Option<serde_json::Value> {
    tree["workspaces"].as_array().unwrap().iter().find(|w| w["name"] == name).cloned()
}

fn wait_for_exited_lifecycle(socket: &Path, terminal_id: &str, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    loop {
        let resolved = request(
            socket,
            serde_json::json!({"id":40,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "exited" {
            return;
        }
        assert!(Instant::now() < deadline, "{terminal_id} was not marked exited");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn assert_dead_tabs(tree: &serde_json::Value, names: &[&str], at: &str) {
    for name in names {
        let workspace = workspace_named(tree, name)
            .unwrap_or_else(|| panic!("{at}: workspace {name} was closed: {tree}"));
        assert_eq!(workspace["screens"].as_array().unwrap().len(), 1, "{at}: {workspace}");
        let tab = first_tab(&workspace)
            .unwrap_or_else(|| panic!("{at}: a logout signal exit removed a tab: {workspace}"));
        assert_eq!(tab["dead"], true, "{at}: {tab}");
    }
}

/// Logout or reboot with graceful signals: the daemon gets SIGTERM, then
/// every shell dies of SIGHUP while its host still runs, so each host
/// leaves an exit sidecar with a signal. The session ended around those
/// shells (`session-shutdown`): the next start keeps every tab, dead. A
/// shell killed by a signal while the daemon runs normally is a real end
/// and its tab goes.
#[test]
fn session_shutdown_signal_exits_keep_tabs_dead() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("session-shutdown-keeps-tabs");

    // While the daemon runs normally, a shell killed by a signal is a real
    // end: its tab goes.
    let (killed, killed_pid) = run_recorded_shell(&harness, 1, "killed");
    // SAFETY: the pid is the harness-owned shell recorded above.
    assert_eq!(unsafe { libc::kill(killed_pid, libc::SIGHUP) }, 0);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":2,"cmd":"resolve-terminal","terminal_id":killed}),
        );
        if resolved["lifecycle"] == "exited" {
            break;
        }
        assert!(Instant::now() < deadline, "the killed shell never exited");
        std::thread::sleep(Duration::from_millis(20));
    }
    // The detach waits out the session shutdown lead (a logout signal may
    // still be on its way to the daemon), then the tab goes.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let tree = request(&harness.socket, serde_json::json!({"id":3,"cmd":"list-workspaces"}));
        // The tab and its emptied workspace go in one commit
        // (LAST-TAB-CLOSES-WORKSPACE).
        let Some(workspace) = workspace_named(&tree, "killed") else { break };
        assert!(first_tab(&workspace).is_some(), "an empty workspace stayed: {workspace}");
        assert!(Instant::now() < deadline, "a real end kept its tab: {workspace}");
        std::thread::sleep(Duration::from_millis(50));
    }

    let names = ["first", "second"];
    let shells = names
        .iter()
        .enumerate()
        .map(|(index, name)| run_recorded_shell(&harness, index + 10, name))
        .collect::<Vec<_>>();
    wait_for_host_records(&harness.host_root(), names.len());

    harness.signal_daemon(libc::SIGTERM);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_file(&harness.socket);
    for (_, pid) in &shells {
        // SAFETY: the pids are the harness-owned shells recorded above.
        assert_eq!(unsafe { libc::kill(*pid, libc::SIGHUP) }, 0);
    }
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while load_terminal_host_exit_records(&harness.host_root()).unwrap().len() < names.len() {
        assert!(Instant::now() < deadline, "hosts did not record their shells' exits");
        std::thread::sleep(Duration::from_millis(20));
    }

    harness.restart();
    for (terminal_id, _) in &shells {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let resolved = request(
                &harness.socket,
                serde_json::json!({"id":20,"cmd":"resolve-terminal","terminal_id":terminal_id}),
            );
            if resolved["lifecycle"] == "exited" {
                break;
            }
            assert!(Instant::now() < deadline, "{terminal_id} was not marked exited");
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    let tree = request(&harness.socket, serde_json::json!({"id":21,"cmd":"list-workspaces"}));
    for name in names {
        let workspace = workspace_named(&tree, name)
            .unwrap_or_else(|| panic!("workspace {name} was closed: {tree}"));
        assert_eq!(workspace["screens"].as_array().unwrap().len(), 1, "{workspace}");
        let tab = first_tab(&workspace)
            .unwrap_or_else(|| panic!("a session shutdown removed a tab: {workspace}"));
        assert_eq!(tab["dead"], true, "{tab}");
    }
}

/// Logout race: logout signals the shells and the daemon at the same time,
/// so a shell's exit by signal can reach the daemon before the daemon's own
/// termination signal does. The daemon then still runs normally; it commits
/// the exit but keeps the tab, dead, for the session shutdown lead before it
/// detaches it. The daemon's shutdown within that lead makes those exits
/// host losses: after the restart, and after a second restart whose
/// shutdown replaced the recorded window, every tab is still there, dead.
/// The lead is raised for the first daemon so a loaded runner cannot outlast
/// it, and is the default again for the last one.
#[test]
fn session_shutdown_logout_race_keeps_tabs_dead() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted("session-shutdown-logout-race");
    harness.session_shutdown_lead_ms = Some(30_000);
    harness.restart();
    let names = ["first", "second"];
    let shells = names
        .iter()
        .enumerate()
        .map(|(index, name)| run_recorded_shell(&harness, index + 1, name))
        .collect::<Vec<_>>();
    wait_for_host_records(&harness.host_root(), names.len());

    // The shells die first and the daemon handles their exits before its
    // own signal arrives: the worst order for the daemon.
    for (_, pid) in &shells {
        // SAFETY: the pids are the harness-owned shells recorded above.
        assert_eq!(unsafe { libc::kill(*pid, libc::SIGHUP) }, 0);
    }
    for (terminal_id, _) in &shells {
        wait_for_exited_lifecycle(&harness.socket, terminal_id, Duration::from_secs(10));
    }
    // Every exit timestamp is before this instant.
    let exits_seen = Instant::now();
    let tree = request(&harness.socket, serde_json::json!({"id":10,"cmd":"list-workspaces"}));
    assert_dead_tabs(&tree, &names, "before the daemon's signal");
    harness.signal_daemon(libc::SIGTERM);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_file(&harness.socket);

    harness.restart();
    for (terminal_id, _) in &shells {
        wait_for_exited_lifecycle(&harness.socket, terminal_id, Duration::from_secs(15));
    }
    let tree = request(&harness.socket, serde_json::json!({"id":11,"cmd":"list-workspaces"}));
    assert_dead_tabs(&tree, &names, "after the restart");

    // This owner's shutdown replaces the recorded window. It starts more
    // than the default lead after the exits, and the next owner runs with
    // the default lead, so that window cannot cover them: only the receipt
    // can keep the tabs dead.
    let past_lead = Duration::from_secs(3);
    if let Some(remaining) = past_lead.checked_sub(exits_seen.elapsed()) {
        std::thread::sleep(remaining);
    }
    harness.session_shutdown_lead_ms = None;
    harness.signal_daemon(libc::SIGTERM);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after the second SIGTERM");
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_file(&harness.socket);
    harness.restart();
    let tree = request(&harness.socket, serde_json::json!({"id":12,"cmd":"list-workspaces"}));
    assert_dead_tabs(&tree, &names, "after the second restart");
}

/// Invariant 3 at runtime: a host killed under a running daemon (no exit
/// status reaches the daemon) leaves its tab in place, dead.
#[test]
fn host_death_keeps_tab_under_running_daemon() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("running-host-sigkill-keeps-tab");
    let (terminal_id, _) = run_cat_workspace(&harness.socket, 1, "killed");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    // SAFETY: the record PID is the dedicated host process owned by this
    // harness; killing it is the failure under test.
    assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":2,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "exited" {
            break;
        }
        assert!(Instant::now() < deadline, "running host never transitioned to Exited");
        std::thread::sleep(Duration::from_millis(20));
    }
    let tree = request(&harness.socket, serde_json::json!({"id":3,"cmd":"list-workspaces"}));
    let workspace = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == "killed")
        .cloned()
        .unwrap_or_else(|| panic!("the workspace of a dead host was closed: {tree}"));
    let tab = first_tab(&workspace)
        .unwrap_or_else(|| panic!("the tab of a dead host was removed: {workspace}"));
    assert_eq!(tab["dead"], true, "{tab}");
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Dead
    );
    let _ = remove_stale_terminal_host_record(&record_path, &record);
}

#[path = "stray_signals.rs"]
mod stray_signals;

#[path = "pty_custody.rs"]
mod pty_custody;

#[path = "owner_idle_exit.rs"]
mod owner_idle_exit;
