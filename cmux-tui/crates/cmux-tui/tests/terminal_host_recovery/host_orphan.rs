//! cx-hostorphan: a terminal host whose owner daemon is gone does not hold
//! its PTY until reboot. With no client stream for the orphan grace
//! (`CMUX_TUI_HOST_ORPHAN_GRACE_SECS`, 10 min by default) it ends its
//! terminal and exits with an owner-gone exit record, which the next owner
//! reads as a host loss (the tab stays); a plain `SIGTERM` ends an orphaned
//! host at once. A host its daemon serves outlives the grace, and a
//! daemon restart inside the grace adopts the same host.

use super::*;

/// Start a daemon that spawns hosts with an orphan grace of `grace_secs`.
fn start_with_orphan_grace(name: &str, grace_secs: u64) -> RecoveryHarness {
    let mut harness = RecoveryHarness::start_unstarted(name);
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_HOST_ORPHAN_GRACE_SECS", grace_secs.to_string());
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    harness
}

/// A `/bin/cat` terminal: (terminal id, surface, host record path, host PID).
fn run_cat(harness: &RecoveryHarness, marker: &str) -> (String, u64, PathBuf, u32) {
    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,"name":"orphan"}),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let surface = created["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, marker).contains(marker));
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    (terminal_id, surface, record_path, record.host_pid)
}

/// The process runs (exists and is not a zombie).
fn running(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the PID exists.
    if unsafe { libc::kill(pid as libc::pid_t, 0) } != 0 {
        return false;
    }
    #[cfg(target_os = "linux")]
    if let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat"))
        && let Some(state) = stat.rsplit(')').next().and_then(|rest| rest.split_whitespace().next())
    {
        return state != "Z";
    }
    true
}

fn wait_until_gone(pid: u32, timeout: Duration) -> bool {
    let deadline = Instant::now() + test_timeout(timeout);
    while running(pid) {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    true
}

fn kill_daemon(harness: &mut RecoveryHarness) {
    harness.sigkill();
}

#[test]
fn an_orphaned_host_exits_after_the_grace_and_a_served_one_does_not() {
    let _exclusive = exclusive_process_test();
    let grace = Duration::from_secs(3);
    let mut harness = start_with_orphan_grace("orphan-grace", grace.as_secs());
    let (terminal_id, surface, _, host_pid) = run_cat(&harness, "orphan-before");

    // Served by its live daemon, the host outlives the grace twice over.
    std::thread::sleep(grace * 2 + Duration::from_secs(1));
    assert!(running(host_pid), "a host its daemon serves ended at the orphan grace");
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":"still-served\n"}),
    );
    assert!(wait_for_screen(&harness.socket, surface, "still-served").contains("still-served"));

    let incarnation = request(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal","terminal_id":&terminal_id}),
    )["terminal_incarnation"]
        .clone();

    // Owner gone: the host ends its terminal after the grace, cleanly.
    let killed = Instant::now();
    kill_daemon(&mut harness);
    assert!(
        wait_until_gone(host_pid, grace + Duration::from_secs(15)),
        "an orphaned host outlived its grace"
    );
    assert!(killed.elapsed() >= grace, "the host ended before its grace");
    let exits = load_terminal_host_exit_records(&harness.host_root()).unwrap();
    assert_eq!(exits.len(), 1, "the orphaned host left no exit record");
    let exit = format!("{:?}", exits[0].1.exit);
    assert!(exit.contains("owner-gone"), "the exit record is not an owner-gone end: {exit}");

    // The next owner reads a host loss, not a process end: the tab stays.
    harness.restart();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":&terminal_id}),
        );
        // A host loss leaves the terminal exited, or respawned (L2).
        if resolved["lifecycle"] == "exited"
            || (resolved["lifecycle"] == "running"
                && resolved["terminal_incarnation"] != incarnation)
        {
            break;
        }
        assert!(Instant::now() < deadline, "the orphan end was not recorded: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    }
    let settle = Instant::now() + Duration::from_secs(2);
    while Instant::now() < settle {
        let tree = request(&harness.socket, serde_json::json!({"id":9,"cmd":"list-workspaces"}));
        let kept = tree["workspaces"].as_array().unwrap().iter().any(|workspace| {
            workspace["name"] == "orphan"
                && first_tab(workspace).is_some_and(|tab| {
                    tab["dead"] == true
                        && tab["end"]["kind"] == "host_lost"
                        && tab["end"]["detail"] == "owner-gone"
                })
        });
        assert!(kept, "the next owner detached the orphan-ended terminal's tab: {tree}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn sigterm_ends_an_orphaned_host() {
    let _exclusive = exclusive_process_test();
    // The default 10 min grace: only the SIGTERM can end the host here.
    let mut harness = RecoveryHarness::start("orphan-sigterm");
    let (_, _, record_path, host_pid) = run_cat(&harness, "orphan-term");
    kill_daemon(&mut harness);

    // The host sees its daemon's stream close shortly after the kill; a
    // TERM that arrives while the stream is still open is survived, so
    // repeat it until the host is orphaned and ends.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    while running(host_pid) {
        assert!(Instant::now() < deadline, "SIGTERM did not end an orphaned host");
        // SAFETY: the PID is the terminal host this test started.
        unsafe { libc::kill(host_pid as libc::pid_t, libc::SIGTERM) };
        std::thread::sleep(Duration::from_millis(200));
    }
    let exits = load_terminal_host_exit_records(&harness.host_root()).unwrap();
    assert_eq!(exits.len(), 1, "the SIGTERM'd host left no exit record");
    let signals = fs::read_to_string(record_path.with_extension("signals")).unwrap_or_default();
    assert!(
        signals.lines().any(|line| line.contains("\"action\":\"ended\"")),
        "the breadcrumbs do not name the ending SIGTERM: {signals}"
    );
}

#[test]
fn a_daemon_restart_inside_the_grace_adopts_the_host() {
    let _exclusive = exclusive_process_test();
    // Long enough for a debug daemon's restart and adoption on a loaded box.
    let grace = Duration::from_secs(15);
    let mut harness = start_with_orphan_grace("orphan-readopt", grace.as_secs());
    let (terminal_id, _, _, host_pid) = run_cat(&harness, "before-restart");
    kill_daemon(&mut harness);
    harness.restart();

    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let surface = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":&terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "terminal was not adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    };
    // Adopted: the same host outlives the grace and still answers input.
    std::thread::sleep(grace + Duration::from_secs(3));
    assert!(running(host_pid), "the adopted host ended at the orphan grace");
    let records = wait_for_host_records(&harness.host_root(), 1);
    assert_eq!(records[0].1.host_pid, host_pid, "the terminal got a new host");
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":"after-restart\n"}),
    );
    assert!(wait_for_screen(&harness.socket, surface, "after-restart").contains("after-restart"));
}
