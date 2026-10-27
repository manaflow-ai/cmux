//! Graceful terminal close (Lawrence, 2026-10-23): closing a terminal tab
//! removes it at once, while its host ends the processes in the background:
//! SIGHUP to the session's process groups, a grace period for them to exit,
//! then SIGTERM, a shorter grace, and SIGKILL last. No host is left behind.

use super::*;

/// Start `script` (Python) as the terminal's only process and wait until it
/// prints `marker`. Returns the terminal id and incarnation.
fn run_python_terminal(
    harness: &RecoveryHarness,
    name: &str,
    script: &str,
    args: &[String],
    marker: &str,
) -> (String, String) {
    let mut argv = vec!["python3".to_owned(), "-c".to_owned(), script.to_owned()];
    argv.extend(args.iter().cloned());
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": argv,
            "new_workspace": true,
            "name": name,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    assert!(wait_for_screen(&harness.socket, surface, marker).contains(marker));
    let tree = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}));
    let tab = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["surface"].as_u64() == Some(surface))
        .expect("the new terminal is in the tree");
    (
        tab["terminal_id"].as_str().unwrap().to_owned(),
        tab["terminal_incarnation"].as_str().unwrap().to_owned(),
    )
}

/// Close the terminal and return how long the reply took and the wall-clock
/// time (seconds since the epoch) when the close was sent.
fn close_and_time(
    harness: &RecoveryHarness,
    terminal_id: &str,
    incarnation: &str,
) -> (Duration, f64) {
    let sent_at = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64();
    let started = Instant::now();
    let closed = request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    let replied_in = started.elapsed();
    assert_eq!(closed["terminal_id"].as_str(), Some(terminal_id), "{closed}");
    (replied_in, sent_at)
}

fn wait_for_file(path: &Path, timeout: Duration) -> Option<String> {
    let deadline = Instant::now() + test_timeout(timeout);
    loop {
        if let Ok(contents) = fs::read_to_string(path)
            && !contents.is_empty()
        {
            return Some(contents);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A program that cleans up on SIGHUP (an editor saving its swap file, an
/// agent flushing its transcript) gets time to finish. The old close path
/// waited 250 ms after SIGHUP and then SIGKILLed the session.
#[test]
fn graceful_close_gives_a_sighup_handler_time_to_finish() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("graceful-close-hup-cleanup");
    let done = harness.dir.join("hup-cleanup.done");
    let pid_path = harness.dir.join("hup-cleanup.pid");
    let marker = format!("hup-cleanup-ready-{}", std::process::id());
    let script = r#"import os, signal, sys, time
def on_hup(*_):
    time.sleep(0.8)
    with open(sys.argv[1] + '.tmp', 'w') as out:
        out.write('cleaned')
    os.replace(sys.argv[1] + '.tmp', sys.argv[1])
    os._exit(0)
signal.signal(signal.SIGHUP, on_hup)
with open(sys.argv[2] + '.tmp', 'w') as out:
    out.write(str(os.getpid()))
os.replace(sys.argv[2] + '.tmp', sys.argv[2])
print(sys.argv[3], flush=True)
while True:
    time.sleep(60)
"#;
    let args = [done.display().to_string(), pid_path.display().to_string(), marker.clone()];
    let (terminal_id, incarnation) =
        run_python_terminal(&harness, "hup-cleanup", script, &args, &marker);
    let pid = wait_for_pid_file(&pid_path);

    let (replied_in, _) = close_and_time(&harness, &terminal_id, &incarnation);
    assert!(replied_in < Duration::from_secs(1), "close waited {replied_in:?} for the shutdown");
    assert!(!tree_terminal_ids(&harness.socket).contains(&terminal_id));

    assert_eq!(
        wait_for_file(&done, Duration::from_secs(10)).as_deref(),
        Some("cleaned"),
        "the SIGHUP handler was killed before it finished its cleanup"
    );
    wait_for_no_host_records(&harness.host_root());
    wait_for_process_and_group_absent(pid);
}

/// A program that ignores SIGHUP gets SIGTERM after the hangup grace, before
/// SIGKILL, so it can still shut down cleanly.
#[test]
fn graceful_close_sends_sigterm_after_the_hangup_grace() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("graceful-close-term");
    let done = harness.dir.join("term.done");
    let pid_path = harness.dir.join("term.pid");
    let marker = format!("term-ready-{}", std::process::id());
    let script = r#"import os, signal, sys, time
def on_term(*_):
    with open(sys.argv[1] + '.tmp', 'w') as out:
        out.write(repr(time.time()))
    os.replace(sys.argv[1] + '.tmp', sys.argv[1])
    os._exit(0)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
signal.signal(signal.SIGTERM, on_term)
with open(sys.argv[2] + '.tmp', 'w') as out:
    out.write(str(os.getpid()))
os.replace(sys.argv[2] + '.tmp', sys.argv[2])
print(sys.argv[3], flush=True)
while True:
    time.sleep(60)
"#;
    let args = [done.display().to_string(), pid_path.display().to_string(), marker.clone()];
    let (terminal_id, incarnation) = run_python_terminal(&harness, "term", script, &args, &marker);
    let pid = wait_for_pid_file(&pid_path);

    let (replied_in, sent_at) = close_and_time(&harness, &terminal_id, &incarnation);
    assert!(replied_in < Duration::from_secs(1), "close waited {replied_in:?} for the shutdown");
    assert!(!tree_terminal_ids(&harness.socket).contains(&terminal_id));

    let termed_at = wait_for_file(&done, Duration::from_secs(10))
        .expect("the SIGHUP-ignoring program never got SIGTERM before SIGKILL");
    let waited = termed_at.trim().parse::<f64>().unwrap() - sent_at;
    assert!(waited >= 1.5, "SIGTERM came {waited:.2}s after close, before the hangup grace");
    wait_for_no_host_records(&harness.host_root());
    wait_for_process_and_group_absent(pid);
}

/// A program that ignores SIGHUP and SIGTERM is still SIGKILLed, and its host
/// exits: closing a tab never leaves an orphaned PTY host.
#[test]
fn graceful_close_kills_a_program_that_ignores_hangup_and_terminate() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("graceful-close-stubborn");
    let pid_path = harness.dir.join("stubborn.pid");
    let marker = format!("stubborn-ready-{}", std::process::id());
    let script = r#"import os, signal, sys, time
signal.signal(signal.SIGHUP, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(sys.argv[1] + '.tmp', 'w') as out:
    out.write(str(os.getpid()))
os.replace(sys.argv[1] + '.tmp', sys.argv[1])
print(sys.argv[2], flush=True)
while True:
    time.sleep(60)
"#;
    let args = [pid_path.display().to_string(), marker.clone()];
    let (terminal_id, incarnation) =
        run_python_terminal(&harness, "stubborn", script, &args, &marker);
    let pid = wait_for_pid_file(&pid_path);
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    let (replied_in, _) = close_and_time(&harness, &terminal_id, &incarnation);
    assert!(replied_in < Duration::from_secs(1), "close waited {replied_in:?} for the shutdown");
    wait_for_process_and_group_absent(pid);
    wait_for_terminal_host_dead(&record_path, &record);
    wait_for_no_host_records(&harness.host_root());
}
