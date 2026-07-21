use std::fs;
#[cfg(unix)]
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::os::fd::FromRawFd;
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
        let dir = unique_temp_dir(name);
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        let child = Command::new(bin())
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
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
                &mut size,
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

#[test]
fn cli_verbs_cover_command_output_errors_and_streams() {
    let server = HeadlessServer::start("matrix");

    let identify = cli(&server, &["identify"]);
    assert_success(&identify);
    assert!(String::from_utf8_lossy(&identify.stdout).starts_with("cmux-tui session="));

    let identify_json = cli(&server, &["--json", "identify"]);
    assert_success(&identify_json);
    let value: serde_json::Value = serde_json::from_slice(&identify_json.stdout).unwrap();
    assert_eq!(value.get("app").and_then(|v| v.as_str()), Some("cmux-tui"));
    assert!(value.get("protocol").and_then(|v| v.as_u64()).unwrap_or(0) >= 5);

    let ping_json = cli(&server, &["--json", "ping"]);
    assert_success(&ping_json);
    let ping: serde_json::Value = serde_json::from_slice(&ping_json.stdout).unwrap();
    assert_eq!(ping.get("ok").and_then(|v| v.as_bool()), Some(true));
    assert_eq!(ping.get("protocol").and_then(|v| v.as_u64()), Some(9));

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
    let excluded = cli(
        &server,
        &["set-client-sizing", "--client", &target_id.to_string(), "--enabled", "false"],
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
            .unwrap()["size_participating"],
        false
    );
    let detached = cli(&server, &["detach-client", "--client", &target_id.to_string()]);
    assert_success(&detached);
    target_response.clear();
    assert_eq!(target_reader.read_line(&mut target_response).unwrap(), 0);

    let title = cli(&server, &["set-window-title", "--title", "hello"]);
    assert_success(&title);
    assert!(title.stdout.is_empty(), "set-window-title should be quiet on success");

    let workspace = cli(&server, &["new-workspace", "--name", "cli-test"]);
    assert_success(&workspace);
    let surface = String::from_utf8(workspace.stdout).unwrap().trim().parse::<u64>().unwrap();
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
        let mut request = String::new();
        {
            let read_half = stream.try_clone_box().unwrap();
            let mut reader = BufReader::new(read_half);
            reader.read_line(&mut request).unwrap();
        }
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
