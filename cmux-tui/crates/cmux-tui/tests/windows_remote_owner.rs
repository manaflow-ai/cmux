#![cfg(windows)]

use std::io::Read;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

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

    let stop = Command::new(executable)
        .args(["remote-stop", "--session", &session, "--state-dir"])
        .arg(state_root.path())
        .output()
        .unwrap();
    assert!(
        stop.status.success(),
        "remote-stop failed: {}",
        String::from_utf8_lossy(&stop.stderr)
    );
    assert!(
        wait_until(Duration::from_secs(5), || !socket_accepts(&mux_socket)),
        "remote-stop left the resident mux owner running"
    );
}
