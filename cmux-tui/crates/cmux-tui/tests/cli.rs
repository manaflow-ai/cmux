use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use wait_timeout::ChildExt;

fn register_test_tui(writer: &mut impl Write, reader: &mut impl BufRead) {
    let client_uuid = uuid::Uuid::new_v4();
    let process_instance_uuid = uuid::Uuid::new_v4();
    writeln!(
        writer,
        "{}",
        serde_json::json!({
            "id": 0,
            "cmd": "register-client",
            "protocol_min": 9,
            "protocol_max": 9,
            "client_uuid": client_uuid,
            "process_instance_uuid": process_instance_uuid,
            "client_kind": "tui",
        })
    )
    .unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "TUI registration failed: {response}");
    let registration = &response["data"];
    assert_eq!(registration["protocol"], 9);
    assert_eq!(registration["client_kind"], "tui");
    assert_eq!(registration["role"], "trusted-frontend");
    uuid::Uuid::parse_str(
        registration["topology_lease_id"].as_str().expect("TUI topology lease id"),
    )
    .expect("valid TUI topology lease id");
    assert!(registration["topology_lease_generation"].as_u64().is_some_and(|value| value > 0));
}

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
        let child = Command::new(bin())
            .args(["--headless", "--state-dir"])
            .arg(dir.join("state"))
            .arg("--socket")
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("CMUX_TUI_CONFIG", &config)
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
            if transport::connect(&self.socket).is_ok() {
                return;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        panic!("headless server did not create socket at {}", self.socket.display());
    }

    fn wait_for_exit(&mut self) -> std::process::ExitStatus {
        self.child
            .wait_timeout(Duration::from_secs(10))
            .unwrap()
            .expect("headless server did not exit after a fatal persistence failure")
    }

    fn read_stderr(&mut self) -> String {
        let mut stderr = String::new();
        self.child.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
        stderr
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
fn durability_failure_terminates_daemon_and_releases_session_lock() {
    let mut server = HeadlessServer::start("durability-failure");
    let store = cmux_tui_core::StateStore::new(server.dir.join("state"));
    let journal = store.journal_path("main");
    fs::remove_file(&journal).unwrap();
    fs::create_dir(&journal).unwrap();

    let mutation = cli(&server, &["new-workspace", "--name", "must-not-acknowledge"]);
    assert!(!mutation.status.success(), "undurable mutation was acknowledged");
    let status = server.wait_for_exit();
    assert!(!status.success(), "daemon exited successfully after losing durability");
    assert!(transport::connect(&server.socket).is_err(), "stale socket still accepted clients");

    let lock_path = fs::read_dir(store.root().join("locks"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.extension().is_some_and(|extension| extension == "lock"))
        .expect("session lock file is missing");
    let lock = fs::OpenOptions::new().read(true).write(true).open(lock_path).unwrap();
    fs2::FileExt::try_lock_exclusive(&lock).expect("daemon retained its session lock after exit");
    fs2::FileExt::unlock(&lock).unwrap();

    let stderr = server.read_stderr();
    assert!(
        stderr.contains("cmux-tui: fatal canonical persistence failure:"),
        "fatal persistence diagnostic missing from stderr: {stderr:?}"
    );
}

#[test]
fn cli_verbs_cover_command_output_errors_and_streams() {
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

    let ping_json = cli(&server, &["--json", "ping"]);
    assert_success(&ping_json);
    let ping: serde_json::Value = serde_json::from_slice(&ping_json.stdout).unwrap();
    assert_eq!(ping.get("ok").and_then(|v| v.as_bool()), Some(true));
    assert_eq!(ping.get("protocol").and_then(|v| v.as_u64()), Some(8));
    assert!(
        ping["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "topology-resume-v1")
    );

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
    register_test_tui(&mut target_writer, &mut target_reader);
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

    let topology = cli(&server, &["--json", "topology-snapshot"]);
    assert_success(&topology);
    let topology: serde_json::Value = serde_json::from_slice(&topology.stdout).unwrap();
    assert_eq!(topology["revision"], tree_json["topology_revision"]);
    assert_eq!(topology["topology"]["workspaces"][0]["id"], tree_json["workspaces"][0]["id"]);
    assert!(topology["topology"]["workspaces"][0]["uuid"].as_str().is_some());

    let split = cli(&server, &["split", "--pane", &pane0.to_string(), "--dir", "right"]);
    assert_success(&split);

    let exported = cli(&server, &["--json", "export-layout"]);
    assert_success(&exported);
    let exported_json: serde_json::Value = serde_json::from_slice(&exported.stdout).unwrap();
    assert_eq!(exported_json["layout"]["type"].as_str(), Some("split"));
    assert_eq!(exported_json["panes"].as_array().unwrap().len(), 2);

    let neighbor =
        cli(&server, &["--json", "pane-neighbor", "--pane", &pane0.to_string(), "--dir", "right"]);
    assert_success(&neighbor);
    let neighbor_json: serde_json::Value = serde_json::from_slice(&neighbor.stdout).unwrap();
    let pane1 = neighbor_json["pane"].as_u64().unwrap();
    assert_ne!(pane0, pane1);

    let focus = cli(
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
    assert_subscribe_topology_reports_revisioned_delta(&server);

    let topology = cli(&server, &["--json", "topology-snapshot"]);
    assert_success(&topology);
    let topology: serde_json::Value = serde_json::from_slice(&topology.stdout).unwrap();
    let stale = cli(
        &server,
        &[
            "subscribe-topology",
            "--daemon-instance-id",
            "00000000-0000-4000-8000-000000000000",
            "--session-id",
            topology["session_id"].as_str().unwrap(),
            "--revision",
            "0",
        ],
    );
    assert_eq!(stale.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&stale.stdout).contains("stale-daemon"));
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

fn assert_subscribe_topology_reports_revisioned_delta(server: &HeadlessServer) {
    let snapshot = cli(server, &["--json", "topology-snapshot"]);
    assert_success(&snapshot);
    let snapshot: serde_json::Value = serde_json::from_slice(&snapshot.stdout).unwrap();
    let daemon = snapshot["daemon_instance_id"].as_str().unwrap();
    let session = snapshot["session_id"].as_str().unwrap();
    let revision = snapshot["revision"].as_u64().unwrap();
    assert!(revision > 0, "topology replay requires a prior revision");
    let replay_revision = revision - 1;
    let mut child = Command::new(bin())
        .args(["--socket"])
        .arg(&server.socket)
        .args([
            "subscribe-topology",
            "--daemon-instance-id",
            daemon,
            "--session-id",
            session,
            "--revision",
            &replay_revision.to_string(),
        ])
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

    let deadline = Instant::now() + Duration::from_secs(10);
    let replay = rx
        .recv_timeout(deadline.saturating_duration_since(Instant::now()))
        .expect("subscribe-topology did not replay the prior topology delta");
    let replay: serde_json::Value = serde_json::from_str(&replay).unwrap();
    assert_eq!(replay["event"], "topology-delta");
    assert_eq!(replay["base_revision"].as_u64(), Some(replay_revision));
    assert_eq!(replay["revision"].as_u64(), Some(revision));

    assert_success(&cli(server, &["new-tab"]));

    let line = rx
        .recv_timeout(deadline.saturating_duration_since(Instant::now()))
        .expect("subscribe-topology did not print the new topology delta");
    let value: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(value["event"], "topology-delta");
    assert_eq!(value["base_revision"].as_u64(), Some(revision));
    assert_eq!(value["revision"].as_u64(), Some(revision + 1));
    assert!(value["replacement"]["workspaces"].is_array());
    let _ = child.kill();
    let _ = child.wait();
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

#[test]
fn attach_rejects_recover_state() {
    let output = Command::new(bin())
        .args(["attach", "--recover-state"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("--recover-state is only valid when starting a daemon session")
    );
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
