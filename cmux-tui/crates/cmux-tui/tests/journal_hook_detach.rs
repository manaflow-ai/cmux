//! `cmux-tui-hook` must never hold the provider hostage to the journal
//! server: it exits once the request is written, and a detached child waits
//! for the receipt. Providers block their agent on the hook's exit and on EOF
//! of its stdout, so both must happen before the server answers.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn socket_path(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-hd-{name}-{}-{stamp}.sock", std::process::id()))
}

fn spawn_hook(socket: &PathBuf, event: &str) -> Child {
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui-hook"))
        .args(["codex", event])
        .env("CMUX_TUI_SOCKET", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"{\"session_id\":\"detach-test\"}\n").unwrap();
    child
}

/// Waits for exit AND stdout/stderr EOF, which is what a provider waits for.
fn wait_with_output(child: Child, budget: Duration) -> Option<std::process::Output> {
    let (sender, receiver) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let _ = sender.send(child.wait_with_output());
    });
    receiver.recv_timeout(budget).ok().and_then(Result::ok)
}

fn read_request(stream: &UnixStream) -> String {
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .expect("set journal request read timeout");
    let mut line = String::new();
    BufReader::new(stream)
        .read_line(&mut line)
        .unwrap_or_else(|error| panic!("read journal request before timeout: {error}"));
    line
}

fn reply(mut stream: &UnixStream, request: &str) {
    let request: serde_json::Value = serde_json::from_str(request).unwrap();
    let response = serde_json::json!({
        "protocol":"cmux.protocol/2","type":"response","id":request["id"],"ok":true,
        "result":{"value":{"sequence":"1"}}
    });
    stream.write_all(format!("{response}\n").as_bytes()).unwrap();
}

#[test]
fn detached_hook_exits_before_the_server_answers() {
    let socket = socket_path("exit");
    let listener = UnixListener::bind(&socket).unwrap();
    let started = Instant::now();
    let child = spawn_hook(&socket, "Stop");
    let (stream, _) = listener.accept().unwrap();
    let request = read_request(&stream);
    assert!(request.contains("\"session.journal.append\""), "{request}");

    // The server has not answered yet; the provider-facing process must be
    // gone, with its stdout closed, without waiting for the receipt.
    let output = wait_with_output(child, Duration::from_secs(3))
        .expect("hook must exit before the journal receipt arrives");
    assert!(output.status.success(), "{output:?}");
    assert!(started.elapsed() < Duration::from_secs(3));

    reply(&stream, &request);
    let _ = std::fs::remove_file(&socket);
}

/// The process at the other end of `stream`.
#[cfg(target_os = "macos")]
fn peer_pid(stream: &UnixStream) -> libc::pid_t {
    use std::os::fd::AsRawFd;
    let mut pid: libc::pid_t = 0;
    let mut length = libc::socklen_t::try_from(size_of::<libc::pid_t>()).unwrap();
    // SAFETY: `pid` is a valid buffer of `length` bytes for this option of an open socket.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&raw mut pid).cast(),
            &raw mut length,
        )
    };
    assert_eq!(result, 0, "{}", std::io::Error::last_os_error());
    pid
}

/// The process at the other end of `stream`.
#[cfg(target_os = "linux")]
fn peer_pid(stream: &UnixStream) -> libc::pid_t {
    use std::os::fd::AsRawFd;
    let mut peer = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut length = libc::socklen_t::try_from(size_of::<libc::ucred>()).unwrap();
    // SAFETY: `peer` is a valid buffer of `length` bytes for this option of an open socket.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut peer).cast(),
            &raw mut length,
        )
    };
    assert_eq!(result, 0, "{}", std::io::Error::last_os_error());
    peer.pid
}

/// The daemon's accept loop knows a terminal's processes by their process session (`getsid`,
/// cmux-tui-core `server/terminal_sessions.rs`). The child that sends the report is NOT in the
/// session of the hook the provider ran: it leads its own (`detach_session`), so that neither
/// the provider nor a closed terminal ends a report on its way. So the daemon cannot place a
/// hook connection at accept, and places it by its first line (the terminal lane, #27698).
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn the_child_that_sends_the_report_leads_its_own_process_session() {
    let socket = socket_path("session");
    let listener = UnixListener::bind(&socket).unwrap();
    let child = spawn_hook(&socket, "Stop");
    // The hook is this test's child and starts no session: it is in this test's process
    // session. Read from this process, because the hook may have exited already.
    // SAFETY: getsid only reads kernel process metadata.
    let hook_session = unsafe { libc::getsid(0) };
    let (stream, _) = listener.accept().unwrap();
    let sender = peer_pid(&stream);
    // SAFETY: as above.
    let sender_session = unsafe { libc::getsid(sender) };
    let request = read_request(&stream);

    assert!(hook_session > 0 && sender_session > 0, "{hook_session} {sender_session}");
    assert_ne!(sender, libc::pid_t::try_from(child.id()).unwrap(), "the hook itself sent");
    assert_eq!(sender_session, sender, "the sending child does not lead a process session");
    assert_ne!(sender_session, hook_session, "the sending child is in the hook's session");

    reply(&stream, &request);
    let _ = wait_with_output(child, Duration::from_secs(3));
    let _ = std::fs::remove_file(&socket);
}

#[test]
fn detached_hook_writes_the_request_before_exiting_even_when_the_server_is_not_accepting() {
    let socket = socket_path("order");
    let listener = UnixListener::bind(&socket).unwrap();
    // Nothing accepts yet: the requests sit in the listen backlog. Each hook
    // still exits only after its own request is written, so provider order
    // becomes arrival order.
    for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
        let output = wait_with_output(spawn_hook(&socket, event), Duration::from_secs(3))
            .expect("hook must exit while the server is not accepting");
        assert!(output.status.success(), "{event}: {output:?}");
    }
    let mut seen = Vec::new();
    for _ in 0..3 {
        let (stream, _) = listener.accept().unwrap();
        let request = read_request(&stream);
        let value: serde_json::Value = serde_json::from_str(&request).unwrap();
        seen.push(
            value["params"]["event"]["payload"]["native_event"].as_str().unwrap_or("").to_owned(),
        );
        reply(&stream, &request);
    }
    assert_eq!(seen, ["SessionStart", "UserPromptSubmit", "Stop"]);
    let _ = std::fs::remove_file(&socket);
}

#[test]
fn detached_hook_without_a_listener_fails_immediately() {
    let socket = socket_path("dead");
    let started = Instant::now();
    let output = wait_with_output(spawn_hook(&socket, "Stop"), Duration::from_secs(3))
        .expect("hook must exit when no server listens");
    // No listener means this terminal is not attached to a live cmux-tui: the
    // child gives up at once and the provider-facing process reports it,
    // without spending the retry deadline.
    assert!(!output.status.success(), "{output:?}");
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn detached_child_rejects_a_newline_free_request_id_before_reading_payload() {
    let socket = socket_path("missing-id-delimiter");
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui-hook"))
        .args(["__detached-append"])
        .env("CMUX_TUI_SOCKET", &socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"550e8400-e29b-41d4-a716-446655440000{}").unwrap();
    let output = child.wait_with_output().unwrap();

    assert!(!output.status.success(), "{output:?}");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("detached request id is missing newline delimiter"), "{stderr}");
}

/// Hosts that receive only the cmux-tui binary (SSH bootstrap) run the helper
/// as `cmux-tui __agent-hook`; its detached child must re-enter that mode.
#[test]
fn embedded_hook_mode_delivers_through_the_detached_child() {
    let socket = socket_path("embedded");
    let listener = UnixListener::bind(&socket).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["__agent-hook", "claude", "Stop"])
        .env("CMUX_TUI_SOCKET", &socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"{\"session_id\":\"embedded-test\"}\n").unwrap();
    let (stream, _) = listener.accept().unwrap();
    let request = read_request(&stream);
    let value: serde_json::Value = serde_json::from_str(&request).unwrap();
    assert_eq!(value["operation"], "session.journal.append", "{request}");
    assert_eq!(value["params"]["event"]["payload"]["native_event"], "Stop", "{request}");
    let output = wait_with_output(child, Duration::from_secs(3))
        .expect("embedded hook must exit before the journal receipt arrives");
    assert!(output.status.success(), "{output:?}");
    reply(&stream, &request);
    let _ = std::fs::remove_file(&socket);
}
