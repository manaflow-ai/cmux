//! A program in the remote terminal opens the pasted path and reports bytes.
//! Acceptance of an upload alone does not establish that an agent can read it.
#![cfg(unix)]

use super::*;
use base64::Engine as _;
use serde_json::json;

// A valid one-pixel RGBA PNG, so the fixture also represents an openable screenshot.
const IMAGE: &[u8] = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0d\x49\x44\x41\x54\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

fn paste_helper(request: serde_json::Value) -> Output {
    let mut helper = Command::new(bin())
        .arg("__terminal-paste")
        .env_remove("CMUX_TUI_SOCKET")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn terminal paste helper");
    serde_json::to_writer(helper.stdin.take().unwrap(), &request).unwrap();
    let deadline = Instant::now() + Duration::from_secs(45);
    while helper.try_wait().unwrap().is_none() {
        if Instant::now() >= deadline {
            let _ = helper.kill();
            let _ = helper.wait();
            panic!("terminal paste helper exceeded fixture deadline");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    helper.wait_with_output().unwrap()
}

fn remote_reader(server: &HeadlessServer, count: usize) -> (String, PathBuf) {
    assert_success(&json_cli(server, &["workspace", "create", "--name", "remote-paste"]));
    let terminals = json_output(&json_cli(server, &["terminal", "list"]));
    let terminal = terminals[0]["id"].as_str().unwrap().to_owned();
    assert!(terminal.starts_with("term_"));
    let result = server.dir.join("remote-readback.json");
    let reader = server.dir.join("remote-reader.py");
    fs::write(&reader, r#"import base64, json, pathlib, shlex, sys, termios
settings = termios.tcgetattr(0)
settings[3] &= ~termios.ECHO
termios.tcsetattr(0, termios.TCSANOW, settings)
print('\x1b[?2004lPASTE_' + 'READY', flush=True)
paths = shlex.split(sys.stdin.readline())
assert len(paths) == int(sys.argv[2]), paths
result = [{'path': path, 'bytes': base64.b64encode(pathlib.Path(path).read_bytes()).decode()} for path in paths]
pathlib.Path(sys.argv[1]).write_text(json.dumps(result))
print('PASTE_' + 'READ_BACK', flush=True)
sys.stdin.readline()
"#).unwrap();
    let command = format!(
        "python3 -u {} {} {}\r",
        shell_quote(reader.to_str().unwrap()),
        shell_quote(result.to_str().unwrap()),
        count
    );
    assert_success(&json_cli(server, &["terminal", &terminal, "write", "--text", &command]));
    assert!(wait_for_screen(server, &terminal, "PASTE_READY").contains("PASTE_READY"));
    (terminal, result)
}

fn read_back(
    server: &HeadlessServer,
    terminal: &str,
    result: &std::path::Path,
) -> serde_json::Value {
    assert_success(&json_cli(server, &["terminal", terminal, "write", "--text", "\r"]));
    assert!(wait_for_screen(server, terminal, "PASTE_READ_BACK").contains("PASTE_READ_BACK"));
    serde_json::from_slice(&fs::read(result).unwrap()).unwrap()
}

#[test]
fn terminal_paste_image_uploads_bytes_and_remote_program_opens_path() {
    let server = HeadlessServer::start("terminal-paste-image");
    let local_source = server.dir.join("client-screenshot.png");
    fs::write(&local_source, IMAGE).unwrap();
    let (terminal, result) = remote_reader(&server, 1);
    let output = paste_helper(json!({
        "socket_path": server.socket, "terminal_id": terminal,
        "image": {"mime": "image/png", "data": base64::engine::general_purpose::STANDARD.encode(IMAGE)}
    }));
    assert_success(&output);
    assert_eq!(json_output(&output)["accepted"], true);
    let received = read_back(&server, &terminal, &result);
    let path = PathBuf::from(received[0]["path"].as_str().unwrap());
    assert!(path.is_absolute());
    assert_ne!(path, local_source);
    assert_eq!(fs::read(&path).unwrap(), IMAGE);
    assert_eq!(received[0]["bytes"], base64::engine::general_purpose::STANDARD.encode(IMAGE));
    // The helper has exited: its connection ending must not expire the image.
    assert!(path.exists());
}

#[test]
fn terminal_paste_files_preserve_quoted_names_empty_files_and_chunked_bytes() {
    let server = HeadlessServer::start("terminal-paste-files");
    let (terminal, result) = remote_reader(&server, 2);
    let source = server.dir.join("a ' quoted file.bin");
    let empty = server.dir.join("empty.txt");
    let bytes: Vec<u8> = (0..150_001).map(|i| (i % 251) as u8).collect();
    fs::write(&source, &bytes).unwrap();
    fs::write(&empty, []).unwrap();
    assert_success(&paste_helper(json!({
        "socket_path": server.socket, "terminal_id": terminal, "files": [source, empty]
    })));
    let received = read_back(&server, &terminal, &result);
    for (index, original) in [source, empty].iter().enumerate() {
        let path = PathBuf::from(received[index]["path"].as_str().unwrap());
        assert_ne!(&path, original);
        assert_eq!(path.file_name(), original.file_name());
        assert_eq!(fs::read(&path).unwrap(), fs::read(original).unwrap());
        assert_eq!(
            received[index]["bytes"],
            base64::engine::general_purpose::STANDARD.encode(fs::read(original).unwrap())
        );
    }
}

#[test]
fn terminal_paste_image_crosses_the_existing_remote_bridge_stream() {
    let server = HeadlessServer::start("terminal-paste-bridge");
    let (terminal, result) = remote_reader(&server, 1);
    let bridge = server.dir.join("bridge.py");
    fs::write(
        &bridge,
        r#"import json, os, select, socket, sys
remote = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
remote.connect(sys.argv[1])
print(json.dumps({'ok': True}), file=sys.stderr, flush=True)
while True:
    ready, _, _ = select.select([0, remote], [], [], 30)
    if not ready: break
    for source in ready:
        data = os.read(source if source == 0 else source.fileno(), 65536)
        if not data: sys.exit(0)
        if source == 0:
            # More than pipe capacity after readiness: the helper must keep
            # stderr open AND drain it while waiting for protocol replies.
            sys.stderr.write('bridge progress ' * 8192 + '\n')
            sys.stderr.flush()
            remote.sendall(data)
        else:
            while data:
                data = data[os.write(1, data):]
"#,
    )
    .unwrap();
    let python =
        Command::new("python3").args(["-c", "import sys; print(sys.executable)"]).output().unwrap();
    assert_success(&python);
    let output = paste_helper(json!({
        "socket_path": "/not-a-local-daemon.sock", "terminal_id": terminal,
        "bridge": {"executable": String::from_utf8(python.stdout).unwrap().trim(),
            "arguments": [bridge, server.socket], "reply_timeout_ms": 2000},
        "image": {"mime": "image/png", "data": base64::engine::general_purpose::STANDARD.encode(IMAGE)}
    }));
    assert_success(&output);
    let received = read_back(&server, &terminal, &result);
    assert_eq!(received[0]["bytes"], base64::engine::general_purpose::STANDARD.encode(IMAGE));
}

#[test]
fn terminal_paste_invalid_later_file_does_not_paste_an_earlier_file() {
    let server = HeadlessServer::start("terminal-paste-invalid-selection");
    let (terminal, result) = remote_reader(&server, 0);
    let source = server.dir.join("valid.png");
    fs::write(&source, IMAGE).unwrap();
    let output = paste_helper(json!({
        "socket_path": server.socket, "terminal_id": terminal, "files": [source, server.dir]
    }));
    assert!(!output.status.success());
    let received = read_back(&server, &terminal, &result);
    assert_eq!(received, json!([]));
}
