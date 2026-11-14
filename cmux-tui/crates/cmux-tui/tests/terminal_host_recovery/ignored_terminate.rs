//! A closed terminal whose host never acts on Terminate must still end. On
//! main a host parser panic poisoned the terminal lock and killed the host's
//! client input thread, so Terminate was never read, and the host and its
//! shell outlived `terminal close` with no trace in the owner's logs. After
//! the close's bounded waits the owner ends such a host itself, with proof
//! that the recorded PID is that host, and logs the forced end. The signal
//! goes to the host's own process group only: the PTY hangup ends the shell,
//! and a process that left the terminal's session (`setsid`) is not ended.

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;

use cmux_tui_core::terminal_host_runtime::wait_for_terminal_host_exit;

use super::*;

/// The terminal's command. A perl child leaves the session (`setsid`, no
/// PTY descriptor) and writes its pid; then the shell holds the write end of
/// `shell_fifo` (its exit is the reader's EOF) and becomes `cat`.
fn shell_script(escaped_pid: &Path, shell_fifo: &Path) -> String {
    // Single-quoted for sh, so perl code uses double quotes only.
    let perl = concat!(
        "use POSIX; pipe(my $r, my $w) or die; my $p = fork() // die; ",
        "if ($p) { close $w; <$r>; open(my $f, \">\", $ARGV[0]) or die; ",
        "print $f $p; close $f; exit 0 } ",
        "close $r; POSIX::setsid() or die; ",
        "open(STDIN, \"<\", \"/dev/null\"); open(STDOUT, \">\", \"/dev/null\"); ",
        "open(STDERR, \">\", \"/dev/null\"); close $w; sleep 300",
    );
    format!(
        "perl -e '{perl}' \"{}\" && exec 3>\"{}\" && exec cat",
        escaped_pid.display(),
        shell_fifo.display()
    )
}

fn make_fifo(path: &Path) {
    let path = CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: a valid NUL-terminated path; mkfifo only creates the node.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0, "mkfifo failed");
}

fn process_alive(pid: libc::pid_t) -> bool {
    // SAFETY: signal 0 only probes the process; nothing is delivered.
    unsafe { libc::kill(pid, 0) == 0 }
}

#[test]
fn a_closed_terminal_host_that_ignores_terminate_is_ended_and_logged() {
    let mut harness = RecoveryHarness::start_unstarted("ignored-terminate");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_HOST_IGNORE_TERMINATE", "1");
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    let escaped_pid_path = harness.dir.join("escaped.pid");
    let shell_fifo = harness.dir.join("shell.fifo");
    make_fifo(&shell_fifo);
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", shell_script(&escaped_pid_path, &shell_fifo)],
            "new_workspace": true,
            "name": "ignored-terminate",
        }),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    // Opens once the shell holds the write end, which it does only after the
    // escaped child wrote its pid. EOF means every writer (the shell) ended.
    let (shell_ended, shell_exit) = mpsc::channel();
    {
        std::thread::spawn(move || {
            let mut reader = fs::File::open(&shell_fifo).unwrap();
            let _ = shell_ended.send(());
            let _ = std::io::copy(&mut reader, &mut std::io::sink());
            let _ = shell_ended.send(());
        });
    }
    shell_exit.recv_timeout(test_timeout(Duration::from_secs(10))).expect("the shell started");
    let escaped: libc::pid_t =
        fs::read_to_string(&escaped_pid_path).unwrap().trim().parse().unwrap();
    assert!(process_alive(escaped), "the escaped child did not start");

    // The host holds its live marker's lease for its whole life, so taking
    // the lease is its exit event.
    let (exited, host_exit) = mpsc::channel();
    {
        let record = record.clone();
        std::thread::spawn(move || {
            let result = wait_for_terminal_host_exit(&record_path, &record);
            let _ = exited.send(result.map_err(|error| format!("{error:#}")));
        });
    }

    let closed = request(
        &harness.socket,
        serde_json::json!({
            "id": 2,
            "cmd": "close-terminal",
            "terminal_id": &terminal_id,
            "terminal_incarnation": &incarnation,
        }),
    );
    assert_eq!(closed["terminal_id"].as_str(), Some(terminal_id.as_str()), "{closed}");

    // The close waits for the host's exit receipt, asks once more with the
    // same wait (about 9.5 s each), then ends the host.
    let ended = host_exit.recv_timeout(test_timeout(Duration::from_secs(40)));
    let shell = shell_exit.recv_timeout(test_timeout(Duration::from_secs(10)));
    let escaped_survived = process_alive(escaped);
    // SAFETY: test cleanup of the child this test's terminal started.
    unsafe { libc::kill(escaped, libc::SIGKILL) };
    assert!(
        matches!(ended, Ok(Ok(()))),
        "the host that ignores Terminate still runs after its terminal closed: {ended:?}"
    );
    assert!(shell.is_ok(), "the shell outlived its ended host");
    assert!(escaped_survived, "the forced end reached a process outside the host's group");
    let log_path = harness.host_root().parent().unwrap().join("terminal-losses.jsonl");
    let log = fs::read_to_string(&log_path).unwrap_or_default();
    let line = log
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .find(|line| {
            line["event"] == "host_close_forced" && line["terminal_id"] == terminal_id.as_str()
        })
        .unwrap_or_else(|| panic!("the forced end is not in {log_path:?}: {log}"));
    assert_eq!(line["incarnation"].as_str(), Some(incarnation.as_str()), "{line}");
    assert_eq!(line["host_pid"].as_u64(), Some(u64::from(record.host_pid)), "{line}");
    wait_for_no_host_records_within(&harness.host_root(), test_timeout(Duration::from_secs(10)));
}
