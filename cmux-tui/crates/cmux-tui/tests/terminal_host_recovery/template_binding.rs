//! The template binding (`CMUX_TUI_TEMPLATE_BOUND_FILE`) tells a clone's warm
//! shell its new identity once. On a Cloud machine it lives in `/run/cmux`,
//! which the bake creates for the daemon's user and the memory snapshot
//! carries. A reboot wipes it, and the daemon cannot recreate it under the
//! root-owned `/run`. Every later daemon start still completes the template
//! terminal: it used to fail that write with `Permission denied` and retry it
//! every 5 s for the life of the machine, one journal line each time.

use super::*;

/// How long a restarted daemon is watched for completion retries. The old
/// loop retried after 100, 200 and 400 ms, so a broken write logged within it.
const RETRY_WINDOW: Duration = Duration::from_millis(1500);

fn stop_with_sigterm(harness: &mut RecoveryHarness) {
    harness.signal_daemon(libc::SIGTERM);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(5));
    while daemon.try_wait().unwrap().is_none() {
        if Instant::now() >= deadline {
            let _ = daemon.kill();
            let _ = daemon.wait();
            panic!("daemon did not exit after SIGTERM");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_file(&harness.socket);
}

/// Start the daemon with the template settings, the binding at `bound`, and
/// its stderr in `log`; return once the template terminal runs again.
fn restart_with_binding(
    harness: &mut RecoveryHarness,
    parked: &ParkedTemplate,
    bound: &Path,
    log: &Path,
) {
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEMPLATE_BOUND_FILE", bound).stderr(fs::File::create(log).unwrap());
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let resolved = request_response(
            &harness.socket,
            serde_json::json!({"id": 1, "cmd": "resolve-terminal", "terminal_id": parked.terminal_id}),
        );
        if resolved["data"]["lifecycle"] == "running"
            && resolved["data"]["terminal_incarnation"].as_str()
                == Some(parked.incarnation.as_str())
        {
            break;
        }
        assert!(Instant::now() < deadline, "template terminal was not adopted again: {resolved}");
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(RETRY_WINDOW);
}

fn log_lines(log: &Path, needle: &str) -> Vec<String> {
    fs::read_to_string(log)
        .unwrap()
        .lines()
        .filter(|line| line.contains(needle))
        .map(str::to_string)
        .collect()
}

#[test]
fn template_restart_without_its_run_directory_does_not_retry_the_binding() {
    let mut harness = RecoveryHarness::start("template-binding");
    let parked = park_template_host(&mut harness);
    harness.adopt_template_terminal = true;
    harness.restart();
    assert_template_bound_and_listed(&harness, &parked);

    // A reboot removed the run directory, and the daemon cannot make it: a
    // regular file stands in for the root-owned /run, so this holds as root.
    stop_with_sigterm(&mut harness);
    let run = harness.dir.join("run");
    fs::write(&run, "").unwrap();
    let missing_dir = harness.dir.join("missing-dir.log");
    restart_with_binding(&mut harness, &parked, &run.join("cmux/bound"), &missing_dir);
    assert_eq!(
        log_lines(&missing_dir, "template terminal"),
        Vec::<String>::new(),
        "no shell waits without the run directory, so nothing is written or retried"
    );

    // The directory exists but the binding cannot be written (a directory
    // sits at its path): reported once, never retried.
    stop_with_sigterm(&mut harness);
    let blocked = harness.dir.join("blocked");
    fs::create_dir_all(blocked.join("bound")).unwrap();
    let unwritable = harness.dir.join("unwritable.log");
    restart_with_binding(&mut harness, &parked, &blocked.join("bound"), &unwritable);
    assert_eq!(log_lines(&unwritable, "not published yet"), Vec::<String>::new());
    assert_eq!(
        log_lines(&unwritable, "binding not written").len(),
        1,
        "{:?}",
        fs::read_to_string(&unwritable)
    );

    // The template terminal still serves after both restarts.
    let created = resource_request(
        &harness.socket,
        "template-binding-create",
        "tab.create_terminal",
        serde_json::json!({"machine":"current","session":"current"}),
        Some("template-binding-create"),
    );
    assert!(created["value"]["terminal_id"].is_string(), "{created}");
}
