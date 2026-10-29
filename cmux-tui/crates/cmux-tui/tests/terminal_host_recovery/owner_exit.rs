//! The owner-exit rule for terminal hosts (the holder's rule, see
//! `cmux-holder/tests/owner_exit.rs`): a host whose owner daemon exits ends
//! its terminal within a bounded time, unless the owner recorded a handoff
//! for that host first (`cmux_holder::handoff`, `<endpoint>.handoff`). A
//! recorded handoff keeps the host, and the next owner adopts it. A normal
//! install's host has no orphan grace, so only this rule can end it here.

use super::*;

/// The bound an unrecorded owner exit gets to end the host: the host's own
/// owner-exit delay plus slack for a loaded box.
const ENDS_WITHIN: Duration = Duration::from_secs(20);

/// A daemon of a normal install: no orphan grace, so the owner rule decides.
fn normal_install_command(harness: &RecoveryHarness) -> Command {
    let mut command = harness.daemon_command();
    command
        .env("CMUX_BUNDLE_ID", "com.cmuxterm.app.rc.ptyh-test")
        .env_remove("CMUX_TUI_HOST_ORPHAN_GRACE_SECS");
    command
}

fn start_normal_install(name: &str) -> RecoveryHarness {
    let mut harness = RecoveryHarness::start_unstarted(name);
    harness.child = Some(normal_install_command(&harness).spawn().unwrap());
    wait_for_socket(&harness.socket);
    harness
}

fn restart_normal_install(harness: &mut RecoveryHarness) {
    harness.child = Some(normal_install_command(harness).spawn().unwrap());
    wait_for_socket(&harness.socket);
}

/// The owner's handoff for every host of this daemon, written the way the
/// daemon's shutdown writes it (`HostAttachment::record_owner_handoff`).
pub(super) fn declare_owner_handoff(harness: &RecoveryHarness) {
    let records = load_terminal_host_records(&harness.host_root()).unwrap();
    assert!(!records.is_empty(), "no terminal host to hand off");
    for (_, record) in records {
        cmux_holder::handoff::write_record(Path::new(&record.endpoint)).unwrap();
    }
}

/// A `/bin/cat` terminal: (terminal id, surface, host PID).
fn run_cat(harness: &RecoveryHarness, marker: &str) -> (String, u64, u32) {
    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,"name":"owner-exit"}),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let surface = created["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, marker).contains(marker));
    let host_pid = wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid;
    (terminal_id, surface, host_pid)
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

/// Wait until the next owner has adopted the terminal; returns its surface.
fn wait_adopted_surface(harness: &RecoveryHarness, terminal_id: &str) -> u64 {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            return surface;
        }
        assert!(Instant::now() < deadline, "terminal was not adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// Red first: an owner that exits (SIGKILL, so it writes nothing) without a
/// recorded handoff ends its terminal host within a bounded time, with an
/// owner-gone exit record. Before the owner rule the host kept its shell.
#[test]
fn a_terminal_host_ends_when_its_owner_exits_without_a_handoff() {
    let _exclusive = exclusive_process_test();
    let mut harness = start_normal_install("owner-exit-unrecorded");
    let (_, _, host_pid) = run_cat(&harness, "owner-exit-before");

    harness.sigkill();
    assert!(
        wait_until_gone(host_pid, ENDS_WITHIN),
        "a host whose owner exited without a handoff kept its terminal past {ENDS_WITHIN:?}"
    );
    let exits = load_terminal_host_exit_records(&harness.host_root()).unwrap();
    assert_eq!(exits.len(), 1, "the owner-less host left no exit record");
    let exit = format!("{:?}", exits[0].1.exit);
    assert!(exit.contains("owner-gone"), "the exit record is not an owner-gone end: {exit}");
}

/// A recorded handoff is the owner's explicit transfer: the host outlives
/// the owner's exit past the bound, and the next owner adopts it.
#[test]
fn a_recorded_handoff_keeps_the_terminal_host_through_the_owner_exit() {
    let _exclusive = exclusive_process_test();
    let mut harness = start_normal_install("owner-exit-recorded");
    let (terminal_id, _, host_pid) = run_cat(&harness, "owner-exit-kept");

    declare_owner_handoff(&harness);
    harness.sigkill();
    std::thread::sleep(ENDS_WITHIN);
    assert!(running(host_pid), "a host with a recorded handoff ended with its owner");

    restart_normal_install(&mut harness);
    let surface = wait_adopted_surface(&harness, &terminal_id);
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":"handoff-after\n"}),
    );
    assert!(wait_for_screen(&harness.socket, surface, "handoff-after").contains("handoff-after"));
    assert_eq!(wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid, host_pid);
}

/// The daemon's own shutdown records the handoff (no test declaration): a
/// graceful stop leaves the host running past the bound, and the next owner
/// adopts it.
#[test]
fn a_graceful_daemon_shutdown_hands_the_terminal_host_over() {
    let _exclusive = exclusive_process_test();
    let mut harness = start_normal_install("owner-exit-graceful");
    let (terminal_id, _, host_pid) = run_cat(&harness, "owner-exit-graceful-before");

    let identify = request(&harness.socket, serde_json::json!({"id":1,"cmd":"identify"}));
    request(
        &harness.socket,
        serde_json::json!({
            "id":2,
            "cmd":"shutdown-daemon",
            "pid":identify["pid"],
            "generation":identify["generation"],
        }),
    );
    let mut child = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(30));
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "the daemon did not exit after its shutdown");
        std::thread::sleep(Duration::from_millis(25));
    }
    let _ = fs::remove_file(&harness.socket);

    std::thread::sleep(ENDS_WITHIN);
    assert!(running(host_pid), "a gracefully shut-down daemon's host ended with it");

    restart_normal_install(&mut harness);
    let surface = wait_adopted_surface(&harness, &terminal_id);
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":"graceful-after\n"}),
    );
    assert!(wait_for_screen(&harness.socket, surface, "graceful-after").contains("graceful-after"));
}
