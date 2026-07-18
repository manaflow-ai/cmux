#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use cmux_tui_core::terminal_host::{
    CapabilityRights, CapabilityToken, ClientHello, ClientRole, TerminalId,
};
use cmux_tui_core::terminal_host_protocol::{
    FLAG_COLORS_FOLLOW, Frame, MAX_FRAME_PAYLOAD, MessageKind, PROTOCOL_VERSION, ProtocolError,
    read_frame, write_frame,
};
use cmux_tui_core::terminal_host_runtime::{
    adopt_terminal_host, decode_terminal_color_overrides, load_terminal_host_records,
    remove_terminal_host_record, terminal_host_root,
};
use ghostty_vt::{Rgb, TerminalColorOverrides};

struct RecoveryHarness {
    child: Option<Child>,
    dir: PathBuf,
    socket: PathBuf,
    state: PathBuf,
    session: String,
}

impl RecoveryHarness {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-terminal-host-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let mut harness = Self {
            child: None,
            socket: dir.join("mux.sock"),
            state: dir.join("state"),
            session: "host-recovery".into(),
            dir,
        };
        harness.restart();
        harness
    }

    fn restart(&mut self) {
        assert!(self.child.is_none());
        let child = Command::new(bin())
            .args(["--headless", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .arg("--state")
            .arg(&self.state)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        self.child = Some(child);
        wait_for_socket(&self.socket);
    }

    fn sigkill(&mut self) {
        let mut child = self.child.take().unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        let _ = fs::remove_file(&self.socket);
    }

    fn host_root(&self) -> PathBuf {
        terminal_host_root(&self.state, &self.session)
    }
}

impl Drop for RecoveryHarness {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }

        let records = load_terminal_host_records(&self.host_root()).unwrap_or_default();
        let endpoints =
            records.iter().map(|(_, record)| PathBuf::from(&record.endpoint)).collect::<Vec<_>>();
        for (path, record) in records {
            if let Ok(host) = adopt_terminal_host(record, path.clone()) {
                let _ = host.terminate();
                host.disconnect();
            }
            remove_terminal_host_record(&path);
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        while endpoints.iter().any(|endpoint| endpoint.exists()) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        for endpoint in endpoints {
            let _ = fs::remove_file(endpoint);
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn terminal_host_survives_sigkill_and_is_adopted_with_io_and_size() {
    let mut harness = RecoveryHarness::start("sigkill-adopt");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "name": "survivor",
            "cols": 80,
            "rows": 24,
        }),
    );
    let original_surface = created["surface"].as_u64().unwrap();
    let workspace = created["workspace"].as_u64().unwrap();

    let tree = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}));
    let workspace_key = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"].as_u64() == Some(workspace))
        .and_then(|item| item["key"].as_str())
        .unwrap()
        .to_string();

    let before = format!("before-sigkill-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "send",
            "surface": original_surface,
            "text": format!("{before}\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, original_surface, &before).contains(&before));

    let records = wait_for_host_records(&harness.host_root(), 1);
    assert_eq!(records[0].1.workspace_key, workspace_key);
    let terminal_id = records[0].1.terminal_id.clone();
    let incarnation = records[0].1.incarnation.clone();
    let endpoint = PathBuf::from(&records[0].1.endpoint);
    assert!(endpoint.exists());
    assert_eq!(created["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(created["terminal_incarnation"].as_str(), Some(incarnation.as_str()));
    let tree_workspace = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"].as_u64() == Some(workspace))
        .unwrap();
    let tree_tab = first_tab(tree_workspace).unwrap();
    assert_eq!(tree_tab["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(tree_tab["terminal_incarnation"].as_str(), Some(incarnation.as_str()));
    let resolved = request(
        &harness.socket,
        serde_json::json!({"id": 21, "cmd": "resolve-terminal", "terminal_id": &terminal_id}),
    );
    assert_eq!(resolved["surface"].as_u64(), Some(original_surface));
    assert_eq!(resolved["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(resolved["terminal_incarnation"].as_str(), Some(incarnation.as_str()));
    let missing = request_response(
        &harness.socket,
        serde_json::json!({
            "id": 22,
            "cmd": "resolve-terminal",
            "terminal_id": "ffffffffffff4fffbfffffffffffffff",
        }),
    );
    assert_eq!(missing["ok"], false);
    assert_eq!(missing["error"], "terminal_not_found");

    // Rights are enforced after authentication, not merely reported in the
    // hello. A READ-only owner connection cannot terminate the terminal.
    let mut read_only = connect_host(
        &records[0].1.endpoint,
        &terminal_id,
        &records[0].1.owner_token,
        ClientRole::Admin,
        CapabilityRights::READ,
    )
    .unwrap();
    write_frame(&mut read_only, &Frame::new(MessageKind::Terminate, Vec::new())).unwrap();
    drop(read_only);

    // JSON brokers a one-use renderer grant while keeping the durable owner
    // secret private. The minted renderer attaches directly to the host and
    // writes to the same PTY.
    let grant = request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "mint-terminal-renderer",
            "surface": original_surface,
            "ttl_ms": 10_000,
        }),
    );
    assert_eq!(grant["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(grant["incarnation"].as_str(), Some(incarnation.as_str()));
    assert_eq!(grant["rights"].as_u64(), Some(u64::from(CapabilityRights::RENDERER.bits())));
    let mut renderer = connect_host_detailed(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();
    let direct = format!("direct-renderer-{}", std::process::id());
    write_frame(
        &mut renderer.stream,
        &Frame::new(MessageKind::Input, format!("{direct}\n").into_bytes()),
    )
    .unwrap();
    assert!(wait_for_screen(&harness.socket, original_surface, &direct).contains(&direct));
    assert!(
        connect_host(
            grant["endpoint"].as_str().unwrap(),
            grant["terminal_id"].as_str().unwrap(),
            grant["token"].as_str().unwrap(),
            ClientRole::Renderer,
            CapabilityRights::RENDERER,
        )
        .is_err(),
        "renderer capability was reusable"
    );
    let expected_colors = {
        let mut colors = TerminalColorOverrides {
            foreground: Some(Rgb { r: 17, g: 18, b: 19 }),
            background: Some(Rgb { r: 33, g: 34, b: 35 }),
            cursor: Some(Rgb { r: 49, g: 50, b: 51 }),
            ..Default::default()
        };
        colors.palette[3] = Some(Rgb { r: 1, g: 2, b: 3 });
        colors
    };
    write_frame(
        &mut renderer.stream,
        &Frame::new(
            MessageKind::Input,
            b"\x1b]4;3;#010203\x07\x1b]10;#111213\x07\x1b]11;#212223\x07\x1b]12;#313233\x07\n"
                .to_vec(),
        ),
    )
    .unwrap();
    renderer.wait_for_colors(&expected_colors);

    // A fresh renderer receives portable VT state and the complete sparse
    // color state as a separate frame at the same atomic sequence boundary.
    let color_grant = request(
        &harness.socket,
        serde_json::json!({
            "id": 31,
            "cmd": "mint-terminal-renderer",
            "surface": original_surface,
            "ttl_ms": 10_000,
        }),
    );
    let color_snapshot = connect_host_detailed(
        color_grant["endpoint"].as_str().unwrap(),
        color_grant["terminal_id"].as_str().unwrap(),
        color_grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();
    assert_eq!(color_snapshot.colors, expected_colors);
    let replay = snapshot_replay(&color_snapshot.snapshot.payload);
    for forbidden in [b"\x1b]4;".as_slice(), b"\x1b]10;", b"\x1b]11;", b"\x1b]12;"] {
        assert!(!contains_bytes(replay, forbidden), "portable Snapshot leaked color OSC");
    }
    drop(color_snapshot);

    write_frame(
        &mut renderer.stream,
        &Frame::new(
            MessageKind::Input,
            b"\x1b]104;3\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07\n".to_vec(),
        ),
    )
    .unwrap();
    renderer.wait_for_colors(&TerminalColorOverrides::default());
    drop(renderer);

    // Child::kill is SIGKILL on Unix. The mux cannot run shutdown hooks, so
    // this proves the PTY and parser live in the independent host process.
    harness.sigkill();
    assert!(endpoint.exists(), "terminal host socket disappeared with the daemon");
    assert_eq!(wait_for_host_records(&harness.host_root(), 1)[0].1.terminal_id, terminal_id);

    harness.restart();
    let recovered =
        request(&harness.socket, serde_json::json!({"id": 4, "cmd": "list-workspaces"}));
    let recovered_workspace = recovered["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["key"].as_str() == Some(&workspace_key))
        .expect("durable workspace was not recovered");
    let adopted_surface =
        first_surface(recovered_workspace).expect("terminal host was not adopted");
    let rebound = request(
        &harness.socket,
        serde_json::json!({"id": 41, "cmd": "resolve-terminal", "terminal_id": &terminal_id}),
    );
    assert_eq!(rebound["surface"].as_u64(), Some(adopted_surface));
    assert_eq!(rebound["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(rebound["terminal_incarnation"].as_str(), Some(incarnation.as_str()));

    let replay = wait_for_screen(&harness.socket, adopted_surface, &before);
    assert!(replay.contains(&before), "host replay did not survive SIGKILL: {replay:?}");

    let after = format!("after-adoption-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id": 5,
            "cmd": "send",
            "surface": adopted_surface,
            "text": format!("{after}\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, adopted_surface, &after).contains(&after));

    let resized = request(
        &harness.socket,
        serde_json::json!({
            "id": 6,
            "cmd": "resize-surface",
            "surface": adopted_surface,
            "cols": 101,
            "rows": 37,
        }),
    );
    assert_eq!(resized["accepted"], true);
    let state = wait_for_vt_size(&harness.socket, adopted_surface, 101, 37);
    assert_eq!(state["cols"].as_u64(), Some(101));
    assert_eq!(state["rows"].as_u64(), Some(37));
    wait_for_host_size(&harness.host_root(), 101, 37);

    let records = wait_for_host_records(&harness.host_root(), 1);
    assert_eq!(records[0].1.terminal_id, terminal_id);
    assert_eq!(records[0].1.incarnation, incarnation);

    // A second crash proves the resize landed in the PTY-owning process, not
    // only in the disposable daemon-side Ghostty mirror.
    harness.sigkill();
    harness.restart();
    let recovered =
        request(&harness.socket, serde_json::json!({"id": 8, "cmd": "list-workspaces"}));
    let recovered_workspace = recovered["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["key"].as_str() == Some(&workspace_key))
        .expect("workspace was not recovered after the resized host survived again");
    let resized_surface =
        first_surface(recovered_workspace).expect("resized terminal host was not adopted");
    let state = request(
        &harness.socket,
        serde_json::json!({"id": 9, "cmd": "vt-state", "surface": resized_surface}),
    );
    assert_eq!(state["cols"].as_u64(), Some(101));
    assert_eq!(state["rows"].as_u64(), Some(37));
    assert!(wait_for_screen(&harness.socket, resized_surface, &after).contains(&after));

    let stale_close = request_response(
        &harness.socket,
        serde_json::json!({
            "id": 10,
            "cmd": "close-terminal",
            "terminal_id": &terminal_id,
            "terminal_incarnation": "00000000000040008000000000000000",
        }),
    );
    assert_eq!(stale_close["ok"], false);
    assert_eq!(stale_close["error"], "terminal_incarnation_mismatch");
    assert_eq!(wait_for_host_records(&harness.host_root(), 1).len(), 1);

    // This stable-id close was logically queued while the daemon was down;
    // after adoption it atomically resolves the new local surface generation,
    // verifies the incarnation, removes it, and only then terminates the host.
    let closed = request(
        &harness.socket,
        serde_json::json!({
            "id": 11,
            "cmd": "close-terminal",
            "terminal_id": &terminal_id,
            "terminal_incarnation": &incarnation,
        }),
    );
    assert_eq!(closed["surface"].as_u64(), Some(resized_surface));
    assert_eq!(closed["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(closed["terminal_incarnation"].as_str(), Some(incarnation.as_str()));
    let tombstoned = request_response(
        &harness.socket,
        serde_json::json!({"id": 12, "cmd": "resolve-terminal", "terminal_id": &terminal_id}),
    );
    assert_eq!(tombstoned["ok"], true);
    assert_eq!(tombstoned["data"]["surface"], serde_json::Value::Null);
    assert_eq!(tombstoned["data"]["lifecycle"], "tombstoned");
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn transient_startup_adoption_failure_retries_in_process_until_running() {
    let mut harness = RecoveryHarness::start("retry-adopt");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,
            "cmd":"run",
            "argv":["/bin/cat"],
            "new_workspace":true,
            "cols":80,
            "rows":24,
        }),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let records = wait_for_host_records(&harness.host_root(), 1);
    let endpoint = PathBuf::from(&records[0].1.endpoint);
    let held_endpoint = endpoint.with_extension("held-for-adoption-test");

    harness.sigkill();
    fs::rename(&endpoint, &held_endpoint).unwrap();
    harness.restart();

    let pending = request(
        &harness.socket,
        serde_json::json!({"id":2,"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    assert_eq!(pending["surface"], serde_json::Value::Null);
    assert_eq!(pending["lifecycle"], "adopting");

    fs::rename(&held_endpoint, &endpoint).unwrap();
    let deadline = Instant::now() + Duration::from_secs(15);
    let surface = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":3,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "terminal never completed in-process adoption");
        std::thread::sleep(Duration::from_millis(50));
    };

    let marker = format!("scheduled-adoption-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({"id":4,"cmd":"send","surface":surface,"text":format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
}

#[test]
fn client_reserved_create_retry_returns_original_binding_without_second_host() {
    let harness = RecoveryHarness::start("reserved-create");
    let workspace = request(
        &harness.socket,
        serde_json::json!({
            "id":1,
            "cmd":"create-workspace",
            "name":"Browser",
            "key":"browser-workspace",
            "origin":"browser",
            "mutation_id":"workspace-create",
            "expected_revision":0,
        }),
    );
    let terminal_id = TerminalId::random().unwrap().to_hex();
    let create = serde_json::json!({
        "id":2,
        "cmd":"create-terminal",
        "key":"browser-workspace",
        "argv":["/bin/cat"],
        "terminal_id":terminal_id,
        "origin":"browser",
        "mutation_id":"terminal-create",
        "expected_generation":workspace["generation"],
        "expected_terminal_revision":0,
        "cols":80,
        "rows":24,
    });
    let first = request(&harness.socket, create.clone());
    assert_eq!(first["terminal_id"], terminal_id);
    assert_eq!(first["replayed"], false);
    assert_eq!(wait_for_host_records(&harness.host_root(), 1).len(), 1);

    let retry = request(&harness.socket, create);
    assert_eq!(retry["replayed"], true);
    assert_eq!(retry["terminal_id"], terminal_id);
    assert_eq!(retry["surface"], first["surface"]);
    assert_eq!(retry["pane"], first["pane"]);
    assert_eq!(retry["screen"], first["screen"]);
    assert_eq!(wait_for_host_records(&harness.host_root(), 1).len(), 1);

    let mismatch = request_response(
        &harness.socket,
        serde_json::json!({
            "id":3,
            "cmd":"create-terminal",
            "key":"browser-workspace",
            "argv":["/bin/echo","different"],
            "terminal_id":terminal_id,
            "origin":"browser",
            "mutation_id":"terminal-create",
            "expected_terminal_revision":0,
        }),
    );
    assert_eq!(mismatch["ok"], false);
    assert!(mismatch["error"].as_str().unwrap().contains("different payload"));
}

#[test]
fn stalled_renderer_is_disconnected_without_freezing_the_host() {
    let harness = RecoveryHarness::start("stalled-renderer");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh"],
            "new_workspace": true,
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let grant = request(
        &harness.socket,
        serde_json::json!({
            "id": 2,
            "cmd": "mint-terminal-renderer",
            "surface": surface,
            "ttl_ms": 10_000,
        }),
    );
    let mut stalled = connect_host_detailed(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();

    let done = format!("overflow-done-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "send",
            "surface": surface,
            "text": format!(
                "/usr/bin/head -c 20000000 /dev/zero; printf '{done}\\n'\n"
            ),
        }),
    );
    assert!(wait_for_screen(&harness.socket, surface, &done).contains(&done));

    let disconnected_before_drain =
        match stalled.stream.set_read_timeout(Some(Duration::from_secs(5))) {
            Ok(()) => false,
            // Darwin reports EINVAL when setting SO_RCVTIMEO after the peer has
            // already issued shutdown(2); that is the overflow outcome under test.
            Err(error) if error.kind() == std::io::ErrorKind::InvalidInput => true,
            Err(error) => panic!("set stalled-renderer timeout: {error}"),
        };
    let mut complete_frames = 0usize;
    if !disconnected_before_drain {
        loop {
            match read_frame(&mut stalled.stream, MAX_FRAME_PAYLOAD) {
                Ok(Some(frame)) => {
                    assert_eq!(frame.request_id, 0);
                    assert_eq!(frame.sequence, stalled.next_sequence);
                    stalled.next_sequence = stalled.next_sequence.wrapping_add(1);
                    complete_frames += 1;
                }
                Ok(None) => break,
                Err(ProtocolError::Io(error))
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    panic!("stalled renderer silently froze instead of being disconnected")
                }
                // Shutdown can interrupt a frame already being copied into the
                // kernel socket buffer. A clean EOF or truncated final frame are
                // both explicit disconnects and require a fresh Snapshot.
                Err(ProtocolError::Truncated { .. }) | Err(ProtocolError::Io(_)) => break,
                Err(error) => panic!("stalled renderer received invalid protocol data: {error}"),
            }
        }
    }
    assert!(
        disconnected_before_drain || complete_frames > 0,
        "stalled renderer received no output before disconnect"
    );

    // Overflow is isolated to the stalled renderer. The daemon proxy and PTY
    // remain responsive and the durable host record remains adoptable.
    let after = format!("host-still-live-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id": 4,
            "cmd": "send",
            "surface": surface,
            "text": format!("printf '{after}\\n'\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, surface, &after).contains(&after));
    assert_eq!(wait_for_host_records(&harness.host_root(), 1).len(), 1);

    request(
        &harness.socket,
        serde_json::json!({"id": 5, "cmd": "close-surface", "surface": surface}),
    );
    wait_for_no_host_records(&harness.host_root());
}

fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let response = request_response(path, value);
    assert_eq!(response["ok"], true, "request failed: {response}");
    response["data"].clone()
}

fn request_response(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn wait_for_socket(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if transport::connect(path).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("server did not accept connections at {}", path.display());
}

fn wait_for_screen(path: &Path, surface: u64, marker: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut last = String::new();
    while Instant::now() < deadline {
        last = request(path, serde_json::json!({"cmd": "read-screen", "surface": surface}))["text"]
            .as_str()
            .unwrap()
            .to_string();
        if last.contains(marker) {
            return last;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    last
}

fn wait_for_host_records(
    root: &Path,
    expected: usize,
) -> Vec<(PathBuf, cmux_tui_core::terminal_host_runtime::TerminalHostRecord)> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let records = load_terminal_host_records(root).unwrap();
        if records.len() == expected {
            return records;
        }
        assert!(Instant::now() < deadline, "expected {expected} host records, got {records:?}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_no_host_records(root: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if load_terminal_host_records(root).unwrap().is_empty() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("terminal host record was not removed after close");
}

fn wait_for_host_size(root: &Path, cols: u16, rows: u16) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let mut records = load_terminal_host_records(root).unwrap();
        if records.len() == 1 {
            let (path, record) = records.pop().unwrap();
            if let Ok(host) = adopt_terminal_host(record, path) {
                let size = (host.snapshot.cols, host.snapshot.rows);
                host.disconnect();
                if size == (cols, rows) {
                    return;
                }
            }
        }
        assert!(Instant::now() < deadline, "host did not resize to {cols}x{rows}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_vt_size(path: &Path, surface: u64, cols: u16, rows: u16) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let state = request(path, serde_json::json!({"cmd": "vt-state", "surface": surface}));
        if state["cols"].as_u64() == Some(u64::from(cols))
            && state["rows"].as_u64() == Some(u64::from(rows))
        {
            return state;
        }
        assert!(Instant::now() < deadline, "daemon mirror did not resize to {cols}x{rows}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn first_surface(workspace: &serde_json::Value) -> Option<u64> {
    first_tab(workspace)?.get("surface")?.as_u64()
}

fn first_tab(workspace: &serde_json::Value) -> Option<&serde_json::Value> {
    workspace["screens"]
        .as_array()?
        .iter()
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .next()
}

fn connect_host(
    endpoint: &str,
    terminal_id: &str,
    token: &str,
    role: ClientRole,
    rights: CapabilityRights,
) -> anyhow::Result<UnixStream> {
    Ok(connect_host_detailed(endpoint, terminal_id, token, role, rights)?.stream)
}

struct DirectHostConnection {
    stream: UnixStream,
    snapshot: Frame,
    colors: TerminalColorOverrides,
    next_sequence: u64,
}

impl DirectHostConnection {
    fn wait_for_colors(&mut self, expected: &TerminalColorOverrides) {
        self.stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut awaiting_colors = false;
        loop {
            let frame = read_frame(&mut self.stream, MAX_FRAME_PAYLOAD)
                .expect("read terminal-host live frame")
                .expect("terminal host closed before Colors");
            assert_eq!(frame.request_id, 0, "unexpected control response on renderer stream");
            assert_eq!(
                frame.sequence, self.next_sequence,
                "terminal-host live sequence was not contiguous"
            );
            self.next_sequence = self.next_sequence.wrapping_add(1);
            match frame.kind {
                MessageKind::Output => match frame.flags {
                    0 => assert!(!awaiting_colors, "unflagged Output split a coupled pair"),
                    FLAG_COLORS_FOLLOW => {
                        assert!(!awaiting_colors, "nested coupled Output frames");
                        awaiting_colors = true;
                    }
                    flags => panic!("unknown Output flags {flags:#x}"),
                },
                MessageKind::Colors => {
                    assert_eq!(frame.flags, 0, "Colors defines no flags");
                    assert!(awaiting_colors, "unpaired live Colors frame");
                    awaiting_colors = false;
                    let colors = decode_terminal_color_overrides(&frame.payload).unwrap();
                    if &colors == expected {
                        return;
                    }
                }
                MessageKind::ResyncRequired => panic!("renderer was told to resync"),
                _ => {
                    assert_eq!(frame.flags, 0, "flags on non-coupled live frame");
                    assert!(!awaiting_colors, "live frame split Output/Colors pair");
                }
            }
        }
    }
}

fn connect_host_detailed(
    endpoint: &str,
    terminal_id: &str,
    token: &str,
    role: ClientRole,
    rights: CapabilityRights,
) -> anyhow::Result<DirectHostConnection> {
    let mut stream = UnixStream::connect(endpoint)?;
    let hello = ClientHello {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        role,
        requested_rights: rights,
        terminal_id: TerminalId::from_bytes(decode_hex(terminal_id)?),
        token: CapabilityToken::from_bytes(decode_hex(token)?),
    };
    write_frame(&mut stream, &hello.into_frame(1))?;
    let hello = read_frame(&mut stream, MAX_FRAME_PAYLOAD)?
        .ok_or_else(|| anyhow::anyhow!("host rejected capability"))?;
    if hello.kind != MessageKind::HostHello {
        anyhow::bail!("host did not return HostHello");
    }
    let snapshot = read_frame(&mut stream, MAX_FRAME_PAYLOAD)?
        .ok_or_else(|| anyhow::anyhow!("host closed before snapshot"))?;
    if snapshot.kind != MessageKind::Snapshot || snapshot.flags != 0 || snapshot.request_id != 0 {
        anyhow::bail!("host did not return Snapshot");
    }
    let colors_frame = read_frame(&mut stream, MAX_FRAME_PAYLOAD)?
        .ok_or_else(|| anyhow::anyhow!("host closed before Colors"))?;
    if colors_frame.kind != MessageKind::Colors
        || colors_frame.flags != 0
        || colors_frame.sequence != snapshot.sequence
        || colors_frame.request_id != 0
    {
        anyhow::bail!("host did not return Colors at the Snapshot boundary");
    }
    let colors = decode_terminal_color_overrides(&colors_frame.payload)?;
    Ok(DirectHostConnection {
        stream,
        next_sequence: snapshot.sequence.wrapping_add(1),
        snapshot,
        colors,
    })
}

fn snapshot_replay(payload: &[u8]) -> &[u8] {
    assert!(payload.len() >= 12, "Snapshot payload was truncated");
    let replay_len = u32::from_le_bytes(payload[8..12].try_into().unwrap()) as usize;
    let end = 12usize.checked_add(replay_len).expect("Snapshot replay length overflow");
    assert!(end <= payload.len(), "Snapshot replay was truncated");
    &payload[12..end]
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|window| window == needle)
}

fn decode_hex<const N: usize>(text: &str) -> anyhow::Result<[u8; N]> {
    if text.len() != N * 2 {
        anyhow::bail!("hex value has wrong length");
    }
    let mut output = [0; N];
    for (index, byte) in output.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[index * 2..index * 2 + 2], 16)?;
    }
    Ok(output)
}

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}
