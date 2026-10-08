//! cx-0tgl LA: every host loss and every owner stop names its cause. A
//! signal's sender is recorded with its name and parent, a host crash
//! leaves its panic message, and a termination signal to the owner daemon
//! is logged with its sender, so an external killer is visible at once.

use super::pty_custody::kill_shell_then_host;
use super::*;

fn loss_log(harness: &RecoveryHarness) -> PathBuf {
    harness.host_root().parent().unwrap().join("terminal-losses.jsonl")
}

fn wait_for_log_line(
    log: &Path,
    what: &str,
    matches: impl Fn(&serde_json::Value) -> bool,
) -> serde_json::Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let found = fs::read_to_string(log)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .find(|line| matches(line));
        if let Some(line) = found {
            return line;
        }
        assert!(Instant::now() < deadline, "no {what} line in {log:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A `/bin/sh` that sends `signal` to `pid` with its builtin `kill`, then
/// stays alive (the trailing `:` keeps the shell from exec'ing `sleep`), so
/// the recipient can name it.
fn spawn_signal_sender(pid: u32, signal: &str) -> Child {
    Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("kill -{signal} {pid}; sleep 30; :"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}

fn stop(mut child: Child) {
    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn host_loss_names_the_sender_of_each_recorded_signal() {
    let harness = RecoveryHarness::start_without_respawn("loss-cause-sender");
    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,"name":"sender"}),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    let sender = spawn_signal_sender(record.host_pid, "TERM");
    let sender_pid = sender.id();
    let signals = record_path.with_extension("signals");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(5));
    while !fs::read_to_string(&signals).unwrap_or_default().contains("\"signal\"") {
        assert!(Instant::now() < deadline, "the host recorded no signal");
        std::thread::sleep(Duration::from_millis(20));
    }
    kill_shell_then_host(&record_path, &record);
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    stop(sender);

    let line = wait_for_log_line(&loss_log(&harness), "loss", |line| {
        line["terminal_id"] == terminal_id.as_str() && line.get("end").is_some()
    });
    let recorded = &line["signals"][0];
    assert_eq!(recorded["sender_pid"].as_u64(), Some(u64::from(sender_pid)), "{line}");
    let name = recorded["sender"]["name"].as_str().unwrap_or_default();
    assert!(!name.is_empty(), "the sender has no name: {line}");
    assert_eq!(recorded["sender"]["ppid"].as_u64(), Some(u64::from(std::process::id())), "{line}");
    let cause = line["cause"].as_str().unwrap();
    assert!(
        cause.contains(&format!("SIGTERM from pid {sender_pid} ({name}")),
        "the cause does not name the sender: {cause}"
    );
}

#[test]
fn host_crash_is_named_with_its_panic_message() {
    let mut harness = RecoveryHarness::start_unstarted("loss-cause-crash");
    let once = harness.dir.join("host-abort-once");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_HOST_ABORT_ONCE", &once);
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);

    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/sh"],"new_workspace":true,"name":"crash"}),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    // The first host aborts after a test-injected panic; the daemon keeps
    // the shell and replaces the host (L1.2), and the line names the crash.
    let line = wait_for_log_line(&loss_log(&harness), "host_replaced", |line| {
        line["terminal_id"] == terminal_id.as_str() && line["event"] == "host_replaced"
    });
    assert!(once.exists(), "the crash seam did not run");
    let cause = line["cause"].as_str().unwrap();
    assert!(cause.contains("crashed"), "{line}");
    assert!(cause.contains("test-injected host crash"), "{line}");
    assert!(line["crash"]["location"].as_str().is_some_and(|at| !at.is_empty()), "{line}");
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
}

#[test]
fn owner_daemon_logs_the_sender_of_its_termination_signal() {
    let mut harness = RecoveryHarness::start("loss-cause-daemon-term");
    let daemon_pid = harness.child.as_ref().unwrap().id();
    let sender = spawn_signal_sender(daemon_pid, "TERM");
    let sender_pid = sender.id();
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "the daemon did not stop on SIGTERM");
        std::thread::sleep(Duration::from_millis(10));
    }
    stop(sender);
    let line = wait_for_log_line(&loss_log(&harness), "daemon_signal", |line| {
        line["event"] == "daemon_signal"
    });
    assert_eq!(line["signal"], libc::SIGTERM, "{line}");
    assert_eq!(line["sender_pid"].as_u64(), Some(u64::from(sender_pid)), "{line}");
    assert_eq!(line["daemon_pid"].as_u64(), Some(u64::from(daemon_pid)), "{line}");
    assert!(line["sender"]["name"].as_str().is_some_and(|name| !name.is_empty()), "{line}");
    let _ = fs::remove_file(&harness.socket);
}
