//! Shared terminal hosts (`CMUX_TUI_SHARED_TERMINAL_HOSTS=1`): one host
//! process runs many terminals, and each terminal still is a CMTH v4 host to
//! every daemon: its own record, endpoint and PTY custody. A daemon restart
//! (SIGTERM) keeps every terminal, whichever mode the next daemon runs in; a
//! crash of the shared process keeps every shell while a daemon holds their
//! custody; a full host makes the daemon start another one.

use super::host_replacement::{daemon_pty_masters, shell_pid, wait_for_replacement};
use super::pty_custody::{process_running, send_line, signal_pid, wait_for_dead_host};
use super::*;

const SHARED: &str = "CMUX_TUI_SHARED_TERMINAL_HOSTS";
const CAPACITY: &str = "CMUX_TUI_SHARED_TERMINAL_HOST_CAPACITY";

fn harness(name: &str, shared: bool, capacity: Option<u32>) -> RecoveryHarness {
    let mut harness = RecoveryHarness::start_unstarted(name);
    set_shared(&mut harness, shared);
    if let Some(capacity) = capacity {
        harness.extra_env.push((CAPACITY.into(), capacity.to_string()));
    }
    harness.restart();
    harness
}

fn set_shared(harness: &mut RecoveryHarness, shared: bool) {
    harness.extra_env.retain(|(key, _)| key != SHARED);
    harness.extra_env.push((SHARED.into(), if shared { "1" } else { "0" }.into()));
}

struct Shell {
    terminal_id: String,
    pid: u32,
    marker: String,
}

/// A `/bin/sh` terminal in its own workspace that printed a marker.
fn start_shell(harness: &RecoveryHarness, name: &str) -> Shell {
    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/sh"],"new_workspace":true,"name":name}),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let surface = created["surface"].as_u64().unwrap();
    let marker = format!("{name}-marker-{}", std::process::id());
    send_line(&harness.socket, surface, &format!("echo {marker}"));
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    let pid = shell_pid(&harness.socket, surface, name);
    Shell { terminal_id, pid, marker }
}

fn record_of(harness: &RecoveryHarness, terminal_id: &str) -> (PathBuf, TerminalHostRecord) {
    load_terminal_host_records(&harness.host_root())
        .unwrap()
        .into_iter()
        .find(|(_, record)| record.terminal_id == terminal_id)
        .unwrap_or_else(|| panic!("no host record for {terminal_id}"))
}

fn host_pid_of(harness: &RecoveryHarness, shell: &Shell) -> u32 {
    record_of(harness, &shell.terminal_id).1.host_pid
}

/// The surface that shows `terminal_id` once it is running again.
fn running_surface(harness: &RecoveryHarness, terminal_id: &str) -> u64 {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            assert!(resolved["exit"].is_null(), "{resolved}");
            return surface;
        }
        assert!(Instant::now() < deadline, "terminal {terminal_id} is not running: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// The terminal kept its screen and its shell, and takes input.
fn assert_same_shell(harness: &RecoveryHarness, shell: &Shell, tag: &str) {
    let surface = running_surface(harness, &shell.terminal_id);
    let screen = wait_for_screen(&harness.socket, surface, &shell.marker);
    assert!(screen.contains(&shell.marker), "the screen was not kept: {screen}");
    assert_eq!(shell_pid(&harness.socket, surface, tag), shell.pid, "another shell runs");
}

fn daemon_pid(harness: &RecoveryHarness) -> u32 {
    harness.child.as_ref().unwrap().id()
}

#[test]
fn shared_hosts_run_many_terminals_in_one_process_across_daemon_restarts() {
    let _exclusive = exclusive_process_test();
    let mut harness = harness("shared-hosts-restart", true, None);
    let shells = ["one", "two", "three"].map(|name| start_shell(&harness, name));
    let host = host_pid_of(&harness, &shells[0]);
    assert_ne!(host, daemon_pid(&harness));
    for shell in &shells {
        assert_eq!(host_pid_of(&harness, shell), host, "a terminal got a host of its own");
        assert_ne!(shell.pid, host);
    }

    // SIGTERM hands off: the host and every shell stay, and the next daemon
    // (shared hosts on) adopts each terminal through its own record.
    harness.terminate();
    assert!(process_running(host), "the shared host ended with its daemon");
    harness.restart();
    for shell in &shells {
        assert_same_shell(&harness, shell, "after-shared-restart");
        assert_eq!(host_pid_of(&harness, shell), host);
    }
    // A new terminal goes to the new daemon's own shared host: the old one
    // takes none after its daemon left.
    let fourth = start_shell(&harness, "four");
    let second_host = host_pid_of(&harness, &fourth);
    assert_ne!(second_host, host);

    // A daemon with shared hosts off adopts them all the same way.
    harness.terminate();
    set_shared(&mut harness, false);
    harness.restart();
    for shell in shells.iter().chain([&fourth]) {
        assert_same_shell(&harness, shell, "after-plain-restart");
    }
    let plain = start_shell(&harness, "plain");
    let plain_host = host_pid_of(&harness, &plain);
    assert!(![host, second_host].contains(&plain_host), "shared hosts are off");

    // And shared hosts on again adopts the one-terminal host too.
    harness.terminate();
    set_shared(&mut harness, true);
    harness.restart();
    for shell in shells.iter().chain([&fourth, &plain]) {
        assert_same_shell(&harness, shell, "after-mixed-restart");
    }

    // Ending a terminal ends only that terminal.
    send_line(&harness.socket, running_surface(&harness, &shells[0].terminal_id), "exit 3");
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &shells[0].terminal_id, "exited");
    assert_eq!(resolved["exit"]["outcome"], serde_json::json!({"kind":"exit","code":3}));
    assert!(process_running(host), "ending one terminal ended its shared host");
    assert_same_shell(&harness, &shells[1], "after-sibling-exit");
}

#[test]
fn a_shared_host_crash_keeps_every_shell_through_pty_custody() {
    let _exclusive = exclusive_process_test();
    let harness = harness("shared-host-crash", true, None);
    let shells = ["left", "right"].map(|name| start_shell(&harness, name));
    let host = host_pid_of(&harness, &shells[0]);
    assert_eq!(host_pid_of(&harness, &shells[1]), host);
    let records = shells.each_ref().map(|shell| record_of(&harness, &shell.terminal_id));
    // The daemon holds both masters before the crash.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    match daemon_pty_masters(&harness) {
        Some(_) => {
            while daemon_pty_masters(&harness) != Some(2) {
                assert!(Instant::now() < deadline, "the daemon holds no custody of both");
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        None => std::thread::sleep(Duration::from_secs(1)),
    }

    signal_pid(host, libc::SIGKILL);
    for ((record_path, record), shell) in records.iter().zip(&shells) {
        wait_for_dead_host(record_path, record);
        let replacement = wait_for_replacement(&harness, record);
        assert_eq!(replacement.incarnation, record.incarnation);
        assert_same_shell(&harness, shell, "after-crash");
    }
}

#[test]
fn a_full_shared_host_makes_the_daemon_start_another() {
    let _exclusive = exclusive_process_test();
    let harness = harness("shared-host-capacity", true, Some(2));
    let shells = ["a", "b", "c"].map(|name| start_shell(&harness, name));
    let hosts = shells.each_ref().map(|shell| host_pid_of(&harness, shell));
    assert_eq!(hosts[0], hosts[1], "{hosts:?}");
    assert_ne!(hosts[1], hosts[2], "{hosts:?}");
    for shell in &shells {
        assert_same_shell(&harness, shell, "full");
    }
}

/// Lists every open descriptor above stdio of the shell, with builtins only
/// (`ls` opens descriptors of its own).
const PROBE: &str = "i=3; o=; while [ $i -lt 1024 ]; do [ -e /dev/fd/$i ] && o=\"$o $i\"; \
                     i=$((i+1)); done; echo FDS:${o}END; exec cat";

#[test]
fn a_shared_host_shell_inherits_no_descriptor_of_its_host() {
    let _exclusive = exclusive_process_test();
    let harness = harness("shared-host-descriptors", true, None);
    // Siblings first: their PTY masters, sockets and locks are open in the
    // host while the last shell starts.
    let siblings = ["one", "two"].map(|name| start_shell(&harness, name));
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", PROBE],
            "new_workspace": true,
            "name": "descriptors",
        }),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap();
    let surface = created["surface"].as_u64().unwrap();
    let host = record_of(&harness, terminal_id).1.host_pid;
    assert_eq!(host, host_pid_of(&harness, &siblings[0]), "not one shared host");
    let screen = wait_for_screen(&harness.socket, surface, "END");
    assert!(screen.contains("FDS:END"), "the shell inherited descriptors: {screen}");
}

/// Threads of process `pid`.
fn thread_count(pid: u32) -> usize {
    #[cfg(target_os = "linux")]
    {
        fs::read_to_string(format!("/proc/{pid}/status"))
            .unwrap()
            .lines()
            .find_map(|line| line.strip_prefix("Threads:"))
            .and_then(|count| count.trim().parse().ok())
            .unwrap()
    }
    #[cfg(not(target_os = "linux"))]
    {
        let output = Command::new("ps").args(["-M", "-p", &pid.to_string()]).output().unwrap();
        // A header line, then one line per thread.
        String::from_utf8_lossy(&output.stdout).lines().count().saturating_sub(1)
    }
}

/// The host's thread count once it is at most `bound`: workers started
/// for a burst end after two idle seconds. The last count when it is not.
fn threads_settle_to(pid: u32, bound: usize) -> usize {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let count = thread_count(pid);
        if count <= bound || Instant::now() >= deadline {
            return count;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn a_shared_host_runs_the_same_threads_for_two_terminals_and_for_twenty() {
    let _exclusive = exclusive_process_test();
    let harness = harness("shared-host-threads", true, None);
    let first = ["t0", "t1"].map(|name| start_shell(&harness, name));
    let host = host_pid_of(&harness, &first[0]);
    // The control thread, the signal writer, the poller and at most four
    // parse workers.
    let few = threads_settle_to(host, 7);
    assert!(few <= 7, "an idle shared host with 2 terminals runs {few} threads");
    let more: Vec<Shell> =
        (2..20).map(|index| start_shell(&harness, &format!("t{index}"))).collect();
    assert!(more.iter().all(|shell| host_pid_of(&harness, shell) == host), "one shared host");
    let many = threads_settle_to(host, few);
    assert!(many <= few, "threads grew with terminals: {few} for 2, {many} for 20");
    // Every terminal still answers.
    for shell in first.iter().chain(&more) {
        assert_same_shell(&harness, shell, "threads");
    }
}
