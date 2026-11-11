//! A dropped connection heals itself (self-healing DESIGN, 2026-10-19): the
//! app closes the first connection after it read the request (a restart of its
//! control server, a refusal under load), and the CLI sends the same request
//! again on a new connection, with the same idempotency key, so the app replays
//! the run instead of running it twice. Before, the CLI stopped at "transport
//! closed" / `mutation.outcome_unknown` and the caller had to retry by hand.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

fn temp_dir(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = Path::new("/tmp").join(format!("cmux-{name}-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Reads one request line from the next connection; answers it when `reply`
/// is set, else closes the connection without an answer.
fn serve_one(listener: &UnixListener, reply: Option<Value>) -> Value {
    let (stream, _) = listener.accept().unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let request: Value = serde_json::from_str(&line).unwrap();
    if let Some(result) = reply {
        let mut stream = stream;
        let answer = json!({ "id": request["id"], "ok": true, "result": result });
        writeln!(stream, "{answer}").unwrap();
    }
    request
}

#[test]
fn a_run_whose_connection_dropped_is_sent_again_with_the_same_key() {
    let dir = temp_dir("resend");
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "--app-socket"])
        .arg(&socket)
        .args(["action", "run", "window.new"])
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    let first = serve_one(&listener, None);
    let second = serve_one(
        &listener,
        Some(json!({ "action": "window.new", "ran": true, "replayed": true })),
    );
    let output = child.wait_with_output().unwrap();
    drop(listener);
    let _ = std::fs::remove_dir_all(&dir);

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(0), "{stderr}");
    assert_eq!(first["method"], "action.run");
    assert_eq!(second["method"], "action.run");
    let key = first["params"]["idempotency_key"].as_str().expect("a keyed run");
    assert_eq!(second["params"]["idempotency_key"].as_str(), Some(key));
    assert!(!stderr.contains("outcome_unknown"), "{stderr}");
}

#[test]
fn an_unkeyed_mutation_is_never_sent_twice() {
    // `errors.clear` carries no key: a resend could clear twice, so the CLI
    // reports the dropped connection instead.
    let dir = temp_dir("noresend");
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(false).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "--app-socket"])
        .arg(&socket)
        .args(["errors", "clear"])
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let first = serve_one(&listener, None);
    let output = child.wait_with_output().unwrap();
    // No second connection came.
    listener.set_nonblocking(true).unwrap();
    let again = listener.accept();
    drop(listener);
    let _ = std::fs::remove_dir_all(&dir);

    assert_ne!(output.status.code(), Some(0));
    assert!(first["method"].as_str().is_some_and(|method| method.starts_with("errors.")));
    assert!(again.is_err(), "the CLI sent an unkeyed mutation again");
}

fn cmux(socket: &Path, args: &[&str]) -> std::process::Child {
    Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "--app-socket"])
        .arg(socket)
        .args(args)
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

/// An app that quit after it read the request (its socket gone): the read fails at the restart limit (5 s) with the
/// app unreachable, not after the request's whole deadline of reconnects (30 s and more).
#[test]
fn a_read_of_an_app_that_quit_fails_at_the_restart_limit() {
    let dir = temp_dir("quit");
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let child = cmux(&socket, &["action", "run", "window.new"]);
    let first = serve_one(&listener, None);
    let quit = Instant::now();
    drop(listener);
    std::fs::remove_file(&socket).unwrap();
    let output = child.wait_with_output().unwrap();
    let took = quit.elapsed();
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(first["method"], "action.run");
    assert_ne!(output.status.code(), Some(0));
    let printed = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    // The answer is the socket that did not come back, not the dropped connection.
    assert!(printed.contains("unreachable"), "{printed}");
    // Generous for a loaded runner; the deadline it no longer waits out is 30 s.
    assert!(took < Duration::from_secs(15), "{took:?}");
}

/// A socket this user may not open fails the same way every time: no reconnects at all.
#[test]
fn a_socket_without_permission_is_not_waited_on() {
    use std::os::unix::fs::PermissionsExt as _;
    if unsafe { libc::geteuid() } == 0 {
        return; // root opens any socket
    }
    let dir = temp_dir("denied");
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let child = cmux(&socket, &["action", "run", "window.new"]);
    // The socket is closed to this user before the connection drops, so the CLI's first reconnect meets it.
    let (stream, _) = listener.accept().unwrap();
    let mut line = String::new();
    BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o000)).unwrap();
    let dropped = Instant::now();
    drop(stream);
    let output = child.wait_with_output().unwrap();
    let took = dropped.elapsed();
    listener.set_nonblocking(true).unwrap();
    let again = listener.accept();
    drop(listener);
    let _ = std::fs::remove_dir_all(&dir);

    assert_ne!(output.status.code(), Some(0));
    assert!(again.is_err(), "the CLI connected again");
    assert!(took < Duration::from_secs(10), "{took:?}");
}

/// No connection carries nothing: every one the CLI opens sends its request (no probe connections).
fn no_more_connections(listener: &UnixListener) -> bool {
    listener.set_nonblocking(true).unwrap();
    listener.accept().is_err()
}

/// A control server that takes 2.5 s to come back after it dropped the connection (slower than the old 1 s
/// grace): the CLI keeps reconnecting with backoff and sends the same keyed run to the restarted server.
#[test]
fn a_control_server_that_restarts_in_2_5_s_is_reconnected() {
    let dir = temp_dir("restart");
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let child = cmux(&socket, &["action", "run", "window.new"]);
    let first = serve_one(&listener, None);
    drop(listener);
    std::fs::remove_file(&socket).unwrap();
    std::thread::sleep(Duration::from_millis(2500));
    let listener = UnixListener::bind(&socket).unwrap();
    let second = serve_one(
        &listener,
        Some(json!({ "action": "window.new", "ran": true, "replayed": true })),
    );
    let output = child.wait_with_output().unwrap();
    let extra = !no_more_connections(&listener);
    drop(listener);
    let _ = std::fs::remove_dir_all(&dir);

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(0), "{stderr}");
    let key = first["params"]["idempotency_key"].as_str().expect("a keyed run");
    assert_eq!(second["params"]["idempotency_key"].as_str(), Some(key));
    assert!(!extra, "the CLI opened a connection it sent nothing on");
}

/// Answers the next line on `reader` with `result`.
fn answer(reader: &mut BufReader<std::os::unix::net::UnixStream>, result: Value) -> Value {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let request: Value = serde_json::from_str(&line).unwrap();
    let reply = json!({ "id": request["id"], "ok": true, "result": result });
    writeln!(reader.get_mut(), "{reply}").unwrap();
    request
}

/// `--socket` names the app's socket, and the app restarts its control server under a request: the restarting
/// server takes connections and closes them before it answers `ping`. That is an app coming back, not "another
/// kind of socket": the CLI waits and the run goes through.
#[test]
fn a_socket_flag_app_that_restarts_is_not_called_another_kind_of_socket() {
    let dir = temp_dir("socketflag");
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "--socket"])
        .arg(&socket)
        .args(["action", "run", "window.new"])
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let (stream, _) = listener.accept().unwrap();
    let mut reader = BufReader::new(stream);
    let ping = answer(&mut reader, json!({ "pong": true }));
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let first: Value = serde_json::from_str(&line).unwrap();
    drop(reader);
    // Restarting: two connections closed before any answer.
    for _ in 0..2 {
        let (stream, _) = listener.accept().unwrap();
        drop(stream);
    }
    let (stream, _) = listener.accept().unwrap();
    let mut reader = BufReader::new(stream);
    let _ = answer(&mut reader, json!({ "pong": true }));
    let second =
        answer(&mut reader, json!({ "action": "window.new", "ran": true, "replayed": true }));
    let output = child.wait_with_output().unwrap();
    let extra = !no_more_connections(&listener);
    drop(listener);
    let _ = std::fs::remove_dir_all(&dir);

    let printed = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(ping["method"], "system.ping");
    assert_eq!(output.status.code(), Some(0), "{printed}");
    assert!(!printed.contains("wrong_kind"), "{printed}");
    assert_eq!(second["params"]["idempotency_key"], first["params"]["idempotency_key"]);
    assert!(!extra, "the CLI opened a connection it sent nothing on");
}
