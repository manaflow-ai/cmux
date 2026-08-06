#![cfg(windows)]

use std::io::Read;
use std::path::Path;
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::Value;

fn wait_until(timeout: Duration, mut predicate: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if predicate() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    predicate()
}

fn wait_for_exit(child: &mut Child, timeout: Duration) -> bool {
    wait_until(timeout, || child.try_wait().is_ok_and(|status| status.is_some()))
}

fn socket_accepts(path: &Path) -> bool {
    cmux_tui_core::platform::transport::connect(path).is_ok()
}

fn wait_for_mux_owner(owner: &mut Child, socket: &Path) {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if socket_accepts(socket) {
            return;
        }
        if let Some(status) = owner.try_wait().unwrap() {
            let mut stderr = String::new();
            owner.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
            panic!("remote owner exited before publishing its mux socket ({status}): {stderr}");
        }
        if Instant::now() >= deadline {
            let _ = owner.kill();
            let _ = owner.wait();
            let mut stderr = String::new();
            owner.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
            panic!("remote owner did not publish its mux socket within 15s: {stderr}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn assert_cmux_success(output: &Output) {
    assert!(
        output.status.success(),
        "cmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn write_terminal(executable: &str, socket: &Path, terminal: &str, command: &str) {
    let encoded = base64::engine::general_purpose::STANDARD.encode(command);
    let output = Command::new(executable)
        .arg("--socket")
        .arg(socket)
        .args(["terminal", terminal, "write", "--bytes-base64", &encoded])
        .output()
        .unwrap();
    assert_cmux_success(&output);
}

fn spawn_carrier(executable: &str, session: &str, state_root: &Path) -> Child {
    Command::new(executable)
        .args(["remote-link", "--stdio", "--session", session, "--state-dir"])
        .arg(state_root)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

fn spawn_owner(executable: &str, session: &str, state_root: &Path) -> Child {
    Command::new(executable)
        .args(["remote-mux-owner", "--session", session, "--state-dir"])
        .arg(state_root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

fn assert_process_stays_running(child: &mut Child, duration: Duration, label: &str) {
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait().unwrap() {
            let mut stderr = String::new();
            child.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
            panic!("{label} exited unexpectedly ({status}): {stderr}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn windows_remote_carrier_exit_preserves_resident_mux_owner() {
    let executable = env!("CARGO_BIN_EXE_cmux-tui");
    let state_root = tempfile::tempdir().unwrap();
    let session = format!("carrier-owner-{}", std::process::id());
    let session_state = state_root.path().join("sessions").join(&session);
    let mux_socket = session_state.join("mux.sock");

    // GitHub's Windows runner forbids CREATE_BREAKAWAY_FROM_JOB. Launch the
    // durable owner from the longer-lived test job, then verify that the SSH
    // carrier can come and go without owning the mux or its ConPTY children.
    let mut owner = spawn_owner(executable, &session, state_root.path());
    wait_for_mux_owner(&mut owner, &mux_socket);
    let mut carrier = spawn_carrier(executable, &session, state_root.path());
    assert_process_stays_running(&mut carrier, Duration::from_millis(250), "remote carrier");
    let created = Command::new(executable)
        .arg("--socket")
        .arg(&mux_socket)
        .args(["--json", "workspace", "create", "--name", "carrier-survival"])
        .output()
        .unwrap();
    assert!(
        created.status.success(),
        "could not create Windows terminal: {}",
        String::from_utf8_lossy(&created.stderr)
    );
    let created: Value = serde_json::from_slice(&created.stdout).unwrap();
    let terminal = created["value"]["terminal_id"].as_str().unwrap().to_owned();
    write_terminal(
        executable,
        &mux_socket,
        &terminal,
        "Write-Output 'CMUX_WINDOWS_BEFORE_CARRIER_LOSS'\r",
    );

    drop(carrier.stdin.take());
    if !wait_for_exit(&mut carrier, Duration::from_secs(5)) {
        let _ = carrier.kill();
        panic!("remote carrier did not exit after stdin closed");
    }
    let mut stderr = String::new();
    carrier.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();

    let owner_survived = wait_until(Duration::from_secs(2), || socket_accepts(&mux_socket));
    if !owner_survived {
        panic!("mux owner died with the SSH carrier: {stderr}");
    }
    write_terminal(
        executable,
        &mux_socket,
        &terminal,
        "Write-Output 'CMUX_WINDOWS_AFTER_CARRIER_LOSS'\r",
    );
    let wait = Command::new(executable)
        .arg("--socket")
        .arg(&mux_socket)
        .args([
            "terminal",
            &terminal,
            "screen",
            "wait",
            "--pattern",
            "CMUX_WINDOWS_AFTER_CARRIER_LOSS",
            "--timeout-ms",
            "5000",
        ])
        .output()
        .unwrap();
    assert_cmux_success(&wait);

    let stop = Command::new(executable)
        .args(["remote-stop", "--session", &session, "--state-dir"])
        .arg(state_root.path())
        .output()
        .unwrap();
    assert!(stop.status.success(), "remote-stop failed: {}", String::from_utf8_lossy(&stop.stderr));
    assert!(
        wait_until(Duration::from_secs(5), || !socket_accepts(&mux_socket)),
        "remote-stop left the resident mux owner running"
    );
    assert!(wait_for_exit(&mut owner, Duration::from_secs(5)), "remote owner did not exit");

    let mut replacement = spawn_owner(executable, &session, state_root.path());
    wait_for_mux_owner(&mut replacement, &mux_socket);
    let terminals = Command::new(executable)
        .arg("--socket")
        .arg(&mux_socket)
        .args(["--json", "terminal", "list"])
        .output()
        .unwrap();
    assert_cmux_success(&terminals);
    assert!(
        !String::from_utf8_lossy(&terminals.stdout).contains(&terminal),
        "replacement owner exposed an unrecoverable terminal as live"
    );
    let final_stop = Command::new(executable)
        .args(["remote-stop", "--session", &session, "--state-dir"])
        .arg(state_root.path())
        .output()
        .unwrap();
    assert_cmux_success(&final_stop);
    assert!(
        wait_for_exit(&mut replacement, Duration::from_secs(5)),
        "replacement owner did not exit"
    );
}
