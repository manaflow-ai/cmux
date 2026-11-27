//! Agent hooks that classic cmux wrote into an agent's own config
//! (`cmux hooks setup`: `~/.codex/hooks.json`, `~/.gemini/settings.json`, ...)
//! run `cmux hooks [enqueue] <agent> <subcommand>`. After the update to
//! cmux-next that `cmux` is this binary, and the agent must still report its
//! state: the hook reaches the journal as that agent's native event. A hook
//! for an agent whose classic payload this build doesn't read exits quietly,
//! as it did outside cmux, and never blocks the agent.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn socket_path(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-ch-{name}-{}-{stamp}.sock", std::process::id()))
}

/// Runs a classic hook command the way the agent does: the native payload on stdin.
fn classic_hook(socket: &PathBuf, args: &[&str], payload: &str) -> Child {
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(args)
        .env("CMUX_TUI_SOCKET", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(payload.as_bytes()).unwrap();
    child
}

fn wait_with_output(child: Child, budget: Duration) -> Option<std::process::Output> {
    let (sender, receiver) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let _ = sender.send(child.wait_with_output());
    });
    receiver.recv_timeout(budget).ok().and_then(Result::ok)
}

fn read_request(stream: &UnixStream) -> serde_json::Value {
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).expect("the hook's journal request");
    serde_json::from_str(&line).unwrap()
}

/// Answers the journal request; a hook that already gave up is not an error here.
fn reply(mut stream: &UnixStream, request: &serde_json::Value) {
    let response = serde_json::json!({
        "protocol":"cmux.protocol/2","type":"response","id":request["id"],"ok":true,
        "result":{"value":{"sequence":"1"}}
    });
    let _ = stream.write_all(format!("{response}\n").as_bytes());
}

/// The journal request a classic hook sends, with the hook's output.
fn journaled(args: &[&str], payload: &str) -> (serde_json::Value, std::process::Output) {
    let socket = socket_path(args[2]);
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(false).unwrap();
    let child = classic_hook(&socket, args, payload);
    let (sender, receiver) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let _ = sender.send(listener.accept().map(|(stream, _)| stream));
    });
    let stream = receiver
        .recv_timeout(Duration::from_secs(5))
        .ok()
        .and_then(Result::ok)
        .unwrap_or_else(|| panic!("`cmux {}` never reached the journal", args.join(" ")));
    let request = read_request(&stream);
    let output = wait_with_output(child, Duration::from_secs(5)).expect("the hook exits");
    reply(&stream, &request);
    let _ = std::fs::remove_file(&socket);
    (request, output)
}

#[test]
fn a_classic_codex_hook_reports_the_turn_end() {
    let (request, output) = journaled(
        &["hooks", "codex", "stop"],
        r#"{"session_id":"classic-codex","hook_event_name":"Stop"}"#,
    );
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request["operation"], "session.journal.append", "{request}");
    assert_eq!(request["params"]["event"]["payload"]["native_event"], "Stop", "{request}");
    assert!(request.to_string().contains("codex"), "{request}");
}

#[test]
fn a_queued_classic_hook_maps_to_the_agents_own_event() {
    // Gemini calls its prompt event BeforeAgent; classic named it prompt-submit.
    let (request, output) = journaled(
        &["hooks", "enqueue", "gemini", "prompt-submit"],
        r#"{"session_id":"classic-gemini"}"#,
    );
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request["params"]["event"]["payload"]["native_event"], "BeforeAgent", "{request}");
}

#[test]
fn a_classic_hook_this_build_cannot_read_exits_quietly() {
    // OpenCode's classic plugin sends its own payload shape: nothing is journaled,
    // and the plugin is not held up.
    let socket = socket_path("opencode");
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let child = classic_hook(
        &socket,
        &["hooks", "enqueue", "opencode", "stop"],
        r#"{"type":"session.idle"}"#,
    );
    let output = wait_with_output(child, Duration::from_secs(5)).expect("the hook exits");
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty(), "{}", String::from_utf8_lossy(&output.stderr));
    let mut connected = listener.accept().ok();
    if let Some((stream, _)) = connected.as_mut() {
        let mut text = String::new();
        let _ = stream.read_to_string(&mut text);
        panic!("journaled an unreadable classic payload: {text}");
    }
    let _ = std::fs::remove_file(&socket);
}

#[test]
fn a_hook_inside_a_cmux_terminal_names_the_socket_first() {
    // Classic's hook lines pass `--socket "$CMUX_SOCKET_PATH"` whenever it is set,
    // which next's own terminals do.
    let (request, output) = journaled(
        &["--socket", "/tmp/classic.sock", "hooks", "codex", "stop"],
        r#"{"session_id":"classic-codex","hook_event_name":"Stop"}"#,
    );
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request["params"]["event"]["payload"]["native_event"], "Stop", "{request}");
}

#[test]
fn a_folded_classic_subcommand_keeps_the_agents_own_event() {
    // Classic sent Copilot's Notification as `stop`: a permission prompt is not a finished turn.
    let (request, output) = journaled(
        &["hooks", "copilot", "stop"],
        r#"{"session_id":"classic-copilot","hook_event_name":"Notification"}"#,
    );
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request["params"]["event"]["payload"]["native_event"], "Notification", "{request}");
}

#[test]
fn a_classic_feed_hook_reports_the_event_it_names() {
    let (request, output) = journaled(
        &["hooks", "feed", "--source", "codex", "--event", "PreToolUse"],
        r#"{"session_id":"classic-codex","tool_name":"Bash"}"#,
    );
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request["params"]["event"]["payload"]["native_event"], "PreToolUse", "{request}");
}
