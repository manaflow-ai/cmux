#[cfg(unix)]
use std::collections::VecDeque;
use std::fs;
#[cfg(unix)]
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::net::Shutdown;
#[cfg(unix)]
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::os::unix::ffi::OsStringExt;
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt, symlink};
#[cfg(unix)]
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

struct HeadlessServer {
    child: Child,
    socket: PathBuf,
    state: PathBuf,
    dir: PathBuf,
}

impl HeadlessServer {
    fn start(name: &str) -> Self {
        Self::start_with_config(name, None)
    }

    fn start_with_config(name: &str, config_contents: Option<&str>) -> Self {
        Self::start_with_options(name, config_contents, None)
    }

    fn start_in(name: &str, launch_cwd: &std::path::Path) -> Self {
        Self::start_with_options(name, None, Some(launch_cwd))
    }

    fn start_with_options(
        name: &str,
        config_contents: Option<&str>,
        launch_cwd: Option<&std::path::Path>,
    ) -> Self {
        let dir = unique_temp_dir(name);
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        // A headless fixture must never inherit the developer's real plugin
        // configuration. Server-owned plugins are configured explicitly by
        // the tests that exercise them.
        let config = dir.join("config.json");
        if let Some(contents) = config_contents {
            fs::write(&config, contents).unwrap();
        }
        let mut command = Command::new(bin());
        command
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("CMUX_TUI_CONFIG", &config)
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        if let Some(launch_cwd) = launch_cwd {
            command.current_dir(launch_cwd);
        }
        let child = command.spawn().unwrap();
        let server = Self { child, socket, state, dir };
        server.wait_for_socket();
        server
    }

    fn wait_for_socket(&self) {
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            if transport::connect(&self.socket).is_ok() {
                return;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        panic!("headless server did not create socket at {}", self.socket.display());
    }

    fn close_all_resources(&self) -> Result<(), String> {
        let host_root =
            cmux_tui_core::terminal_host_runtime::terminal_host_root(&self.state, "main");
        // Capture exact host PIDs before close can remove their discovery
        // records. Waiting on both proves teardown did not merely unlink the
        // record while leaving its process behind.
        let host_pids = terminal_host_pids(&host_root);
        let Some(tree) = try_json_socket_request(
            &self.socket,
            serde_json::json!({"id": u64::MAX - 1, "cmd": "list-workspaces"}),
        ) else {
            return host_pids.is_empty().then_some(()).ok_or_else(|| {
                format!("server socket unavailable; live host pids: {host_pids:?}")
            });
        };
        let mut surfaces = tree["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
            .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
            .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
            .filter_map(|tab| tab["surface"].as_u64())
            .collect::<Vec<_>>();
        surfaces.sort_unstable();
        surfaces.dedup();
        let terminal_pids = surfaces
            .iter()
            .filter_map(|surface| {
                try_json_socket_request(
                    &self.socket,
                    serde_json::json!({
                        "id": u64::MAX - 2,
                        "cmd": "process-info",
                        "surface": surface,
                    }),
                )?["pid"]
                    .as_u64()
            })
            .filter_map(|pid| u32::try_from(pid).ok())
            .collect::<Vec<_>>();

        // A terminal runtime is independent of its placements. Explicitly
        // close every terminal resource, including zero-view terminals that
        // cannot appear in the legacy workspace tree below.
        let mut close_failures = Vec::new();
        if let Ok(output) = Command::new(bin())
            .args(["--json", "--socket"])
            .arg(&self.socket)
            .args(["terminal", "list"])
            .env_remove("CMUX_TUI_SOCKET")
            .output()
            && output.status.success()
            && let Ok(terminals) = serde_json::from_slice::<serde_json::Value>(&output.stdout)
            && let Some(terminals) = terminals.as_array()
        {
            for terminal in terminals {
                let Some(terminal_id) = terminal["id"].as_str() else { continue };
                let output = Command::new(bin())
                    .args(["--quiet", "--socket"])
                    .arg(&self.socket)
                    .args(["terminal", terminal_id, "close"])
                    .env_remove("CMUX_TUI_SOCKET")
                    .output();
                match output {
                    Ok(output) if output.status.success() => {}
                    Ok(output) => close_failures.push(format!(
                        "{terminal_id}: status={:?} stderr={}",
                        output.status.code(),
                        String::from_utf8_lossy(&output.stderr)
                    )),
                    Err(error) => close_failures.push(format!("{terminal_id}: {error}")),
                }
            }
        }

        // Close any remaining browser placements. Terminal placements were
        // already removed by terminal.close, so missing-surface responses are
        // expected and harmless here.
        for (index, surface) in surfaces.into_iter().enumerate() {
            let index = u64::try_from(index).expect("surface count fits a protocol request id");
            let _ = try_json_socket_request(
                &self.socket,
                serde_json::json!({
                    "id": u64::MAX - 3 - index,
                    "cmd": "close-surface",
                    "surface": surface,
                }),
            );
        }

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            let records_remain =
                fs::read_dir(&host_root).ok().into_iter().flatten().filter_map(Result::ok).any(
                    |entry| {
                        entry.path().extension().and_then(|value| value.to_str()) == Some("json")
                    },
                );
            let processes_remain = host_pids.iter().copied().any(process_exists);
            let terminals_remain = terminal_pids
                .iter()
                .copied()
                .any(|pid| process_exists(pid) || process_group_exists(pid));
            if !records_remain && !processes_remain && !terminals_remain {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let record_paths = fs::read_dir(&host_root)
            .ok()
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().and_then(|value| value.to_str()) == Some("json"))
            .collect::<Vec<_>>();
        let live_hosts =
            host_pids.iter().copied().filter(|pid| process_exists(*pid)).collect::<Vec<_>>();
        let live_terminals = terminal_pids
            .iter()
            .copied()
            .filter(|pid| process_exists(*pid) || process_group_exists(*pid))
            .collect::<Vec<_>>();
        Err(format!(
            "close failures: {close_failures:?}; records: {record_paths:?}; live hosts: {live_hosts:?}; live terminals or groups: {live_terminals:?}"
        ))
    }
}

#[cfg(unix)]
fn wait_for_child_exit(child: &mut Child, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if child.try_wait().unwrap().is_some() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
}

#[cfg(unix)]
fn wait_for_processes_to_exit(pids: &[u32], timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if pids.iter().copied().all(|pid| !process_exists(pid) && !process_group_exists(pid)) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
}

#[cfg(unix)]
fn signal_test_process_group(pid: u32, signal: libc::c_int) {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return };
    // SAFETY: the test just captured this isolated PTY process group from its
    // private terminal-host record or process-info response.
    unsafe {
        libc::kill(-pid, signal);
    }
}

impl Drop for HeadlessServer {
    fn drop(&mut self) {
        // Durable terminal hosts intentionally outlive the daemon. Tests must
        // close their terminal resources first rather than assuming SIGKILL
        // of the daemon also owns or reaps their processes.
        let hosts_stopped = self.close_all_resources();
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_file(&self.socket);
        let _ = fs::remove_dir_all(&self.dir);
        if let Err(error) = hosts_stopped
            && !std::thread::panicking()
        {
            panic!("headless CLI fixture left a durable terminal-host process behind: {error}");
        }
    }
}

fn try_json_socket_request(
    path: &std::path::Path,
    request: serde_json::Value,
) -> Option<serde_json::Value> {
    let stream = transport::connect(path).ok()?;
    let mut writer = stream.try_clone_box().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let response: serde_json::Value = serde_json::from_str(&line).ok()?;
    (response["ok"] == true).then(|| response["data"].clone())
}

fn terminal_host_pids(root: &std::path::Path) -> Vec<u32> {
    fs::read_dir(root)
        .ok()
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter_map(|entry| fs::read(entry.path()).ok())
        .filter_map(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .filter_map(|record| record["host_pid"].as_u64())
        .filter_map(|pid| u32::try_from(pid).ok())
        .collect()
}

#[cfg(unix)]
fn process_exists(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    // SAFETY: signal zero performs only an existence/permission check.
    if unsafe { libc::kill(pid, 0) == 0 } {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(unix)]
fn process_group_exists(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    // SAFETY: a negative PID with signal zero checks the process group and
    // cannot deliver a signal.
    if unsafe { libc::kill(-pid, 0) == 0 } {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn process_exists(_pid: u32) -> bool {
    false
}

#[cfg(not(unix))]
fn process_group_exists(_pid: u32) -> bool {
    false
}

fn wait_for_socket_path(path: &std::path::Path) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if transport::connect(path).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("server did not accept connections at {}", path.display());
}

fn lifecycle_cli(args: &[&str]) -> Output {
    Command::new(bin())
        .args(args)
        .env("LC_ALL", "C")
        .env("LC_MESSAGES", "C")
        .env("LANG", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_MUX_SOCKET")
        .output()
        .unwrap()
}

#[cfg(unix)]
fn accept_with_timeout(listener: &UnixListener, timeout: Duration) -> std::io::Result<UnixStream> {
    let deadline = Instant::now() + timeout;
    loop {
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "server did not receive the lifecycle connection",
            ));
        };
        let timeout_ms = i32::try_from(remaining.as_millis().max(1)).unwrap_or(i32::MAX);
        let mut descriptor =
            libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: descriptor contains one valid listener fd and remains alive
        // for the complete poll call.
        let ready = unsafe { libc::poll(&mut descriptor, 1, timeout_ms) };
        if ready > 0 {
            return listener.accept().map(|(stream, _)| stream);
        }
        if ready == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "server did not receive the lifecycle connection",
            ));
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(unix)]
struct ServerEventSubscription {
    writer: Box<dyn transport::Stream>,
    receiver: mpsc::Receiver<Result<serde_json::Value, String>>,
    reader_thread: Option<std::thread::JoinHandle<()>>,
    pending: VecDeque<serde_json::Value>,
}

#[cfg(unix)]
impl ServerEventSubscription {
    fn start(path: &std::path::Path) -> Self {
        let stream = transport::connect(path).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        let (sender, receiver) = mpsc::channel();
        let reader_thread = std::thread::spawn(move || {
            for line in BufReader::new(stream).lines() {
                let value = line.map_err(|error| error.to_string()).and_then(|line| {
                    serde_json::from_str(&line).map_err(|error| error.to_string())
                });
                if sender.send(value).is_err() {
                    break;
                }
            }
        });
        writeln!(writer, r#"{{"id":1,"cmd":"subscribe"}}"#).unwrap();
        writer.flush().unwrap();

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut pending = VecDeque::new();
        loop {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .expect("server did not acknowledge the readiness subscription");
            let message: serde_json::Value = receiver
                .recv_timeout(remaining)
                .expect("server did not acknowledge the readiness subscription")
                .expect("readiness subscription returned invalid JSON");
            if message["id"].as_u64() == Some(1) {
                assert_eq!(message["ok"], true, "readiness subscription failed: {message}");
                break;
            }
            pending.push_back(message);
        }

        Self { writer, receiver, reader_thread: Some(reader_thread), pending }
    }

    fn next_before(&mut self, deadline: Instant) -> serde_json::Value {
        if let Some(message) = self.pending.pop_front() {
            return message;
        }
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .expect("interactive owner did not register its TUI client");
        self.receiver
            .recv_timeout(remaining)
            .expect("interactive owner did not register its TUI client")
            .expect("readiness subscription returned invalid JSON")
    }
}

#[cfg(unix)]
impl Drop for ServerEventSubscription {
    fn drop(&mut self) {
        let _ = self.writer.shutdown(Shutdown::Both);
        if let Some(reader_thread) = self.reader_thread.take() {
            let _ = reader_thread.join();
        }
    }
}

#[cfg(unix)]
fn has_tui_client(socket: &std::path::Path) -> bool {
    let clients =
        lifecycle_cli(&["--json", "--socket", socket.to_str().unwrap(), "client", "list"]);
    clients.status.success()
        && json_output(&clients).as_array().is_some_and(|clients| {
            clients.iter().any(|client| client["client_kind"].as_str() == Some("tui"))
        })
}

#[cfg(unix)]
fn wait_for_owner_server_ready(socket: &std::path::Path, owner: &mut PtyChild) {
    let mut events = ServerEventSubscription::start(socket);
    let mut tui_attached = has_tui_client(socket);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = owner.child.as_mut().unwrap().try_wait().unwrap() {
            panic!("interactive owner exited before shutdown: {status}");
        }
        assert!(
            Instant::now() < deadline,
            "interactive owner did not make its server lifecycle-ready"
        );
        if tui_attached {
            let identity =
                json_socket_request(socket, serde_json::json!({"id":1,"cmd":"identify"}));
            if identity["lifecycle_ready"].as_bool() == Some(true) {
                return;
            }
            continue;
        }
        let event = events.next_before(deadline);
        if matches!(event["event"].as_str(), Some("client-attached" | "client-changed"))
            && event["kind"].as_str() == Some("tui")
        {
            tui_attached = true;
        }
        assert_ne!(event["event"], "overflow", "readiness subscription overflowed");
    }
}

#[cfg(unix)]
struct SocketFileGuard(PathBuf);

#[cfg(unix)]
impl Drop for SocketFileGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[test]
fn server_lifecycle_help_and_typos_do_not_fall_back_to_startup_help() {
    for args in [
        &["server", "--help"][..],
        &["server", "stop", "--help"][..],
        &["server", "status", "--help"][..],
        &["server", "reload-config", "--help"][..],
    ] {
        let output = lifecycle_cli(args);
        assert_success(&output);
        let help = String::from_utf8(output.stdout).unwrap();
        assert!(help.contains("cmux server"), "{help}");
        assert!(!help.contains("cmux [OPTIONS]           Start a session"), "{help}");
    }

    let leaf_typo = lifecycle_cli(&["server", "stpo"]);
    assert_eq!(leaf_typo.status.code(), Some(2));
    let leaf_error = String::from_utf8(leaf_typo.stderr).unwrap();
    assert!(leaf_error.contains("Did you mean `stop`?"), "{leaf_error}");
    assert!(!leaf_error.contains("START OPTIONS"), "{leaf_error}");

    let json_typo = lifecycle_cli(&["--json", "server", "stpo"]);
    assert_eq!(json_typo.status.code(), Some(2));
    let json_error: serde_json::Value = serde_json::from_slice(&json_typo.stderr).unwrap();
    assert_eq!(json_error["code"], "usage.invalid");
    assert!(json_error["message"].as_str().unwrap().contains("Did you mean `stop`?"));

    let output_flag_used_as_a_socket_value =
        lifecycle_cli(&["--socket", "--json", "server", "stpo"]);
    assert_eq!(output_flag_used_as_a_socket_value.status.code(), Some(2));
    let error = String::from_utf8(output_flag_used_as_a_socket_value.stderr).unwrap();
    assert!(error.contains("Did you mean `stop`?"), "{error}");
    assert!(!error.trim_start().starts_with('{'), "{error}");

    let misplaced_start_option = lifecycle_cli(&["--term", "xterm-256color", "server", "start"]);
    assert_eq!(misplaced_start_option.status.code(), Some(2));
    let error = String::from_utf8(misplaced_start_option.stderr).unwrap();
    assert!(error.contains("after `server start`"), "{error}");
    assert!(!error.contains("Did you mean `start`?"), "{error}");

    let scope_typo = lifecycle_cli(&["sever", "stop"]);
    assert_eq!(scope_typo.status.code(), Some(2));
    let scope_error = String::from_utf8(scope_typo.stderr).unwrap();
    assert!(scope_error.contains("Did you mean `server`?"), "{scope_error}");
    assert!(!scope_error.contains("START OPTIONS"), "{scope_error}");
}

#[test]
fn server_lifecycle_start_rejects_inline_relay_ticket_without_echoing_secret() {
    let secret = "inline-server-start-secret-marker";
    for args in [
        &["server", "start", "--relay-ticket", secret][..],
        &["--json", "server", "start", "--relay-ticket", secret][..],
        &["server", "start", "--relay-ticket=inline-server-start-secret-marker"][..],
        &["server", "start", "--relay-ticket", "--help"][..],
        &["server", "start", "--relay-ticket=inline-server-start-secret-marker", "--help"][..],
        &["server", "start", "--help", "--relay-ticket", secret][..],
        &["server", "start", "--session", "--relay-ticket", secret][..],
    ] {
        let output = lifecycle_cli(args);
        assert_eq!(output.status.code(), Some(2));
        let diagnostic = String::from_utf8(output.stderr).unwrap();
        assert!(diagnostic.contains("inline relay tickets are not accepted"), "{diagnostic}");
        assert!(!diagnostic.contains(secret), "{diagnostic}");
    }
}

#[test]
fn public_command_payload_preserves_relay_ticket_argument() {
    let output = lifecycle_cli(&[
        "workspace",
        "current",
        "run",
        "--",
        "tool",
        "--relay-ticket",
        "child-value",
    ]);
    let diagnostic = String::from_utf8(output.stderr).unwrap();

    assert_ne!(output.status.code(), Some(2), "{diagnostic}");
    assert!(!diagnostic.contains("inline relay tickets are not accepted"), "{diagnostic}");
}

#[test]
fn public_resource_value_preserves_relay_ticket_literal() {
    let output = lifecycle_cli(&["workspace", "current", "rename", "--name", "--relay-ticket"]);
    let diagnostic = String::from_utf8(output.stderr).unwrap();

    assert_ne!(output.status.code(), Some(2), "{diagnostic}");
    assert!(!diagnostic.contains("inline relay tickets are not accepted"), "{diagnostic}");
}

#[test]
fn server_lifecycle_start_rejects_output_modes_without_starting_an_owner() {
    let dir = unique_temp_dir("server-start-output-mode");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");

    for mode in ["--json", "--jsonl"] {
        let output =
            lifecycle_cli(&[mode, "server", "start", "--socket", socket.to_str().unwrap()]);
        assert_eq!(output.status.code(), Some(2));
        let diagnostic: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
        assert_eq!(diagnostic["code"], "usage.invalid");
        assert!(
            diagnostic["message"]
                .as_str()
                .unwrap()
                .contains("server start does not support output modes")
        );
        assert!(!socket.exists());
    }

    let quiet =
        lifecycle_cli(&["server", "start", "--quiet", "--socket", socket.to_str().unwrap()]);
    assert_eq!(quiet.status.code(), Some(2));
    assert!(quiet.stdout.is_empty());
    let quiet_error = String::from_utf8(quiet.stderr).unwrap();
    assert!(quiet_error.contains("server start does not support output modes"), "{quiet_error}");
    assert!(!socket.exists());

    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn failed_remote_server_start_removes_its_served_socket() {
    let dir = TestTempDir::create("failed-server-start-cleanup");
    let dir = dir.path();
    let socket = dir.join("mux.sock");
    let invalid_state_root = dir.join("state-root-is-a-file");
    fs::write(&invalid_state_root, "not a directory").unwrap();

    let output = lifecycle_cli(&[
        "server",
        "start",
        "--socket",
        socket.to_str().unwrap(),
        "--remote",
        "--remote-state-dir",
        invalid_state_root.to_str().unwrap(),
    ]);

    assert!(!output.status.success(), "invalid remote state root unexpectedly started a server");
    assert!(!socket.exists(), "failed startup left its served socket behind");
}

#[cfg(unix)]
#[test]
fn refused_second_server_start_preserves_the_live_owner_socket() {
    let server = HeadlessServer::start("second-server-start-live-socket");
    let socket = server.socket.to_str().unwrap();

    let second = lifecycle_cli(&["server", "start", "--ephemeral", "--socket", socket]);

    assert!(!second.status.success(), "a second owner unexpectedly started on the live socket");
    let ping = json_cli(&server, &["session", "current", "ping"]);
    assert_success(&ping);
    assert_eq!(json_output(&ping)["alive"], true);
}

#[test]
fn local_and_authenticated_remote_namespaces_do_not_cross_target() {
    let remote_help = lifecycle_cli(&["remote", "--help"]);
    assert_success(&remote_help);
    let remote_help = String::from_utf8(remote_help.stdout).unwrap();
    assert!(
        remote_help.contains("USAGE: cmux remote connect|ssh|forward|rpc [OPTIONS]"),
        "{remote_help}"
    );
    assert!(remote_help.contains("cmux remote enroll <ACTION> [OPTIONS]"), "{remote_help}");
    assert!(remote_help.contains("cmux remote known-daemons [OPTIONS]"), "{remote_help}");
    assert!(remote_help.contains("cmux remote stop [OPTIONS]"), "{remote_help}");
    assert!(remote_help.contains("cmux remote stop"), "{remote_help}");
    assert!(remote_help.contains("cmux remote connect"), "{remote_help}");

    let nested_connect_help = lifecycle_cli(&["remote", "connect", "--help"]);
    assert_success(&nested_connect_help);
    let nested_connect_help = String::from_utf8(nested_connect_help.stdout).unwrap();
    assert!(nested_connect_help.contains("cmux remote connect [ROUTE]"));
    assert!(!nested_connect_help.contains("cmux-tui connect"));

    let nested_stop_help = lifecycle_cli(&["remote", "stop", "--help"]);
    assert_success(&nested_stop_help);
    let nested_stop_help = String::from_utf8(nested_stop_help.stdout).unwrap();
    assert!(nested_stop_help.contains("cmux remote stop"));
    assert!(!nested_stop_help.contains("cmux-tui remote-stop"));

    let typo_help = lifecycle_cli(&["remote", "frobnicate", "--help"]);
    assert_success(&typo_help);
    let typo_help = String::from_utf8(typo_help.stdout).unwrap();
    assert!(typo_help.contains("cmux remote stop"), "{typo_help}");
    assert!(typo_help.contains("cmux remote connect"), "{typo_help}");

    let unknown_remote_action = lifecycle_cli(&["remote", "frobnicate"]);
    assert_eq!(unknown_remote_action.status.code(), Some(1));
    let error = String::from_utf8(unknown_remote_action.stderr).unwrap();
    assert!(error.contains("unknown remote action \"frobnicate\""), "{error}");

    let local_only_option = lifecycle_cli(&[
        "server",
        "stop",
        "--remote-admin-socket",
        "/tmp/must-not-connect.remote.sock",
    ]);
    assert_eq!(local_only_option.status.code(), Some(2));
    assert!(
        String::from_utf8(local_only_option.stderr)
            .unwrap()
            .contains("unknown flag --remote-admin-socket")
    );

    let remote_only_option =
        lifecycle_cli(&["remote", "stop", "--socket", "/tmp/must-not-connect.local.sock"]);
    assert!(!remote_only_option.status.success());
    let error = String::from_utf8(remote_only_option.stderr).unwrap();
    assert!(error.contains("unknown") && error.contains("--socket"), "{error}");
    assert!(!error.contains("not running"), "{error}");
}

#[test]
fn local_server_lifecycle_rejects_machine_before_socket_access() {
    for args in [
        &[
            "--machine",
            "other",
            "server",
            "status",
            "--socket",
            "/tmp/cmux-machine-must-not-connect.sock",
        ][..],
        &[
            "--machine",
            "other",
            "server",
            "stop",
            "--socket",
            "/tmp/cmux-machine-must-not-connect.sock",
        ][..],
        &[
            "--machine",
            "other",
            "server",
            "reload-config",
            "--socket",
            "/tmp/cmux-machine-must-not-connect.sock",
        ][..],
        &[
            "--machine",
            "other",
            "session",
            "named",
            "stop",
            "--socket",
            "/tmp/cmux-machine-must-not-connect.sock",
        ][..],
    ] {
        let output = lifecycle_cli(args);
        assert_eq!(output.status.code(), Some(2));
        let error = String::from_utf8(output.stderr).unwrap();
        assert!(error.contains("--machine cannot target a local server"), "{error}");
    }
}

#[test]
fn local_server_lifecycle_rejects_invalid_derived_socket_sessions() {
    for action in ["status", "stop", "reload-config"] {
        let output = lifecycle_cli(&["--json", "--session", "../outside", "server", action]);

        assert_eq!(output.status.code(), Some(2), "action={action}");
        assert!(output.stdout.is_empty(), "action={action}");
        let error: serde_json::Value =
            serde_json::from_slice(&output.stderr).unwrap_or_else(|error| {
                panic!(
                    "action={action}: expected JSON error, got {error}: {}",
                    String::from_utf8_lossy(&output.stderr)
                )
            });
        assert_eq!(error["code"], "usage.invalid", "action={action}");
        assert!(
            error["message"].as_str().is_some_and(|message| message.contains("invalid")),
            "action={action}: {error}"
        );
    }
}

#[cfg(unix)]
#[test]
fn explicit_session_overrides_an_inherited_socket_route() {
    let unique = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let session = format!("explicit-route-{unique}");
    let socket = cmux_tui_core::server::default_socket_path(&session);
    fs::create_dir_all(socket.parent().unwrap()).unwrap();
    let _ = fs::remove_file(&socket);
    let _socket_guard = SocketFileGuard(socket.clone());
    let listener = UnixListener::bind(&socket).unwrap();
    let expected_session = session.clone();
    let thread = std::thread::spawn(move || {
        let stream = accept_with_timeout(&listener, Duration::from_secs(5))
            .unwrap_or_else(|error| panic!("explicit session route was not used: {error}"));
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        let request: serde_json::Value = serde_json::from_str(&request).unwrap();
        assert_eq!(request["cmd"], "identify");
        writeln!(
            writer,
            "{}",
            serde_json::json!({
                "id":request["id"],
                "ok":true,
                "data":{
                    "app":"cmux-tui",
                    "session":expected_session,
                    "pid":4242,
                    "generation":"generation-a",
                    "capabilities":[]
                }
            })
        )
        .unwrap();
    });
    let inherited = unique_temp_dir("inherited-wrong-route").join("wrong.sock");
    let output = Command::new(bin())
        .args(["--json", "--session", &session, "server", "status"])
        .env("CMUX_TUI_SOCKET", &inherited)
        .env_remove("CMUX_MUX_SOCKET")
        .output()
        .unwrap();
    thread.join().unwrap();
    assert_success(&output);
    assert_eq!(json_output(&output)["session"], session);
}

#[test]
fn removed_daemon_entrypoint_fails_before_process_work_with_precise_migration() {
    let root = unique_temp_dir("removed-daemon-entrypoint");
    let socket = root.join("must-not-create.sock");
    let state = root.join("must-not-create-state");
    let output = lifecycle_cli(&[
        "daemon",
        "--socket",
        socket.to_str().unwrap(),
        "--state",
        state.to_str().unwrap(),
    ]);
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let error = String::from_utf8(output.stderr).unwrap();
    assert!(error.contains("`cmux daemon` was renamed to `cmux server start`"), "{error}");
    assert!(error.contains("cmux server start --help"), "{error}");
    assert!(!error.contains("START OPTIONS"), "{error}");
    assert!(!socket.exists());
    assert!(!state.exists());
}

#[test]
fn uvx_spelling_server_stop_is_absent_idempotent_with_stable_output_modes() {
    let dir = unique_temp_dir("server-stop-absent");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("absent.sock");

    let status = lifecycle_cli(&[
        "--json",
        "server",
        "status",
        "--session",
        "absent",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    assert_eq!(status.status.code(), Some(3));
    let error: serde_json::Value = serde_json::from_slice(&status.stderr).unwrap();
    assert_eq!(error["code"], "server.unavailable");
    assert!(!error["message"].as_str().unwrap().contains(socket.to_str().unwrap()));

    // This is the binary-level spelling reached by `uvx cmux server stop`.
    let human = lifecycle_cli(&[
        "server",
        "stop",
        "--session",
        "absent",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    assert_success(&human);
    assert!(
        String::from_utf8(human.stdout).unwrap().contains("not running"),
        "human absent stop should explain the idempotent outcome"
    );

    let json = lifecycle_cli(&[
        "--json",
        "server",
        "stop",
        "--session",
        "absent",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    assert_success(&json);
    assert_eq!(json_output(&json)["status"], "not_running");
    assert_eq!(json_output(&json)["session"], "absent");

    let socket_only =
        lifecycle_cli(&["--json", "server", "stop", "--socket", socket.to_str().unwrap()]);
    assert_success(&socket_only);
    assert_eq!(json_output(&socket_only)["status"], "not_running");
    assert_eq!(json_output(&socket_only)["session"], serde_json::Value::Null);

    let quiet = lifecycle_cli(&[
        "--quiet",
        "server",
        "stop",
        "--session",
        "absent",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    assert_success(&quiet);
    assert!(quiet.stdout.is_empty());
    assert!(quiet.stderr.is_empty());
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn absent_server_stop_serializes_a_non_utf8_inherited_socket_path() {
    let dir = TestTempDir::create("server-stop-non-utf8-socket");
    let dir = dir.path();
    let socket = dir.join(std::ffi::OsString::from_vec(b"mux-\xff.sock".to_vec()));
    let output = Command::new(bin())
        .args(["--json", "server", "stop"])
        .env("CMUX_TUI_SOCKET", &socket)
        .env_remove("CMUX_MUX_SOCKET")
        .output()
        .unwrap();

    assert_success(&output);
    let result = json_output(&output);
    assert_eq!(result["status"], "not_running");
    assert_eq!(result["socket"], socket.to_string_lossy().as_ref());
}

#[cfg(unix)]
#[test]
fn lifecycle_errors_do_not_expose_raw_server_failures() {
    let dir = unique_temp_dir("server-lifecycle-error-privacy");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("owned.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let thread = std::thread::spawn(move || {
        let stream = accept_with_timeout(&listener, Duration::from_secs(5)).unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        let identify: serde_json::Value = serde_json::from_str(&request).unwrap();
        writeln!(
            writer,
            "{}",
            serde_json::json!({
                "id": identify["id"],
                "ok": true,
                "data": {
                    "app": "cmux-tui",
                    "session": "private",
                    "pid": 4242,
                    "generation": "generation-a",
                    "capabilities": []
                }
            })
        )
        .unwrap();
        request.clear();
        reader.read_line(&mut request).unwrap();
        let reload: serde_json::Value = serde_json::from_str(&request).unwrap();
        assert_eq!(reload["cmd"], "reload-config");
        writeln!(
            writer,
            "{}",
            serde_json::json!({
                "id": reload["id"],
                "ok": false,
                "error": "secret token and /private/internal/config/path"
            })
        )
        .unwrap();
    });

    let output = lifecycle_cli(&[
        "server",
        "reload-config",
        "--session",
        "private",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    thread.join().unwrap();
    assert_eq!(output.status.code(), Some(1));
    let error = String::from_utf8(output.stderr).unwrap();
    assert!(error.contains("rejected the configuration reload"), "{error}");
    assert!(!error.contains("secret token"), "{error}");
    assert!(!error.contains("/private/internal"), "{error}");
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn server_reload_rejects_false_acknowledgement() {
    let dir = unique_temp_dir("server-reload-false-ack");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("owned.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let thread = std::thread::spawn(move || {
        let stream = accept_with_timeout(&listener, Duration::from_secs(5)).unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        let identify: serde_json::Value = serde_json::from_str(&request).unwrap();
        writeln!(
            writer,
            "{}",
            serde_json::json!({
                "id": identify["id"],
                "ok": true,
                "data": {
                    "app": "cmux-tui",
                    "session": "false-ack",
                    "pid": 4242,
                    "generation": "generation-a",
                    "capabilities": [],
                    "lifecycle_ready": true
                }
            })
        )
        .unwrap();
        request.clear();
        reader.read_line(&mut request).unwrap();
        let reload: serde_json::Value = serde_json::from_str(&request).unwrap();
        assert_eq!(reload["cmd"], "reload-config");
        writeln!(
            writer,
            "{}",
            serde_json::json!({
                "id": reload["id"],
                "ok": true,
                "data": {"reloaded": false}
            })
        )
        .unwrap();
    });

    let output = lifecycle_cli(&[
        "--json",
        "server",
        "reload-config",
        "--session",
        "false-ack",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    thread.join().unwrap();
    assert_eq!(output.status.code(), Some(3));
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["code"], "server.invalid_response");
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn server_status_rejects_a_malformed_lifecycle_readiness_value() {
    let dir = unique_temp_dir("server-status-malformed-readiness");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("owned.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let thread = std::thread::spawn(move || {
        let stream = accept_with_timeout(&listener, Duration::from_secs(5)).unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        let identify: serde_json::Value = serde_json::from_str(&request).unwrap();
        assert_eq!(identify["cmd"], "identify");
        writeln!(
            writer,
            "{}",
            serde_json::json!({
                "id": identify["id"],
                "ok": true,
                "data": {
                    "app": "cmux-tui",
                    "session": "malformed-readiness",
                    "pid": 4242,
                    "generation": "generation-a",
                    "capabilities": [],
                    "lifecycle_ready": "false"
                }
            })
        )
        .unwrap();
    });

    let output = lifecycle_cli(&[
        "--json",
        "server",
        "status",
        "--session",
        "malformed-readiness",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    thread.join().unwrap();
    assert_eq!(output.status.code(), Some(3));
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["code"], "server.invalid_identity");
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn server_stop_uses_identify_fence_and_refuses_cross_session_targeting() {
    fn fake_server(listener: UnixListener, identified_session: &'static str, expect_stop: bool) {
        let stream = accept_with_timeout(&listener, Duration::from_secs(5)).unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        let identify_request: serde_json::Value = serde_json::from_str(&request).unwrap();
        assert_eq!(identify_request["cmd"], "identify");
        writeln!(
            writer,
            "{}",
            serde_json::json!({
                "id": identify_request["id"],
                "ok": true,
                "data": {
                    "app": "cmux-tui",
                    "session": identified_session,
                    "pid": 4242,
                    "generation": "generation-a",
                    "capabilities": ["daemon-handoff-force-v1"]
                }
            })
        )
        .unwrap();
        if !expect_stop {
            return;
        }
        request.clear();
        reader.read_line(&mut request).unwrap();
        let request: serde_json::Value = serde_json::from_str(&request).unwrap();
        assert_eq!(request["cmd"], "shutdown-daemon");
        assert_eq!(request["pid"], 4242);
        assert_eq!(request["generation"], "generation-a");
        assert_eq!(request["force"], true);
        writeln!(
            writer,
            "{}",
            serde_json::json!({"id":request["id"],"ok":true,"data":{"accepted":true}})
        )
        .unwrap();
    }

    let dir = unique_temp_dir("server-stop-fence");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("owned.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let thread = std::thread::spawn(move || fake_server(listener, "owned", true));
    let forced = lifecycle_cli(&[
        "--json",
        "server",
        "stop",
        "--force",
        "--session",
        "owned",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    thread.join().unwrap();
    assert_success(&forced);
    assert_eq!(json_output(&forced)["status"], "stopped");

    fs::remove_file(&socket).unwrap();
    let listener = UnixListener::bind(&socket).unwrap();
    let thread = std::thread::spawn(move || fake_server(listener, "remote-or-other", false));
    let crossed = lifecycle_cli(&[
        "server",
        "stop",
        "--session",
        "local",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    thread.join().unwrap();
    assert!(!crossed.status.success());
    let error = String::from_utf8(crossed.stderr).unwrap();
    assert!(error.contains("different session"), "{error}");
    assert!(!error.contains("remote-or-other"), "{error}");

    fs::remove_file(&socket).unwrap();
    let listener = UnixListener::bind(&socket).unwrap();
    let thread = std::thread::spawn(move || fake_server(listener, "private-session", false));
    let crossed = lifecycle_cli(&[
        "--json",
        "server",
        "stop",
        "--session",
        "local",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    thread.join().unwrap();
    assert!(!crossed.status.success());
    let error = String::from_utf8(crossed.stderr).unwrap();
    let error_json: serde_json::Value = serde_json::from_str(&error).unwrap();
    assert_eq!(error_json["code"], "server.different_session");
    assert!(!error.contains("private-session"), "{error}");
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn named_server_status_stop_alias_and_durable_restart_preserve_topology() {
    let dir = unique_temp_dir("server-lifecycle-durable");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let state = dir.join("state");
    let spawn = || {
        Command::new(bin())
            .args(["--session", "durable", "server", "start", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    };

    let mut first = spawn();
    wait_for_socket_path(&socket);
    let create = lifecycle_cli(&[
        "--json",
        "--socket",
        socket.to_str().unwrap(),
        "workspace",
        "create",
        "--name",
        "survivor",
        "--empty",
    ]);
    assert_success(&create);

    let status = lifecycle_cli(&[
        "--json",
        "server",
        "status",
        "--session",
        "durable",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    assert_success(&status);
    assert_eq!(json_output(&status)["status"], "running");
    assert_eq!(json_output(&status)["session"], "durable");

    let stop_alias = lifecycle_cli(&[
        "--quiet",
        "--session",
        "durable",
        "session",
        "current",
        "stop",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    assert_success(&stop_alias);
    assert!(wait_for_child_exit(&mut first, Duration::from_secs(10)));

    let mut restarted = spawn();
    wait_for_socket_path(&socket);
    let workspaces =
        lifecycle_cli(&["--json", "--socket", socket.to_str().unwrap(), "workspace", "list"]);
    assert_success(&workspaces);
    assert!(
        json_output(&workspaces)
            .as_array()
            .unwrap()
            .iter()
            .any(|item| { item["name"] == "survivor" })
    );

    let reload = lifecycle_cli(&[
        "--json",
        "server",
        "reload-config",
        "--session",
        "durable",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    assert_success(&reload);
    assert_eq!(json_output(&reload)["reloaded"], true);

    let invalid = lifecycle_cli(&[
        "server",
        "status",
        "--force",
        "--socket",
        dir.join("must-not-connect.sock").to_str().unwrap(),
    ]);
    assert_eq!(invalid.status.code(), Some(2));
    assert!(String::from_utf8(invalid.stderr).unwrap().contains("unknown flag --force"));

    restarted.kill().unwrap();
    restarted.wait().unwrap();
    fs::remove_dir_all(dir).unwrap();
}

fn json_socket_request(path: &std::path::Path, request: serde_json::Value) -> serde_json::Value {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "request failed: {response}");
    response["data"].clone()
}

#[test]
fn explicit_socket_keeps_state_in_platform_root() {
    let dir = unique_temp_dir("explicit-socket-durable-state");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let state = dir.join("platform-state");
    let child = Command::new(bin())
        .args(["--headless", "--socket"])
        .arg(&socket)
        .env("CMUX_TUI_STATE_DIR", &state)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let server = HeadlessServer { child, socket, state, dir };
    server.wait_for_socket();

    let registry_exists = || {
        fs::read_dir(&server.state)
            .ok()
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .any(|entry| entry.path().join("workspace-registry.sqlite3").is_file())
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    while !registry_exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(registry_exists(), "explicit transport socket did not use platform state root");
    assert!(
        !server.socket.with_extension("state").exists(),
        "explicit transport socket unexpectedly relocated durable state"
    );
}

#[test]
fn newer_workspace_schema_failure_reports_socket_specific_recovery() {
    let dir = unique_temp_dir("newer-workspace-schema-recovery");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("future session.sock");
    let state = dir.join("state");
    let home = dir.join("home");
    fs::create_dir_all(&home).unwrap();
    let session = "--old-schema-{found}";

    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    let database = fs::read_dir(&state)
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.path().join("workspace-registry.sqlite3"))
        .find(|path| path.is_file())
        .expect("workspace registry database");
    let connection = rusqlite::Connection::open(&database).unwrap();
    let supported: i64 = connection
        .query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| {
            row.get::<_, String>(0)
        })
        .unwrap()
        .parse()
        .unwrap();
    let newer = supported + 1;
    let registry_id: String = connection
        .query_row("SELECT value FROM meta WHERE key = 'registry_id'", [], |row| row.get(0))
        .unwrap();
    connection
        .execute("UPDATE meta SET value = ?1 WHERE key = 'schema_version'", [newer.to_string()])
        .unwrap();
    drop(connection);

    fn output_with_deadline(command: &mut Command) -> Output {
        command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = command.spawn().unwrap();
        let mut stdout = child.stdout.take().unwrap();
        let stdout = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            stdout.read_to_end(&mut bytes).unwrap();
            bytes
        });
        let mut stderr = child.stderr.take().unwrap();
        let stderr = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            stderr.read_to_end(&mut bytes).unwrap();
            bytes
        });
        let deadline = Instant::now() + Duration::from_secs(15);
        let (status, timed_out) = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break (status, false);
            }
            if Instant::now() >= deadline {
                child.kill().unwrap();
                break (child.wait().unwrap(), true);
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        let output =
            Output { status, stdout: stdout.join().unwrap(), stderr: stderr.join().unwrap() };
        if timed_out {
            panic!(
                "schema recovery command did not exit before deadline:\n{}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
        output
    }

    #[cfg(unix)]
    fn accept_with_deadline(listener: &UnixListener) -> UnixStream {
        listener.set_nonblocking(true).unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            match listener.accept() {
                Ok((stream, _)) => return stream,
                Err(error)
                    if error.kind() == std::io::ErrorKind::WouldBlock
                        && Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("schema recovery listener did not accept: {error}"),
            }
        }
    }

    let launch = |locale: &str| {
        let mut command = Command::new(bin());
        command
            .args(["--headless", "--session", session, "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("HOME", &home)
            .env("CFFIXED_USER_HOME", &home)
            .env("XDG_CONFIG_HOME", home.join(".config"))
            .env("CMUX_TUI_CONFIG", home.join("cmux.json"))
            .env("LC_ALL", locale)
            .env("LC_MESSAGES", locale)
            .env("LANG", locale);
        output_with_deadline(&mut command)
    };

    let english = launch("C");
    assert!(!english.status.success());
    let english = String::from_utf8(english.stderr).unwrap();
    assert!(english.contains(&format!("session \"{session}\"")), "{english}");
    assert!(!english.contains("workspace schema"), "{english}");
    assert!(!english.contains("supports through"), "{english}");
    assert!(english.contains(&format!("session socket: {}", socket.display())), "{english}");
    assert!(!english.contains("state database:"), "{english}");
    assert!(!english.contains(&database.display().to_string()), "{english}");
    assert!(english.contains("no server is listening on this socket"), "{english}");
    assert!(!english.contains("nothing needs to be stopped"), "{english}");
    #[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
    {
        assert!(
            english.contains(&format!(
                "cmux session 'name:{session}' reset-state --state '{}'",
                state.display()
            )),
            "{english}"
        );
        assert!(
            !english.contains(&format!(
                "cmux session 'name:{session}' reset-state --state '{}' --force",
                state.display()
            )),
            "{english}"
        );
    }
    #[cfg(not(any(
        target_os = "ios",
        target_os = "macos",
        target_os = "linux",
        target_os = "android"
    )))]
    {
        assert!(!english.contains(" reset-state"), "{english}");
        assert!(
            english.contains(
                "scoped saved-state reset is not supported on this platform; no reset command is shown"
            ),
            "{english}"
        );
    }
    assert!(!english.contains("session current shutdown --force"), "{english}");
    assert!(english.contains("saved state still requires a newer cmux"), "{english}");
    assert!(english.contains(&format!("--session '{session}-separate'")), "{english}");

    #[cfg(unix)]
    {
        let listener = UnixListener::bind(&socket).unwrap();
        let expected_session = session.to_string();
        let expected_registry_id = registry_id.clone();
        let responder = std::thread::spawn(move || {
            let mut stream = accept_with_deadline(&listener);
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut request).unwrap();
            let request: serde_json::Value = serde_json::from_str(&request).unwrap();
            assert_eq!(request["cmd"], "identify");
            writeln!(
                stream,
                "{}",
                serde_json::json!({
                    "id": request["id"],
                    "ok": true,
                    "data": {
                        "app": "cmux-tui",
                        "session": expected_session,
                        "registry_id": expected_registry_id,
                        "pid": 4242,
                        "generation": "schema-generation",
                        "capabilities": ["daemon-handoff-force-v1"],
                    },
                })
            )
            .unwrap();
        });
        let live_server = launch("C");
        responder.join().unwrap();
        assert!(!live_server.status.success());
        let live_server = String::from_utf8(live_server.stderr).unwrap();
        assert!(
            live_server.contains(&format!(
                "cmux --socket '{}' raw command --request-json '{{\"cmd\":\"shutdown-daemon\",\"force\":true,\"generation\":\"schema-generation\",\"id\":1,\"pid\":4242}}'",
                socket.display()
            )),
            "{live_server}"
        );
        assert!(
            !live_server
                .contains("no server is listening on this socket; nothing needs to be stopped"),
            "{live_server}"
        );

        fs::remove_file(&socket).unwrap();
        let listener = UnixListener::bind(&socket).unwrap();
        let expected_session = session.to_string();
        let expected_registry_id = registry_id;
        let responder = std::thread::spawn(move || {
            let mut stream = accept_with_deadline(&listener);
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut request).unwrap();
            let request: serde_json::Value = serde_json::from_str(&request).unwrap();
            writeln!(
                stream,
                "{}",
                serde_json::json!({
                    "id": request["id"],
                    "ok": true,
                    "data": {
                        "app": "cmux-tui",
                        "session": expected_session,
                        "registry_id": expected_registry_id,
                        "pid": 4242,
                        "generation": "schema-generation",
                        "capabilities": [],
                    },
                })
            )
            .unwrap();
        });
        let legacy_server = launch("C");
        responder.join().unwrap();
        assert!(!legacy_server.status.success());
        let legacy_server = String::from_utf8(legacy_server.stderr).unwrap();
        assert!(
            legacy_server.contains("this server cannot accept a safe forced shutdown command"),
            "{legacy_server}"
        );
        assert!(!legacy_server.contains("shutdown-daemon"), "{legacy_server}");

        fs::remove_file(&socket).unwrap();
        let listener = UnixListener::bind(&socket).unwrap();
        let expected_session = session.to_string();
        let responder = std::thread::spawn(move || {
            let mut stream = accept_with_deadline(&listener);
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut request).unwrap();
            let request: serde_json::Value = serde_json::from_str(&request).unwrap();
            writeln!(
                stream,
                "{}",
                serde_json::json!({
                    "id": request["id"],
                    "ok": true,
                    "data": {
                        "app": "cmux-tui",
                        "session": expected_session,
                        "registry_id": "another-registry",
                    },
                })
            )
            .unwrap();
        });
        let other_server = launch("C");
        responder.join().unwrap();
        assert!(!other_server.status.success());
        let other_server = String::from_utf8(other_server.stderr).unwrap();
        assert!(
            other_server.contains(
                "this socket belongs to a different cmux session; no shutdown command is shown"
            ),
            "{other_server}"
        );
        assert!(!other_server.contains("session current shutdown --force"), "{other_server}");

        fs::remove_file(&socket).unwrap();
    }

    let japanese = launch("ja_JP.UTF-8");
    assert!(!japanese.status.success());
    let japanese = String::from_utf8(japanese.stderr).unwrap();
    assert!(japanese.contains("セッションソケット:"), "{japanese}");
    assert!(!japanese.contains("状態データベース:"), "{japanese}");
    assert!(!japanese.contains(&database.display().to_string()), "{japanese}");
    assert!(japanese.contains("このソケットを待ち受けているサーバーはありません"), "{japanese}");
    assert!(!japanese.contains("停止は不要"), "{japanese}");
    #[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
    {
        assert!(
            japanese.contains(&format!(
                "cmux session 'name:{session}' reset-state --state '{}'",
                state.display()
            )),
            "{japanese}"
        );
        assert!(
            !japanese.contains(&format!(
                "cmux session 'name:{session}' reset-state --state '{}' --force",
                state.display()
            )),
            "{japanese}"
        );
    }
    #[cfg(not(any(
        target_os = "ios",
        target_os = "macos",
        target_os = "linux",
        target_os = "android"
    )))]
    {
        assert!(!japanese.contains(" reset-state"), "{japanese}");
        assert!(
            japanese.contains("このプラットフォームではスコープ付き保存状態リセットに対応していないため、リセットコマンドは表示しません"),
            "{japanese}"
        );
    }
    assert!(!japanese.contains("session current shutdown --force"), "{japanese}");
    assert!(japanese.contains("保存状態には新しい cmux が必要です"), "{japanese}");

    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn session_reset_state_rejects_global_routing_options() {
    let dir = unique_temp_dir("session-reset-routing-options");
    let state = dir.join("state");
    for (option, value) in
        [("--socket", "ignored.sock"), ("--session", "ignored"), ("--machine", "ignored")]
    {
        let output = Command::new(bin())
            .args(["--json", option, value, "session", "target", "reset-state", "--state"])
            .arg(&state)
            .env_remove("CMUX_TUI_SOCKET")
            .output()
            .unwrap();
        assert!(!output.status.success(), "{option} unexpectedly reached reset execution");
        let error = json_error(&output);
        assert_eq!(error["code"], "session.reset_state.routing_options_unsupported");
        assert_eq!(error["details"]["options"], serde_json::json!([option]));
        assert!(error["message"].as_str().unwrap().contains(option));
        assert!(!state.exists(), "{option} created the ignored state root");
    }
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn session_reset_state_removes_only_the_named_saved_state() {
    let dir = unique_temp_dir("session-reset-state");
    fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    let stale_session = "schema-reset-target";
    let kept_session = "schema-reset-kept";

    drop(cmux_tui_core::WorkspaceRegistry::open(&state, stale_session).unwrap());
    drop(cmux_tui_core::WorkspaceRegistry::open(&state, kept_session).unwrap());
    let session_database = |session: &str| {
        fs::read_dir(&state)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
            .map(|entry| entry.path().join("workspace-registry.sqlite3"))
            .filter(|path| path.is_file())
            .find(|path| {
                let connection = rusqlite::Connection::open(path).unwrap();
                let session_id: String = connection
                    .query_row("SELECT value FROM meta WHERE key = 'session_name'", [], |row| {
                        row.get(0)
                    })
                    .unwrap();
                session_id == session
            })
            .expect("session database")
    };
    let stale_database = session_database(stale_session);
    let kept_database = session_database(kept_session);
    let stale_host_root =
        cmux_tui_core::terminal_host_runtime::terminal_host_root(&state, stale_session);
    let kept_host_root =
        cmux_tui_core::terminal_host_runtime::terminal_host_root(&state, kept_session);
    fs::create_dir_all(&stale_host_root).unwrap();
    fs::create_dir_all(&kept_host_root).unwrap();
    fs::write(stale_host_root.join("orphaned-sidecar"), b"stale").unwrap();
    fs::write(kept_host_root.join("orphaned-sidecar"), b"kept").unwrap();
    let connection = rusqlite::Connection::open(&stale_database).unwrap();
    connection.execute("UPDATE meta SET value = '999' WHERE key = 'schema_version'", []).unwrap();
    drop(connection);

    let preview = Command::new(bin())
        .args(["--json", "session", stale_session, "reset-state", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&preview);
    let preview: serde_json::Value = serde_json::from_slice(&preview.stdout).unwrap();
    assert_eq!(preview["session"], stale_session);
    assert_eq!(preview["requires_force"], true);
    assert_eq!(preview["state_root"], state.display().to_string());
    assert_eq!(preview["session_dir"], stale_database.parent().unwrap().display().to_string());
    assert_eq!(preview["terminal_host_root"], stale_host_root.display().to_string());
    let confirm_reset = preview["confirm_reset"].as_str().unwrap().to_string();
    assert!(stale_database.exists(), "preview removed stale database");
    assert!(stale_host_root.exists(), "preview removed stale terminal-host state");

    let rejected = Command::new(bin())
        .args(["session", stale_session, "reset-state", "--force", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(!rejected.status.success(), "force without preview token unexpectedly succeeded");
    assert!(stale_database.exists(), "rejected force removed stale database");
    assert!(stale_host_root.exists(), "rejected force removed stale terminal-host state");

    let reset = Command::new(bin())
        .args([
            "session",
            stale_session,
            "reset-state",
            "--force",
            "--confirm-reset",
            &confirm_reset,
            "--state",
        ])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&reset);
    assert!(!stale_database.exists(), "reset left stale database at {}", stale_database.display());
    assert!(!stale_host_root.exists(), "reset left stale terminal-host state");
    assert!(kept_database.exists(), "reset removed another session's database");
    assert!(kept_host_root.exists(), "reset removed another session's terminal-host state");
    drop(cmux_tui_core::WorkspaceRegistry::open(&state, stale_session).unwrap());

    fs::remove_dir_all(dir).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn session_reset_state_refuses_live_terminal_host_state() {
    let dir = unique_temp_dir("session-reset-live-host");
    fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    let session = "schema-reset-live-host";

    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    let database = find_session_database(&state, session);
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&state, session);
    let _live_host = create_live_terminal_host_record(&host_root);
    let preview = Command::new(bin())
        .args(["--json", "session", session, "reset-state", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&preview);
    let preview: serde_json::Value = serde_json::from_slice(&preview.stdout).unwrap();
    let confirm_reset = preview["confirm_reset"].as_str().unwrap();

    let reset = Command::new(bin())
        .args([
            "session",
            session,
            "reset-state",
            "--force",
            "--confirm-reset",
            confirm_reset,
            "--state",
        ])
        .arg(&state)
        .env("LC_ALL", "C")
        .env("LC_MESSAGES", "C")
        .env("LANG", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(!reset.status.success(), "reset unexpectedly succeeded");
    let stderr = String::from_utf8(reset.stderr).unwrap();
    assert!(stderr.contains("could not complete saved-state reset for session"), "{stderr}");
    assert!(stderr.contains("stop it cleanly before retrying the reset"), "{stderr}");
    assert!(!stderr.contains(&state.display().to_string()), "{stderr}");
    assert!(database.exists(), "reset removed the registry while a live host was present");
    assert!(host_root.exists(), "reset removed live terminal-host state");

    fs::remove_dir_all(dir).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn session_reset_state_refuses_orphan_terminal_host_live_marker() {
    let dir = unique_temp_dir("session-reset-orphan-host-marker");
    fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    let session = "schema-reset-orphan-host";

    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    let database = find_session_database(&state, session);
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&state, session);
    fs::create_dir_all(&host_root).unwrap();
    fs::set_permissions(&host_root, fs::Permissions::from_mode(0o700)).unwrap();
    let live_marker = host_root.join("orphan.live");
    let live_file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&live_marker)
        .unwrap();
    assert_eq!(unsafe { libc::flock(live_file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    let preview = Command::new(bin())
        .args(["--json", "session", session, "reset-state", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&preview);
    let preview: serde_json::Value = serde_json::from_slice(&preview.stdout).unwrap();
    let confirm_reset = preview["confirm_reset"].as_str().unwrap();

    let reset = Command::new(bin())
        .args([
            "session",
            session,
            "reset-state",
            "--force",
            "--confirm-reset",
            confirm_reset,
            "--state",
        ])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(!reset.status.success(), "reset unexpectedly succeeded");
    assert!(database.exists(), "reset removed the registry while a live marker was present");
    assert!(live_marker.exists(), "reset removed the orphan live marker");

    fs::remove_dir_all(dir).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn session_reset_state_removes_dead_orphan_terminal_host_live_marker() {
    let dir = unique_temp_dir("session-reset-dead-orphan-host-marker");
    fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    let session = "schema-reset-dead-orphan-host";

    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    let database = find_session_database(&state, session);
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&state, session);
    fs::create_dir_all(&host_root).unwrap();
    fs::set_permissions(&host_root, fs::Permissions::from_mode(0o700)).unwrap();
    let live_marker = host_root.join("orphan.live");
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&live_marker)
        .unwrap();
    let preview = Command::new(bin())
        .args(["--json", "session", session, "reset-state", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&preview);
    let preview: serde_json::Value = serde_json::from_slice(&preview.stdout).unwrap();
    let confirm_reset = preview["confirm_reset"].as_str().unwrap();

    let reset = Command::new(bin())
        .args([
            "session",
            session,
            "reset-state",
            "--force",
            "--confirm-reset",
            confirm_reset,
            "--state",
        ])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&reset);
    assert!(!database.exists(), "reset left the registry after removing a dead live marker");
    assert!(!host_root.exists(), "reset left terminal-host state after removing a dead marker");

    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn session_reset_state_rejects_stale_preview_when_targets_change() {
    let dir = unique_temp_dir("session-reset-stale-preview");
    fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    let session = "schema-reset-stale-preview";

    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    let database = find_session_database(&state, session);
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&state, session);
    assert!(!host_root.exists());

    let preview = Command::new(bin())
        .args(["--json", "session", session, "reset-state", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&preview);
    let preview: serde_json::Value = serde_json::from_slice(&preview.stdout).unwrap();
    let stale_confirm_reset = preview["confirm_reset"].as_str().unwrap();

    fs::create_dir_all(&host_root).unwrap();
    fs::set_permissions(&host_root, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(host_root.join("sentinel"), b"new-host-state").unwrap();

    let reset = Command::new(bin())
        .args([
            "session",
            session,
            "reset-state",
            "--force",
            "--confirm-reset",
            stale_confirm_reset,
            "--state",
        ])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(!reset.status.success(), "reset accepted a stale preview token");
    assert!(database.exists(), "reset removed the registry with a stale token");
    assert!(host_root.join("sentinel").exists(), "reset removed newly appeared host state");

    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn session_reset_state_rejects_preview_for_recreated_registry() {
    let dir = unique_temp_dir("session-reset-recreated-registry");
    fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    let session = "schema-reset-recreated-registry";

    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    let original_database = find_session_database(&state, session);
    let session_dir = original_database.parent().unwrap().to_path_buf();

    let preview = Command::new(bin())
        .args(["--json", "session", session, "reset-state", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&preview);
    let preview: serde_json::Value = serde_json::from_slice(&preview.stdout).unwrap();
    let stale_confirm_reset = preview["confirm_reset"].as_str().unwrap();

    fs::remove_dir_all(&session_dir).unwrap();
    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    let recreated_database = find_session_database(&state, session);

    let reset = Command::new(bin())
        .args([
            "session",
            session,
            "reset-state",
            "--force",
            "--confirm-reset",
            stale_confirm_reset,
            "--state",
        ])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(!reset.status.success(), "reset accepted a token from a replaced registry");
    assert!(recreated_database.exists(), "reset removed the recreated registry");

    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn session_reset_state_rejects_preview_when_session_sidecar_appears() {
    let dir = unique_temp_dir("session-reset-new-sidecar");
    fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    let session = "schema-reset-new-sidecar";

    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    let database = find_session_database(&state, session);
    let session_dir = database.parent().unwrap();

    let preview = Command::new(bin())
        .args(["--json", "session", session, "reset-state", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&preview);
    let preview: serde_json::Value = serde_json::from_slice(&preview.stdout).unwrap();
    let stale_confirm_reset = preview["confirm_reset"].as_str().unwrap();

    let sidecar = session_dir.join("workspace-registry.sqlite3-wal");
    fs::write(&sidecar, b"new-sidecar-state").unwrap();

    let reset = Command::new(bin())
        .args([
            "session",
            session,
            "reset-state",
            "--force",
            "--confirm-reset",
            stale_confirm_reset,
            "--state",
        ])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(!reset.status.success(), "reset accepted a token before a new sidecar existed");
    assert!(database.exists(), "reset removed the registry with a stale token");
    assert!(sidecar.exists(), "reset removed a sidecar that was not previewed");

    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn session_reset_state_rejects_preview_when_nested_session_file_appears() {
    let dir = unique_temp_dir("session-reset-new-nested-file");
    fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    let session = "schema-reset-new-nested-file";

    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    let database = find_session_database(&state, session);
    let session_dir = database.parent().unwrap();
    let nested_dir = session_dir.join("nested");
    fs::create_dir_all(&nested_dir).unwrap();
    fs::write(nested_dir.join("previewed"), b"old").unwrap();

    let preview = Command::new(bin())
        .args(["--json", "session", session, "reset-state", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&preview);
    let preview: serde_json::Value = serde_json::from_slice(&preview.stdout).unwrap();
    let stale_confirm_reset = preview["confirm_reset"].as_str().unwrap();

    let unpreviewed = nested_dir.join("unpreviewed");
    fs::write(&unpreviewed, b"new").unwrap();

    let reset = Command::new(bin())
        .args([
            "session",
            session,
            "reset-state",
            "--force",
            "--confirm-reset",
            stale_confirm_reset,
            "--state",
        ])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(!reset.status.success(), "reset accepted a token before a nested file existed");
    assert!(database.exists(), "reset removed the registry with a stale token");
    assert!(unpreviewed.exists(), "reset removed a nested file that was not previewed");

    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn session_reset_state_bad_token_does_not_mutate_state_root() {
    let dir = unique_temp_dir("session-reset-bad-token-no-mutation");
    fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    fs::create_dir_all(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o755)).unwrap();
    let session = "schema-reset-bad-token";
    let resetter = cmux_tui_core::PersistentSessionStateResetter::new(state.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();

    let reset = Command::new(bin())
        .args([
            "session",
            session,
            "reset-state",
            "--force",
            "--confirm-reset",
            "wrong-token",
            "--state",
        ])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(!reset.status.success(), "reset accepted a wrong confirmation token");
    assert!(!state.join("session-locks").exists(), "wrong-token reset created session locks");
    assert_eq!(fs::metadata(&state).unwrap().permissions().mode() & 0o777, 0o755);

    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn session_reset_state_rejects_symlinked_terminal_host_state() {
    let dir = unique_temp_dir("session-reset-symlink-host");
    fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    let session = "schema-reset-symlink-host";

    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    let database = find_session_database(&state, session);
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&state, session);
    let outside_host_root = dir.join("outside-host-state");
    fs::create_dir_all(&outside_host_root).unwrap();
    fs::set_permissions(&outside_host_root, fs::Permissions::from_mode(0o700)).unwrap();
    let outside_sentinel = outside_host_root.join("sentinel");
    fs::write(&outside_sentinel, b"outside").unwrap();
    symlink(&outside_host_root, &host_root).unwrap();

    let preview = Command::new(bin())
        .args(["--json", "session", session, "reset-state", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&preview);
    let preview: serde_json::Value = serde_json::from_slice(&preview.stdout).unwrap();
    let confirm_reset = preview["confirm_reset"].as_str().unwrap();

    let reset = Command::new(bin())
        .args([
            "session",
            session,
            "reset-state",
            "--force",
            "--confirm-reset",
            confirm_reset,
            "--state",
        ])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(!reset.status.success(), "reset accepted a symlinked host root");
    assert!(database.exists(), "reset removed the registry after rejecting host root");
    assert!(fs::symlink_metadata(&host_root).unwrap().file_type().is_symlink());
    assert!(outside_sentinel.exists(), "reset mutated the symlink target");

    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn session_reset_state_rejects_symlinked_state_root() {
    let dir = unique_temp_dir("session-reset-symlink-root");
    fs::create_dir_all(&dir).unwrap();
    let actual_state = dir.join("actual-state");
    let state = dir.join("state-link");
    let session = "schema-reset-symlink-root";
    fs::create_dir_all(&actual_state).unwrap();
    fs::write(actual_state.join("root-sentinel"), b"keep").unwrap();
    symlink(&actual_state, &state).unwrap();

    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    let database = find_session_database(&actual_state, session);
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&state, session);
    fs::create_dir_all(&host_root).unwrap();
    fs::write(host_root.join("orphaned-sidecar"), b"stale").unwrap();

    let preview = Command::new(bin())
        .args(["--json", "session", session, "reset-state", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(!preview.status.success(), "preview accepted a symlinked state root");
    let preview_error: serde_json::Value = serde_json::from_slice(&preview.stderr).unwrap();
    assert_eq!(preview_error["code"], "session.reset_state.filesystem");

    let reset = Command::new(bin())
        .args([
            "--json",
            "session",
            session,
            "reset-state",
            "--force",
            "--confirm-reset",
            "unused",
            "--state",
        ])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(!reset.status.success(), "reset accepted a symlinked state root");
    let reset_error: serde_json::Value = serde_json::from_slice(&reset.stderr).unwrap();
    assert_eq!(reset_error["code"], "session.reset_state.filesystem");
    assert!(database.exists(), "reset removed stale database through symlinked state root");
    assert!(host_root.exists(), "reset removed terminal-host state through symlinked state root");
    assert!(fs::symlink_metadata(&state).unwrap().file_type().is_symlink());
    assert!(actual_state.join("root-sentinel").exists(), "reset removed root sibling data");

    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn session_reset_state_missing_target_does_not_mutate_state_root() {
    let dir = unique_temp_dir("session-reset-missing-target");
    fs::create_dir_all(&dir).unwrap();
    let state = dir.join("not-cmux-state");
    fs::create_dir_all(&state).unwrap();
    #[cfg(unix)]
    fs::set_permissions(&state, fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(state.join("sentinel"), b"keep").unwrap();

    let reset = Command::new(bin())
        .args(["--json", "session", "missing-session", "reset-state", "--force", "--state"])
        .arg(&state)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&reset);
    let reset: serde_json::Value = serde_json::from_slice(&reset.stdout).unwrap();
    assert_eq!(reset["removed_session_state"], false);
    assert_eq!(reset["removed_terminal_hosts"], false);
    assert!(state.join("sentinel").exists());
    assert!(!state.join("session-locks").exists());
    #[cfg(unix)]
    assert_eq!(fs::metadata(&state).unwrap().permissions().mode() & 0o777, 0o755);

    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn durable_registry_survives_sigkill_and_rejects_a_second_writer() {
    let dir = unique_temp_dir("durable-restart");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let second_socket = dir.join("second.sock");
    let state = dir.join("state");
    let spawn = |socket: &std::path::Path| {
        Command::new(bin())
            .args(["--headless", "--session", "durable", "--socket"])
            .arg(socket)
            .arg("--state")
            .arg(&state)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    };

    let mut first = spawn(&socket);
    wait_for_socket_path(&socket);
    let identify = json_socket_request(&socket, serde_json::json!({"id":1,"cmd":"identify"}));
    let registry_id = identify["registry_id"].as_str().unwrap().to_string();
    let generation = identify["generation"].as_str().unwrap().to_string();
    let created = json_socket_request(
        &socket,
        serde_json::json!({
            "id":2,
            "cmd":"create-workspace",
            "name":"survivor",
            "key":"018f6e21-7b70-7e70-8000-000000000044",
            "origin":"process-test",
            "mutation_id":"create-durable",
            "expected_revision":0,
        }),
    );
    assert_eq!(created["workspace_revision"], 1);

    let mut second = spawn(&second_socket);
    let second_status = second.wait().unwrap();
    assert!(!second_status.success());
    let mut second_stderr = String::new();
    second.stderr.take().unwrap().read_to_string(&mut second_stderr).unwrap();
    assert!(second_stderr.contains("already owned by another daemon"), "{second_stderr}");

    // Child::kill is SIGKILL on Unix, intentionally bypassing graceful
    // cleanup and leaving the old socket behind.
    first.kill().unwrap();
    first.wait().unwrap();
    let _ = fs::remove_file(&socket);

    let mut restarted = spawn(&socket);
    wait_for_socket_path(&socket);
    let recovered =
        json_socket_request(&socket, serde_json::json!({"id":3,"cmd":"list-workspaces"}));
    assert_eq!(recovered["registry_id"], registry_id);
    assert_ne!(recovered["generation"], generation);
    assert_eq!(recovered["workspace_revision"], 1);
    assert_eq!(recovered["workspaces"][0]["key"], "018f6e21-7b70-7e70-8000-000000000044");
    assert_eq!(recovered["workspaces"][0]["name"], "survivor");
    assert!(recovered["workspaces"][0]["screens"].as_array().unwrap().is_empty());

    restarted.kill().unwrap();
    restarted.wait().unwrap();
    let _ = fs::remove_dir_all(dir);
}

#[cfg(unix)]
#[test]
fn machine_agent_is_a_real_entrypoint_without_changing_ordinary_cli_dispatch() {
    let machine_agent = Command::new(bin())
        .env("LC_ALL", "C")
        .env("LC_MESSAGES", "C")
        .env("LANG", "C")
        .args(["machine-agent", "--help"])
        .output()
        .unwrap();
    assert_success(&machine_agent);
    let help = String::from_utf8(machine_agent.stdout).unwrap();
    assert!(help.starts_with("cmux machine-agent - share one local cmux session"));
    assert!(help.contains("Authenticate with the configured host before retrying."));
    assert!(!help.contains("cmux machine register"));
    assert!(!help.contains("BatchMode"));

    let version = Command::new(bin()).arg("--version").output().unwrap();
    assert_success(&version);
    assert!(String::from_utf8(version.stdout).unwrap().starts_with("cmux "));
}

#[test]
fn ghostty_config_helper_outputs_resolved_file_defaults() {
    let dir = unique_temp_dir("ghostty-config-helper-output");
    let config_home = dir.join("config");
    let ghostty_dir = config_home.join("ghostty");
    fs::create_dir_all(&ghostty_dir).unwrap();
    fs::write(
        ghostty_dir.join("config"),
        "foreground = #010203\n\
         background = #040506\n\
         cursor-color = #070809\n\
         cursor-style = block_hollow\n\
         cursor-style-blink = false\n\
         palette = 2=#0a0b0c\n",
    )
    .unwrap();

    let output = Command::new(bin())
        .arg("__ghostty-config-defaults")
        .env("HOME", dir.join("home"))
        .env("CFFIXED_USER_HOME", dir.join("home"))
        .env("XDG_CONFIG_HOME", &config_home)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_success(&output);
    let stdout = String::from_utf8(output.stdout).unwrap();
    fs::remove_dir_all(dir).unwrap();

    assert!(stdout.contains("foreground = #010203\n"), "{stdout}");
    assert!(stdout.contains("background = #040506\n"), "{stdout}");
    assert!(stdout.contains("cursor-color = #070809\n"), "{stdout}");
    assert!(stdout.contains("cursor-style = block_hollow\n"), "{stdout}");
    assert!(stdout.contains("cursor-style-blink = false\n"), "{stdout}");
    assert!(stdout.contains("palette = 2=#0a0b0c\n"), "{stdout}");
}

#[cfg(target_os = "linux")]
#[test]
fn ghostty_config_helper_scrubs_provider_env_before_desktop_probe() {
    let dir = unique_temp_dir("ghostty-config-helper-provider-env");
    let config_home = dir.join("config");
    let ghostty_dir = config_home.join("ghostty");
    let theme_dir = ghostty_dir.join("themes");
    let bin_dir = dir.join("bin");
    fs::create_dir_all(&theme_dir).unwrap();
    fs::create_dir_all(&bin_dir).unwrap();
    fs::write(
        ghostty_dir.join("config"),
        "window-theme = system\n\
         theme = dark:Dark Direct Probe, light:Light Direct Probe\n",
    )
    .unwrap();
    fs::write(theme_dir.join("Dark Direct Probe"), "foreground = #010203\n").unwrap();
    fs::write(theme_dir.join("Light Direct Probe"), "foreground = #a0b0c0\n").unwrap();
    let gdbus = bin_dir.join("gdbus");
    fs::write(
        &gdbus,
        "#!/bin/sh\n\
         if [ \"${CMUX_MACHINE_PROVIDER_TOKEN+x}\" = x ] || [ \"${CMUX_PROVIDER_WORKSPACE_AUTHORITY+x}\" = x ]; then\n\
         \tprintf '(<uint32 2>,)\\n'\n\
         \texit 0\n\
         fi\n\
         printf '(<uint32 1>,)\\n'\n",
    )
    .unwrap();
    fs::set_permissions(&gdbus, fs::Permissions::from_mode(0o700)).unwrap();

    let output = Command::new(bin())
        .arg("__ghostty-config-defaults")
        .env("HOME", dir.join("home"))
        .env("CFFIXED_USER_HOME", dir.join("home"))
        .env("XDG_CONFIG_HOME", &config_home)
        .env("PATH", &bin_dir)
        .env("CMUX_MACHINE_PROVIDER_TOKEN", "direct-helper-token")
        .env("CMUX_PROVIDER_WORKSPACE_AUTHORITY", "direct-helper-authority")
        .env_remove("AppleInterfaceStyle")
        .env_remove("GTK_THEME")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_success(&output);
    let stdout = String::from_utf8(output.stdout).unwrap();
    fs::remove_dir_all(dir).unwrap();

    assert!(stdout.contains("foreground = #010203\n"), "{stdout}");
    assert!(!stdout.contains("foreground = #a0b0c0\n"), "{stdout}");
}

#[cfg(unix)]
#[test]
fn machine_agent_argument_failures_are_stable_and_localized() {
    let output = Command::new(bin())
        .env("LC_ALL", "ja_JP.UTF-8")
        .env("LC_MESSAGES", "ja_JP.UTF-8")
        .env("LANG", "ja_JP.UTF-8")
        .args(["machine-agent", "--cloud-port", "invalid"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("--cloud-port の値が無効です: invalid"));
    assert!(!stderr.contains("machine-agent を開始または続行できませんでした"));
}

#[cfg(unix)]
#[test]
fn known_daemon_human_output_uses_selected_locale() {
    let dir = unique_temp_dir("known-daemon-locale");
    let client = dir.join("client");
    fs::create_dir_all(&client).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(&client, fs::Permissions::from_mode(0o700)).unwrap();
    let state = serde_json::json!({
        "version": 1,
        "daemons": {
            "enrolled-fingerprint": {
                "fingerprint": "enrolled-fingerprint",
                "name": "enrolled-host",
                "public_key": "unused",
                "route_hints": ["ssh://enrolled.example"],
                "auth": "enrolled",
                "first_seen_at_unix": 1,
                "last_used_at_unix": 2
            },
            "carrier-fingerprint": {
                "fingerprint": "carrier-fingerprint",
                "name": "carrier-host",
                "public_key": "unused",
                "route_hints": ["ssh://carrier.example"],
                "auth": "carrier",
                "first_seen_at_unix": 1,
                "last_used_at_unix": 2
            }
        }
    });
    let known = client.join("known-daemons.json");
    fs::write(&known, serde_json::to_vec(&state).unwrap()).unwrap();
    fs::set_permissions(&known, fs::Permissions::from_mode(0o600)).unwrap();

    let localized = |arguments: &[&str]| {
        Command::new(bin())
            .args(arguments)
            .arg("--state-dir")
            .arg(&dir)
            .env("LC_ALL", "ja_JP.UTF-8")
            .env("LC_MESSAGES", "ja_JP.UTF-8")
            .env("LANG", "ja_JP.UTF-8")
            .output()
            .unwrap()
    };

    let list = localized(&["known-daemons"]);
    assert_success(&list);
    let list = String::from_utf8(list.stdout).unwrap();
    assert!(list.contains("\t登録済み\n"), "{list}");
    assert!(list.contains("\t信頼済み搬送路\n"), "{list}");
    assert!(!list.contains("\tenrolled\n"), "{list}");
    assert!(!list.contains("\tcarrier\n"), "{list}");

    let forget = localized(&["known-daemons", "forget", "enrolled-fingerprint"]);
    assert_success(&forget);
    let forget = String::from_utf8(forget.stdout).unwrap();
    assert_eq!(forget, "デーモン enrolled-fingerprint を削除しました。\n");

    let empty_dir = unique_temp_dir("known-daemon-empty-locale");
    let empty = Command::new(bin())
        .args(["known-daemons", "--state-dir"])
        .arg(&empty_dir)
        .env("LC_ALL", "ja_JP.UTF-8")
        .env("LC_MESSAGES", "ja_JP.UTF-8")
        .env("LANG", "ja_JP.UTF-8")
        .output()
        .unwrap();
    assert_success(&empty);
    assert_eq!(String::from_utf8(empty.stdout).unwrap(), "登録済みのデーモンはありません。\n");

    fs::remove_dir_all(dir).unwrap();
    fs::remove_dir_all(empty_dir).unwrap();
}

#[test]
fn noun_first_ratio_commands_reject_nonfinite_values_before_connecting() {
    const PANE: &str = "pane_11111111111111111111111111111111";
    const SPLIT: &str = "split_22222222222222222222222222222222";
    for args in [
        ["pane", PANE, "split", "--right", "--ratio", "NaN"].as_slice(),
        ["pane", PANE, "split", "ratio", "set", "--split", SPLIT, "--ratio", "NaN"].as_slice(),
    ] {
        let output = Command::new(bin())
            .env("LC_ALL", "ja_JP.UTF-8")
            .env("LC_MESSAGES", "ja_JP.UTF-8")
            .env("LANG", "ja_JP.UTF-8")
            .args(args)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2));
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(stderr.starts_with("cmux: "), "{stderr}");
        assert!(stderr.contains("--ratio must be greater than 0 and less than 1"), "{stderr}");
        assert!(!stderr.contains("cmux-tui"), "{stderr}");
    }
}

#[test]
fn noun_first_viewport_width_rejects_invalid_values_before_connecting() {
    const PANE: &str = "pane_11111111111111111111111111111111";
    for (args, expected) in [
        (
            ["pane", PANE, "split", "--right", "--viewport-width", "NaN"].as_slice(),
            "--viewport-width must be from 0.1 through 1",
        ),
        (
            ["pane", PANE, "split", "--right", "--viewport-width", "0.09"].as_slice(),
            "--viewport-width must be from 0.1 through 1",
        ),
        (
            ["pane", PANE, "split", "--down", "--viewport-width", "0.5"].as_slice(),
            "--viewport-width requires --right",
        ),
    ] {
        let output = Command::new(bin()).args(args).output().unwrap();
        assert_eq!(output.status.code(), Some(2));
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(stderr.starts_with("cmux: "), "{stderr}");
        assert!(stderr.contains(expected), "{stderr}");
        assert!(!stderr.contains("cmux-tui"), "{stderr}");
    }
}

#[cfg(unix)]
struct PtyChild {
    child: Option<Box<dyn cmux_pty::Child + Send + Sync>>,
    output_drain: Option<std::thread::JoinHandle<()>>,
}

#[cfg(unix)]
struct TestTempDir(PathBuf);

#[cfg(unix)]
impl TestTempDir {
    fn create(name: &str) -> Self {
        let path = unique_temp_dir(name);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &std::path::Path {
        &self.0
    }
}

#[cfg(unix)]
impl Drop for TestTempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(unix)]
impl PtyChild {
    fn start(args: &[&str]) -> Self {
        Self::start_with_env(args, &[])
    }

    fn start_with_env(args: &[&str], env: &[(&str, &std::ffi::OsStr)]) -> Self {
        let spawned = spawn_pty_child(args, env);
        let mut master = spawned.master.try_clone_reader().unwrap();
        let output_drain = std::thread::spawn(move || {
            let mut buffer = [0; 8192];
            while master.read(&mut buffer).is_ok_and(|read| read > 0) {}
        });
        Self { child: Some(spawned.child), output_drain: Some(output_drain) }
    }

    fn wait_for_exit(&mut self, timeout: Duration) -> Option<cmux_pty::ExitStatus> {
        let mut child = self.child.take().expect("PTY child already has an exit waiter");
        let mut killer = child.clone_killer();
        let (sender, receiver) = mpsc::sync_channel(1);
        let _waiter = std::thread::spawn(move || {
            let _ = sender.send(child.wait());
        });
        match receiver.recv_timeout(timeout) {
            Ok(status) => Some(status.unwrap()),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let _ = killer.kill();
                match receiver.recv_timeout(Duration::from_secs(5)) {
                    Ok(Ok(_)) => {}
                    Ok(Err(error)) => {
                        panic!("interactive owner did not exit cleanly after kill: {error}");
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        let _ = self.output_drain.take();
                        panic!("interactive owner did not exit after kill");
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        let _ = self.output_drain.take();
                        panic!("interactive owner exit waiter disconnected after kill");
                    }
                }
                None
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = self.output_drain.take();
                panic!("interactive owner exit waiter disconnected")
            }
        }
    }
}

#[cfg(unix)]
impl Drop for PtyChild {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Some(output_drain) = self.output_drain.take() {
            let _ = output_drain.join();
        }
    }
}

#[cfg(unix)]
struct DisconnectablePtyChild {
    child: Box<dyn cmux_pty::Child + Send + Sync>,
    master: Option<Box<dyn cmux_pty::MasterPty + Send>>,
}

#[cfg(unix)]
impl DisconnectablePtyChild {
    fn start(args: &[&str]) -> Self {
        let spawned = spawn_pty_child(args, &[]);
        Self { child: spawned.child, master: Some(spawned.master) }
    }

    fn disconnect_host_terminal(&mut self) {
        self.master.take();
    }
}

#[cfg(unix)]
fn spawn_pty_child(args: &[&str], env: &[(&str, &std::ffi::OsStr)]) -> cmux_pty::SpawnedPty {
    let pair =
        cmux_pty::open(cmux_pty::PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
            .unwrap();
    let mut command = cmux_pty::PtyCommand::new(bin());
    command.args(args.iter().copied());
    command.env_clear();
    for (key, value) in std::env::vars() {
        if key != "CMUX_TUI_SOCKET" {
            command.env(key, value);
        }
    }
    for (key, value) in env {
        command.env(*key, value.to_string_lossy());
    }
    pair.spawn(command).unwrap()
}

#[cfg(unix)]
fn plain_tui_is_ready(server: &HeadlessServer) -> bool {
    let clients = json_cli(server, &["client", "list"]);
    if !clients.status.success()
        || !json_output(&clients).as_array().is_some_and(|clients| {
            clients.iter().any(|client| client["client_kind"].as_str() == Some("tui"))
        })
    {
        return false;
    }

    let terminals = json_cli(server, &["terminal", "list"]);
    terminals.status.success()
        && json_output(&terminals).as_array().is_some_and(|terminals| !terminals.is_empty())
}

#[cfg(unix)]
impl Drop for DisconnectablePtyChild {
    fn drop(&mut self) {
        self.master.take();
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(unix)]
#[test]
fn startup_does_not_invoke_external_ghostty_config_resolver() {
    let dir = unique_temp_dir("external-ghostty-config-resolver");
    fs::create_dir_all(&dir).unwrap();
    let helper = dir.join("ghostty-config-probe");
    let capture = dir.join("resolver-invoked.txt");
    let socket = dir.join("mux.sock");
    fs::write(
        &helper,
        r#"#!/bin/sh
echo invoked > "$CMUX_TEST_GHOSTTY_CAPTURE"
exit 0
"#,
    )
    .unwrap();
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();

    let output = Command::new(bin())
        .args(["--machine-provider", "/does/not/exist", "--headless", "--socket"])
        .arg(&socket)
        .env("GHOSTTY_BIN", &helper)
        .env("CMUX_TEST_GHOSTTY_CAPTURE", &capture)
        .env("CMUX_MACHINE_PROVIDER_TOKEN", "edge-test-bearer")
        .env("CMUX_PROVIDER_WORKSPACE_AUTHORITY", "provider-workspace-authority-test-00000001")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert!(!output.status.success(), "conflicting provider launch unexpectedly succeeded");
    assert!(!capture.exists(), "startup invoked external Ghostty config resolver");
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn plain_launch_attaches_to_existing_local_session() {
    let server = HeadlessServer::start("plain-launch-attach");
    let mut tui = PtyChild::start(&["--socket", server.socket.to_str().unwrap()]);
    let deadline = Instant::now() + Duration::from_secs(10);

    while Instant::now() < deadline {
        if let Some(status) = tui.child.as_mut().unwrap().try_wait().unwrap() {
            panic!("plain launch exited instead of attaching: {status}");
        }
        if plain_tui_is_ready(&server) {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    panic!("plain launch never attached to its committed initial terminal");
}

#[cfg(unix)]
#[test]
fn session_shutdown_exits_an_interactive_local_owner() {
    let dir = TestTempDir::create("interactive-session-shutdown");
    let socket = dir.path().join("mux.sock");
    let socket_arg = socket.to_str().unwrap();
    let mut owner =
        PtyChild::start(&["--session", "interactive-session-shutdown", "--socket", socket_arg]);
    wait_for_socket_path(&socket);
    wait_for_owner_server_ready(&socket, &mut owner);

    let shutdown =
        lifecycle_cli(&["--json", "--socket", socket_arg, "session", "current", "shutdown"]);
    assert_success(&shutdown);
    assert_eq!(json_output(&shutdown)["value"]["accepted"], true);

    let status = owner
        .wait_for_exit(Duration::from_secs(5))
        .expect("interactive owner remained alive after session shutdown");
    assert!(status.success(), "interactive owner exited unsuccessfully: {status}");
}

#[cfg(unix)]
#[test]
fn host_terminal_disconnect_exits_frontend_without_stopping_server() {
    let server = HeadlessServer::start("host-terminal-disconnect");
    let mut tui = DisconnectablePtyChild::start(&["--socket", server.socket.to_str().unwrap()]);
    let attach_deadline = Instant::now() + Duration::from_secs(10);
    let mut attached = false;

    while Instant::now() < attach_deadline {
        if let Some(status) = tui.child.try_wait().unwrap() {
            panic!("plain launch exited before host disconnect: {status}");
        }
        if plain_tui_is_ready(&server) {
            attached = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(attached, "plain launch never attached to its committed terminal before disconnect");

    tui.disconnect_host_terminal();
    let exit_deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = tui.child.try_wait().unwrap() {
            break status;
        }
        assert!(
            Instant::now() < exit_deadline,
            "frontend remained alive after its host terminal disconnected"
        );
        std::thread::sleep(Duration::from_millis(25));
    };
    assert!(!status.success(), "host terminal disconnect unexpectedly reported success");

    let ping = json_cli(&server, &["session", "current", "ping"]);
    assert_success(&ping);
    assert_eq!(json_output(&ping)["alive"], true);
}

#[cfg(unix)]
#[test]
fn explicit_attach_registers_a_full_session_tui_client() {
    let server = HeadlessServer::start("explicit-attach");
    let created = json_cli(&server, &["workspace", "create", "--name", "single"]);
    assert_success(&created);
    let created = json_output(&created);
    let terminal = created["value"]["terminal_id"].as_str().unwrap().to_string();
    let pane = created["value"]["pane_id"].as_str().unwrap().to_string();
    let second = json_cli(&server, &["tab", "create", "terminal", "--pane", pane.as_str()]);
    assert_success(&second);
    let second_terminal =
        json_output(&second)["value"]["terminal_id"].as_str().unwrap().to_string();

    let clients_before = json_cli(&server, &["client", "list"]);
    assert_success(&clients_before);
    assert!(
        json_output(&clients_before)
            .as_array()
            .unwrap()
            .iter()
            .all(|client| client["client_kind"].as_str() != Some("tui"))
    );

    let mut tui = PtyChild::start(&["attach", "--socket", server.socket.to_str().unwrap()]);
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(status) = tui.child.as_mut().unwrap().try_wait().unwrap() {
            panic!("explicit attach exited unexpectedly: {status}");
        }
        let clients = json_cli(&server, &["client", "list"]);
        if clients.status.success() {
            let clients = json_output(&clients);
            if let Some(client) = clients
                .as_array()
                .unwrap()
                .iter()
                .find(|client| client["client_kind"].as_str() == Some("tui"))
            {
                let attached = client["attached_terminal_ids"].as_array().unwrap();
                if attached.len() < 2 {
                    std::thread::sleep(Duration::from_millis(50));
                    continue;
                }
                let sizes = client["sizes"].as_array().unwrap();
                if !sizes.iter().any(|size| {
                    size["cols"].as_u64().is_some_and(|cols| cols > 0)
                        && size["rows"].as_u64().is_some_and(|rows| rows > 0)
                }) {
                    std::thread::sleep(Duration::from_millis(50));
                    continue;
                }
                assert!(attached.iter().any(|id| id.as_str() == Some(terminal.as_str())));
                assert!(attached.iter().any(|id| id.as_str() == Some(second_terminal.as_str())));
                return;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    panic!("explicit attach never registered the full session");
}

#[cfg(unix)]
#[test]
fn graceful_shutdown_stops_server_owned_sidebar_process() {
    let mut server = HeadlessServer::start_with_config(
        "sidebar-host-shutdown",
        Some(r#"{"sidebar":{"plugin":{"command":["/bin/cat"]}}}"#),
    );
    let sidebar = try_json_socket_request(
        &server.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "sidebar-plugin",
            "cols": 20,
            "rows": 8,
            "relaunch": true,
        }),
    )
    .expect("start configured sidebar plugin");
    let surface = sidebar["surface"].as_u64().expect("sidebar plugin surface");
    let plugin_pid = try_json_socket_request(
        &server.socket,
        serde_json::json!({"id": 2, "cmd": "process-info", "surface": surface}),
    )
    .and_then(|response| response["pid"].as_u64())
    .and_then(|pid| u32::try_from(pid).ok())
    .expect("sidebar plugin PID");

    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&server.state, "main");
    let records = cmux_tui_core::terminal_host_runtime::load_terminal_host_records(&host_root)
        .expect("load sidebar terminal-host record");
    let used_durable_host = !records.is_empty();
    let mut owned_pids = vec![plugin_pid];
    owned_pids.extend(records.iter().map(|(_, record)| record.host_pid));

    let server_pid = libc::pid_t::try_from(server.child.id()).unwrap();
    // SAFETY: this PID is the live child owned by the test fixture.
    assert_eq!(unsafe { libc::kill(server_pid, libc::SIGINT) }, 0);
    let server_stopped = wait_for_child_exit(&mut server.child, Duration::from_secs(10));
    let owned_processes_stopped = wait_for_processes_to_exit(&owned_pids, Duration::from_secs(5));

    // Keep lifecycle regressions leak-free. Every captured process group and
    // record belongs to this fixture's private state root.
    if !owned_processes_stopped {
        for pid in &owned_pids {
            signal_test_process_group(*pid, libc::SIGTERM);
        }
        if !wait_for_processes_to_exit(&owned_pids, Duration::from_secs(2)) {
            for pid in &owned_pids {
                signal_test_process_group(*pid, libc::SIGKILL);
            }
            assert!(
                wait_for_processes_to_exit(&owned_pids, Duration::from_secs(2)),
                "fixture could not reap its isolated sidebar processes"
            );
        }
        for (record_path, record) in &records {
            let _ = cmux_tui_core::terminal_host_runtime::remove_stale_terminal_host_record(
                record_path,
                record,
            );
        }
    }

    assert!(server_stopped, "SIGINT did not complete graceful server shutdown");
    assert!(
        !used_durable_host,
        "server-owned sidebar process entered the durable terminal-host registry"
    );
    assert!(
        owned_processes_stopped,
        "graceful shutdown left its server-owned sidebar process alive"
    );
}

#[cfg(unix)]
#[test]
fn configured_websocket_server_does_not_attach_to_existing_session() {
    let server = HeadlessServer::start("configured-websocket-server");
    let config = server.dir.join("config.json");
    fs::write(&config, r#"{"server":{"ws":"127.0.0.1:0"}}"#).unwrap();
    let mut tui = PtyChild::start_with_env(
        &["--socket", server.socket.to_str().unwrap()],
        &[("CMUX_TUI_CONFIG", config.as_os_str())],
    );
    let deadline = Instant::now() + Duration::from_secs(10);

    while Instant::now() < deadline {
        if let Some(status) = tui.child.as_mut().unwrap().try_wait().unwrap() {
            assert!(!status.success(), "server launch unexpectedly succeeded");
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    panic!("configured WebSocket server attached instead of preserving server mode");
}

#[cfg(unix)]
#[test]
fn raw_command_is_the_explicit_private_protocol_v10_escape() {
    let dir = unique_temp_dir("raw-client-sizing");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut writer = stream.try_clone().unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let request: serde_json::Value = serde_json::from_str(&line).unwrap();
        writeln!(
            writer,
            "{}",
            serde_json::json!({"id":"raw-sizing","ok":true,"data":{"changed":true}})
        )
        .unwrap();
        request
    });

    let output = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&socket)
        .args([
            "raw",
            "command",
            "--request-json",
            r#"{"id":"raw-sizing","cmd":"set-client-sizing","surface":9,"client":7,"enabled":false}"#,
        ])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    let request = server.join().unwrap();
    fs::remove_dir_all(dir).unwrap();

    assert_success(&output);
    assert_eq!(
        request,
        serde_json::json!({
            "id":"raw-sizing",
            "cmd":"set-client-sizing",
            "surface":9,
            "client":7,
            "enabled":false,
        })
    );
    assert_eq!(json_output(&output), serde_json::json!({"changed":true}));
}

#[test]
fn noun_first_cli_covers_resources_output_errors_and_private_raw_escape() {
    let server = HeadlessServer::start("matrix");

    let identify = raw_cli(&server, serde_json::json!({"id":"identify-human","cmd":"identify"}));
    assert_success(&identify);
    assert!(
        String::from_utf8_lossy(&identify.stdout)
            .contains(&format!("\"protocol\":{}", cmux_tui_core::server::PROTOCOL_VERSION))
    );

    let identify_json =
        raw_cli(&server, serde_json::json!({"id":"identify-json","cmd":"identify"}));
    assert_success(&identify_json);
    let value = json_output(&identify_json);
    assert_eq!(value.get("app").and_then(|v| v.as_str()), Some("cmux-tui"));
    assert!(value.get("protocol").and_then(|v| v.as_u64()).unwrap_or(0) >= 5);

    let session = json_cli(&server, &["session", "current", "show"]);
    assert_success(&session);
    assert!(json_output(&session)["id"].as_str().unwrap().starts_with("session_"));

    let ping_json = json_cli(&server, &["session", "current", "ping"]);
    assert_success(&ping_json);
    let ping = json_output(&ping_json);
    assert_eq!(ping.get("alive").and_then(|v| v.as_bool()), Some(true));
    assert!(ping["cursor"]["generation"].is_string());

    let client_info = json_cli(
        &server,
        &["client", "current", "label", "set", "--name", "one-shot", "--kind", "cli-test"],
    );
    assert_success(&client_info);
    assert_eq!(json_output(&client_info)["name"], "one-shot");

    let target = transport::connect(&server.socket).unwrap();
    let mut target_writer = target.try_clone_box().unwrap();
    let mut target_reader = BufReader::new(target);
    writeln!(
        target_writer,
        r#"{{"id":1,"cmd":"set-client-info","name":"cli-detach-target","kind":"test"}}"#
    )
    .unwrap();
    let mut target_response = String::new();
    target_reader.read_line(&mut target_response).unwrap();
    assert_eq!(serde_json::from_str::<serde_json::Value>(&target_response).unwrap()["ok"], true);

    let sizing_workspace = json_cli(&server, &["workspace", "create", "--name", "cli-test"]);
    assert_success(&sizing_workspace);
    let created = json_output(&sizing_workspace);
    let workspace_id = created["value"]["workspace_id"].as_str().unwrap().to_string();
    let screen_id = created["value"]["screen_id"].as_str().unwrap().to_string();
    let pane0 = created["value"]["pane_id"].as_str().unwrap().to_string();
    let terminal = created["value"]["terminal_id"].as_str().unwrap().to_string();
    // Create all terminals before opening the long-lived raw control client.
    // Terminal creation can rebalance the shared Kitty image budget; keeping
    // this resource setup ahead of the sizing lease avoids a cross-resource
    // wait in this fixture.
    let split = json_cli(&server, &["pane", &pane0, "split", "--right"]);
    assert_success(&split);
    let pane1 = json_output(&split)["value"]["pane_id"].as_str().unwrap().to_string();
    let raw_tree =
        raw_json(&server, serde_json::json!({"id":"created-tree","cmd":"list-workspaces"}));
    let sizing_surface =
        raw_tree["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0]["surface"].as_u64().unwrap();
    writeln!(target_writer, r#"{{"id":2,"cmd":"attach-surface","surface":{sizing_surface}}}"#)
        .unwrap();
    loop {
        target_response.clear();
        target_reader.read_line(&mut target_response).unwrap();
        let response = serde_json::from_str::<serde_json::Value>(&target_response).unwrap();
        if response["id"] == 2 {
            assert_eq!(response["ok"], true);
            break;
        }
    }
    writeln!(
        target_writer,
        r#"{{"id":3,"cmd":"resize-surface","surface":{sizing_surface},"cols":80,"rows":24}}"#
    )
    .unwrap();
    loop {
        target_response.clear();
        target_reader.read_line(&mut target_response).unwrap();
        let response = serde_json::from_str::<serde_json::Value>(&target_response).unwrap();
        if response["id"] == 3 {
            assert_eq!(response["ok"], true);
            break;
        }
    }

    let clients = json_cli(&server, &["client", "list"]);
    assert_success(&clients);
    let clients_json = json_output(&clients);
    let target_id = clients_json
        .as_array()
        .unwrap()
        .iter()
        .find(|client| client["name"] == "cli-detach-target")
        .unwrap()["id"]
        .as_str()
        .unwrap();
    let clients_human = cli(&server, &["client", "list"]);
    assert_success(&clients_human);
    assert!(String::from_utf8_lossy(&clients_human.stdout).contains("CONNECTED SECONDS"));
    assert!(String::from_utf8_lossy(&clients_human.stdout).contains("participating"));
    let excluded = json_cli(
        &server,
        &["client", target_id, "sizing", "set", "--terminal", &terminal, "--enabled", "false"],
    );
    assert_success(&excluded);
    let clients = json_cli(&server, &["client", "list"]);
    assert_success(&clients);
    let clients_json = json_output(&clients);
    assert_eq!(
        clients_json
            .as_array()
            .unwrap()
            .iter()
            .find(|client| client["id"] == target_id)
            .unwrap()["sizes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|size| size["terminal_id"] == terminal)
            .unwrap()["participating"],
        false
    );
    let detached = cli(&server, &["--quiet", "client", target_id, "detach"]);
    assert_success(&detached);
    loop {
        target_response.clear();
        if target_reader.read_line(&mut target_response).unwrap() == 0 {
            break;
        }
    }

    let title = cli(
        &server,
        &["--quiet", "session", "current", "window", "title", "set", "--title", "hello"],
    );
    assert_success(&title);
    assert!(title.stdout.is_empty(), "--quiet mutation wrote output");

    let surface = sizing_surface;
    assert!(surface > 0);
    let snapshot = json_cli(&server, &["session", "current", "snapshot"]);
    assert_success(&snapshot);
    let tree_json = json_output(&snapshot);
    let screen = tree_json["screens"]
        .as_array()
        .unwrap()
        .iter()
        .find(|candidate| candidate["id"] == screen_id)
        .unwrap();
    assert!(
        screen["layout"]["root"].get("columns").is_none(),
        "ordinary public layout unexpectedly used viewport columns"
    );

    let projected = json_cli(
        &server,
        &[
            "terminal",
            &terminal,
            "project",
            "--workspace",
            &workspace_id,
            "--screen",
            &screen_id,
            "--pane",
            &pane1,
            "--index",
            "0",
            "--name",
            "mirror",
        ],
    );
    assert_success(&projected);
    let projected = json_output(&projected);
    assert_eq!(projected["value"]["focused"], false);
    let projected_tab = projected["value"]["id"].as_str().unwrap();
    let terminals = json_cli(&server, &["terminal", "list"]);
    assert_success(&terminals);
    let terminals = json_output(&terminals);
    let source =
        terminals.as_array().unwrap().iter().find(|candidate| candidate["id"] == terminal).unwrap();
    assert_eq!(source["tab_ids"].as_array().unwrap().len(), 2);
    let snapshot = json_cli(&server, &["session", "current", "snapshot"]);
    assert_success(&snapshot);
    let snapshot_json = json_output(&snapshot);
    let projected_record = snapshot_json["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["id"].as_str() == Some(projected_tab))
        .unwrap();
    assert_eq!(projected_record["pane_id"], pane1);
    assert_eq!(projected_record["focused"], false);
    let focused_tab = snapshot_json["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["pane_id"] == pane1 && tab["focused"] == true)
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    assert_ne!(focused_tab, projected_tab);

    let new_pane = json_cli(
        &server,
        &["screen", &screen_id, "pane", "create", "--cols", "80", "--rows", "24"],
    );
    assert_success(&new_pane);

    let exported = json_cli(&server, &["screen", &screen_id, "layout", "export"]);
    assert_success(&exported);
    let exported_json = json_output(&exported);
    assert_eq!(exported_json["root"]["kind"].as_str(), Some("split"));
    assert_eq!(layout_leaf_count(&exported_json["root"]), 3);
    let split_id = first_layout_split_id(&exported_json["root"]).unwrap();

    let exact_ratio = json_cli(
        &server,
        &["pane", &pane0, "split", "ratio", "set", "--split", split_id, "--ratio", "0.7"],
    );
    assert_success(&exact_ratio);
    let exported = json_cli(&server, &["screen", &screen_id, "layout", "export"]);
    let exported_json = json_output(&exported);
    let ratio = layout_split_ratio(&exported_json["root"], split_id).unwrap();
    assert!((ratio - 0.7).abs() < 0.0001, "layout ratio was {ratio}");

    let neighbor = json_cli(&server, &["pane", &pane0, "neighbor", "right"]);
    assert_success(&neighbor);
    let neighbor_json = json_output(&neighbor);
    let neighboring_pane = neighbor_json["pane"]["id"].as_str().unwrap();
    assert_ne!(pane0, neighboring_pane);

    let focus = json_cli(&server, &["pane", &pane0, "focus", "direction", "right"]);
    assert_success(&focus);
    let focus_json = json_output(&focus);
    assert_ne!(focus_json["value"]["id"].as_str(), Some(pane0.as_str()));

    let zoom = json_cli(&server, &["pane", &pane1, "zoom", "--enabled", "true"]);
    assert_success(&zoom);
    let zoom_json = json_output(&zoom);
    assert_eq!(zoom_json["value"]["zoomed"].as_bool(), Some(true));
    assert_eq!(zoom_json["value"]["id"].as_str(), Some(pane1.as_str()));

    let raw_tree =
        raw_json(&server, serde_json::json!({"id":"pre-viewport-tree","cmd":"list-workspaces"}));
    let raw_screen = &raw_tree["workspaces"][0]["screens"][0];
    let raw_pane = raw_screen["active_pane"].as_u64().unwrap();
    let viewport_pane = raw_json(
        &server,
        serde_json::json!({
            "id":"new-viewport-pane",
            "cmd":"new-pane-right",
            "pane":raw_pane,
            "cols":51,
            "rows":22,
        }),
    );
    let viewport_surface = viewport_pane["surface"].as_u64().unwrap();
    assert!(viewport_surface > 0);
    let tree = raw_json(&server, serde_json::json!({"id":"viewport-tree","cmd":"list-workspaces"}));
    let viewport_splits =
        tree["workspaces"][0]["screens"][0]["viewport_splits"].as_array().unwrap();
    assert_eq!(viewport_splits.len(), 1);
    let width = viewport_splits[0]["width"].as_f64().unwrap();
    assert!((width - 2.0 / 3.0).abs() < 0.0001);
    let viewport_pane = tree["workspaces"][0]["screens"][0]["active_pane"].as_u64().unwrap();
    raw_json(
        &server,
        serde_json::json!({
            "id":"resize-viewport",
            "cmd":"set-viewport-pane-width",
            "pane":viewport_pane,
            "width":0.5,
        }),
    );
    let base_pane = tree["workspaces"][0]["screens"][0]["panes"][0]["id"].as_u64().unwrap();
    raw_json(
        &server,
        serde_json::json!({
            "id":"resize-base",
            "cmd":"set-viewport-pane-width",
            "pane":base_pane,
            "width":0.75,
        }),
    );
    let tree = raw_json(&server, serde_json::json!({"id":"resized-tree","cmd":"list-workspaces"}));
    let screen = &tree["workspaces"][0]["screens"][0];
    assert_eq!(screen["viewport_base_width"].as_f64(), Some(0.75));
    assert_eq!(screen["viewport_splits"][0]["width"].as_f64(), Some(0.5));

    let marker = format!("cmux_cli_marker_{}", std::process::id());
    let send = cli(
        &server,
        &["--quiet", "terminal", &terminal, "write", "--text", &format!("echo {marker}\r")],
    );
    assert_success(&send);
    assert!(send.stdout.is_empty(), "--quiet mutation wrote output");
    let screen = wait_for_screen(&server, &terminal, &marker);
    assert!(screen.contains(&marker), "screen did not contain marker; got {screen:?}");

    let ids =
        raw_json(&server, serde_json::json!({"id":"surface-ids","cmd":"ids","kind":"surface"}));
    assert!(ids["ids"].as_array().unwrap().iter().any(|item| item["id"].as_u64() == Some(surface)));

    let copied = json_cli(&server, &["terminal", &terminal, "copy", "--mode", "screen"]);
    assert_success(&copied);
    assert!(json_output(&copied)["text"].as_str().unwrap().contains(&marker));

    let pending = format!("echo prompt_kept_{}", std::process::id());
    let type_pending =
        cli(&server, &["--quiet", "terminal", &terminal, "write", "--text", &pending]);
    assert_success(&type_pending);
    wait_for_screen(&server, &terminal, &pending);

    let cleared = cli(&server, &["--quiet", "terminal", &terminal, "history", "clear"]);
    assert_success(&cleared);
    assert!(cleared.stdout.is_empty(), "--quiet history clear wrote output");
    let output = json_cli(&server, &["terminal", &terminal, "screen", "read"]);
    assert_success(&output);
    let cleared_screen = json_output(&output)["text"].as_str().unwrap().to_string();
    assert!(
        cleared_screen.contains(&marker),
        "clear-history removed visible output without a safe prompt boundary: {cleared_screen:?}"
    );
    assert!(!cleared_screen.trim().is_empty(), "clear-history blanked the active terminal");
    let cleared_scrollback =
        json_cli(&server, &["terminal", &terminal, "history", "read", "--limit", "200"]);
    assert_success(&cleared_scrollback);
    assert!(
        !String::from_utf8_lossy(&cleared_scrollback.stdout).contains(&marker),
        "clear-history retained prior output in scrollback"
    );

    let notify = json_cli(&server, &["notification", "create", "--title", "Build", "--body", "ok"]);
    assert_success(&notify);
    assert!(json_output(&notify)["value"]["id"].as_str().unwrap().starts_with("notification_"));

    let report = json_cli(
        &server,
        &[
            "agent",
            "report",
            "--terminal",
            &terminal,
            "--state",
            "idle",
            "--source",
            "socket",
            "--source-session",
            "cli",
        ],
    );
    assert_success(&report);
    let agents = json_cli(&server, &["agent", "list", "--terminal", &terminal]);
    assert_success(&agents);
    let agents = json_output(&agents);
    assert_eq!(agents[0]["state"].as_str(), Some("idle"));

    let send_key = cli(&server, &["--quiet", "terminal", &terminal, "keys", "enter"]);
    if !send_key.status.success() {
        assert_eq!(send_key.status.code(), Some(1));
        assert!(
            String::from_utf8_lossy(&send_key.stderr)
                .contains("the external effect may have run before its outcome was recorded"),
            "unexpected key delivery failure: {}",
            String::from_utf8_lossy(&send_key.stderr)
        );
    }
    assert!(send_key.stdout.is_empty(), "--quiet key delivery wrote output");

    let select_bare = cli(&server, &["tab"]);
    assert_eq!(select_bare.status.code(), Some(2));

    // Keep terminal.close focused on its CLI contract; multiview close semantics have dedicated
    // core coverage.
    let close_projection = json_cli(&server, &["tab", projected_tab, "close"]);
    assert_success(&close_projection);
    let remaining_terminal = json_cli(&server, &["terminal", &terminal, "screen", "read"]);
    assert_success(&remaining_terminal);

    let mut terminal_closed = false;
    for attempt in 0..3 {
        let key = format!("matrix-terminal-close-{attempt}");
        let close = json_cli(&server, &["terminal", &terminal, "close", "--idempotency-key", &key]);
        if !close.status.success() {
            assert_eq!(close.status.code(), Some(1));
            let error = json_error(&close);
            assert_eq!(error["code"], "mutation.indeterminate");
            assert_eq!(error["details"]["idempotency_key"], key);
            assert_eq!(error["details"]["operation"], "terminal.close");
            assert_eq!(error["details"]["recovery"], "inspect_state_then_retry_with_new_key");
        }

        let read = json_cli(&server, &["terminal", &terminal, "screen", "read"]);
        if !read.status.success() {
            assert_eq!(read.status.code(), Some(1));
            assert_eq!(json_error(&read)["code"], "selector.not_found");
            terminal_closed = true;
            break;
        }
        assert_success(&read);
        assert!(!close.status.success(), "successful close left the terminal addressable");
    }
    assert!(terminal_closed, "terminal remained addressable after three inspected close attempts");

    let bogus = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(server.dir.join("missing.sock"))
        .args(["session", "current", "show"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_eq!(bogus.status.code(), Some(3));

    assert_subscribe_reports_tree_changed(&server);
}

#[test]
fn raw_protocol_apply_layout_preserves_explicit_surface_size() {
    let server = HeadlessServer::start("apply-layout-size");
    let applied = raw_json(
        &server,
        serde_json::json!({
            "id":"apply-sized-layout",
            "cmd":"apply-layout",
            "layout":{"type":"leaf"},
            "cols":111,
            "rows":37,
        }),
    );
    let surface = applied["panes"][0]["surface"].as_u64().unwrap();

    let state = raw_json(
        &server,
        serde_json::json!({"id":"sized-state","cmd":"vt-state","surface":surface}),
    );
    assert_eq!(state["cols"].as_u64(), Some(111));
    assert_eq!(state["rows"].as_u64(), Some(37));

    let inherited = raw_json(
        &server,
        serde_json::json!({"id":"inherited-workspace","cmd":"new-workspace"}),
    )["surface"]
        .as_u64()
        .unwrap();
    let state = raw_json(
        &server,
        serde_json::json!({"id":"inherited-state","cmd":"vt-state","surface":inherited}),
    );
    assert_eq!(state["cols"].as_u64(), Some(111));
    assert_eq!(state["rows"].as_u64(), Some(37));

    let partial = raw_json(
        &server,
        serde_json::json!({
            "id":"partial-layout-size",
            "cmd":"apply-layout",
            "layout":{"type":"leaf"},
            "cols":90,
        }),
    );
    let partial_surface = partial["panes"][0]["surface"].as_u64().unwrap();
    let state = raw_json(
        &server,
        serde_json::json!({
            "id":"partial-layout-state",
            "cmd":"vt-state",
            "surface":partial_surface,
        }),
    );
    assert_eq!(state["cols"].as_u64(), Some(111));
    assert_eq!(state["rows"].as_u64(), Some(37));
}

fn assert_subscribe_reports_tree_changed(server: &HeadlessServer) {
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let reader = BufReader::new(stream);
        for line in reader.lines() {
            if tx.send(line.unwrap()).is_err() {
                break;
            }
        }
    });
    writeln!(writer, r#"{{"id":1,"cmd":"subscribe"}}"#).unwrap();

    std::thread::sleep(Duration::from_millis(200));
    let tab = json_cli(server, &["tab", "create", "terminal"]);
    if !tab.status.success() {
        let mut lines = Vec::new();
        while let Ok(line) = rx.recv_timeout(Duration::from_millis(250)) {
            lines.push(line);
        }
        panic!(
            "tab creation failed while subscribed; stdout={} stderr={} events={lines:?}",
            String::from_utf8_lossy(&tab.stdout),
            String::from_utf8_lossy(&tab.stderr),
        );
    }
    assert_success(&tab);

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut lines = Vec::new();
    while Instant::now() < deadline {
        if let Ok(line) = rx.recv_timeout(Duration::from_millis(250)) {
            lines.push(line.clone());
            if line.contains("\"event\":\"tree-changed\"") {
                return;
            }
        }
    }
    panic!("subscribe did not print tree-changed event; lines={lines:?}");
}

#[test]
fn raw_command_preserves_a_partial_response_line() {
    let dir = unique_temp_dir("partial-line");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        let mut request = String::new();
        {
            let read_half = stream.try_clone_box().unwrap();
            let mut reader = BufReader::new(read_half);
            reader.read_line(&mut request).unwrap();
        }
        assert!(request.contains("\"cmd\":\"ping\""));

        stream.write_all(br#"{"id":"partial","ok":true,"data":{"message":""#).unwrap();
        stream.flush().unwrap();
        std::thread::sleep(Duration::from_millis(350));
        stream.write_all(br#"split-line-ok"}}"#).unwrap();
        stream.write_all(b"\n").unwrap();
        stream.flush().unwrap();
    });

    let output = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&socket)
        .args(["raw", "command", "--request-json", r#"{"id":"partial","cmd":"ping"}"#])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    server.join().unwrap();
    let _ = fs::remove_file(&socket);
    let _ = fs::remove_dir_all(&dir);

    assert_success(&output);
    assert_eq!(json_output(&output), serde_json::json!({"message":"split-line-ok"}));
}

#[test]
fn help_uses_public_cmux_scopes_and_keeps_startup_options_discoverable() {
    let root = Command::new(bin()).arg("--help").env_remove("CMUX_TUI_SOCKET").output().unwrap();
    assert_success(&root);
    let root = String::from_utf8(root.stdout).unwrap();
    assert!(root.starts_with("cmux - terminal multiplexer and resource client"));
    assert!(root.contains("sidebar       Manage sidebar views and local plugins"));
    assert!(!root.contains("cmux-tui"));
    assert!(!root.contains("new-pane-right"));

    let sidebar = Command::new(bin())
        .args(["sidebar", "--help"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&sidebar);
    let sidebar = String::from_utf8(sidebar.stdout).unwrap();
    assert!(sidebar.contains("cmux sidebar plugin install <git-url>"));
    assert!(sidebar.contains("cmux sidebar plugin use --builtin"));

    let startup =
        Command::new(bin()).args(["help", "start"]).env_remove("CMUX_TUI_SOCKET").output().unwrap();
    assert_success(&startup);
    let startup = String::from_utf8(startup.stdout).unwrap();
    assert!(startup.starts_with("cmux - "));
    assert!(startup.contains("--ws <addr>"));
    assert!(startup.contains("--ws-token <token>"));
    assert!(startup.contains("--ws-insecure-bind"));
    assert!(!startup.contains("cmux-tui"));
}

#[cfg(unix)]
#[test]
fn plugin_install_use_and_list_work_against_local_git_repo() {
    let dir = unique_temp_dir("plugin-install");
    let source = dir.join("source");
    // The runnable is NOT committed: [build] must create it, so this fixture
    // exercises the build step and the post-build executable verification.
    fs::create_dir_all(&source).unwrap();
    fs::write(
        source.join("cmux-plugin.toml"),
        r#"
            [plugin]
            name = "fixture"
            kind = "sidebar"
            version = "0.1.0"
            description = "Fixture sidebar"

            [run]
            command = ["bin/sidebar"]

            [build]
            command = ["/bin/sh", "build.sh"]
        "#,
    )
    .unwrap();
    let build_script = concat!(
        "#!/bin/sh\n",
        "mkdir -p bin\n",
        "cat > bin/sidebar <<'EOF'\n",
        "#!/bin/sh\n",
        "printf 'fixture sidebar\\n'\n",
        "EOF\n",
        "chmod 755 bin/sidebar\n"
    );
    fs::write(source.join("build.sh"), build_script).unwrap();
    git(&source, &["init"]);
    git(&source, &["add", "."]);
    git(
        &source,
        &[
            "-c",
            "user.name=cmux",
            "-c",
            "user.email=cmux@example.invalid",
            "commit",
            "-m",
            "fixture",
        ],
    );

    let data_home = dir.join("data");
    let config_path = dir.join("config").join("mux.json");
    fs::create_dir_all(config_path.parent().unwrap()).unwrap();
    fs::write(&config_path, r#"{"future":{"keep":true},"sidebar":{"width":33}}"#).unwrap();
    let missing_socket = dir.join("missing.sock");
    let url = format!("file://{}", source.display());

    let install = plugin_cli(
        &data_home,
        &config_path,
        &[
            "--json",
            "--socket",
            missing_socket.to_str().unwrap(),
            "sidebar",
            "plugin",
            "install",
            &url,
            "--name",
            "fixture",
        ],
    );
    assert_success(&install);
    let installed = json_output(&install);
    assert_eq!(installed["plugin"]["name"].as_str(), Some("fixture"));
    assert_eq!(installed["plugin"]["active"].as_bool(), Some(false));
    let installed_dir = data_home.join("cmux").join("mux-plugins").join("fixture");
    assert!(installed_dir.join("cmux-plugin.toml").is_file());

    let list = plugin_cli(&data_home, &config_path, &["--json", "sidebar", "plugin", "list"]);
    assert_success(&list);
    let listed = json_output(&list);
    assert_eq!(listed[0]["name"].as_str(), Some("fixture"));
    assert_eq!(listed[0]["active"].as_bool(), Some(false));

    let use_plugin = plugin_cli(
        &data_home,
        &config_path,
        &[
            "--json",
            "--socket",
            missing_socket.to_str().unwrap(),
            "sidebar",
            "plugin",
            "use",
            "fixture",
        ],
    );
    assert_success(&use_plugin);
    let used = json_output(&use_plugin);
    assert_eq!(used["plugin"]["name"].as_str(), Some("fixture"));
    assert_eq!(used["plugin"]["active"].as_bool(), Some(true));

    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&config_path).unwrap()).unwrap();
    assert_eq!(written["future"]["keep"].as_bool(), Some(true));
    assert_eq!(written["sidebar"]["width"].as_u64(), Some(33));
    // plugin use canonicalizes paths; /tmp is a symlink to /private/tmp on
    // macOS, so compare against the canonicalized install dir.
    let canonical_dir = fs::canonicalize(&installed_dir).unwrap();
    assert_eq!(written["sidebar"]["plugin"]["cwd"].as_str(), Some(canonical_dir.to_str().unwrap()));
    assert_eq!(
        written["sidebar"]["plugin"]["command"][0].as_str(),
        Some(canonical_dir.join("bin/sidebar").to_str().unwrap())
    );

    let list = plugin_cli(&data_home, &config_path, &["--json", "sidebar", "plugin", "list"]);
    assert_success(&list);
    let listed = json_output(&list);
    assert_eq!(listed[0]["active"].as_bool(), Some(true));

    let builtin = plugin_cli(
        &data_home,
        &config_path,
        &["--socket", missing_socket.to_str().unwrap(), "sidebar", "plugin", "use", "--builtin"],
    );
    assert_success(&builtin);
    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&config_path).unwrap()).unwrap();
    assert!(written["sidebar"].get("plugin").is_none());
    assert_eq!(written["future"]["keep"].as_bool(), Some(true));

    let _ = fs::remove_dir_all(&dir);
}

fn wait_for_screen(server: &HeadlessServer, terminal: &str, marker: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut last = String::new();
    while Instant::now() < deadline {
        let output = json_cli(server, &["terminal", terminal, "screen", "read"]);
        assert_success(&output);
        last = json_output(&output)["text"].as_str().unwrap().to_string();
        if last.contains(marker) {
            return last;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    last
}

fn plugin_cli(data_home: &PathBuf, config_path: &PathBuf, args: &[&str]) -> Output {
    Command::new(bin())
        .args(args)
        .env("XDG_DATA_HOME", data_home)
        .env("CMUX_MUX_CONFIG", config_path)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap()
}

fn git(dir: &PathBuf, args: &[&str]) {
    let output = Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
    assert_success(&output);
}

#[test]
fn new_terminals_default_to_the_daemon_launch_directory() {
    // Regression for https://github.com/manaflow-ai/cmux/issues/10756: a
    // terminal created without an explicit cwd must start where the daemon
    // was launched, not in $HOME. $HOME-rooted agents recursively scan and
    // watch the whole home directory.
    let launch = unique_temp_dir("launch-cwd-dir");
    fs::create_dir_all(&launch).unwrap();
    // The daemon reports its physical working directory, so compare against
    // the resolved path (macOS /tmp is a symlink to /private/tmp).
    let launch = launch.canonicalize().unwrap();
    let server = HeadlessServer::start_in("launch-cwd", &launch);

    let created = json_cli(&server, &["tab", "create", "terminal"]);
    assert_success(&created);
    let listed = json_output(&json_cli(&server, &["terminal", "list"]));
    let terminals = listed.as_array().expect("terminal list returns an array");
    assert_eq!(terminals.len(), 1, "expected one terminal: {listed}");
    assert_eq!(
        terminals[0]["cwd"].as_str(),
        launch.to_str(),
        "terminal cwd must be the daemon launch directory"
    );
}

fn cli(server: &HeadlessServer, args: &[&str]) -> Output {
    Command::new(bin())
        .args(["--socket"])
        .arg(&server.socket)
        .args(args)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap()
}

fn json_cli(server: &HeadlessServer, args: &[&str]) -> Output {
    Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(args)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap()
}

fn raw_cli(server: &HeadlessServer, request: serde_json::Value) -> Output {
    let request = serde_json::to_string(&request).unwrap();
    Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["raw", "command", "--request-json", &request])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap()
}

fn raw_json(server: &HeadlessServer, request: serde_json::Value) -> serde_json::Value {
    let output = raw_cli(server, request);
    assert_success(&output);
    json_output(&output)
}

fn json_output(output: &Output) -> serde_json::Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
        panic!("expected JSON stdout, got {error}: {}", String::from_utf8_lossy(&output.stdout))
    })
}

fn json_error(output: &Output) -> serde_json::Value {
    serde_json::from_slice(&output.stderr).unwrap_or_else(|error| {
        panic!("expected JSON stderr, got {error}: {}", String::from_utf8_lossy(&output.stderr))
    })
}

fn layout_leaf_count(node: &serde_json::Value) -> usize {
    match node["kind"].as_str() {
        Some("leaf") => 1,
        Some("split") => layout_leaf_count(&node["first"]) + layout_leaf_count(&node["second"]),
        Some("viewport") => node["columns"]
            .as_array()
            .unwrap()
            .iter()
            .map(|column| layout_leaf_count(&column["root"]))
            .sum(),
        Some("stack") => node["pane_ids"].as_array().unwrap().len(),
        other => panic!("unexpected public layout node {other:?}: {node}"),
    }
}

fn first_layout_split_id(node: &serde_json::Value) -> Option<&str> {
    match node["kind"].as_str() {
        Some("split") => node["split_id"]
            .as_str()
            .or_else(|| first_layout_split_id(&node["first"]))
            .or_else(|| first_layout_split_id(&node["second"])),
        Some("viewport") => node["columns"]
            .as_array()
            .into_iter()
            .flatten()
            .find_map(|column| first_layout_split_id(&column["root"])),
        _ => None,
    }
}

fn layout_split_ratio(node: &serde_json::Value, split_id: &str) -> Option<f64> {
    match node["kind"].as_str() {
        Some("split") if node["split_id"].as_str() == Some(split_id) => node["ratio"].as_f64(),
        Some("split") => layout_split_ratio(&node["first"], split_id)
            .or_else(|| layout_split_ratio(&node["second"], split_id)),
        Some("viewport") => node["columns"]
            .as_array()
            .into_iter()
            .flatten()
            .find_map(|column| layout_split_ratio(&column["root"], split_id)),
        _ => None,
    }
}

#[track_caller]
fn assert_success(output: &Output) {
    assert!(
        output.status.success(),
        "expected success, got status {:?}\nstdout:\n{}\nstderr:\n{}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn find_session_database(state: &std::path::Path, session: &str) -> PathBuf {
    fs::read_dir(state)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| entry.path().join("workspace-registry.sqlite3"))
        .filter(|path| path.is_file())
        .find(|path| {
            let connection = rusqlite::Connection::open(path).unwrap();
            let session_id: String = connection
                .query_row("SELECT value FROM meta WHERE key = 'session_name'", [], |row| {
                    row.get(0)
                })
                .unwrap();
            session_id == session
        })
        .expect("session database")
}

#[cfg(unix)]
fn create_live_terminal_host_record(root: &std::path::Path) -> fs::File {
    fs::create_dir_all(root).unwrap();
    fs::set_permissions(root, fs::Permissions::from_mode(0o700)).unwrap();
    let terminal_id = "0000000000004000800000000000002a";
    let incarnation = "0000000000004000800000000000002b";
    let owner_token = "01".repeat(32);
    let host_start_nonce = "02".repeat(32);
    let uid = fs::metadata(root).unwrap().uid();
    let record = cmux_tui_core::terminal_host_runtime::TerminalHostRecord {
        record_version: 2,
        terminal_id: terminal_id.to_string(),
        incarnation: incarnation.to_string(),
        endpoint: format!("/tmp/cmux-th-{uid}/{terminal_id}.sock"),
        owner_token,
        host_pid: std::process::id(),
        host_start_nonce: host_start_nonce.clone(),
        workspace_key: String::new(),
        supports_set_defaults: true,
        supports_clear_history: true,
        supports_terminate_ack: false,
    };
    let record_path = record.record_path(root);
    let live_path = record_path.with_extension(format!("{incarnation}-{host_start_nonce}.live"));
    let live_file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&live_path)
        .unwrap();
    assert_eq!(unsafe { libc::flock(live_file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    let mut record_file =
        fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&record_path).unwrap();
    record_file.write_all(&serde_json::to_vec(&record).unwrap()).unwrap();
    record_file.sync_all().unwrap();
    live_file
}

fn unique_temp_dir(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-cli-{name}-{}-{stamp}", std::process::id()))
}

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}
