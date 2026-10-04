//! R41: a terminal whose shell still runs is never reported dead. Covers a
//! host whose adoption is still pending after a daemon restart (C1) and a
//! host record this build cannot read, such as a newer record version after a
//! rollback (C3). See plans/cmux-next/durable-sessions.md section 7.

use super::*;

fn find_tab(
    socket: &Path,
    request_id: u64,
    what: &str,
    matches: impl Fn(&serde_json::Value) -> bool,
) -> serde_json::Value {
    let tree = request(socket, serde_json::json!({"id": request_id, "cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| matches(tab))
        .cloned()
        .unwrap_or_else(|| panic!("tab {what} missing from tree: {tree}"))
}

/// The durable tab id of the tab showing `surface` (stable across restarts;
/// the runtime surface id is not).
fn tab_resource_id_of(socket: &Path, surface: u64, request_id: u64) -> String {
    let tab = find_tab(socket, request_id, &format!("with surface {surface}"), |tab| {
        tab["surface"].as_u64() == Some(surface)
    });
    tab["tab_resource_id"].as_str().expect("tab resource id").to_string()
}

fn tab_with_resource_id(socket: &Path, tab_id: &str, request_id: u64) -> serde_json::Value {
    find_tab(socket, request_id, tab_id, |tab| tab["tab_resource_id"].as_str() == Some(tab_id))
}

fn subscribe(socket: &Path) -> BufReader<Box<dyn transport::Stream>> {
    let stream = transport::connect(socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{}", serde_json::json!({"id": 1, "cmd": "subscribe"})).unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "subscribe failed: {response}");
    reader
}

/// C1: while a restarted daemon still retries adoption of a live host, the
/// tab has no runtime surface. It must report the terminal as adopting, not
/// dead, and the daemon must push `tree-changed` once adoption completes, so a
/// client never shows "Process exited" for a running shell.
#[test]
fn pending_adoption_tab_is_not_dead_and_completion_pushes_tree_changed() {
    let mut harness = RecoveryHarness::start("false-exit-adopting");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let tab_id = tab_resource_id_of(&harness.socket, surface, 50);
    let records = wait_for_host_records(&harness.host_root(), 1);
    let endpoint = PathBuf::from(&records[0].1.endpoint);
    let held_endpoint = endpoint.with_extension("held-for-false-exit-test");

    harness.sigkill();
    fs::rename(&endpoint, &held_endpoint).unwrap();
    harness.restart();

    let pending = request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
    );
    assert_eq!(pending["lifecycle"], "adopting");
    let tab = tab_with_resource_id(&harness.socket, &tab_id, 3);
    assert_eq!(tab["dead"], false, "a pending adoption was reported dead: {tab}");
    assert_eq!(tab["terminal_state"], "adopting", "{tab}");

    // Clients refresh tab liveness only on tree pushes: completion must push
    // one after which the tab reads running.
    let mut events = subscribe(&harness.socket);
    let (tree_changed, pushes) = mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        while events.read_line(&mut line).is_ok_and(|read| read > 0) {
            if line.contains("\"event\":\"tree-changed\"") && tree_changed.send(()).is_err() {
                return;
            }
            line.clear();
        }
    });
    fs::rename(&held_endpoint, &endpoint).unwrap();
    // Nothing else changes the tree meanwhile, so the first push after the
    // host is reachable again must be adoption's, and must show it running.
    pushes
        .recv_timeout(test_timeout(Duration::from_secs(15)))
        .expect("adoption completion pushed no tree-changed");
    let tab = tab_with_resource_id(&harness.socket, &tab_id, 4);
    assert_eq!(tab["dead"], false, "{tab}");
    assert_eq!(tab["terminal_state"], "running", "{tab}");
}

/// C3: a host record this build cannot validate (here a future
/// `record_version`) belongs to a host that may still run. The terminal must
/// not be ended as `missing-host-record`; it stays visible as unadoptable and
/// the host keeps running until the user closes it, which ends the host.
#[test]
fn unreadable_host_record_keeps_terminal_unadoptable_not_ended() {
    let mut harness = RecoveryHarness::start("false-exit-unadoptable");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let tab_id = tab_resource_id_of(&harness.socket, surface, 50);
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let host_pid = record.host_pid as libc::pid_t;
    // The harness's own cleanup cannot read the rewritten record; never leak
    // the host when an assertion fails.
    struct KillOnDrop(libc::pid_t);
    impl Drop for KillOnDrop {
        fn drop(&mut self) {
            // SAFETY: the PID is this test's terminal host (a session leader).
            unsafe { libc::killpg(self.0, libc::SIGKILL) };
        }
    }
    let _host_guard = KillOnDrop(host_pid);

    harness.sigkill();
    let mut future: serde_json::Value =
        serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
    future["record_version"] = serde_json::json!(99);
    fs::write(&record_path, serde_json::to_vec(&future).unwrap()).unwrap();
    harness.restart();

    let resolved = request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
    );
    assert_ne!(resolved["lifecycle"], "exited", "unreadable record ended the terminal: {resolved}");
    assert!(process_exists(host_pid), "the host must keep running");
    let tab = tab_with_resource_id(&harness.socket, &tab_id, 3);
    assert_eq!(tab["dead"], false, "{tab}");
    assert_eq!(tab["terminal_state"], "unadoptable", "{tab}");
    assert_eq!(tab["host_record_version"], 99, "{tab}");

    request(
        &harness.socket,
        serde_json::json!({
            "id": 4,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    wait_for_process_and_group_absent(host_pid);
}

/// C3, continued: an unadoptable host whose shell exits by itself must not
/// leave its tab "unadoptable" forever. The daemon watches the host's live
/// marker and ends the terminal with the exit status the host recorded.
#[test]
fn unadoptable_host_that_exits_ends_its_terminal_with_the_real_status() {
    let mut harness = RecoveryHarness::start("false-exit-unadoptable-exit");
    let gate = harness.dir.join("gate");
    let c_path = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) }, 0);
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", format!("read line < '{}'; exit 7", gate.display())],
            "new_workspace": true,
            "cols": 80,
            "rows": 24,
        }),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let host_pid = record.host_pid as libc::pid_t;

    harness.sigkill();
    let mut future: serde_json::Value =
        serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
    future["record_version"] = serde_json::json!(99);
    fs::write(&record_path, serde_json::to_vec(&future).unwrap()).unwrap();
    harness.restart();
    let resolved = request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
    );
    assert_ne!(resolved["lifecycle"], "exited", "{resolved}");

    fs::write(&gate, b"go\n").unwrap();
    wait_for_process_and_group_absent(host_pid);
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let resolved = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id": 3, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
        );
        if resolved["lifecycle"] == "exited" {
            break resolved;
        }
        assert!(Instant::now() < deadline, "the ended unadoptable host never ended its terminal");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(
        resolved["exit"]["outcome"],
        serde_json::json!({"kind": "exit", "code": 7}),
        "{resolved}"
    );
    assert!(!record_path.exists(), "the ended host's record must be removed");
}

/// A live host that refuses every protocol this build offers (a newer
/// build's host after a rollback, whose record this build still reads) must
/// not read "adopting" forever. After repeated refusals while the host is
/// live, the terminal reads unadoptable, the host keeps running, and close
/// ends the host with proof (plans/cmux-next/durable-sessions.md section 7).
#[test]
fn live_host_that_refuses_every_protocol_is_unadoptable_not_adopting() {
    let mut harness = RecoveryHarness::start("false-exit-no-common-protocol");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let tab_id = tab_resource_id_of(&harness.socket, surface, 50);
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let host_pid = record.host_pid as libc::pid_t;
    struct KillOnDrop(libc::pid_t);
    impl Drop for KillOnDrop {
        fn drop(&mut self) {
            // SAFETY: the PID is this test's terminal host (a session leader).
            unsafe { libc::killpg(self.0, libc::SIGKILL) };
        }
    }
    let _host_guard = KillOnDrop(host_pid);
    let endpoint = PathBuf::from(&record.endpoint);
    let held_endpoint = endpoint.with_extension("held-for-protocol-test");

    harness.sigkill();
    // The real host keeps running and holds its live marker. Its socket is
    // replaced by one that reads each ClientHello and closes without a
    // HostHello: what a host with no protocol in common does.
    fs::rename(&endpoint, &held_endpoint).unwrap();
    let refusing = std::os::unix::net::UnixListener::bind(&endpoint).unwrap();
    std::thread::spawn(move || {
        for stream in refusing.incoming() {
            let Ok(mut stream) = stream else { return };
            let _ = read_frame(&mut stream, MAX_FRAME_PAYLOAD);
        }
    });
    harness.restart();
    let mut events = subscribe(&harness.socket);
    let (pushed, pushes) = mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        while events.read_line(&mut line).is_ok_and(|read| read > 0) {
            if line.contains("\"event\":\"tree-changed\"") && pushed.send(()).is_err() {
                return;
            }
            line.clear();
        }
    });
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    let tab = loop {
        let tab = tab_with_resource_id(&harness.socket, &tab_id, 3);
        if tab["terminal_state"] == "unadoptable" {
            break tab;
        }
        assert_eq!(tab["terminal_state"], "adopting", "{tab}");
        let remaining = deadline.saturating_duration_since(Instant::now());
        // Each push is a candidate transition; the tab is re-read after it.
        if pushes.recv_timeout(remaining).is_err() {
            break tab_with_resource_id(&harness.socket, &tab_id, 4);
        }
    };
    assert_eq!(
        tab["terminal_state"], "unadoptable",
        "a host that refuses every protocol stayed adopting: {tab}"
    );
    assert_eq!(tab["dead"], false, "{tab}");
    assert!(process_exists(host_pid), "the refusing host must keep running");

    request(
        &harness.socket,
        serde_json::json!({
            "id": 5,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    wait_for_process_and_group_absent(host_pid);
}
