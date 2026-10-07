//! cx-6so.49 L1.2: a running daemon keeps custody of every host's PTY
//! master, so when a host dies (SIGKILL, a crash) while its shell lives,
//! the daemon starts a replacement host on the same shell. The terminal
//! keeps its id, incarnation, tab, screen and shell; nothing records an
//! end. A shell that exits, or dies with its host, ends the terminal as
//! before.

use super::pty_custody::{
    kill_shell_then_host, process_running, send_line, signal_pid, wait_for_dead_host,
};
use super::*;

/// A terminal running `/bin/sh` in a new workspace.
struct Shell {
    terminal_id: String,
    incarnation: String,
    surface: u64,
    pid: u32,
    record_path: PathBuf,
    record: TerminalHostRecord,
}

fn start_shell(harness: &RecoveryHarness, name: &str) -> Shell {
    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/sh"],"new_workspace":true,"name":name}),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let surface = created["surface"].as_u64().unwrap();
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let pid = shell_pid(&harness.socket, surface, "first");
    Shell { terminal_id, incarnation, surface, pid, record_path, record }
}

/// The shell's PID, printed by `echo <tag>-$$` (the echoed command line
/// shows `$$`, the output the number).
fn shell_pid(socket: &Path, surface: u64, tag: &str) -> u32 {
    send_line(socket, surface, &format!("echo {tag}-$$"));
    let needle = format!("{tag}-");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let screen =
            request(socket, serde_json::json!({"cmd":"read-screen","surface":surface}))["text"]
                .as_str()
                .unwrap_or_default()
                .to_string();
        let pid = screen.match_indices(&needle).find_map(|(at, _)| {
            let digits: String =
                screen[at + needle.len()..].chars().take_while(char::is_ascii_digit).collect();
            digits.parse::<u32>().ok()
        });
        if let Some(pid) = pid {
            return pid;
        }
        assert!(Instant::now() < deadline, "the shell printed no {needle}PID: {screen}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// PTY masters the daemon holds (Linux: from `/proc`); `None` elsewhere.
fn daemon_pty_masters(harness: &RecoveryHarness) -> Option<usize> {
    #[cfg(target_os = "linux")]
    {
        let pid = harness.child.as_ref()?.id();
        let entries = fs::read_dir(format!("/proc/{pid}/fd")).ok()?;
        Some(
            entries
                .flatten()
                .filter_map(|entry| fs::read_link(entry.path()).ok())
                .filter(|target| target.to_string_lossy().ends_with("ptmx"))
                .count(),
        )
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = harness;
        None
    }
}

/// Wait until the daemon holds (or released) custody of a PTY master.
/// Without `/proc`, a holding wait gives the custody thread a second.
fn wait_for_daemon_custody(harness: &RecoveryHarness, held: bool) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        match daemon_pty_masters(harness) {
            None => {
                if held {
                    std::thread::sleep(Duration::from_secs(1));
                }
                return;
            }
            Some(count) if (count > 0) == held => return,
            Some(count) => {
                assert!(Instant::now() < deadline, "daemon holds {count} PTY masters, held={held}");
                std::thread::sleep(Duration::from_millis(20));
            }
        }
    }
}

fn loss_log_lines(harness: &RecoveryHarness, terminal_id: &str) -> Vec<serde_json::Value> {
    let log = harness.host_root().parent().unwrap().join("terminal-losses.jsonl");
    fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .filter(|line| line["terminal_id"] == terminal_id)
        .collect()
}

fn tab_of(harness: &RecoveryHarness, name: &str) -> serde_json::Value {
    let tree = request(&harness.socket, serde_json::json!({"id":3,"cmd":"list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == name)
        .and_then(first_tab)
        .cloned()
        .unwrap_or_else(|| panic!("workspace {name} lost its tab: {tree}"))
}

/// The host record once a host other than `old` serves the terminal.
fn wait_for_replacement(harness: &RecoveryHarness, old: &TerminalHostRecord) -> TerminalHostRecord {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let records = load_terminal_host_records(&harness.host_root()).unwrap();
        if let Some((path, record)) = records.into_iter().find(|(_, record)| {
            record.terminal_id == old.terminal_id && record.host_pid != old.host_pid
        }) && terminal_host_record_liveness(&path, &record).unwrap()
            == TerminalHostLiveness::Live
        {
            return record;
        }
        assert!(Instant::now() < deadline, "no replacement host for {}", old.terminal_id);
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Kill the host of `shell` with `signal` and prove the terminal came back
/// in place on the same shell. Returns the replacement host's record.
fn assert_replaced_in_place(
    harness: &RecoveryHarness,
    shell: &Shell,
    name: &str,
    signal: libc::c_int,
) -> TerminalHostRecord {
    let marker = format!("before-host-{signal}-{}", std::process::id());
    send_line(&harness.socket, shell.surface, &format!("echo {marker}"));
    assert!(wait_for_screen(&harness.socket, shell.surface, &marker).contains(&marker));
    wait_for_daemon_custody(harness, true);

    signal_pid(shell.record.host_pid, signal);
    if signal == libc::SIGSEGV {
        // Rust's stack-overflow handler swallows one SIGSEGV that is not a
        // guard-page fault and restores the default action; a second one is
        // the crash.
        let deadline = Instant::now() + Duration::from_millis(500);
        while process_running(shell.record.host_pid) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        if process_running(shell.record.host_pid) {
            signal_pid(shell.record.host_pid, libc::SIGSEGV);
        }
    }
    wait_for_dead_host(&shell.record_path, &shell.record);
    let replacement = wait_for_replacement(harness, &shell.record);
    assert_eq!(replacement.incarnation, shell.incarnation);
    assert_ne!(replacement.host_start_nonce, shell.record.host_start_nonce);
    assert!(replacement.supports_pty_custody, "{replacement:?}");

    let resolved = wait_for_terminal_lifecycle(&harness.socket, &shell.terminal_id, "running");
    assert_eq!(resolved["terminal_incarnation"], shell.incarnation.as_str(), "{resolved}");
    assert_eq!(resolved["surface"].as_u64(), Some(shell.surface), "{resolved}");
    assert!(resolved["exit"].is_null(), "a replaced host recorded an end: {resolved}");
    let tab = tab_of(harness, name);
    assert_eq!(tab["dead"], false, "{tab}");
    let screen = wait_for_screen(&harness.socket, shell.surface, &marker);
    assert!(screen.contains(&marker), "the screen was not preserved: {screen}");
    assert_eq!(
        shell_pid(&harness.socket, shell.surface, "again"),
        shell.pid,
        "the terminal runs another shell"
    );

    let lines = loss_log_lines(harness, &shell.terminal_id);
    let replaced = lines
        .iter()
        .find(|line| line["event"] == "host_replaced")
        .unwrap_or_else(|| panic!("no host_replaced line: {lines:?}"));
    assert_eq!(replaced["old_host_pid"].as_u64(), Some(u64::from(shell.record.host_pid)));
    assert_eq!(replaced["new_host_pid"].as_u64(), Some(u64::from(replacement.host_pid)));
    assert_eq!(replaced["incarnation"], shell.incarnation.as_str());
    assert!(
        lines.iter().all(|line| line.get("end").is_none()),
        "a host loss was logged: {lines:?}"
    );
    replacement
}

#[test]
fn sigkill_of_a_host_under_a_running_daemon_keeps_the_same_terminal_and_shell() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("host-replaced-sigkill");
    let shell = start_shell(&harness, "replaced");
    assert_replaced_in_place(&harness, &shell, "replaced", libc::SIGKILL);
}

#[test]
fn sigsegv_of_a_host_is_replaced_the_same_way() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("host-replaced-sigsegv");
    let shell = start_shell(&harness, "crashed");
    assert_replaced_in_place(&harness, &shell, "crashed", libc::SIGSEGV);
}

#[test]
fn a_shell_that_exits_normally_with_custody_held_ends_normally() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("custody-normal-exit");
    let shell = start_shell(&harness, "exits");
    wait_for_daemon_custody(&harness, true);
    send_line(&harness.socket, shell.surface, "exit 7");

    let resolved = wait_for_terminal_lifecycle(&harness.socket, &shell.terminal_id, "exited");
    assert_eq!(resolved["terminal_incarnation"], shell.incarnation.as_str(), "{resolved}");
    assert_eq!(
        resolved["exit"]["outcome"],
        serde_json::json!({"kind":"exit","code":7}),
        "{resolved}"
    );
    wait_for_dead_host(&shell.record_path, &shell.record);
    wait_for_daemon_custody(&harness, false);
    assert!(!process_running(shell.pid), "the shell outlived its exit");
    let lines = loss_log_lines(&harness, &shell.terminal_id);
    assert!(lines.is_empty(), "a process end was logged as a loss or replacement: {lines:?}");
}

#[test]
fn a_replaced_host_is_readopted_after_a_daemon_restart() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("host-replaced-restart");
    let shell = start_shell(&harness, "readopted");
    let replacement = assert_replaced_in_place(&harness, &shell, "readopted", libc::SIGKILL);

    harness.signal_daemon(libc::SIGTERM);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_file(&harness.socket);
    harness.restart();

    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let (resolved, surface) = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":shell.terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break (resolved, surface);
        }
        assert!(Instant::now() < deadline, "the replaced terminal was not re-adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    };
    assert_eq!(resolved["terminal_incarnation"], shell.incarnation.as_str(), "{resolved}");
    let records = wait_for_host_records(&harness.host_root(), 1);
    assert_eq!(records[0].1.host_pid, replacement.host_pid, "the terminal got another host");
    assert_eq!(shell_pid(&harness.socket, surface, "restarted"), shell.pid);
    // The new daemon takes custody again and can replace the host again.
    wait_for_daemon_custody(&harness, true);
}

#[test]
fn a_terminal_whose_shell_died_with_its_host_is_not_replaced() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("host-and-shell-killed");
    let shell = start_shell(&harness, "both");
    wait_for_daemon_custody(&harness, true);
    kill_shell_then_host(&shell.record_path, &shell.record);

    let resolved = wait_for_terminal_lifecycle(&harness.socket, &shell.terminal_id, "exited");
    assert!(!resolved["exit"].is_null(), "{resolved}");
    assert_eq!(tab_of(&harness, "both")["dead"], true);
    let lines = loss_log_lines(&harness, &shell.terminal_id);
    assert!(
        lines.iter().all(|line| line["event"] != "host_replaced"),
        "a dead shell got a replacement host: {lines:?}"
    );
    assert!(
        load_terminal_host_records(&harness.host_root())
            .unwrap()
            .iter()
            .all(|(path, record)| terminal_host_record_liveness(path, record).unwrap()
                != TerminalHostLiveness::Live),
        "a host serves the terminal of a dead shell"
    );
    wait_for_daemon_custody(&harness, false);
}
