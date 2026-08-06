#![cfg(windows)]

use std::fs::OpenOptions;
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::Engine as _;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::link::FrameLink;
use cmux_remote::provider::{
    CarrierEvidence, LengthDelimitedLink, LinkGroup, LinkRequest, ProviderCapabilities,
    ProviderError,
};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{LanePolicy, SessionId};
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

struct WindowsStdioLinkGroup {
    executable: PathBuf,
    session: String,
    state_root: PathBuf,
    carrier_log: PathBuf,
    evidence: CarrierEvidence,
}

#[async_trait]
impl LinkGroup for WindowsStdioLinkGroup {
    fn description(&self) -> &str {
        "windows-stdio-regression"
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::STREAM
    }

    fn evidence(&self) -> &CarrierEvidence {
        &self.evidence
    }

    async fn open(&self, _request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        let stderr = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.carrier_log)
            .map_err(|error| ProviderError::Transport(error.to_string()))?;
        let mut child = tokio::process::Command::new(&self.executable)
            .args(["remote-link", "--stdio", "--session", &self.session, "--state-dir"])
            .arg(&self.state_root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(stderr))
            .spawn()
            .map_err(|error| ProviderError::Transport(error.to_string()))?;
        let stdin = child.stdin.take().ok_or_else(|| {
            ProviderError::Transport("Windows carrier stdin was not piped".into())
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            ProviderError::Transport("Windows carrier stdout was not piped".into())
        })?;

        Ok(Box::new(LengthDelimitedLink::new("windows-stdio-regression", 65_535, stdout, stdin)))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        Ok(())
    }
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
fn windows_remote_stop_recovers_an_orphaned_mux_socket() {
    let executable = env!("CARGO_BIN_EXE_cmux-tui");
    let state_root = tempfile::tempdir().unwrap();
    let session = format!("stale-owner-{}", std::process::id());
    let mux_socket = state_root.path().join("sessions").join(&session).join("mux.sock");
    let mut owner = spawn_owner(executable, &session, state_root.path());
    wait_for_mux_owner(&mut owner, &mux_socket);

    owner.kill().unwrap();
    assert!(wait_for_exit(&mut owner, Duration::from_secs(5)), "remote owner did not terminate");
    assert!(mux_socket.exists(), "forced owner exit did not leave an orphaned mux socket");
    let error = match cmux_tui_core::platform::transport::connect(&mux_socket) {
        Ok(_) => panic!("orphaned mux socket still accepted connections"),
        Err(error) => error,
    };
    assert!(
        error.raw_os_error() == Some(10_050) || error.kind() == ErrorKind::ConnectionRefused,
        "orphaned Windows AF_UNIX socket returned a live-owner error: {error:?}"
    );

    let stop = Command::new(executable)
        .args(["remote-stop", "--session", &session, "--state-dir"])
        .arg(state_root.path())
        .output()
        .unwrap();
    assert_cmux_success(&stop);

    let mut replacement = spawn_owner(executable, &session, state_root.path());
    wait_for_mux_owner(&mut replacement, &mux_socket);
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn windows_remote_stdio_completes_authenticated_handshake() {
    let executable = std::env::current_exe()
        .unwrap()
        .parent()
        .and_then(Path::parent)
        .unwrap()
        .join("cmux-tui.exe");
    let state_root = tempfile::tempdir().unwrap();
    let session = format!("stdio-handshake-{}", std::process::id());
    let session_state = state_root.path().join("sessions").join(&session);
    let mux_socket = session_state.join("mux.sock");
    let link_socket = session_state.join("link.sock");
    let carrier_log = state_root.path().join("carrier.log");
    let mut owner = spawn_owner(executable.to_str().unwrap(), &session, state_root.path());
    wait_for_mux_owner(&mut owner, &mux_socket);
    assert!(
        wait_until(Duration::from_secs(5), || link_socket.exists()),
        "remote owner did not publish its carrier socket"
    );

    let group = Arc::new(WindowsStdioLinkGroup {
        executable: executable.clone(),
        session: session.clone(),
        state_root: state_root.path().to_path_buf(),
        carrier_log: carrier_log.clone(),
        evidence: CarrierEvidence::Ssh { destination: "windows-stdio-regression".into() },
    });
    let config = ClientConnectionConfig {
        identity: StaticIdentity::generate().unwrap(),
        expected_daemon: None,
        auth: ClientAuthMode::Carrier,
        device_name: "windows-stdio-regression".into(),
        session: SessionId([91; 16]),
        lane_policy: LanePolicy::Single,
        limits: SessionLimits::default(),
        reconnect: ReconnectPolicy {
            heartbeat_interval: None,
            maximum_attempts: Some(1),
            ..ReconnectPolicy::default()
        },
    };

    let connected =
        tokio::time::timeout(Duration::from_secs(5), ClientConnection::connect(group, config))
            .await;
    let failure = match connected {
        Ok(Ok(client)) => tokio::time::timeout(Duration::from_secs(3), client.close())
            .await
            .map_err(|_| "client close timed out".to_owned())
            .and_then(|result| result.map_err(|error| error.to_string()))
            .err(),
        Ok(Err(error)) => Some(format!("handshake failed: {error}")),
        Err(_) => Some("handshake timed out".into()),
    };

    let stop = Command::new(&executable)
        .args(["remote-stop", "--session", &session, "--state-dir"])
        .arg(state_root.path())
        .output()
        .unwrap();
    assert_cmux_success(&stop);
    assert!(wait_for_exit(&mut owner, Duration::from_secs(5)), "remote owner did not exit");

    let diagnostics = std::fs::read_to_string(carrier_log).unwrap_or_default();
    assert!(failure.is_none(), "{}; carrier diagnostics: {diagnostics}", failure.unwrap());
}
