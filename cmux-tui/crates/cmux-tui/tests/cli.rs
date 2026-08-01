#[cfg(unix)]
use std::ffi::CStr;
use std::fs;
#[cfg(unix)]
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::os::fd::AsRawFd;
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
            if transport::connect(&self.socket).is_ok() {
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

#[cfg(unix)]
#[test]
fn server_establishes_shutdown_ownership_before_publishing_its_listener() {
    let dir = unique_temp_dir("watchdog-start-failure");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let marker = dir.join("watchdog-starting");
    let mut child = Command::new(bin())
        .args(["--headless", "--ephemeral", "--socket"])
        .arg(&socket)
        .env("CMUX_TUI_TEST_WATCHDOG_START_FAILURE", &marker)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    let marker_deadline = Instant::now() + Duration::from_secs(15);
    while !marker.exists() && Instant::now() < marker_deadline {
        assert!(
            child.try_wait().unwrap().is_none(),
            "server exited before entering the watchdog failure hook"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(marker.exists(), "watchdog failure hook was not reached");
    let listener_was_published = socket.exists();

    let exit_deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= exit_deadline {
            child.kill().unwrap();
            break child.wait().unwrap();
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let _ = fs::remove_file(&socket);
    let _ = fs::remove_dir_all(&dir);

    assert!(!status.success(), "forced watchdog failure unexpectedly started the server");
    assert!(
        !listener_was_published,
        "server accepted clients before its shutdown watchdog owned cleanup"
    );
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

#[cfg(target_os = "linux")]
fn process_is_active(pid: u32) -> bool {
    let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) else {
        return false;
    };
    stat.rsplit_once(") ")
        .and_then(|(_, fields)| fields.split_whitespace().next())
        .map_or_else(|| process_exists(pid), |state| state != "Z")
}

#[cfg(all(unix, not(target_os = "linux")))]
fn process_is_active(pid: u32) -> bool {
    process_exists(pid)
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
        Self::start_with_surface_pid(name, scenario, reported_pid, None)
    }

    fn start_with_surface_pid(
        name: &str,
        scenario: &str,
        reported_pid: Option<u32>,
        surface_pid: Option<u32>,
    ) -> Self {
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
        if let Some(surface_pid) = surface_pid {
            command.env("CMUX_TUI_TEST_LEGACY_SURFACE_PID", surface_pid.to_string());
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
    let reported_surface_pid = std::env::var("CMUX_TUI_TEST_LEGACY_SURFACE_PID")
        .ok()
        .map(|value| value.parse::<u32>().unwrap());
    let mut reparent_on_close = None;
    if matches!(
        scenario.as_str(),
        "success"
            | "kill-caller"
            | "cleanup-failure"
            | "applied-close-error"
            | "applied-close-disconnect"
            | "exit-after-close"
            | "persistent-close-error"
            | "concurrent-client"
            | "draining-client"
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
    } else if scenario == "dead-owned-surface" {
        let mut command = Command::new("/bin/bash");
        command
            .args([
                "--noprofile",
                "--norc",
                "-c",
                concat!(
                    "trap '' HUP; ",
                    "(trap '' HUP; while :; do sleep 60; done) & ",
                    "printf '%s' \"$!\" > \"$CMUX_TUI_TEST_LEGACY_DESCENDANT_PID_FILE\""
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
        let mut direct = command.spawn().unwrap();
        assert!(direct.wait().unwrap().success());
        let pid_file =
            PathBuf::from(std::env::var_os("CMUX_TUI_TEST_LEGACY_DESCENDANT_PID_FILE").unwrap());
        let _ = wait_for_pid_file(&pid_file, Duration::from_secs(5));
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
    let mut list_client_scans = 0;
    'snapshots: loop {
        request.clear();
        if reader.read_line(&mut request).unwrap() == 0 {
            loop {
                std::thread::park();
            }
        }
        let list_request: serde_json::Value = serde_json::from_str(&request).unwrap();
        if list_request["cmd"].as_str() == Some("list-clients") {
            list_client_scans += 1;
            let mut clients = vec![serde_json::json!({
                "client": 1,
                "transport": "unix",
                "self": true,
            })];
            if scenario == "concurrent-client"
                || (scenario == "draining-client" && list_client_scans == 1)
            {
                clients.push(serde_json::json!({
                    "client": 2,
                    "transport": "unix",
                    "self": false,
                }));
            }
            writeln!(
                stream,
                "{}",
                serde_json::json!({
                    "id": list_request["id"],
                    "ok": true,
                    "data": clients,
                })
            )
            .unwrap();
            continue;
        }
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
                | "exit-after-close"
                | "persistent-close-error"
                | "concurrent-client"
                | "draining-client"
                | "zombie-child"
                | "reparent-on-close"
                | "unowned-surface"
                | "browser-surface"
                | "dead-surface"
                | "dead-owned-surface"
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
                } else if matches!(scenario.as_str(), "dead-surface" | "dead-owned-surface") {
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
                } else if let Some(pid) = reported_surface_pid {
                    Some(pid)
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
            if scenario == "exit-after-close" {
                drop(reader);
                drop(stream);
                drop(listener);
                let _ = fs::remove_file(&socket);
                return;
            }
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
fn newer_workspace_schema_failure_reports_socket_specific_recovery() {
    let dir = unique_temp_dir("newer-workspace-schema-recovery");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("future session.sock");
    let state = dir.join("state");
    let home = dir.join("home");
    fs::create_dir_all(&home).unwrap();
    let session = "schema-{found}";

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
    fn accept_with_deadline(listener: &UnixListener) -> std::os::unix::net::UnixStream {
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
    assert!(
        english.contains("no server is listening on this socket; nothing needs to be stopped"),
        "{english}"
    );
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
    assert!(
        japanese.contains("このソケットを待ち受けているサーバーはありません。停止は不要です"),
        "{japanese}"
    );
    assert!(!japanese.contains("session current shutdown --force"), "{japanese}");
    assert!(japanese.contains("保存状態には新しい cmux が必要です"), "{japanese}");

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

#[cfg(unix)]
fn open_test_pty() -> (File, File) {
    static PTY_NAME_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    let _name_lock = PTY_NAME_LOCK.lock().unwrap();
    let master_fd = unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC) };
    assert_ne!(master_fd, -1, "posix_openpt failed: {}", std::io::Error::last_os_error());
    let master = unsafe { File::from_raw_fd(master_fd) };
    let master_flags = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_GETFD) };
    assert_ne!(
        master_flags,
        -1,
        "fcntl(F_GETFD) failed for PTY master: {}",
        std::io::Error::last_os_error()
    );
    assert_ne!(master_flags & libc::FD_CLOEXEC, 0, "PTY master was created without close-on-exec");
    assert_eq!(
        unsafe { libc::grantpt(master.as_raw_fd()) },
        0,
        "grantpt failed: {}",
        std::io::Error::last_os_error()
    );
    assert_eq!(
        unsafe { libc::unlockpt(master.as_raw_fd()) },
        0,
        "unlockpt failed: {}",
        std::io::Error::last_os_error()
    );
    let slave_name = unsafe { libc::ptsname(master.as_raw_fd()) };
    assert!(!slave_name.is_null(), "ptsname failed: {}", std::io::Error::last_os_error());
    let slave_name = unsafe { CStr::from_ptr(slave_name) }.to_owned();
    let slave_fd =
        unsafe { libc::open(slave_name.as_ptr(), libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC) };
    assert_ne!(slave_fd, -1, "open PTY slave failed: {}", std::io::Error::last_os_error());
    let slave = unsafe { File::from_raw_fd(slave_fd) };
    let size = libc::winsize { ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0 };
    assert_ne!(
        unsafe { libc::ioctl(slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
        -1,
        "set PTY size failed: {}",
        std::io::Error::last_os_error()
    );
    (master, slave)
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
        let (mut master, slave) = open_test_pty();
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
struct DisconnectablePtyChild {
    child: Child,
    disconnect: Option<mpsc::Sender<()>>,
    master_drain: Option<std::thread::JoinHandle<()>>,
}

#[cfg(unix)]
impl DisconnectablePtyChild {
    fn start(args: &[&str]) -> Self {
        let (mut master, slave) = open_test_pty();
        let child = Command::new(bin())
            .args(args)
            .env_remove("CMUX_TUI_SOCKET")
            .stdin(Stdio::from(slave.try_clone().unwrap()))
            .stdout(Stdio::from(slave.try_clone().unwrap()))
            .stderr(Stdio::from(slave))
            .spawn()
            .unwrap();
        let status_flags = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_GETFL) };
        assert_ne!(
            status_flags,
            -1,
            "fcntl(F_GETFL) failed for PTY master: {}",
            std::io::Error::last_os_error()
        );
        assert_ne!(
            unsafe {
                libc::fcntl(master.as_raw_fd(), libc::F_SETFL, status_flags | libc::O_NONBLOCK)
            },
            -1,
            "fcntl(F_SETFL) failed for PTY master: {}",
            std::io::Error::last_os_error()
        );
        let (disconnect, disconnected) = mpsc::channel();
        let master_drain = std::thread::spawn(move || {
            let mut buffer = [0; 8192];
            loop {
                if disconnected.try_recv().is_ok() {
                    break;
                }
                match master.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        match disconnected.recv_timeout(Duration::from_millis(10)) {
                            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                            Err(mpsc::RecvTimeoutError::Timeout) => {}
                        }
                    }
                    Err(_) => break,
                }
            }
        });
        Self { child, disconnect: Some(disconnect), master_drain: Some(master_drain) }
    }

    fn disconnect_host_terminal(&mut self) {
        if let Some(disconnect) = self.disconnect.take() {
            let _ = disconnect.send(());
        }
        if let Some(master_drain) = self.master_drain.take() {
            master_drain.join().unwrap();
        }
    }
}

#[cfg(unix)]
impl Drop for DisconnectablePtyChild {
    fn drop(&mut self) {
        self.disconnect_host_terminal();
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(unix)]
#[test]
fn startup_config_helper_inherits_no_provider_secrets() {
    let dir = unique_temp_dir("provider-secret-config-helper");
    fs::create_dir_all(&dir).unwrap();
    let helper = dir.join("ghostty-secret-probe");
    let capture = dir.join("inherited-env.txt");
    let socket = dir.join("mux.sock");
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
        .args(["--machine-provider", "/does/not/exist", "--headless", "--socket"])
        .arg(&socket)
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
        let clients = json_cli(&server, &["client", "list"]);
        if clients.status.success() {
            let clients = json_output(&clients);
            if clients
                .as_array()
                .unwrap()
                .iter()
                .any(|client| client["client_kind"].as_str() == Some("tui"))
            {
                return;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    panic!("plain launch never attached as a TUI client");
}

#[cfg(target_os = "linux")]
#[test]
fn plain_launch_preserves_the_existing_session_connect_deadline() {
    let dir = unique_temp_dir("saturated-existing-session");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    // SAFETY: listener owns a valid listening Unix socket. Reapplying listen
    // only narrows its pending connection queue for this isolated fixture.
    assert_eq!(unsafe { libc::listen(listener.as_raw_fd(), 0) }, 0);

    let mut queued = Vec::new();
    for _ in 0..32 {
        match transport::connect_until(&socket, Instant::now() + Duration::from_millis(75)) {
            Ok(stream) => queued.push(stream),
            Err(error) => {
                assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
                break;
            }
        }
    }
    assert!(queued.len() < 32, "could not saturate the existing session listener");

    let mut launch = Command::new(bin())
        .args(["--ephemeral", "--socket"])
        .arg(&socket)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    let status = loop {
        if let Some(status) = launch.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = launch.kill();
            let _ = launch.wait();
            panic!("plain launch exceeded the existing-session connection deadline");
        }
        std::thread::sleep(Duration::from_millis(10));
    };

    assert!(!status.success(), "plain launch replaced a live saturated session");
    assert!(socket.exists(), "plain launch unlinked the live saturated session socket");
    drop(queued);
    drop(listener);
    fs::remove_file(socket).unwrap();
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn plain_launch_reports_an_incompatible_server_without_reconnecting() {
    let dir = unique_temp_dir("incompatible-server");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let (accepted_tx, accepted_rx) = mpsc::sync_channel(1);
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
                "protocol": 8,
            },
        });
        writeln!(stream, "{response}").unwrap();
        let _cleanup_or_duplicate = listener.accept().unwrap();
        accepted_tx.send(()).unwrap();
    });

    let output = Command::new(bin())
        .args(["--socket"])
        .arg(&socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    let reconnected = accepted_rx.recv_timeout(Duration::from_millis(250)).is_ok();
    if !reconnected {
        let _cleanup = transport::connect(&socket).unwrap();
        accepted_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    }
    server.join().unwrap();
    let _ = fs::remove_file(&socket);
    let _ = fs::remove_dir_all(&dir);

    assert_eq!(output.status.code(), Some(1));
    assert!(!reconnected, "plain startup opened a second connection after identifying the server");
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
fn incompatible_server_status_and_public_api_use_separate_compatibility_domains() {
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
            let response = if let Some(command) = request["cmd"].as_str() {
                commands.push(command.to_string());
                serde_json::json!({
                    "id": request["id"],
                    "ok": true,
                    "data": {
                        "app": "cmux-tui",
                        "session": "test",
                        "pid": 4242,
                        "version": "0.0.0-stale",
                        "protocol": cmux_tui_core::server::PROTOCOL_VERSION,
                    },
                })
            } else {
                commands.push(request["operation"].as_str().unwrap().to_string());
                serde_json::json!({
                    "protocol": "cmux.protocol/1",
                    "type": "response",
                    "id": request["id"],
                    "ok": true,
                    "result": {"alive": true},
                })
            };
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
        .args(["--json", "--socket"])
        .arg(&socket)
        .args(["raw", "command", "--request-json", r#"{"id":"identify","cmd":"identify"}"#])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&identify);
    assert_eq!(json_output(&identify)["version"], "0.0.0-stale");

    let ping = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&socket)
        .args(["session", "current", "ping"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&ping);
    assert_eq!(json_output(&ping)["alive"], true);

    assert_eq!(server.join().unwrap(), ["identify", "identify", "identify", "session.ping"]);
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
        .args(["--socket"])
        .arg(&socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("cmux server stop"), "{stderr}");
    assert!(stderr.contains("then rerun the previous command using `cmux`."), "{stderr}");
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
    assert!(
        String::from_utf8_lossy(&stop.stderr).contains("Stopping exits pane processes."),
        "direct server stop omitted its destructive-operation warning: {}",
        String::from_utf8_lossy(&stop.stderr)
    );
    assert!(server.child.wait().unwrap().success());
    assert!(!server.socket.exists());
}

#[test]
fn server_lifecycle_help_and_machine_rejection_are_localized() {
    let help = Command::new(bin())
        .env("LC_ALL", "ja_JP.UTF-8")
        .env("LC_MESSAGES", "ja_JP.UTF-8")
        .env("LANG", "ja_JP.UTF-8")
        .args(["server", "--help"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&help);
    let help = String::from_utf8(help.stdout).unwrap();
    assert!(help.contains("使用方法"), "{help}");
    assert!(help.contains("別のリリース"), "{help}");
    assert!(!help.contains("These local lifecycle commands"), "{help}");

    let rejected = Command::new(bin())
        .env("LC_ALL", "ja_JP.UTF-8")
        .env("LC_MESSAGES", "ja_JP.UTF-8")
        .env("LANG", "ja_JP.UTF-8")
        .args(["--machine", "remote", "server", "status"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_eq!(rejected.status.code(), Some(2));
    let rejected = String::from_utf8(rejected.stderr).unwrap();
    assert!(rejected.contains("--machine を使用できません"), "{rejected}");
    assert!(!rejected.contains("lifecycle commands cannot use"), "{rejected}");
}

#[cfg(unix)]
#[test]
fn signal_termination_completes_server_shutdown() {
    let dir = unique_temp_dir("server-signal-shutdown");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let mut server = Command::new(bin())
        .args(["--headless", "--ephemeral", "--socket"])
        .arg(&socket)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    wait_for_socket_path(&socket);

    assert_eq!(unsafe { libc::kill(server.id() as libc::pid_t, libc::SIGTERM) }, 0);
    let deadline = Instant::now() + Duration::from_secs(3);
    let status = loop {
        if let Some(status) = server.try_wait().unwrap() {
            break Some(status);
        }
        if Instant::now() >= deadline {
            server.kill().unwrap();
            let _ = server.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let socket_remained = socket.exists();
    fs::remove_dir_all(dir).unwrap();

    let status = status.expect("SIGTERM left the server waiting on an unrequested mux shutdown");
    assert!(status.success(), "signal-driven shutdown exited with {status}");
    assert!(!socket_remained, "signal-driven shutdown retained its control socket");
}

#[cfg(unix)]
#[test]
fn invalid_websocket_startup_returns_after_publishing_the_local_socket() {
    let dir = unique_temp_dir("invalid-websocket-startup");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let published = dir.join("published");
    let ghostty = dir.join("ghostty");
    fs::write(&ghostty, "#!/bin/sh\nprintf 'background = #272822\\nforeground = #fdfff1\\n'\n")
        .unwrap();
    fs::set_permissions(&ghostty, fs::Permissions::from_mode(0o700)).unwrap();
    let mut server = Command::new(bin())
        .args(["--headless", "--ephemeral", "--socket"])
        .arg(&socket)
        .args(["--ws", "not-an-address"])
        .env("GHOSTTY_BIN", &ghostty)
        .env("CMUX_TUI_TEST_LOCAL_SOCKET_PUBLISHED_MARKER", &published)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    let publication_deadline = Instant::now() + Duration::from_secs(15);
    while !published.exists() && Instant::now() < publication_deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(published.exists(), "invalid WebSocket setup did not publish its local socket");

    let deadline = Instant::now() + Duration::from_secs(3);
    let status = loop {
        if let Some(status) = server.try_wait().unwrap() {
            break Some(status);
        }
        if Instant::now() >= deadline {
            server.kill().unwrap();
            let _ = server.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let socket_remained = socket.exists();
    let mut stderr = String::new();
    server.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
    fs::remove_dir_all(dir).unwrap();

    let status = status.expect("invalid WebSocket setup entered the running-server shutdown wait");
    assert!(!status.success(), "invalid WebSocket setup unexpectedly succeeded");
    assert!(stderr.contains("invalid WebSocket address"), "{stderr}");
    assert!(!socket_remained, "failed startup retained its local control socket");
}

#[cfg(unix)]
#[test]
fn server_shutdown_exits_when_the_interactive_driver_cannot_progress() {
    let dir = unique_temp_dir("server-stop-blocked-interactive-driver");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let state = dir.join("state");
    let mut server = PtyChild::start_with_env(
        &["--socket", socket.to_str().unwrap(), "--state", state.to_str().unwrap()],
        &[
            ("CMUX_TUI_TEST_BLOCK_INTERACTIVE_DRIVER", std::ffi::OsStr::new("1")),
            ("CMUX_TUI_TEST_SHUTDOWN_EXIT_GRACE_MS", std::ffi::OsStr::new("100")),
        ],
    );
    wait_for_socket_path(&socket);

    let response = json_socket_request(&socket, serde_json::json!({"id": 1, "cmd": "shutdown"}));
    assert_eq!(response, serde_json::json!({}));

    let deadline = Instant::now() + Duration::from_secs(3);
    let status = loop {
        if let Some(status) = server.child.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "server remained alive after acknowledging shutdown");
        std::thread::sleep(Duration::from_millis(10));
    };
    assert!(status.success(), "server exited with {status}");
    assert!(transport::connect(&socket).is_err());
    drop(server);
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn forced_exit_waits_for_remote_runtime_cleanup() {
    let dir = unique_temp_dir("remote-cleanup-fence");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let state = dir.join("state");
    let remote_state = dir.join("remote-state");
    let remote_started = dir.join("remote-started");
    let remote_shutdown = dir.join("remote-shutdown");
    let mut server = PtyChild::start_with_env(
        &[
            "--socket",
            socket.to_str().unwrap(),
            "--state",
            state.to_str().unwrap(),
            "--remote",
            "--remote-state-dir",
            remote_state.to_str().unwrap(),
        ],
        &[
            ("CMUX_TUI_TEST_BLOCK_INTERACTIVE_DRIVER", std::ffi::OsStr::new("1")),
            ("CMUX_TUI_TEST_SHUTDOWN_EXIT_GRACE_MS", std::ffi::OsStr::new("100")),
            ("CMUX_TUI_TEST_REMOTE_RUNTIME_STARTED_MARKER", remote_started.as_os_str()),
            ("CMUX_TUI_TEST_REMOTE_SHUTDOWN_MARKER", remote_shutdown.as_os_str()),
            ("CMUX_TUI_TEST_REMOTE_SHUTDOWN_DELAY_MS", std::ffi::OsStr::new("500")),
        ],
    );
    wait_for_socket_path(&socket);
    let startup_deadline = Instant::now() + Duration::from_secs(10);
    while !remote_started.exists() {
        assert!(
            server.child.try_wait().unwrap().is_none(),
            "server exited before starting its remote runtime"
        );
        assert!(Instant::now() < startup_deadline, "remote runtime did not start");
        std::thread::sleep(Duration::from_millis(10));
    }

    let response = json_socket_request(&socket, serde_json::json!({"id": 1, "cmd": "shutdown"}));
    assert_eq!(response, serde_json::json!({}));
    std::thread::sleep(Duration::from_millis(250));
    assert_eq!(
        fs::read(&remote_shutdown).ok().as_deref(),
        Some(b"started".as_slice()),
        "remote runtime cleanup did not enter the process completion fence"
    );
    assert!(
        server.child.try_wait().unwrap().is_none(),
        "server forced exit before remote runtime cleanup completed"
    );

    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = server.child.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "server remained alive after remote cleanup");
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(fs::read(&remote_shutdown).unwrap(), b"complete");
    assert!(status.success(), "server exited with {status}");
    drop(server);
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn daemon_handoff_cleans_local_ptys_before_forcing_a_blocked_interactive_driver_to_exit() {
    let dir = unique_temp_dir("daemon-handoff-blocked-interactive-driver");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let pid_file = dir.join("local-pty.pid");
    let mut server = PtyChild::start_with_env(
        &["--socket", socket.to_str().unwrap(), "--ephemeral"],
        &[
            ("CMUX_TUI_TEST_BLOCK_INTERACTIVE_DRIVER", std::ffi::OsStr::new("1")),
            ("CMUX_TUI_TEST_SHUTDOWN_EXIT_GRACE_MS", std::ffi::OsStr::new("100")),
        ],
    );
    wait_for_socket_path(&socket);
    let command =
        format!("trap '' HUP TERM; echo $$ > {}; while :; do sleep 1; done", pid_file.display());
    let run = raw_cli_command(
        &socket,
        serde_json::json!({
            "id": "daemon-handoff-local-pty",
            "cmd": "run",
            "new_workspace": true,
            "command": command,
        }),
    )
    .output()
    .unwrap();
    assert_success(&run);
    let local_pid = wait_for_pid_file(&pid_file, Duration::from_secs(5));
    let identity = json_socket_request(&socket, serde_json::json!({"id": 1, "cmd": "identify"}));

    let response = json_socket_request(
        &socket,
        serde_json::json!({
            "id": 2,
            "cmd": "shutdown-daemon",
            "pid": identity["pid"],
            "generation": identity["generation"],
        }),
    );
    assert_eq!(response["accepted"], true);

    let deadline = Instant::now() + Duration::from_secs(3);
    let status = loop {
        if let Some(status) = server.child.try_wait().unwrap() {
            break status;
        }
        assert!(
            Instant::now() < deadline,
            "server remained alive after acknowledging daemon handoff"
        );
        std::thread::sleep(Duration::from_millis(10));
    };
    assert!(status.success(), "server exited with {status}");
    assert!(transport::connect(&socket).is_err());
    let cleanup_deadline = Instant::now() + Duration::from_secs(3);
    while (process_exists(local_pid) || process_group_exists(local_pid))
        && Instant::now() < cleanup_deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    let cleaned = !process_exists(local_pid) && !process_group_exists(local_pid);
    if !cleaned {
        let local_pid = libc::pid_t::try_from(local_pid).unwrap();
        // SAFETY: local_pid names the isolated PTY session created by this test.
        unsafe {
            libc::kill(-local_pid, libc::SIGKILL);
            libc::kill(local_pid, libc::SIGKILL);
        }
    }
    drop(server);
    fs::remove_dir_all(dir).unwrap();
    assert!(cleaned, "forced interactive-driver exit abandoned its local PTY session");
}

#[cfg(unix)]
#[test]
fn server_stop_cancels_a_blocked_terminal_host_launch() {
    let mut server = HeadlessServer::start_with(
        "server-stop-blocked-launch",
        false,
        &[("CMUX_TUI_TEST_BOOTSTRAP_READY_DELAY_MS", "3000")],
    );
    let mut create = raw_cli_command(
        &server.socket,
        serde_json::json!({"id":"blocked-create","cmd":"new-workspace"}),
    )
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
fn server_stop_cancels_a_blocked_terminal_host_launch_write() {
    let mut server = HeadlessServer::start_with(
        "server-stop-blocked-launch-write",
        false,
        &[("CMUX_TUI_TEST_STALL_AFTER_BOOTSTRAP_READY_MS", "3000")],
    );
    // Linux caps one execve argument below 128 KiB even when the aggregate
    // ARG_MAX is larger. This still exceeds the bootstrap pipe capacity, so
    // the host blocks on the Launch write without failing the CLI spawn first.
    let command = format!(": #{}", "x".repeat(96 * 1024));
    let mut create = raw_cli_command(
        &server.socket,
        serde_json::json!({
            "id": "blocked-launch-write",
            "cmd": "run",
            "new_workspace": true,
            "command": command,
        }),
    )
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .unwrap();
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&server.state, "main");
    std::thread::sleep(Duration::from_millis(250));
    assert!(create.try_wait().unwrap().is_none(), "terminal creation did not block on Launch");

    let stop_started = Instant::now();
    let stop = cli(&server, &["--json", "server", "stop"]);
    let stop_elapsed = stop_started.elapsed();

    assert_success(&stop);
    assert!(server.child.wait().unwrap().success());
    assert!(!create.wait().unwrap().success());
    assert!(terminal_host_pids(&host_root).is_empty());
    assert!(
        stop_elapsed < Duration::from_secs(2),
        "shutdown waited for the blocked Launch write: {stop_elapsed:?}"
    );
}

#[cfg(unix)]
#[test]
fn cancelled_published_host_is_terminated_through_its_record() {
    let barrier = unique_temp_dir("server-stop-published-launch").with_extension("barrier");
    let barrier_value = barrier.to_string_lossy().into_owned();
    let mut server = HeadlessServer::start_with(
        "server-stop-published-launch",
        false,
        &[("CMUX_TUI_TEST_LAUNCH_ACK_BARRIER", &barrier_value)],
    );
    let direct_pid_file = server.dir.join("published-direct.pid");
    let descendant_pid_file = server.dir.join("published-descendant.pid");
    let command = format!(
        "echo $$ > {}; trap '' HUP; (trap '' HUP; while :; do sleep 1; done) & echo $! > {}; wait",
        direct_pid_file.display(),
        descendant_pid_file.display()
    );
    let mut create = raw_cli_command(
        &server.socket,
        serde_json::json!({
            "id": "published-host-create",
            "cmd": "run",
            "new_workspace": true,
            "command": command,
        }),
    )
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .unwrap();
    let host_root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&server.state, "main");
    let deadline = Instant::now() + Duration::from_secs(5);
    while (!direct_pid_file.exists()
        || !descendant_pid_file.exists()
        || terminal_host_pids(&host_root).is_empty()
        || !barrier.exists())
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
    let _ = fs::remove_file(&barrier);
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
    let surface =
        raw_json(&server, serde_json::json!({"id":"ephemeral-run","cmd":"run","command":command}))
            ["surface"]
            .as_u64()
            .unwrap();
    let info = raw_json(
        &server,
        serde_json::json!({"id":"ephemeral-process","cmd":"process-info","surface":surface}),
    );
    let direct_pid = u32::try_from(info["pid"].as_u64().unwrap()).unwrap();
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
    let surface = raw_json(
        &server,
        serde_json::json!({"id":"job-control-run","cmd":"run","command":command}),
    )["surface"]
        .as_u64()
        .unwrap();
    let info = raw_json(
        &server,
        serde_json::json!({"id":"job-control-process","cmd":"process-info","surface":surface}),
    );
    let direct_pid = u32::try_from(info["pid"].as_u64().unwrap()).unwrap();
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
    let applied = raw_json(
        &server,
        serde_json::json!({
            "id":"many-panes-layout",
            "cmd":"apply-layout",
            "layout":{
                "type":"stack",
                "panes":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,
                    17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32],
                "expanded":1,
            },
        }),
    );
    let surfaces = applied["panes"].as_array().unwrap();
    assert_eq!(surfaces.len(), 32);
    let first_surface = surfaces[0]["surface"].as_u64().unwrap();
    let info = raw_json(
        &server,
        serde_json::json!({
            "id":"many-panes-first-process",
            "cmd":"process-info",
            "surface":first_surface,
        }),
    );
    let first_terminal_pid = u32::try_from(info["pid"].as_u64().unwrap()).unwrap();
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
fn server_stop_fails_closed_when_another_legacy_client_can_create_surfaces() {
    let mut server =
        LegacyServerProcess::start("legacy-server-concurrent-client", "concurrent-client", None);
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
    assert!(transport::connect(&server.socket).is_ok(), "failed shutdown did not restore socket");
}

#[cfg(unix)]
#[test]
fn server_stop_waits_for_the_initiating_legacy_client_to_drain() {
    let mut server =
        LegacyServerProcess::start("legacy-server-draining-client", "draining-client", None);
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
fn server_stop_fails_closed_for_a_dead_legacy_surface_with_a_live_session() {
    let mut server =
        LegacyServerProcess::start("legacy-server-dead-owned", "dead-owned-surface", None);
    let descendant_pid = wait_for_pid_file(&server.descendant_pid_file, Duration::from_secs(5));

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert!(!output.status.success(), "live process behind a dead surface was ignored");
    assert!(server.child.try_wait().unwrap().is_none(), "legacy server was killed on ambiguity");
    assert!(process_exists(descendant_pid), "ambiguous pane process was killed without ownership");
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

    let output = raw_cli(
        &server,
        serde_json::json!({
            "id":"failed-published-host",
            "cmd":"run",
            "new_workspace":true,
            "command":command,
        }),
    );
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
fn server_stop_completes_when_the_last_legacy_surface_exits_with_its_server() {
    let mut server =
        LegacyServerProcess::start("legacy-server-exit-after-close", "exit-after-close", None);
    let descendant_pid = server.descendant_pid().unwrap();

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    assert_success(&output);
    assert!(server.child.wait().unwrap().success());
    let deadline = Instant::now() + Duration::from_secs(5);
    while process_is_active(descendant_pid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        !process_is_active(descendant_pid),
        "last-surface server exit leaked its captured PTY owner"
    );
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
    assert!(transport::connect(&server.socket).is_ok(), "failed shutdown did not restore socket");
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
fn server_stop_never_signals_an_unowned_legacy_surface_pid() {
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
    let mut victim = command.spawn().unwrap();
    let mut server = LegacyServerProcess::start_with_surface_pid(
        "legacy-server-unowned-surface",
        "unowned-surface",
        None,
        Some(victim.id()),
    );

    let output = Command::new(bin())
        .args(["server", "stop", "--socket"])
        .arg(&server.socket)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();

    let victim_survived = victim.try_wait().unwrap().is_none();
    let server_survived = server.child.try_wait().unwrap().is_none();
    if victim_survived {
        victim.kill().unwrap();
        victim.wait().unwrap();
    }

    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("could not close pane processes before stopping the older server")
    );
    assert!(victim_survived, "legacy cleanup signaled a process outside the server tree");
    assert!(server_survived, "legacy cleanup stopped the server after ownership proof failed");
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
        let clients = json_cli(&server, &["client", "list"]);
        if clients.status.success() {
            let clients = json_output(&clients);
            if clients
                .as_array()
                .unwrap()
                .iter()
                .any(|client| client["client_kind"].as_str() == Some("tui"))
            {
                attached = true;
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(attached, "plain launch never attached before host disconnect");

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
        if let Some(status) = tui.child.try_wait().unwrap() {
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
    assert!(String::from_utf8_lossy(&identify.stdout).contains("\"protocol\":10"));

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
    let screen_id = created["value"]["screen_id"].as_str().unwrap().to_string();
    let pane0 = created["value"]["pane_id"].as_str().unwrap().to_string();
    let terminal = created["value"]["terminal_id"].as_str().unwrap().to_string();
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

    let split = json_cli(&server, &["pane", &pane0, "split", "--right"]);
    assert_success(&split);
    let pane1 = json_output(&split)["value"]["pane_id"].as_str().unwrap().to_string();

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
    assert_success(&send_key);

    let select_bare = cli(&server, &["tab"]);
    assert_eq!(select_bare.status.code(), Some(2));

    let close = cli(&server, &["--quiet", "terminal", &terminal, "close"]);
    assert_success(&close);
    let closed_read = json_cli(&server, &["terminal", &terminal, "screen", "read"]);
    assert_eq!(closed_read.status.code(), Some(1));
    assert_eq!(json_error(&closed_read)["code"], "selector.not_found");

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
    raw_cli_command(&server.socket, request).output().unwrap()
}

fn raw_cli_command(socket: &std::path::Path, request: serde_json::Value) -> Command {
    let request = serde_json::to_string(&request).unwrap();
    let mut command = Command::new(bin());
    command
        .args(["--json", "--socket"])
        .arg(socket)
        .args(["raw", "command", "--request-json", &request])
        .env_remove("CMUX_TUI_SOCKET");
    command
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
