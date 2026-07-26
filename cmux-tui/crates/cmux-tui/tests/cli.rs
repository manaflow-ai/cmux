use std::fs;
#[cfg(unix)]
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::os::fd::FromRawFd;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
#[cfg(unix)]
use std::os::unix::net::UnixListener;
#[cfg(unix)]
use std::os::unix::process::{CommandExt, ExitStatusExt};
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
        Self::start_with(name, false, &[])
    }

    fn start_with(name: &str, ephemeral: bool, environment: &[(&str, &str)]) -> Self {
        let dir = unique_temp_dir(name);
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        let mut command = Command::new(bin());
        command.args(["--headless", "--socket"]).arg(&socket);
        if ephemeral {
            command.arg("--ephemeral");
        } else {
            command.arg("--state").arg(&state);
        }
        for (name, value) in environment {
            command.env(name, value);
        }
        let child = command.stdout(Stdio::null()).stderr(Stdio::piped()).spawn().unwrap();
        let server = Self { child, socket, state, dir };
        server.wait_for_socket();
        server
    }

    fn wait_for_socket(&self) {
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            if self.socket.exists() {
                return;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        panic!("headless server did not create socket at {}", self.socket.display());
    }

    fn close_all_surfaces(&self) -> bool {
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
            return host_pids.is_empty();
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
                return true;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        false
    }
}

impl Drop for HeadlessServer {
    fn drop(&mut self) {
        // Durable terminal hosts intentionally outlive the daemon. Tests must
        // close their canonical surfaces first rather than assuming SIGKILL
        // of the daemon also owns or reaps its per-terminal processes.
        let hosts_stopped = self.close_all_surfaces();
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_file(&self.socket);
        let _ = fs::remove_dir_all(&self.dir);
        if !hosts_stopped && !std::thread::panicking() {
            panic!("headless CLI fixture left a durable terminal-host process behind");
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

#[cfg(unix)]
fn wait_for_pid_file(path: &std::path::Path, timeout: Duration) -> u32 {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(pid) =
            fs::read_to_string(path).ok().and_then(|value| value.trim().parse::<u32>().ok())
        {
            return pid;
        }
        assert!(Instant::now() < deadline, "PID file was not ready: {}", path.display());
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(unix)]
struct LegacyServerProcess {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
    descendant_pid_file: PathBuf,
}

#[cfg(unix)]
impl LegacyServerProcess {
    fn start(name: &str, scenario: &str, reported_pid: Option<u32>) -> Self {
        let dir = unique_temp_dir(name);
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let descendant_pid_file = dir.join("descendant.pid");
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args(["--ignored", "--exact", "legacy_server_process_helper"])
            .env("CMUX_TUI_TEST_LEGACY_SOCKET", &socket)
            .env("CMUX_TUI_TEST_LEGACY_SCENARIO", scenario)
            .env("CMUX_TUI_TEST_LEGACY_DESCENDANT_PID_FILE", &descendant_pid_file)
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        if let Some(reported_pid) = reported_pid {
            command.env("CMUX_TUI_TEST_LEGACY_REPORTED_PID", reported_pid.to_string());
        }
        let child = command.spawn().unwrap();
        let mut server = Self { child, socket, dir, descendant_pid_file };
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            if server.socket.exists() {
                return server;
            }
            if let Some(status) = server.child.try_wait().unwrap() {
                let mut stderr = String::new();
                server.child.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
                panic!("legacy server helper exited with {status}: {stderr}");
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        panic!("legacy server helper did not create socket at {}", server.socket.display());
    }

    fn descendant_pid(&self) -> Option<u32> {
        fs::read_to_string(&self.descendant_pid_file).ok()?.trim().parse().ok()
    }
}

#[cfg(unix)]
impl Drop for LegacyServerProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(pid) = self.descendant_pid().and_then(|pid| libc::pid_t::try_from(pid).ok()) {
            // SAFETY: test cleanup targets the PID written by this fixture.
            let _ = unsafe { libc::kill(pid, libc::SIGKILL) };
        }
        let _ = fs::remove_file(&self.socket);
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[cfg(unix)]
#[test]
#[ignore]
fn legacy_server_process_helper() {
    let socket = PathBuf::from(std::env::var_os("CMUX_TUI_TEST_LEGACY_SOCKET").unwrap());
    let scenario = std::env::var("CMUX_TUI_TEST_LEGACY_SCENARIO").unwrap();
    let reported_pid = std::env::var("CMUX_TUI_TEST_LEGACY_REPORTED_PID")
        .ok()
        .map(|value| value.parse::<u32>().unwrap())
        .unwrap_or_else(std::process::id);
    let mut reparent_on_close = None;
    if matches!(
        scenario.as_str(),
        "success"
            | "kill-caller"
            | "cleanup-failure"
            | "applied-close-error"
            | "applied-close-disconnect"
            | "persistent-close-error"
            | "browser-surface"
    ) {
        let mut command = Command::new("yes");
        command.stdout(Stdio::null()).stderr(Stdio::null());
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let descendant = command.spawn().unwrap();
        fs::write(
            std::env::var_os("CMUX_TUI_TEST_LEGACY_DESCENDANT_PID_FILE").unwrap(),
            descendant.id().to_string(),
        )
        .unwrap();
        drop(descendant);
    } else if scenario == "zombie-child" {
        let descendant =
            Command::new("true").stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
        let descendant_pid = descendant.id();
        fs::write(
            std::env::var_os("CMUX_TUI_TEST_LEGACY_DESCENDANT_PID_FILE").unwrap(),
            descendant_pid.to_string(),
        )
        .unwrap();
        drop(descendant);
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let status = Command::new("ps")
                .args(["-o", "stat=", "-p", &descendant_pid.to_string()])
                .output()
                .unwrap();
            if String::from_utf8_lossy(&status.stdout).trim_start().starts_with('Z') {
                break;
            }
            assert!(Instant::now() < deadline, "descendant did not become a zombie");
            std::thread::sleep(Duration::from_millis(10));
        }
    } else if scenario == "reparent-on-close" {
        let mut command = Command::new("/bin/bash");
        command
            .args([
                "--noprofile",
                "--norc",
                "-c",
                concat!(
                    "set -m; trap '' HUP; ",
                    "(trap '' HUP; while :; do sleep 60; done) & ",
                    "printf '%s' \"$!\" > \"$CMUX_TUI_TEST_LEGACY_DESCENDANT_PID_FILE\"; wait"
                ),
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        reparent_on_close = Some(command.spawn().unwrap());
    }
    let listener = transport::listen(&socket).unwrap();
    let serve_identify = |stream: &mut Box<dyn transport::Stream>| {
        let mut reader = BufReader::new(stream.try_clone_box().unwrap());
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        let identify_request: serde_json::Value = serde_json::from_str(&request).unwrap();
        assert_eq!(identify_request["cmd"].as_str(), Some("identify"));
        let release = cmux_tui_core::release::ReleaseIdentity::current(
            cmux_tui_core::server::PROTOCOL_VERSION,
        );
        let modern =
            matches!(scenario.as_str(), "compatible-failure" | "mismatched-modern-failure");
        let (version, build_commit, ghostty_commit, protocol) = if scenario == "compatible-failure"
        {
            (release.version, release.build_commit, release.ghostty_commit, release.protocol)
        } else {
            ("0.0.0-stale".to_string(), None, None, 8)
        };
        let capabilities = if modern { vec!["server-shutdown-v1"] } else { Vec::new() };
        writeln!(
            stream,
            "{}",
            serde_json::json!({
                "id": identify_request["id"],
                "ok": true,
                "data": {
                    "app": "cmux-tui",
                    "session": "test",
                    "pid": reported_pid,
                    "version": version,
                    "build_commit": build_commit,
                    "ghostty_commit": ghostty_commit,
                    "protocol": protocol,
                    "capabilities": capabilities,
                },
            })
        )
        .unwrap();
    };

    let reject_shutdown = |stream: &mut Box<dyn transport::Stream>| {
        let mut reader = BufReader::new(stream.try_clone_box().unwrap());
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        let request: serde_json::Value = serde_json::from_str(&request).unwrap();
        assert_eq!(request["cmd"].as_str(), Some("shutdown"));
        writeln!(
            stream,
            "{}",
            serde_json::json!({
                "id": request["id"],
                "ok": false,
                "error": "shutdown failed",
            })
        )
        .unwrap();
    };

    let mut initial_stream = listener.accept().unwrap();
    let caller_pid = initial_stream.peer_process_id().unwrap().unwrap();
    serve_identify(&mut initial_stream);
    if matches!(scenario.as_str(), "compatible-failure" | "mismatched-modern-failure") {
        reject_shutdown(&mut initial_stream);
        loop {
            std::thread::park();
        }
    }
    drop(initial_stream);
    if scenario == "spoofed-pid" {
        loop {
            std::thread::park();
        }
    }

    let mut stream = listener.accept().unwrap();
    serve_identify(&mut stream);
    let mut reader = BufReader::new(stream.try_clone_box().unwrap());
    let mut request = String::new();
    let mut snapshot_index = 0;
    'snapshots: loop {
        request.clear();
        if reader.read_line(&mut request).unwrap() == 0 {
            loop {
                std::thread::park();
            }
        }
        let list_request: serde_json::Value = serde_json::from_str(&request).unwrap();
        assert_eq!(list_request["cmd"].as_str(), Some("list-workspaces"));
        if scenario == "cleanup-failure" {
            writeln!(
                stream,
                "{}",
                serde_json::json!({
                    "id": list_request["id"],
                    "ok": false,
                    "error": "cleanup unavailable",
                })
            )
            .unwrap();
            loop {
                std::thread::park();
            }
        }
        assert!(matches!(
            scenario.as_str(),
            "success"
                | "kill-caller"
                | "applied-close-error"
                | "applied-close-disconnect"
                | "persistent-close-error"
                | "zombie-child"
                | "reparent-on-close"
                | "browser-surface"
                | "dead-surface"
        ));
        let surfaces: &[u64] = match (scenario.as_str(), snapshot_index) {
            ("zombie-child", _) => &[],
            ("persistent-close-error", _) | (_, 0) => &[41],
            ("success" | "kill-caller", 1) => &[42],
            _ => &[],
        };
        let tabs = surfaces
            .iter()
            .map(|surface| {
                if scenario == "browser-surface" {
                    serde_json::json!({"surface": surface, "kind": "browser"})
                } else if scenario == "dead-surface" {
                    serde_json::json!({"surface": surface, "kind": "pty", "dead": true})
                } else {
                    serde_json::json!({"surface": surface, "kind": "pty"})
                }
            })
            .collect::<Vec<_>>();
        writeln!(
            stream,
            "{}",
            serde_json::json!({
                "id": list_request["id"],
                "ok": true,
                "data": {
                    "workspaces": [{
                        "screens": [{
                            "panes": [{
                                "tabs": tabs,
                            }],
                        }],
                    }],
                },
            })
        )
        .unwrap();
        for &expected_surface in surfaces {
            request.clear();
            if reader.read_line(&mut request).unwrap() == 0 {
                loop {
                    std::thread::park();
                }
            }
            let mut close_request: serde_json::Value = serde_json::from_str(&request).unwrap();
            if close_request["cmd"].as_str() == Some("process-info") {
                assert_eq!(close_request["surface"].as_u64(), Some(expected_surface));
                let pid = if scenario == "dead-surface" {
                    None
                } else {
                    Some(
                        fs::read_to_string(
                            std::env::var_os("CMUX_TUI_TEST_LEGACY_DESCENDANT_PID_FILE").unwrap(),
                        )
                        .unwrap()
                        .trim()
                        .parse::<u32>()
                        .unwrap(),
                    )
                };
                writeln!(
                    stream,
                    "{}",
                    serde_json::json!({
                        "id": close_request["id"],
                        "ok": true,
                        "data": {"pid": pid},
                    })
                )
                .unwrap();
                request.clear();
                if reader.read_line(&mut request).unwrap() == 0 {
                    loop {
                        std::thread::park();
                    }
                }
                close_request = serde_json::from_str(&request).unwrap();
            }
            assert_eq!(close_request["cmd"].as_str(), Some("close-surface"));
            assert_eq!(close_request["surface"].as_u64(), Some(expected_surface));
            if scenario == "applied-close-disconnect" {
                drop(reader);
                drop(stream);
                stream = listener.accept().unwrap();
                serve_identify(&mut stream);
                reader = BufReader::new(stream.try_clone_box().unwrap());
                snapshot_index += 1;
                continue 'snapshots;
            }
            let response =
                if matches!(scenario.as_str(), "applied-close-error" | "persistent-close-error") {
                    serde_json::json!({
                        "id": close_request["id"],
                        "ok": false,
                        "error": "surface cleanup reported an error",
                    })
                } else {
                    serde_json::json!({
                        "id": close_request["id"],
                        "ok": true,
                        "data": {},
                    })
                };
            writeln!(stream, "{response}").unwrap();
            if scenario == "reparent-on-close"
                && let Some(mut direct) = reparent_on_close.take()
            {
                direct.kill().unwrap();
                direct.wait().unwrap();
            }
            if scenario == "kill-caller" && expected_surface == 41 {
                let caller_pid = libc::pid_t::try_from(caller_pid).unwrap();
                assert_eq!(unsafe { libc::kill(caller_pid, libc::SIGKILL) }, 0);
            }
        }
        snapshot_index += 1;
    }
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
struct PtyChild {
    child: Child,
    output_drain: Option<std::thread::JoinHandle<()>>,
}

#[cfg(unix)]
impl PtyChild {
    fn start(args: &[&str]) -> Self {
        Self::start_with_env(args, &[])
    }

    fn start_with_env(args: &[&str], env: &[(&str, &std::ffi::OsStr)]) -> Self {
        let mut master = -1;
        let mut slave = -1;
        let mut size = libc::winsize { ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0 };
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &raw mut size,
            )
        };
        assert_eq!(opened, 0, "openpty failed: {}", std::io::Error::last_os_error());
        let mut master = unsafe { File::from_raw_fd(master) };
        let slave = unsafe { File::from_raw_fd(slave) };
        let output_drain = std::thread::spawn(move || {
            let mut buffer = [0; 8192];
            while master.read(&mut buffer).is_ok_and(|read| read > 0) {}
        });
        let mut command = Command::new(bin());
        command.args(args).env_remove("CMUX_TUI_SOCKET");
        for (key, value) in env {
            command.env(key, value);
        }
        let child = command
            .stdin(Stdio::from(slave.try_clone().unwrap()))
            .stdout(Stdio::from(slave.try_clone().unwrap()))
            .stderr(Stdio::from(slave))
            .spawn()
            .unwrap();
        Self { child, output_drain: Some(output_drain) }
    }
}

#[cfg(unix)]
impl Drop for PtyChild {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(output_drain) = self.output_drain.take() {
            let _ = output_drain.join();
        }
    }
}

#[cfg(unix)]
#[test]
fn startup_config_helper_inherits_no_provider_secrets() {
    let dir = unique_temp_dir("provider-secret-config-helper");
    fs::create_dir_all(&dir).unwrap();
    let helper = dir.join("ghostty-secret-probe");
    let capture = dir.join("inherited-env.txt");
    fs::write(
        &helper,
        r#"#!/bin/sh
{
if [ "${CMUX_MACHINE_PROVIDER_TOKEN+x}" = x ]; then
    echo token=present
else
    echo token=absent
fi
if [ "${CMUX_PROVIDER_WORKSPACE_AUTHORITY+x}" = x ]; then
    echo authority=present
else
    echo authority=absent
fi
} > "$CMUX_TEST_SECRET_CAPTURE"
"#,
    )
    .unwrap();
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();

    let output = Command::new(bin())
        .args(["--machine-provider", "/does/not/exist", "--headless"])
        .env("GHOSTTY_BIN", &helper)
        .env("CMUX_TEST_SECRET_CAPTURE", &capture)
        .env("CMUX_MACHINE_PROVIDER_TOKEN", "edge-test-bearer")
        .env("CMUX_PROVIDER_WORKSPACE_AUTHORITY", "provider-workspace-authority-test-00000001")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert!(!output.status.success(), "conflicting provider launch unexpectedly succeeded");
    let inherited = fs::read_to_string(&capture).unwrap();
    assert_eq!(inherited, "token=absent\nauthority=absent\n");
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn plain_launch_attaches_to_existing_local_session() {
    let server = HeadlessServer::start("plain-launch-attach");
    let mut tui = PtyChild::start(&["--socket", server.socket.to_str().unwrap()]);
    let deadline = Instant::now() + Duration::from_secs(10);

    while Instant::now() < deadline {
        if let Some(status) = tui.child.try_wait().unwrap() {
            panic!("plain launch exited instead of attaching: {status}");
        }
        let clients = cli(&server, &["--json", "list-clients"]);
        if clients.status.success() {
            let clients: serde_json::Value = serde_json::from_slice(&clients.stdout).unwrap();
            if clients
                .as_array()
                .unwrap()
                .iter()
                .any(|client| client["kind"].as_str() == Some("tui"))
            {
                return;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    panic!("plain launch never attached as a TUI client");
}

#[test]
fn plain_launch_explains_how_to_replace_an_incompatible_local_server() {
    let dir = unique_temp_dir("incompatible-server");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        for connection in 0..2 {
            let mut stream = listener.accept().unwrap();
            if connection == 0 {
                let mut request = String::new();
                BufReader::new(stream.try_clone_box().unwrap()).read_line(&mut request).unwrap();
                let request: serde_json::Value = serde_json::from_str(&request).unwrap();
                let response = serde_json::json!({
                    "id": request["id"],
                    "ok": true,
                    "data": {
                        "app": "cmux-tui",
                        "session": "test",
                        "pid": 4242,
                        "version": "0.0.0-stale",
                        "protocol": 8,
                    },
                });
                writeln!(stream, "{response}").unwrap();
            }
        }
    });

    let output = Command::new(bin())
        .args(["--socket"])
        .arg(&socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    server.join().unwrap();
    let _ = fs::remove_file(&socket);
    let _ = fs::remove_dir_all(&dir);

    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("server: v0.0.0-stale protocol 8"), "{stderr}");
    assert!(
        stderr.contains(&format!(
            "client: v{} protocol {}",
            env!("CARGO_PKG_VERSION"),
            cmux_tui_core::server::PROTOCOL_VERSION
        )),
        "{stderr}"
    );
    assert!(stderr.contains("Stopping exits pane processes."), "{stderr}");
    assert!(stderr.contains("cmux-tui server stop"), "{stderr}");
    assert!(!stderr.contains("already in use"), "{stderr}");
}

#[test]
fn incompatible_server_allows_identity_and_status_but_rejects_ping() {
    let dir = unique_temp_dir("incompatible-cli");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut commands = Vec::new();
        for _ in 0..4 {
            let mut stream = listener.accept().unwrap();
            let mut request = String::new();
            BufReader::new(stream.try_clone_box().unwrap()).read_line(&mut request).unwrap();
            let request: serde_json::Value = serde_json::from_str(&request).unwrap();
            commands.push(request["cmd"].as_str().unwrap().to_string());
            let response = serde_json::json!({
                "id": request["id"],
                "ok": true,
                "data": {
                    "app": "cmux-tui",
                    "session": "test",
                    "pid": 4242,
                    "version": "0.0.0-stale",
                    "protocol": cmux_tui_core::server::PROTOCOL_VERSION,
                },
            });
            writeln!(stream, "{response}").unwrap();
        }
        commands
    });

    let status = Command::new(bin())
        .args(["server", "status", "--socket"])
        .arg(&socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&status);
    let status_text = String::from_utf8_lossy(&status.stdout);
    assert!(status_text.contains("status: incompatible"));
    assert!(status_text.contains("reason: distribution version differs"));
    assert!(status_text.contains("source build differs"));
    assert!(status_text.contains("terminal engine build differs"));

    let status_json = Command::new(bin())
        .args(["--json", "server", "status", "--socket"])
        .arg(&socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&status_json);
    let status_json: serde_json::Value = serde_json::from_slice(&status_json.stdout).unwrap();
    assert_eq!(
        status_json["mismatch_reasons"],
        serde_json::json!(["distribution-version", "source-build", "terminal-engine"])
    );

    let identify = Command::new(bin())
        .args(["identify", "--socket"])
        .arg(&socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&identify);
    assert!(String::from_utf8_lossy(&identify.stdout).contains("version=0.0.0-stale"));

    let ping = Command::new(bin())
        .args(["ping", "--socket"])
        .arg(&socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_eq!(ping.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&ping.stderr).contains("cmux-tui server stop"));

    assert_eq!(server.join().unwrap(), ["identify", "identify", "identify", "identify"]);
    let _ = fs::remove_file(&socket);
    let _ = fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn packaged_launcher_name_is_used_in_upgrade_instructions() {
    let dir = unique_temp_dir("packaged-launcher-message");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        let mut request = String::new();
        BufReader::new(stream.try_clone_box().unwrap()).read_line(&mut request).unwrap();
        let request: serde_json::Value = serde_json::from_str(&request).unwrap();
        let response = serde_json::json!({
            "id": request["id"],
            "ok": true,
            "data": {
                "app": "cmux-tui",
                "session": "test",
                "pid": 4242,
                "version": "0.0.0-stale",
                "protocol": cmux_tui_core::server::PROTOCOL_VERSION,
            },
        });
        writeln!(stream, "{response}").unwrap();
    });

    let output = Command::new(bin())
        .arg0("cmux")
        .args(["ping", "--socket"])
        .arg(&socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("cmux server stop"), "{stderr}");
    assert!(stderr.contains("then run `cmux` again"), "{stderr}");
    server.join().unwrap();
    let _ = fs::remove_file(&socket);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn server_status_and_stop_control_a_compatible_headless_session() {
    let mut server = HeadlessServer::start("server-lifecycle");
    let status = cli(&server, &["--json", "server", "status"]);
    assert_success(&status);
    let status: serde_json::Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(status["running"].as_bool(), Some(true));
    assert_eq!(status["compatible"].as_bool(), Some(true));
    assert_eq!(status["mismatch_reasons"], serde_json::json!([]));
    assert_eq!(
        status["server"]["version"].as_str(),
        Some(cmux_tui_core::release::distribution_version())
    );

    let stop = cli(&server, &["--json", "server", "stop"]);
    assert_success(&stop);
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&stop.stdout).unwrap(),
        serde_json::json!({"stopped": true})
    );
    assert!(server.child.wait().unwrap().success());
    assert!(!server.socket.exists());
}

#[cfg(unix)]
#[test]
fn server_stop_cancels_a_blocked_terminal_host_launch() {
    let mut server = HeadlessServer::start_with(
        "server-stop-blocked-launch",
        false,
        &[("CMUX_TUI_TEST_BOOTSTRAP_READY_DELAY_MS", "3000")],
    );
    let mut create = Command::new(bin())
        .args(["--socket"])
        .arg(&server.socket)
        .arg("new-workspace")
        .env_remove("CMUX_TUI_SOCKET")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&server.state, "main");
    std::thread::sleep(Duration::from_millis(250));
    assert!(create.try_wait().unwrap().is_none(), "terminal creation did not remain in flight");

    let stop_started = Instant::now();
    let stop = cli(&server, &["--json", "server", "stop"]);

    assert_success(&stop);
    assert!(
        stop_started.elapsed() < Duration::from_secs(2),
        "shutdown waited for the blocked creator: {:?}",
        stop_started.elapsed()
    );
    assert!(server.child.wait().unwrap().success());
    assert!(!create.wait().unwrap().success());
    assert!(terminal_host_pids(&host_root).is_empty());
}

#[cfg(unix)]
#[test]
fn cancelled_published_host_is_terminated_through_its_record() {
    let mut server = HeadlessServer::start_with(
        "server-stop-published-launch",
        false,
        &[("CMUX_TUI_TEST_HOST_READY_DELAY_MS", "1000")],
    );
    let direct_pid_file = server.dir.join("published-direct.pid");
    let descendant_pid_file = server.dir.join("published-descendant.pid");
    let command = format!(
        "echo $$ > {}; trap '' HUP; (trap '' HUP; while :; do sleep 1; done) & echo $! > {}; wait",
        direct_pid_file.display(),
        descendant_pid_file.display()
    );
    let mut create = Command::new(bin())
        .args(["--socket"])
        .arg(&server.socket)
        .args(["run", "--new-workspace", "--command", &command])
        .env_remove("CMUX_TUI_SOCKET")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&server.state, "main");
    let deadline = Instant::now() + Duration::from_secs(5);
    while (!direct_pid_file.exists()
        || !descendant_pid_file.exists()
        || terminal_host_pids(&host_root).is_empty())
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    let direct_pid = wait_for_pid_file(&direct_pid_file, Duration::from_secs(5));
    let descendant_pid = wait_for_pid_file(&descendant_pid_file, Duration::from_secs(5));

    let stop = cli(&server, &["--json", "server", "stop"]);

    assert_success(&stop);
    assert!(server.child.wait().unwrap().success());
    assert!(!create.wait().unwrap().success());
    let deadline = Instant::now() + Duration::from_secs(5);
    while (process_exists(direct_pid)
        || process_group_exists(direct_pid)
        || process_exists(descendant_pid))
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!process_exists(direct_pid));
    assert!(!process_group_exists(direct_pid));
    assert!(!process_exists(descendant_pid));
    assert!(terminal_host_pids(&host_root).is_empty());
}

#[cfg(unix)]
#[test]
fn server_stop_kills_ephemeral_pty_process_groups() {
    let mut server = HeadlessServer::start_with("server-stop-ephemeral-process-group", true, &[]);
    let descendant_pid_file = server.dir.join("ephemeral-descendant.pid");
    let command = format!(
        "trap '' HUP; (trap '' HUP; while :; do sleep 1; done) & echo $! > {}; wait",
        descendant_pid_file.display()
    );
    let run = cli(&server, &["run", "--command", &command]);
    assert_success(&run);
    let surface = String::from_utf8(run.stdout).unwrap().trim().parse::<u64>().unwrap();
    let info = cli(&server, &["--json", "process-info", "--surface", &surface.to_string()]);
    assert_success(&info);
    let direct_pid = u32::try_from(
        serde_json::from_slice::<serde_json::Value>(&info.stdout).unwrap()["pid"].as_u64().unwrap(),
    )
    .unwrap();
    let descendant_pid = wait_for_pid_file(&descendant_pid_file, Duration::from_secs(5));

    let stop = cli(&server, &["--json", "server", "stop"]);

    assert_success(&stop);
    assert!(server.child.wait().unwrap().success());
    let deadline = Instant::now() + Duration::from_secs(5);
    while (process_exists(direct_pid)
        || process_group_exists(direct_pid)
        || process_exists(descendant_pid))
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!process_exists(direct_pid));
    assert!(!process_group_exists(direct_pid));
    assert!(!process_exists(descendant_pid));
}

#[cfg(unix)]
#[test]
fn server_stop_kills_background_jobs_in_separate_pty_process_groups() {
    let mut server =
        HeadlessServer::start_with("server-stop-ephemeral-job-control-group", true, &[]);
    let descendant_pid_file = server.dir.join("ephemeral-background-job.pid");
    let command = format!(
        concat!(
            "exec /bin/bash --noprofile --norc -i -c '",
            "trap \"\" HUP; ",
            "(trap \"\" HUP; while :; do sleep 60; done) & ",
            "printf \"%s\" \"$!\" > {}; wait'",
        ),
        descendant_pid_file.display()
    );
    let run = cli(&server, &["run", "--command", &command]);
    assert_success(&run);
    let surface = String::from_utf8(run.stdout).unwrap().trim().parse::<u64>().unwrap();
    let info = cli(&server, &["--json", "process-info", "--surface", &surface.to_string()]);
    assert_success(&info);
    let direct_pid = u32::try_from(
        serde_json::from_slice::<serde_json::Value>(&info.stdout).unwrap()["pid"].as_u64().unwrap(),
    )
    .unwrap();
    let descendant_pid = wait_for_pid_file(&descendant_pid_file, Duration::from_secs(5));
    let direct_pid_raw = libc::pid_t::try_from(direct_pid).unwrap();
    let descendant_pid_raw = libc::pid_t::try_from(descendant_pid).unwrap();
    // SAFETY: both fixture processes are live and owned by this test.
    let direct_group = unsafe { libc::getpgid(direct_pid_raw) };
    // SAFETY: both fixture processes are live and owned by this test.
    let descendant_group = unsafe { libc::getpgid(descendant_pid_raw) };
    // SAFETY: both fixture processes are live and owned by this test.
    let direct_session = unsafe { libc::getsid(direct_pid_raw) };
    // SAFETY: both fixture processes are live and owned by this test.
    let descendant_session = unsafe { libc::getsid(descendant_pid_raw) };

    let stop = cli(&server, &["--json", "server", "stop"]);

    assert_success(&stop);
    assert!(server.child.wait().unwrap().success());
    let deadline = Instant::now() + Duration::from_secs(1);
    while process_exists(descendant_pid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    let descendant_remained = process_exists(descendant_pid);
    if descendant_remained {
        // SAFETY: the live process and group belong to this isolated fixture.
        let _ = unsafe { libc::killpg(descendant_group, libc::SIGKILL) };
        // SAFETY: the live process belongs to this isolated fixture.
        let _ = unsafe { libc::kill(descendant_pid_raw, libc::SIGKILL) };
    }

    assert!(direct_group > 0);
    assert!(descendant_group > 0);
    assert_ne!(
        descendant_group, direct_group,
        "fixture background job did not enter a separate process group"
    );
    assert_eq!(
        descendant_session, direct_session,
        "fixture background job left the owned PTY session"
    );
    assert!(!process_exists(direct_pid));
    assert!(
        !descendant_remained,
        "server acknowledged shutdown while a background job in its PTY session remained alive"
    );
}

#[cfg(unix)]
#[test]
fn server_stop_drains_many_hosted_panes_before_acknowledging() {
    let mut server = HeadlessServer::start("server-stop-many-panes");
    let applied = cli(
        &server,
        &[
            "--json",
            "apply-layout",
            "--layout",
            r#"{"type":"stack","panes":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32],"expanded":1}"#,
        ],
    );
    assert_success(&applied);
    let applied: serde_json::Value = serde_json::from_slice(&applied.stdout).unwrap();
    let surfaces = applied["panes"].as_array().unwrap();
    assert_eq!(surfaces.len(), 32);
    let first_surface = surfaces[0]["surface"].as_u64().unwrap();
    let info = cli(&server, &["--json", "process-info", "--surface", &first_surface.to_string()]);
    assert_success(&info);
    let first_terminal_pid = u32::try_from(
        serde_json::from_slice::<serde_json::Value>(&info.stdout).unwrap()["pid"].as_u64().unwrap(),
    )
    .unwrap();
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&server.state, "main");
    let host_pids = terminal_host_pids(&host_root);
    assert_eq!(host_pids.len(), 32);

    let stop_started = Instant::now();
    let stop = cli(&server, &["--json", "server", "stop"]);

    assert_success(&stop);
    assert!(stop_started.elapsed() < Duration::from_secs(5));
    assert!(server.child.wait().unwrap().success());
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline
        && (host_pids.iter().copied().any(process_exists)
            || process_exists(first_terminal_pid)
            || process_group_exists(first_terminal_pid))
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!host_pids.iter().copied().any(process_exists));
    assert!(!process_exists(first_terminal_pid));
    assert!(!process_group_exists(first_terminal_pid));
    assert!(!server.socket.exists());
}

#[cfg(unix)]
#[test]
fn server_stop_falls_back_when_an_older_server_lacks_shutdown_capability() {
    let mut server = LegacyServerProcess::start("legacy-server-stop", "success", None);
    let descendant_pid = server.descendant_pid().unwrap();

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_success(&output);
    let status = server.child.wait().unwrap();
    assert_eq!(status.signal(), Some(libc::SIGKILL));
    let deadline = Instant::now() + Duration::from_secs(5);
    while process_exists(descendant_pid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!process_exists(descendant_pid));
}

#[cfg(unix)]
#[test]
fn server_stop_closes_exited_legacy_placeholders_without_a_pid() {
    let mut server =
        LegacyServerProcess::start("legacy-server-dead-placeholder", "dead-surface", None);

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_success(&output);
    let status = server.child.wait().unwrap();
    assert_eq!(status.signal(), Some(libc::SIGKILL));
}

#[cfg(unix)]
#[test]
fn published_host_launch_errors_reap_the_complete_pty_session() {
    let mut server = HeadlessServer::start_with(
        "published-host-launch-error",
        false,
        &[("CMUX_TUI_TEST_INVALID_HOST_READY", "1"), ("CMUX_TUI_TEST_HOST_READY_DELAY_MS", "500")],
    );
    let direct_pid_file = server.dir.join("failed-launch-direct.pid");
    let descendant_pid_file = server.dir.join("failed-launch-descendant.pid");
    let command = format!(
        "echo $$ > {}; trap '' HUP; (trap '' HUP; while :; do sleep 1; done) & echo $! > {}; wait",
        direct_pid_file.display(),
        descendant_pid_file.display()
    );

    let output = cli(&server, &["run", "--new-workspace", "--command", &command]);
    assert!(!output.status.success(), "injected invalid launch acknowledgement succeeded");
    let direct_pid = wait_for_pid_file(&direct_pid_file, Duration::from_secs(5));
    let descendant_pid = wait_for_pid_file(&descendant_pid_file, Duration::from_secs(5));
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&server.state, "main");
    let deadline = Instant::now() + Duration::from_secs(5);
    while (process_exists(direct_pid)
        || process_group_exists(direct_pid)
        || process_exists(descendant_pid)
        || !terminal_host_pids(&host_root).is_empty())
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    let cleaned = !process_exists(direct_pid)
        && !process_group_exists(direct_pid)
        && !process_exists(descendant_pid)
        && terminal_host_pids(&host_root).is_empty();

    let stop = cli(&server, &["--json", "server", "stop"]);
    assert_success(&stop);
    assert!(server.child.wait().unwrap().success());
    for pid in [direct_pid, descendant_pid] {
        if let Ok(pid) = libc::pid_t::try_from(pid) {
            // SAFETY: both PIDs came from this isolated test fixture.
            let _ = unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    }

    assert!(cleaned, "post-publication launch error left PTY ownership unreconciled");
}

#[cfg(unix)]
#[test]
fn legacy_stop_retains_pty_ownership_captured_before_surface_close() {
    let mut server =
        LegacyServerProcess::start("legacy-server-reparent-on-close", "reparent-on-close", None);
    let descendant_pid = wait_for_pid_file(&server.descendant_pid_file, Duration::from_secs(5));

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_success(&output);
    let status = server.child.wait().unwrap();
    assert_eq!(status.signal(), Some(libc::SIGKILL));
    let deadline = Instant::now() + Duration::from_secs(5);
    while process_exists(descendant_pid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        !process_exists(descendant_pid),
        "surface close reparented a captured PTY job outside the final server tree"
    );
}

#[cfg(target_os = "macos")]
#[test]
fn server_stop_handles_an_exited_unreaped_legacy_descendant() {
    let mut server = LegacyServerProcess::start("legacy-server-zombie-child", "zombie-child", None);
    let descendant_pid = server.descendant_pid().unwrap();

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_success(&output);
    let status = server.child.wait().unwrap();
    assert_eq!(status.signal(), Some(libc::SIGKILL));
    let deadline = Instant::now() + Duration::from_secs(5);
    while process_exists(descendant_pid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!process_exists(descendant_pid));
}

#[cfg(unix)]
#[test]
fn server_stop_reconciles_an_applied_legacy_close_that_returned_an_error() {
    let mut server = LegacyServerProcess::start(
        "legacy-server-applied-close-error",
        "applied-close-error",
        None,
    );
    let descendant_pid = server.descendant_pid().unwrap();

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_success(&output);
    let status = server.child.wait().unwrap();
    assert_eq!(status.signal(), Some(libc::SIGKILL));
    let deadline = Instant::now() + Duration::from_secs(5);
    while process_exists(descendant_pid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!process_exists(descendant_pid));
}

#[cfg(unix)]
#[test]
fn server_stop_reconnects_after_an_applied_legacy_close_drops_the_control_stream() {
    let mut server = LegacyServerProcess::start(
        "legacy-server-applied-close-disconnect",
        "applied-close-disconnect",
        None,
    );
    let descendant_pid = server.descendant_pid().unwrap();

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_success(&output);
    let status = server.child.wait().unwrap();
    assert_eq!(status.signal(), Some(libc::SIGKILL));
    let deadline = Instant::now() + Duration::from_secs(5);
    while process_exists(descendant_pid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!process_exists(descendant_pid));
}

#[cfg(unix)]
#[test]
fn server_stop_refuses_when_a_legacy_close_error_leaves_the_surface_present() {
    let mut server = LegacyServerProcess::start(
        "legacy-server-persistent-close-error",
        "persistent-close-error",
        None,
    );
    let descendant_pid = server.descendant_pid().unwrap();

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("could not close pane processes before stopping the older server")
    );
    assert!(server.child.try_wait().unwrap().is_none());
    assert!(process_exists(descendant_pid));
}

#[cfg(unix)]
#[test]
fn detached_legacy_stop_survives_the_calling_pane_process_exit() {
    let mut server = LegacyServerProcess::start("legacy-server-detached", "kill-caller", None);
    let descendant_pid = server.descendant_pid().unwrap();

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_eq!(output.status.signal(), Some(libc::SIGKILL));
    let status = server.child.wait().unwrap();
    assert_eq!(status.signal(), Some(libc::SIGKILL));
    let deadline = Instant::now() + Duration::from_secs(5);
    while process_exists(descendant_pid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!process_exists(descendant_pid));
}

#[cfg(unix)]
#[test]
fn server_stop_does_not_force_kill_a_compatible_server_after_shutdown_failure() {
    let mut server =
        LegacyServerProcess::start("server-shutdown-failure", "compatible-failure", None);

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("could not stop cleanly"));
    assert!(server.child.try_wait().unwrap().is_none());
}

#[cfg(unix)]
#[test]
fn server_stop_does_not_force_kill_a_mismatched_modern_server_after_shutdown_failure() {
    let mut server = LegacyServerProcess::start(
        "mismatched-server-shutdown-failure",
        "mismatched-modern-failure",
        None,
    );

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("could not stop cleanly"));
    assert!(server.child.try_wait().unwrap().is_none());
}

#[cfg(unix)]
#[test]
fn server_stop_does_not_signal_an_older_server_when_pane_cleanup_fails() {
    let mut server =
        LegacyServerProcess::start("legacy-server-cleanup-failure", "cleanup-failure", None);
    let descendant_pid = server.descendant_pid().unwrap();

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("could not close pane processes before stopping the older server")
    );
    assert!(server.child.try_wait().unwrap().is_none());
    assert!(process_exists(descendant_pid));
}

#[cfg(unix)]
#[test]
fn server_stop_refuses_an_older_browser_without_target_confirmation() {
    let mut server = LegacyServerProcess::start("legacy-server-browser", "browser-surface", None);

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("could not close pane processes before stopping the older server")
    );
    assert!(server.child.try_wait().unwrap().is_none());
}

#[cfg(unix)]
#[test]
fn server_stop_refuses_a_legacy_server_that_spoofs_another_process_id() {
    let mut victim =
        Command::new("yes").stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
    let mut server =
        LegacyServerProcess::start("legacy-server-spoofed-pid", "spoofed-pid", Some(victim.id()));

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("reported process does not own its socket")
    );
    assert!(victim.try_wait().unwrap().is_none());
    assert!(server.child.try_wait().unwrap().is_none());
    victim.kill().unwrap();
    victim.wait().unwrap();
}

#[cfg(unix)]
#[test]
fn surface_attach_uses_the_full_terminal_and_attaches_only_its_target() {
    let server = HeadlessServer::start("single-surface-attach");
    let created = cli(&server, &["new-workspace", "--name", "single"]);
    assert_success(&created);
    let target = String::from_utf8(created.stdout).unwrap().trim().parse::<u64>().unwrap();
    let tree = cli(&server, &["--json", "list-workspaces"]);
    assert_success(&tree);
    let tree: serde_json::Value = serde_json::from_slice(&tree.stdout).unwrap();
    let pane = tree["workspaces"][0]["screens"][0]["panes"][0]["id"].as_u64().unwrap();
    let second = cli(&server, &["new-tab", "--pane", &pane.to_string()]);
    assert_success(&second);

    let mut tui = PtyChild::start(&[
        "attach",
        "--socket",
        server.socket.to_str().unwrap(),
        "--surface",
        &target.to_string(),
    ]);
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(status) = tui.child.try_wait().unwrap() {
            panic!("single-surface attach exited unexpectedly: {status}");
        }
        let clients = cli(&server, &["--json", "list-clients"]);
        if clients.status.success() {
            let clients: serde_json::Value = serde_json::from_slice(&clients.stdout).unwrap();
            if let Some(client) = clients
                .as_array()
                .unwrap()
                .iter()
                .find(|client| client["kind"].as_str() == Some("tui"))
            {
                if client["attached"].as_array().is_some_and(Vec::is_empty) {
                    std::thread::sleep(Duration::from_millis(50));
                    continue;
                }
                assert_eq!(client["attached"], serde_json::json!([target]));
                let Some(size) = client["sizes"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|size| size["surface"].as_u64() == Some(target))
                else {
                    std::thread::sleep(Duration::from_millis(50));
                    continue;
                };
                assert_eq!(size["cols"].as_u64(), Some(80));
                assert_eq!(size["rows"].as_u64(), Some(24));
                let closed = cli(&server, &["close-surface", "--surface", &target.to_string()]);
                assert_success(&closed);
                let exit_deadline = Instant::now() + Duration::from_secs(5);
                while Instant::now() < exit_deadline {
                    if let Some(status) = tui.child.try_wait().unwrap() {
                        assert!(status.success(), "single-surface attach exited with {status}");
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(25));
                }
                panic!("single-surface attach stayed open after its terminal closed");
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    panic!("single-surface attach never registered its target");
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
        if let Some(status) = tui.child.try_wait().unwrap() {
            assert!(!status.success(), "server launch unexpectedly succeeded");
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    panic!("configured WebSocket server attached instead of preserving server mode");
}

#[cfg(unix)]
#[test]
fn client_sizing_rejects_protocol_9_without_forwarding_mutation() {
    let dir = unique_temp_dir("protocol-9-client-sizing");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (commands_tx, commands_rx) = mpsc::channel();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let mut writer = stream.try_clone().unwrap();
        let mut reader = BufReader::new(stream);
        let mut commands = Vec::new();
        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {}
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    break;
                }
                Err(error) => panic!("protocol 9 test server read failed: {error}"),
            }
            let request: serde_json::Value = serde_json::from_str(&line).unwrap();
            let command = request["cmd"].as_str().unwrap().to_string();
            commands.push(command.clone());
            let id = request["id"].as_u64().unwrap();
            let response = if command == "identify" {
                serde_json::json!({
                    "id": id,
                    "ok": true,
                    "data": {
                        "app": "cmux-tui",
                        "protocol": 9,
                        "capabilities": []
                    }
                })
            } else {
                serde_json::json!({"id": id, "ok": true, "data": {}})
            };
            writeln!(writer, "{response}").unwrap();
        }
        commands_tx.send(commands).unwrap();
    });

    let output = Command::new(bin())
        .args(["--socket"])
        .arg(&socket)
        .args(["set-client-sizing", "--surface", "9", "--client", "7", "--enabled", "false"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    let commands = commands_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    server.join().unwrap();
    fs::remove_dir_all(dir).unwrap();

    assert!(!output.status.success(), "protocol 9 sizing mutation unexpectedly succeeded");
    assert!(String::from_utf8_lossy(&output.stderr).contains("requires protocol 10"));
    assert_eq!(commands, vec!["identify"]);
}

#[test]
fn cli_verbs_cover_command_output_errors_and_streams() {
    let server = HeadlessServer::start("matrix");

    let identify = cli(&server, &["identify"]);
    assert_success(&identify);
    let identify = String::from_utf8(identify.stdout).unwrap();
    assert!(identify.starts_with("cmux-tui session=main protocol="));
    assert!(identify.contains(" pid="));
    assert!(identify.contains(" version="));

    let identify_json = cli(&server, &["--json", "identify"]);
    assert_success(&identify_json);
    let value: serde_json::Value = serde_json::from_slice(&identify_json.stdout).unwrap();
    assert_eq!(value.get("app").and_then(|v| v.as_str()), Some("cmux-tui"));
    assert!(value.get("protocol").and_then(|v| v.as_u64()).unwrap_or(0) >= 5);

    let ping_json = cli(&server, &["--json", "ping"]);
    assert_success(&ping_json);
    let ping: serde_json::Value = serde_json::from_slice(&ping_json.stdout).unwrap();
    assert_eq!(ping.get("ok").and_then(|v| v.as_bool()), Some(true));
    assert_eq!(ping.get("protocol").and_then(|v| v.as_u64()), Some(10));

    let client_info =
        cli(&server, &["set-client-info", "--name", "one-shot", "--kind", "cli-test"]);
    assert_success(&client_info);

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

    let sizing_workspace = cli(&server, &["new-workspace", "--name", "cli-test"]);
    assert_success(&sizing_workspace);
    let sizing_surface =
        String::from_utf8(sizing_workspace.stdout).unwrap().trim().parse::<u64>().unwrap();
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

    let clients = cli(&server, &["--json", "list-clients"]);
    assert_success(&clients);
    let clients_json: serde_json::Value = serde_json::from_slice(&clients.stdout).unwrap();
    let target_id = clients_json
        .as_array()
        .unwrap()
        .iter()
        .find(|client| client["name"] == "cli-detach-target")
        .unwrap()["client"]
        .as_u64()
        .unwrap();
    let clients_human = cli(&server, &["list-clients"]);
    assert_success(&clients_human);
    assert!(String::from_utf8_lossy(&clients_human.stdout).contains("connected="));
    assert!(String::from_utf8_lossy(&clients_human.stdout).contains(":sizing=true"));
    let excluded = cli(
        &server,
        &[
            "set-client-sizing",
            "--surface",
            &sizing_surface.to_string(),
            "--client",
            &target_id.to_string(),
            "--enabled",
            "false",
        ],
    );
    assert_success(&excluded);
    let clients = cli(&server, &["--json", "list-clients"]);
    assert_success(&clients);
    let clients_json: serde_json::Value = serde_json::from_slice(&clients.stdout).unwrap();
    assert_eq!(
        clients_json
            .as_array()
            .unwrap()
            .iter()
            .find(|client| client["client"] == target_id)
            .unwrap()["sizes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|size| size["surface"] == sizing_surface)
            .unwrap()["size_participating"],
        false
    );
    let detached = cli(&server, &["detach-client", "--client", &target_id.to_string()]);
    assert_success(&detached);
    loop {
        target_response.clear();
        if target_reader.read_line(&mut target_response).unwrap() == 0 {
            break;
        }
    }

    let title = cli(&server, &["set-window-title", "--title", "hello"]);
    assert_success(&title);
    assert!(title.stdout.is_empty(), "set-window-title should be quiet on success");

    let surface = sizing_surface;
    assert!(surface > 0, "new-workspace should print the new surface id");
    let tree = cli(&server, &["--json", "list-workspaces"]);
    assert_success(&tree);
    let tree_json: serde_json::Value = serde_json::from_slice(&tree.stdout).unwrap();
    let pane0 = tree_json["workspaces"][0]["screens"][0]["panes"][0]["id"].as_u64().unwrap();

    let split = cli(&server, &["split", "--pane", &pane0.to_string(), "--dir", "right"]);
    assert_success(&split);

    let tree = cli(&server, &["--json", "list-workspaces"]);
    assert_success(&tree);
    let tree_json: serde_json::Value = serde_json::from_slice(&tree.stdout).unwrap();
    let pane1 = tree_json["workspaces"][0]["screens"][0]["panes"][1]["id"].as_u64().unwrap();
    let new_pane = cli(&server, &["new-pane", "--pane", &pane1.to_string()]);
    assert_success(&new_pane);

    let exported = cli(&server, &["--json", "export-layout"]);
    assert_success(&exported);
    let exported_json: serde_json::Value = serde_json::from_slice(&exported.stdout).unwrap();
    assert_eq!(exported_json["layout"]["type"].as_str(), Some("split"));
    assert_eq!(exported_json["panes"].as_array().unwrap().len(), 3);
    let split_id = exported_json["layout"]["split"].as_u64().unwrap();

    let exact_ratio =
        cli(&server, &["set-split-ratio", "--split", &split_id.to_string(), "--ratio", "0.7"]);
    assert_success(&exact_ratio);
    let exported = cli(&server, &["--json", "export-layout"]);
    let exported_json: serde_json::Value = serde_json::from_slice(&exported.stdout).unwrap();
    assert_eq!(exported_json["layout"]["split"].as_u64(), Some(split_id));
    let ratio = exported_json["layout"]["ratio"].as_f64().unwrap();
    assert!((ratio - 0.7).abs() < 0.0001, "layout ratio was {ratio}");

    let legacy_ratio = cli(
        &server,
        &["set-ratio", "--pane", &pane0.to_string(), "--dir", "right", "--ratio", "0.6"],
    );
    assert_success(&legacy_ratio);

    let neighbor =
        cli(&server, &["--json", "pane-neighbor", "--pane", &pane0.to_string(), "--dir", "right"]);
    assert_success(&neighbor);
    let neighbor_json: serde_json::Value = serde_json::from_slice(&neighbor.stdout).unwrap();
    let neighboring_pane = neighbor_json["pane"].as_u64().unwrap();
    assert_ne!(pane0, neighboring_pane);

    let focus = cli(
        &server,
        &["--json", "focus-direction", "--pane", &pane0.to_string(), "--dir", "right"],
    );
    assert_success(&focus);
    let focus_json: serde_json::Value = serde_json::from_slice(&focus.stdout).unwrap();
    assert_ne!(focus_json["pane"].as_u64(), Some(pane0));

    let zoom =
        cli(&server, &["--json", "zoom-pane", "--pane", &pane1.to_string(), "--mode", "toggle"]);
    assert_success(&zoom);
    let zoom_json: serde_json::Value = serde_json::from_slice(&zoom.stdout).unwrap();
    assert_eq!(zoom_json["zoomed"].as_bool(), Some(true));
    assert_eq!(zoom_json["zoomed_pane"].as_u64(), Some(pane1));

    let marker = format!("cmux_cli_marker_{}", std::process::id());
    let send = cli(
        &server,
        &["send", "--surface", &surface.to_string(), "--text", &format!("echo {marker}\r")],
    );
    assert_success(&send);
    assert!(send.stdout.is_empty(), "mutating commands should be quiet on success");
    let screen = wait_for_screen(&server, surface, &marker);
    assert!(screen.contains(&marker), "screen did not contain marker; got {screen:?}");

    let ids_json = cli(&server, &["--json", "ids", "--kind", "surface"]);
    assert_success(&ids_json);
    let ids: serde_json::Value = serde_json::from_slice(&ids_json.stdout).unwrap();
    assert!(ids["ids"].as_array().unwrap().iter().any(|item| item["id"].as_u64() == Some(surface)));

    let copied = cli(&server, &["copy", "--surface", &surface.to_string(), "--mode", "screen"]);
    assert_success(&copied);
    assert!(String::from_utf8_lossy(&copied.stdout).contains(&marker));

    let notify = cli(&server, &["notify", "--title", "Build", "--body", "ok"]);
    assert_success(&notify);
    assert!(String::from_utf8_lossy(&notify.stdout).trim().parse::<u64>().unwrap() > 0);

    let report = cli(
        &server,
        &[
            "report-agent",
            "--surface",
            &surface.to_string(),
            "--state",
            "working",
            "--source",
            "socket",
            "--session",
            "cli",
        ],
    );
    assert_success(&report);
    let agents = cli(&server, &["--json", "list-agents", "--surface", &surface.to_string()]);
    assert_success(&agents);
    let agents: serde_json::Value = serde_json::from_slice(&agents.stdout).unwrap();
    assert_eq!(agents["agents"][0]["state"].as_str(), Some("working"));

    let send_key = cli(&server, &["send-key", "--surface", &surface.to_string(), "enter"]);
    assert_success(&send_key);

    let select_bare = cli(&server, &["select-tab"]);
    assert_eq!(select_bare.status.code(), Some(2));

    let close = cli(&server, &["close-surface", "--surface", &surface.to_string()]);
    assert_success(&close);
    let closed_read = cli(&server, &["read-screen", "--surface", &surface.to_string()]);
    assert_eq!(closed_read.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&closed_read.stderr).contains("unknown surface"));

    let bogus = Command::new(bin())
        .args(["--socket"])
        .arg(server.dir.join("missing.sock"))
        .arg("identify")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_eq!(bogus.status.code(), Some(3));

    assert_subscribe_reports_tree_changed(&server);
}

#[test]
fn cli_apply_layout_passes_explicit_surface_size() {
    let server = HeadlessServer::start("apply-layout-size");
    let applied = cli(
        &server,
        &[
            "--json",
            "apply-layout",
            "--layout",
            r#"{"type":"leaf"}"#,
            "--cols",
            "111",
            "--rows",
            "37",
        ],
    );
    assert_success(&applied);
    let applied: serde_json::Value = serde_json::from_slice(&applied.stdout).unwrap();
    let surface = applied["panes"][0]["surface"].as_u64().unwrap();

    let state = cli(&server, &["--json", "vt-state", "--surface", &surface.to_string()]);
    assert_success(&state);
    let state: serde_json::Value = serde_json::from_slice(&state.stdout).unwrap();
    assert_eq!(state["cols"].as_u64(), Some(111));
    assert_eq!(state["rows"].as_u64(), Some(37));

    let inherited = cli(&server, &["new-workspace"]);
    assert_success(&inherited);
    let inherited = String::from_utf8(inherited.stdout).unwrap().trim().parse::<u64>().unwrap();
    let state = cli(&server, &["--json", "vt-state", "--surface", &inherited.to_string()]);
    assert_success(&state);
    let state: serde_json::Value = serde_json::from_slice(&state.stdout).unwrap();
    assert_eq!(state["cols"].as_u64(), Some(111));
    assert_eq!(state["rows"].as_u64(), Some(37));

    let partial = cli(&server, &["apply-layout", "--layout", r#"{"type":"leaf"}"#, "--cols", "90"]);
    assert_eq!(partial.status.code(), Some(2));
}

fn assert_subscribe_reports_tree_changed(server: &HeadlessServer) {
    let mut child = Command::new(bin())
        .args(["--socket"])
        .arg(&server.socket)
        .arg("subscribe")
        .env_remove("CMUX_TUI_SOCKET")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            if tx.send(line.unwrap()).is_err() {
                break;
            }
        }
    });

    std::thread::sleep(Duration::from_millis(200));
    let tab = cli(server, &["new-tab"]);
    assert_success(&tab);

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut lines = Vec::new();
    while Instant::now() < deadline {
        if let Ok(line) = rx.recv_timeout(Duration::from_millis(250)) {
            lines.push(line.clone());
            if line.contains("\"event\":\"tree-changed\"") {
                let _ = child.kill();
                let _ = child.wait();
                return;
            }
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    panic!("subscribe did not print tree-changed event; lines={lines:?}");
}

#[test]
fn stream_preserves_partial_line_across_read_timeout() {
    let dir = unique_temp_dir("partial-line");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        let read_half = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(read_half);
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        let request_json: serde_json::Value = serde_json::from_str(&request).unwrap();
        assert_eq!(request_json["cmd"].as_str(), Some("identify"));
        let release = cmux_tui_core::release::ReleaseIdentity::current(
            cmux_tui_core::server::PROTOCOL_VERSION,
        );
        writeln!(
            stream,
            "{}",
            serde_json::json!({
                "id": request_json["id"],
                "ok": true,
                "data": {
                    "app": "cmux-tui",
                    "version": release.version,
                    "build_commit": release.build_commit,
                    "ghostty_commit": release.ghostty_commit,
                    "protocol": release.protocol,
                    "capabilities": [],
                    "session": "test",
                    "pid": std::process::id(),
                },
            })
        )
        .unwrap();

        request.clear();
        reader.read_line(&mut request).unwrap();
        assert!(request.contains("\"cmd\":\"subscribe\""));

        stream.write_all(br#"{"event":"status","message":""#).unwrap();
        stream.flush().unwrap();
        std::thread::sleep(Duration::from_millis(350));
        stream.write_all(br#"split-line-ok"}"#).unwrap();
        stream.write_all(b"\n").unwrap();
        stream.flush().unwrap();
    });

    let output = Command::new(bin())
        .args(["--socket"])
        .arg(&socket)
        .arg("subscribe")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    server.join().unwrap();
    let _ = fs::remove_file(&socket);
    let _ = fs::remove_dir_all(&dir);

    assert_success(&output);
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        "{\"event\":\"status\",\"message\":\"split-line-ok\"}\n"
    );
}

#[test]
fn help_lists_plugin_verbs() {
    let output = Command::new(bin()).arg("--help").env_remove("CMUX_TUI_SOCKET").output().unwrap();
    assert_success(&output);
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("plugin install <git-url>"));
    assert!(stdout.contains("plugin use --builtin"));
    assert!(stdout.contains("Manage installed sidebar plugins locally."));
    assert!(stdout.contains("--ws <addr>"));
    assert!(stdout.contains("--ws-token <token>"));
    assert!(stdout.contains("--ws-insecure-bind"));
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
            "--socket",
            missing_socket.to_str().unwrap(),
            "plugin",
            "install",
            &url,
            "--name",
            "fixture",
        ],
    );
    assert_success(&install);
    assert!(String::from_utf8_lossy(&install.stdout).contains("next: cmux-tui plugin use fixture"));
    let installed_dir = data_home.join("cmux").join("mux-plugins").join("fixture");
    assert!(installed_dir.join("cmux-plugin.toml").is_file());

    let list = plugin_cli(&data_home, &config_path, &["--json", "plugin", "list"]);
    assert_success(&list);
    let listed: serde_json::Value = serde_json::from_slice(&list.stdout).unwrap();
    assert_eq!(listed["plugins"][0]["name"].as_str(), Some("fixture"));
    assert_eq!(listed["plugins"][0]["selected"].as_bool(), Some(false));

    let use_plugin = plugin_cli(
        &data_home,
        &config_path,
        &["--socket", missing_socket.to_str().unwrap(), "plugin", "use", "fixture"],
    );
    assert_success(&use_plugin);
    let stdout = String::from_utf8(use_plugin.stdout).unwrap();
    assert!(stdout.contains("using fixture"));
    assert!(stdout.contains("reload-config: not sent"));

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

    let list = plugin_cli(&data_home, &config_path, &["--json", "plugin", "list"]);
    assert_success(&list);
    let listed: serde_json::Value = serde_json::from_slice(&list.stdout).unwrap();
    assert_eq!(listed["plugins"][0]["selected"].as_bool(), Some(true));

    let builtin = plugin_cli(
        &data_home,
        &config_path,
        &["--socket", missing_socket.to_str().unwrap(), "plugin", "use", "--builtin"],
    );
    assert_success(&builtin);
    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&config_path).unwrap()).unwrap();
    assert!(written["sidebar"].get("plugin").is_none());
    assert_eq!(written["future"]["keep"].as_bool(), Some(true));

    let _ = fs::remove_dir_all(&dir);
}

fn wait_for_screen(server: &HeadlessServer, surface: u64, marker: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut last = String::new();
    while Instant::now() < deadline {
        let output = cli(server, &["read-screen", "--surface", &surface.to_string()]);
        assert_success(&output);
        last = String::from_utf8(output.stdout).unwrap();
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

fn cli(server: &HeadlessServer, args: &[&str]) -> Output {
    Command::new(bin())
        .args(["--socket"])
        .arg(&server.socket)
        .args(args)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap()
}

fn assert_success(output: &Output) {
    assert!(
        output.status.success(),
        "expected success, got status {:?}\nstdout:\n{}\nstderr:\n{}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn unique_temp_dir(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-cli-{name}-{}-{stamp}", std::process::id()))
}

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}
