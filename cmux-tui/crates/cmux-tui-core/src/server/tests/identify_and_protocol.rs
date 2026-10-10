//! Workspace selector conflicts, provider-managed locking, identify capabilities, protocol key input and window titles.

use super::*;

#[test]
fn identify_advertises_additive_capabilities() {
    let mux = test_mux();
    let identity =
        handle_command(&mux, mux.local_test_client(0), Command::Identify, &test_writer()).unwrap();

    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    for expected in [
        "attach-initial-size",
        SURFACE_SUBSCRIBE_FILTER_CAPABILITY,
        "workspace-registry-v1",
        GUARDED_BROWSER_POINTER_CAPABILITY,
        VIEWPORT_SPLITS_CAPABILITY,
        VIEWPORT_COLUMN_RESIZE_CAPABILITY,
        LAYOUT_UNDO_CAPABILITY,
        CLEAR_HISTORY_CAPABILITY,
        CLEAR_HISTORY_KEY_CAPABILITY,
        "surface-subscribe-filter",
        SESSION_JOURNAL_CAPABILITY,
        FRONTEND_JOURNAL_CAPABILITY,
        VIEW_ATTACHMENT_LEASE_CAPABILITY,
        VIEW_ATTACHMENT_DETACH_CAPABILITY,
        CREATION_RECEIPTS_CAPABILITY,
        CREATION_SELECTOR_FALLBACKS_CAPABILITY,
        PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY,
        STATE_RESOURCES_CAPABILITY,
        WINDOW_RECORDS_CAPABILITY,
        TERMINAL_STATE_CAPABILITY,
        FRONTEND_BROWSER_OWNER_CAPABILITY,
        crate::git_ops::CHECKPOINTS_CAPABILITY,
        crate::git_ops::FILES_SEARCH_CAPABILITY,
    ] {
        assert!(capabilities.iter().any(|value| value.as_str() == Some(expected)));
    }
}

#[cfg(target_os = "linux")]
#[test]
fn private_link_port_discovery_reports_listener_process() {
    use crate::server::cmd_server::machine_listening_tcp_json;

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = listener.local_addr().unwrap().to_string();
    let inventory = machine_listening_tcp_json().unwrap();
    let stdout = inventory["stdout"].as_str().unwrap();
    let row = stdout
        .lines()
        .find(|line| line.split_whitespace().nth(3) == Some(endpoint.as_str()))
        .expect("the inventory must contain the test's listening socket");
    let pid = std::process::id();
    assert!(
        row.contains(&format!("pid={pid},"))
            || row.split_whitespace().any(|field| field.starts_with(&format!("{pid}/"))),
        "listener ownership is needed to distinguish application ports from internal services: {row}"
    );
}

#[cfg(unix)]
#[test]
fn paused_server_serves_identity_before_lifecycle_readiness() {
    let dir = TestSocketDir::create("paused-readiness");
    let path = dir.path().join("mux.sock");
    let mux = test_mux();
    let pending = serve_paused(mux, Some(path.clone())).unwrap();
    let mut stream = transport::connect(&path).unwrap();
    writeln!(stream, r#"{{"id":1,"cmd":"identify"}}"#).unwrap();
    stream.flush().unwrap();
    let (response_tx, response_rx) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut response = String::new();
        let result = BufReader::new(stream).read_line(&mut response).map(|_| response);
        response_tx.send(result).unwrap();
    });
    let response = response_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("ordinary protocol identify waited for lifecycle readiness")
        .unwrap();
    assert_eq!(serde_json::from_str::<Value>(&response).unwrap()["ok"], true);

    let mut lifecycle = transport::connect(&path).unwrap();
    writeln!(lifecycle, r#"{{"id":2,"cmd":"identify"}}"#).unwrap();
    lifecycle.flush().unwrap();
    let mut starting = String::new();
    BufReader::new(&mut lifecycle).read_line(&mut starting).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&starting).unwrap()["data"]["lifecycle_ready"], false);

    writeln!(lifecycle, r#"{{"id":3,"cmd":"reload-config"}}"#).unwrap();
    lifecycle.flush().unwrap();
    let mut rejected = String::new();
    BufReader::new(&mut lifecycle).read_line(&mut rejected).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&rejected).unwrap()["ok"], false);

    let served = pending.mark_ready().unwrap();
    writeln!(lifecycle, r#"{{"id":4,"cmd":"identify"}}"#).unwrap();
    lifecycle.flush().unwrap();
    let mut ready = String::new();
    BufReader::new(lifecycle).read_line(&mut ready).unwrap();
    assert_eq!(served, path);
    assert_eq!(serde_json::from_str::<Value>(&ready).unwrap()["data"]["lifecycle_ready"], true);
    cleanup(&served);
}

#[test]
fn cmux_next_notify_accepts_a_source_and_reports_it_on_the_wire() {
    assert!(advertised_capabilities(false).contains(&NOTIFICATION_SOURCE_CAPABILITY));
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
    let events = mux.subscribe();
    run_json_command(
        &mux,
        json!({"cmd":"notify","title":"hook","body":"","surface":surface.id,"source":"agent"}),
    )
    .unwrap();
    run_json_command(&mux, json!({"cmd":"notify","title":"cli","body":"","surface":surface.id}))
        .unwrap();
    let notes = events
        .try_iter()
        .filter(|event| matches!(event, MuxEvent::Notification(_)))
        .map(|event| subscribed_event_json(&event))
        .collect::<Vec<_>>();
    assert_eq!(notes.len(), 2, "{notes:?}");
    assert_eq!(notes[0]["title"], "hook");
    assert_eq!(notes[0]["source"], "agent");
    assert_eq!(notes[1]["title"], "cli");
    assert_eq!(notes[1]["source"], "cli", "notify defaults to the cli source");

    let tree = run_json_command(&mux, json!({"cmd":"list-workspaces"})).unwrap();
    let tab = tree["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0].clone();
    assert_eq!(tab["surface"], json!(surface.id));
    assert_eq!(tab["notification"]["source"], "cli", "{tab}");

    for source in ["daemon", "terminal"] {
        run_json_command(
            &mux,
            json!({"cmd":"notify","title":source,"body":"","surface":surface.id,"source":source}),
        )
        .unwrap();
    }
    assert!(
        run_json_command(&mux, json!({"cmd":"notify","title":"x","body":"","source":"bogus"}))
            .is_err()
    );
}
