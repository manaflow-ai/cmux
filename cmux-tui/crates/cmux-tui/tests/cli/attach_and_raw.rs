use super::*;

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
fn scoped_terminal_attach_streams_pty_and_detaches_without_killing_terminal() {
    let server = HeadlessServer::start("scoped-terminal-attach-lifecycle");
    let created = json_cli(&server, &["tab", "create", "terminal"]);
    assert_success(&created);
    let terminal = json_output(&created)["value"]["terminal_id"]
        .as_str()
        .expect("terminal creation returns a terminal id")
        .to_string();

    let first_marker = "scoped_attach_lifecycle_marker";
    let write = json_cli(
        &server,
        &["terminal", &terminal, "write", "--text", &format!("printf '{first_marker}\\n'\n")],
    );
    assert_success(&write);
    assert!(
        wait_for_screen(&server, &terminal, first_marker).contains(first_marker),
        "daemon terminal did not produce the attach marker"
    );

    let socket = server.socket.to_str().unwrap();
    let mut attached =
        CapturingPtyChild::start(&["attach", "--socket", socket, "--terminal", &terminal]);
    let output = attached.wait_for_output(first_marker, Duration::from_secs(10));
    assert!(
        output.windows(first_marker.len()).any(|window| window == first_marker.as_bytes()),
        "scoped attach PTY did not replay terminal output: {}",
        String::from_utf8_lossy(&output)
    );

    let clients_deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < clients_deadline {
        let clients = json_cli(&server, &["client", "list"]);
        if clients.status.success()
            && json_output(&clients).as_array().is_some_and(|clients| {
                clients.iter().any(|client| {
                    client["client_kind"].as_str() == Some("tui")
                        && client["attached_terminal_ids"].as_array().is_some_and(|ids| {
                            ids.len() == 1 && ids[0].as_str() == Some(terminal.as_str())
                        })
                })
            })
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let clients = json_output(&json_cli(&server, &["client", "list"]));
    assert!(
        clients.as_array().is_some_and(|clients| {
            clients.iter().any(|client| {
                client["client_kind"].as_str() == Some("tui")
                    && client["attached_terminal_ids"].as_array().is_some_and(|ids| {
                        ids.len() == 1 && ids[0].as_str() == Some(terminal.as_str())
                    })
            })
        }),
        "scoped attach did not register exactly one terminal: {clients}"
    );

    attached.write(b"\x02d");
    let status = attached
        .wait_for_exit(Duration::from_secs(10))
        .expect("scoped attach did not exit after Ctrl-b d");
    assert!(status.success(), "scoped attach exited unsuccessfully: {status}");

    let second_marker = "scoped_attach_after_detach_marker";
    let write = json_cli(
        &server,
        &["terminal", &terminal, "write", "--text", &format!("printf '{second_marker}\\n'\n")],
    );
    assert_success(&write);
    assert!(
        wait_for_screen(&server, &terminal, second_marker).contains(second_marker),
        "daemon terminal stopped accepting input after scoped detach"
    );
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
    let server = HeadlessServer::start_without_shell_integration("matrix");

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

/// `history clear` on a shell without prompt marks keeps the visible screen
/// (a pending command line included) and drops the scrollback (cx-6so.48).
/// Deterministic on purpose: bash without rc files and a fixed one-cell
/// prompt, so neither a long user prompt nor a resize redraw can wrap the
/// pending line, and every step waits for the screen it needs.
#[test]
fn history_clear_without_a_prompt_boundary_keeps_the_visible_screen() {
    let server = HeadlessServer::start_without_shell_integration("history-clear");
    let created = json_cli(&server, &["workspace", "create", "--name", "history-clear"]);
    assert_success(&created);
    let terminal = json_output(&created)["value"]["terminal_id"].as_str().unwrap().to_string();
    let write = |text: &str| {
        let sent = cli(&server, &["--quiet", "terminal", &terminal, "write", "--text", text]);
        assert_success(&sent);
    };
    let screen = || {
        let read = json_cli(&server, &["terminal", &terminal, "screen", "read"]);
        assert_success(&read);
        json_output(&read)["text"].as_str().unwrap().to_string()
    };
    let wait_until = |what: &str, done: &dyn Fn(&str) -> bool| {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let text = screen();
            if done(&text) {
                return text;
            }
            assert!(Instant::now() < deadline, "{what} never happened: {text:?}");
            std::thread::sleep(Duration::from_millis(100));
        }
    };

    // Replace the login shell (any user rc and prompt) with a clean bash.
    write("exec env PS1='$ ' PROMPT_COMMAND= bash --norc --noprofile -i\r");
    write("clear\r");
    wait_until("the clean prompt", &|text| text.trim() == "$");

    // Old output that only the scrollback holds after the next screenful.
    write("seq -f old_%g 1 60\r");
    let marker = format!("history_clear_marker_{}", std::process::id());
    write(&format!("echo {marker}\r"));
    wait_until("the marker", &|text| text.contains(&format!("{marker}\n$")));
    let pending = format!("echo prompt_kept_{}", std::process::id());
    write(&pending);
    wait_until("the pending line", &|text| text.contains(&pending));

    // `old_1` exactly (not `old_10`): the first line, long scrolled off.
    let history_has_old_1 = || {
        let read = json_cli(&server, &["terminal", &terminal, "history", "read", "--limit", "200"]);
        assert_success(&read);
        let text = String::from_utf8_lossy(&read.stdout).into_owned();
        text.match_indices("old_1")
            .any(|(at, _)| !text[at + 5..].starts_with(|c: char| c.is_ascii_digit()))
    };
    assert!(history_has_old_1(), "the scrollback never held the old output");

    let cleared = cli(&server, &["--quiet", "terminal", &terminal, "history", "clear"]);
    assert_success(&cleared);
    assert!(cleared.stdout.is_empty(), "--quiet history clear wrote output");
    let cleared_screen = screen();
    assert!(
        cleared_screen.contains(&marker) && cleared_screen.contains(&pending),
        "clear-history removed visible output without a safe prompt boundary: {cleared_screen:?}"
    );
    assert!(!history_has_old_1(), "clear-history retained prior output in scrollback");
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
