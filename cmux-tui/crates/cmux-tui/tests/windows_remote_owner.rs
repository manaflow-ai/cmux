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

fn assert_cmux_success(output: Output) {
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
    assert_cmux_success(output);
}

#[test]
fn windows_remote_carrier_exit_preserves_resident_mux_owner() {
    let executable = env!("CARGO_BIN_EXE_cmux-tui");
    let state_root = tempfile::tempdir().unwrap();
    let session = format!("carrier-owner-{}", std::process::id());
    let session_state = state_root.path().join("sessions").join(&session);
    let mux_socket = session_state.join("mux.sock");

    let mut carrier = Command::new(executable)
        .args(["remote-link", "--stdio", "--session", &session, "--state-dir"])
        .arg(state_root.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    assert!(
        wait_until(Duration::from_secs(5), || socket_accepts(&mux_socket)),
        "remote carrier never published its mux socket"
    );
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
    assert_cmux_success(wait);

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
}
