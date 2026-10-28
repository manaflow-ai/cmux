//! H12: under the holder model a terminal that comes back keeps its model.
//! A `restart-tab` of a dead tab and the next start's respawn of a shell
//! a logout ended start the new shell on the holder, never on a terminal
//! host process of its own: these two were the way terminals left the
//! holder.

use super::*;

/// The holder model, whatever this suite's harness picks by default.
fn holder_harness(name: &str) -> RecoveryHarness {
    let mut harness = RecoveryHarness::start_unstarted(name);
    harness.extra_env.push(("CMUX_TUI_TERMINAL_HOST_MODEL".into(), "holder".into()));
    harness
}

fn parent_of(pid: i32) -> i32 {
    let out = Command::new("ps").args(["-o", "ppid=", "-p", &pid.to_string()]).output().unwrap();
    String::from_utf8_lossy(&out.stdout).trim().parse().unwrap()
}

fn command_line(pid: i32) -> String {
    let out =
        Command::new("ps").args(["-ww", "-o", "args=", "-p", &pid.to_string()]).output().unwrap();
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// Ends the holder and the shells a test started (the harness only ends
/// terminal hosts it finds records of).
struct Reap(Vec<i32>);

impl Drop for Reap {
    fn drop(&mut self) {
        for pid in self.0.drain(..) {
            // SAFETY: SIGKILL of a holder or shell this test's daemon started.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    }
}

/// The shell of `surface` runs on the holder: its parent is the holder
/// (its socket is under `/tmp/cmux-hd-`), not a `__terminal-host`, and no
/// terminal host record exists. Returns (shell, holder).
fn assert_on_the_holder(
    harness: &RecoveryHarness,
    surface: u64,
    tag: &str,
    at: &str,
) -> (i32, i32) {
    let shell: i32 = echo_value(harness, surface, tag, "$$").parse().expect("a pid");
    let parent = parent_of(shell);
    let args = command_line(parent);
    let hosts = load_terminal_host_records(&harness.host_root()).unwrap_or_default();
    assert!(
        !args.contains("__terminal-host") && args.contains("/tmp/cmux-hd-") && hosts.is_empty(),
        "{at}: the shell runs on a terminal host, not on the holder: parent {parent} `{args}`, \
         {} host record(s)",
        hosts.len()
    );
    (shell, parent)
}

/// A process end kept by `on_exit` keep, restarted with `restart-tab`.
#[test]
fn a_restart_tab_under_the_holder_model_starts_on_the_holder() {
    let _exclusive = exclusive_process_test();
    let mut harness = holder_harness("holder-restart-tab");
    harness.restart();
    let mut reap = Reap(Vec::new());
    let workspace = &create_empty_workspace(&harness.socket, "holder-restart", "Holder restart");
    let run = resource_request(
        &harness.socket,
        "holder-restart-run",
        "workspace.run",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "workspace":workspace,
            "argv":["/bin/sh","-c","printf 'holder-exit-marker\\n'; exit 9"],
            "on_exit":"keep",
        }),
        Some("holder-restart-run"),
    );
    assert!(run["value"]["tab_id"].is_string(), "{run}");
    let terminal_id = tab_named(&harness, "Holder restart")["terminal_id"]
        .as_str()
        .expect("the run tab names its terminal")
        .to_string();
    let exited = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let incarnation = exited["terminal_incarnation"].as_str().unwrap_or_default().to_string();
    let dead = tab_named(&harness, "Holder restart");
    assert_eq!(dead["dead"], true, "{dead}");
    assert!(
        load_terminal_host_records(&harness.host_root()).unwrap_or_default().is_empty(),
        "the first shell ran on a terminal host: the holder model is not on"
    );

    let restarted = request_response(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"restart-tab","surface":dead["tab_resource_id"]}),
    );
    assert_eq!(restarted["ok"], true, "{restarted}");
    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let tab = tab_named(&harness, "Holder restart");
    assert_eq!(tab["dead"], false, "{tab}");
    let surface = tab["surface"].as_u64().expect("the restarted tab has a surface");
    let (shell, holder) = assert_on_the_holder(&harness, surface, "restarted", "after restart-tab");
    reap.0.extend([shell, holder]);
}

/// Logout race: the shell dies of SIGHUP and the daemon gets SIGTERM
/// within the session shutdown lead, so the end is a `session-shutdown`
/// loss, which the next start respawns.
#[test]
fn a_respawn_after_logout_under_the_holder_model_starts_on_the_holder() {
    let _exclusive = exclusive_process_test();
    let mut harness = holder_harness("holder-logout-respawn");
    harness.session_shutdown_lead_ms = Some(30_000);
    harness.restart();
    let mut reap = Reap(Vec::new());
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "logout");
    let (shell, holder) = assert_on_the_holder(&harness, surface, "first", "before the logout");
    reap.0.push(holder);
    // SAFETY: the pid is this test's shell, read above.
    assert_eq!(unsafe { libc::kill(shell, libc::SIGHUP) }, 0);
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    harness.signal_daemon(libc::SIGTERM);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_file(&harness.socket);

    harness.session_shutdown_lead_ms = None;
    harness.restart();
    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let tab = tab_named(&harness, "logout");
    assert_eq!(tab["dead"], false, "{tab}");
    let surface = tab["surface"].as_u64().expect("the respawned tab has a surface");
    let (shell, holder) = assert_on_the_holder(&harness, surface, "respawned", "after the logout");
    reap.0.extend([shell, holder]);
}

/// The holder starts a respawned shell at once (a terminal host waits for
/// the respawn to commit): a shell that exits before the commit must still
/// end its terminal, never leave it `running` with no shell.
#[test]
fn a_restarted_shell_that_exits_at_once_ends_its_terminal() {
    let _exclusive = exclusive_process_test();
    let mut harness = holder_harness("holder-restart-exits-at-once");
    // The restart runs the default shell, which exits at once.
    harness.extra_env.push(("SHELL".into(), "/bin/false".into()));
    // The shell's exit reaches the daemon before the respawn commits.
    harness.extra_env.push(("CMUX_TUI_TEST_RESPAWN_INSTALL_DELAY_MS".into(), "500".into()));
    harness.restart();
    let workspace = &create_empty_workspace(&harness.socket, "holder-quick", "Holder quick");
    let run = resource_request(
        &harness.socket,
        "holder-quick-run",
        "workspace.run",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "workspace":workspace,
            "argv":["/bin/sh","-c","exit 9"],
            "on_exit":"keep",
        }),
        Some("holder-quick-run"),
    );
    assert!(run["value"]["tab_id"].is_string(), "{run}");
    let terminal_id = tab_named(&harness, "Holder quick")["terminal_id"]
        .as_str()
        .expect("the run tab names its terminal")
        .to_string();
    let exited = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let first = exited["terminal_incarnation"].as_str().unwrap_or_default().to_string();
    let dead = tab_named(&harness, "Holder quick");
    let restarted = request_response(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"restart-tab","surface":dead["tab_resource_id"]}),
    );
    assert_eq!(restarted["ok"], true, "{restarted}");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default();
        if resolved["lifecycle"] == "exited" && !incarnation.is_empty() && incarnation != first {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the restarted shell exited at once but its terminal never ended: {resolved}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    // A shell that died before its respawn committed was not respawned:
    // the loss log names no respawn of it.
    let respawned = respawn_lines(&harness, &terminal_id);
    assert!(respawned.is_empty(), "a dead shell was logged as respawned: {respawned:?}");
}
