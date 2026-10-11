//! Pipelined `new-tab` requests start their hosts in parallel; a ready gate
//! proves the launches overlap without timing them.

use super::*;

/// A burst of `new-tab` requests pipelined on one connection starts their
/// hosts in parallel. Every host waits before Ready at a gate (a FIFO the
/// test holds closed), so a serial start never has more than one host
/// record on disk: all six records while the gate is closed prove the
/// launches overlap. A request queued after the creates is answered while
/// they wait, the creates reply in request order once the gate opens, and
/// the tabs land in the pane in request order.
#[test]
fn pipelined_new_tabs_start_hosts_in_parallel_in_request_order() {
    // Below the daemon's 8 terminal workers, so a worker busy with other
    // work cannot queue a create behind the gated launches.
    const TABS: u64 = 6;
    let mut harness = RecoveryHarness::start_unstarted("parallel-new-tabs");
    let gate = harness.dir.join("host-ready-gate");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_HOST_READY_GATE", &gate);
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    let anchor = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "name": "anchor",
        }),
    );
    let pane = anchor["pane"].as_u64().expect("run omitted its pane");
    wait_for_host_records(&harness.host_root(), 1);
    // Hosts launched from here on wait at the gate before Ready.
    let path = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: `path` is a NUL-terminated string that outlives the call.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0, "mkfifo {gate:?}");
    let gate_guard = ReadyGate(gate);

    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    for index in 0..TABS {
        writeln!(
            writer,
            "{}",
            serde_json::json!({"id": 100 + index, "cmd": "new-tab", "pane": pane})
        )
        .unwrap();
    }
    writeln!(writer, "{}", serde_json::json!({"id": 999, "cmd": "identify"})).unwrap();
    let mut read_reply = || loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "daemon closed the connection");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message.get("id").is_some() {
            assert_eq!(message["ok"], true, "request failed: {message}");
            return message;
        }
    };
    // No create can reply while its host waits at the closed gate.
    let identify = read_reply();
    assert_eq!(identify["id"], 999, "a create replied before its host was Ready: {identify}");
    let started = wait_for_host_records_or(&harness.host_root(), 1 + TABS as usize);
    assert_eq!(
        started.len(),
        1 + TABS as usize,
        "{TABS} pipelined new-tabs held at the ready gate left {} host records; their hosts \
         started one at a time",
        started.len() - 1
    );
    let open = gate_guard.open();
    let replies: Vec<serde_json::Value> = (0..TABS).map(|_| read_reply()).collect();
    drop(open);
    drop(gate_guard);
    let creates: Vec<u64> = replies.iter().map(|reply| reply["id"].as_u64().unwrap()).collect();
    assert_eq!(creates, (0..TABS).map(|index| 100 + index).collect::<Vec<_>>());
    let surfaces: Vec<u64> =
        replies.iter().map(|reply| reply["data"]["surface"].as_u64().unwrap()).collect();

    let tree = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}));
    let tabs: Vec<u64> = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .filter(|candidate| candidate["id"].as_u64() == Some(pane))
        .flat_map(|candidate| candidate["tabs"].as_array().into_iter().flatten())
        .filter_map(|tab| tab["surface"].as_u64())
        .filter(|surface| surfaces.contains(surface))
        .collect();
    assert_eq!(tabs, surfaces, "tabs did not land in request order");
    wait_for_host_records(&harness.host_root(), 1 + TABS as usize);
}

/// The FIFO `CMUX_TUI_TEST_HOST_READY_GATE` names. Hosts that find it wait
/// before Ready until it is opened for writing. Dropping the gate opens it
/// once (releasing any waiting host) and removes it.
struct ReadyGate(PathBuf);

impl ReadyGate {
    /// Open the gate: every waiting host and every later one passes while
    /// the returned descriptor stays open. Read-write never blocks.
    fn open(&self) -> fs::File {
        fs::OpenOptions::new().read(true).write(true).open(&self.0).unwrap()
    }
}

impl Drop for ReadyGate {
    fn drop(&mut self) {
        // Remove while open: a host past its existence check still gets
        // through, and a later one finds no gate.
        let open = fs::OpenOptions::new().read(true).write(true).open(&self.0);
        let _ = fs::remove_file(&self.0);
        drop(open);
    }
}

/// The host records once `expected` exist, or the records present when the
/// wait gives up, for a test that names the shortfall itself.
fn wait_for_host_records_or(root: &Path, expected: usize) -> Vec<(PathBuf, TerminalHostRecord)> {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let records = load_terminal_host_records(root).unwrap();
        if records.len() >= expected || Instant::now() >= deadline {
            return records;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}
