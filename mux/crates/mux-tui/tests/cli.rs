use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use mux_core::platform::transport;

struct HeadlessServer {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl HeadlessServer {
    fn start(name: &str) -> Self {
        let dir = unique_temp_dir(name);
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let child = Command::new(bin())
            .args(["--headless", "--socket"])
            .arg(&socket)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let server = Self { child, socket, dir };
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
}

impl Drop for HeadlessServer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_file(&self.socket);
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn cli_verbs_cover_command_output_errors_and_streams() {
    let server = HeadlessServer::start("matrix");

    let identify = cli(&server, &["identify"]);
    assert_success(&identify);
    assert!(String::from_utf8_lossy(&identify.stdout).starts_with("cmux-mux session="));

    let identify_json = cli(&server, &["--json", "identify"]);
    assert_success(&identify_json);
    let value: serde_json::Value = serde_json::from_slice(&identify_json.stdout).unwrap();
    assert_eq!(value.get("app").and_then(|v| v.as_str()), Some("cmux-mux"));
    assert!(value.get("protocol").and_then(|v| v.as_u64()).unwrap_or(0) >= 5);

    let ping_json = cli(&server, &["--json", "ping"]);
    assert_success(&ping_json);
    let ping: serde_json::Value = serde_json::from_slice(&ping_json.stdout).unwrap();
    assert_eq!(ping.get("ok").and_then(|v| v.as_bool()), Some(true));
    assert_eq!(ping.get("protocol").and_then(|v| v.as_u64()), Some(7));

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
        &["--json", "focus-direction", "--pane", &pane0.to_string(), "--dir", "right"],
    );
    assert_success(&focus);
    let focus_json: serde_json::Value = serde_json::from_slice(&focus.stdout).unwrap();
    assert_eq!(focus_json["pane"].as_u64(), Some(pane1));

    let zoom =
        cli(&server, &["--json", "zoom-pane", "--pane", &pane1.to_string(), "--mode", "toggle"]);
    assert_success(&zoom);
    let zoom_json: serde_json::Value = serde_json::from_slice(&zoom.stdout).unwrap();
    assert_eq!(zoom_json["zoomed"].as_bool(), Some(true));
    assert_eq!(zoom_json["zoomed_pane"].as_u64(), Some(pane1));

    let marker = format!("cmux_cli_marker_{}", std::process::id());
    let marker_suffix = std::process::id().to_string();
    let send = cli(
        &server,
        &[
            "send",
            "--surface",
            &surface.to_string(),
            "--text",
            &format!("printf 'cmux_cli_marker_%s\\n' '{marker_suffix}'\n"),
        ],
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
        .env_remove("CMUX_MUX_SOCKET")
        .output()
        .unwrap();
    assert_eq!(bogus.status.code(), Some(3));

    assert_subscribe_reports_tree_changed(&server);
}

fn assert_subscribe_reports_tree_changed(server: &HeadlessServer) {
    let mut child = Command::new(bin())
        .args(["--socket"])
        .arg(&server.socket)
        .arg("subscribe")
        .env_remove("CMUX_MUX_SOCKET")
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
        .env_remove("CMUX_MUX_SOCKET")
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

fn cli(server: &HeadlessServer, args: &[&str]) -> Output {
    Command::new(bin())
        .args(["--socket"])
        .arg(&server.socket)
        .args(args)
        .env_remove("CMUX_MUX_SOCKET")
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
    env!("CARGO_BIN_EXE_cmux-mux")
}
