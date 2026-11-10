//! #27698 keeps 16 of the daemon's 64 connections for the app: the processes in the session's
//! terminals may hold 48. The accept loop knew such a process only by its process session
//! (`getsid`), and an agent hook's sending child leaves that session before it connects
//! (`cmux-tui-hook` `detach_session`: `setsid`, so neither the provider nor a closed terminal
//! ends a report on its way). So hook children counted as outside clients and took from all 64:
//! a burst of agents that report at one time (a launch after an update, 170 agents) locked the
//! app out of its own daemon. Bench hold r1 showed 61 hook connections open at one time.
//!
//! These tests run the real accept loop on a real socket. A terminal of the session starts 56
//! processes that each send one agent hook report and keep the connection; then the app
//! connects 16 times. The two tests differ only in `setsid`.

#![cfg(unix)]

use std::os::unix::process::CommandExt as _;
use std::process::{Command, Stdio};

use super::*;

/// The test the terminal's processes run (this binary, in another role).
const PROCESS_TEST: &str = "server::tests::hook_connection_lane::hook_children_that_left_the_terminals_process_session_leave_the_apps_connections_free";
/// `launcher` (the terminal's program) or `client` (one hook child).
const ROLE: &str = "CMUX_TEST_HOOK_LANE_ROLE";
const SOCKET: &str = "CMUX_TEST_HOOK_LANE_SOCKET";
/// The directory the clients report in: `<index>.admitted`, `<index>.refused`, and `stop`.
const RESULTS: &str = "CMUX_TEST_HOOK_LANE_RESULTS";
/// `1`: each client leaves the terminal's process session before it connects.
const OWN_SESSION: &str = "CMUX_TEST_HOOK_LANE_OWN_SESSION";
const INDEX: &str = "CMUX_TEST_HOOK_LANE_INDEX";

/// More than the terminal lane (48), fewer than the daemon's limit (64).
const HOOK_CHILDREN: usize = 56;
/// What #27698 keeps for the app.
const APP_CONNECTIONS: usize = MAX_SERVER_CONNECTIONS - MAX_TERMINAL_CONNECTIONS;
const WAIT: Duration = Duration::from_secs(90);
/// How long one connection waits for the daemon's answer to its first line.
const ANSWER_WAIT: Duration = Duration::from_secs(20);

/// What the daemon answered.
struct Seen {
    hooks_admitted: usize,
    hooks_refused: usize,
    app_admitted: usize,
    app_refused: usize,
}

#[test]
fn hook_children_that_left_the_terminals_process_session_leave_the_apps_connections_free() {
    if ran_as_a_terminal_process() {
        return;
    }
    let seen = connect_from_a_terminal_then_from_the_app(true);
    assert_eq!(
        seen.app_refused, 0,
        "the app was refused {} of its {APP_CONNECTIONS} connections: {} hook children hold connections",
        seen.app_refused, seen.hooks_admitted
    );
    assert_eq!(seen.app_admitted, APP_CONNECTIONS);
    assert!(
        seen.hooks_admitted > 0 && seen.hooks_admitted <= MAX_TERMINAL_CONNECTIONS,
        "{} hook children hold connections; the terminal lane is {MAX_TERMINAL_CONNECTIONS}",
        seen.hooks_admitted
    );
    assert_eq!(
        seen.hooks_admitted + seen.hooks_refused,
        HOOK_CHILDREN,
        "a hook child past the lane reads the busy line"
    );
}

/// The same processes without `setsid`: the accept loop knows them by the terminal's process
/// session. This is the part #27698 covered.
#[test]
fn processes_in_the_terminals_process_session_leave_the_apps_connections_free() {
    let seen = connect_from_a_terminal_then_from_the_app(false);
    assert_eq!(seen.app_refused, 0, "{} processes hold connections", seen.hooks_admitted);
    assert_eq!(seen.app_admitted, APP_CONNECTIONS);
    assert!(seen.hooks_admitted > 0 && seen.hooks_admitted <= MAX_TERMINAL_CONNECTIONS);
    assert_eq!(seen.hooks_admitted + seen.hooks_refused, HOOK_CHILDREN);
}

fn connect_from_a_terminal_then_from_the_app(own_session: bool) -> Seen {
    let results = cmux_unix_socket::short_test_dir("hkl");
    let socket = TestSocket::new("hook-lane");
    let exe = std::env::current_exe().unwrap().to_string_lossy().into_owned();
    let text = |path: &Path| path.to_string_lossy().into_owned();
    let options = SurfaceOptions {
        command: Some(
            [exe.as_str(), "--exact", PROCESS_TEST, "--nocapture", "--test-threads", "1"]
                .map(String::from)
                .to_vec(),
        ),
        extra_env: vec![
            (ROLE.into(), "launcher".into()),
            (SOCKET.into(), text(&socket.path)),
            (RESULTS.into(), text(results.path())),
            (OWN_SESSION.into(), String::from(if own_session { "1" } else { "0" })),
        ],
        ..SurfaceOptions::default()
    };
    // What the daemon does at its start (`cmux-tui` owner_start.rs). This process holds the
    // daemon's end of every connection and the app's end too: the default soft limit of open
    // files (256 on macOS) is too low for that, and the terminal's processes get it back.
    crate::raise_open_file_limit(crate::OPEN_FILE_LIMIT_CEILING).unwrap();
    // A real PTY and a real process: the accept loop reads the peer's process session.
    let mux = Mux::new("hook-lane", options);
    serve_paused(mux.clone(), Some(socket.path.clone())).unwrap().mark_ready().unwrap();
    let terminal = mux.new_workspace(None, Some((80, 24))).unwrap();
    assert!(terminal.process_id().is_some(), "the terminal has no process");

    let answered = |suffix: &str| {
        std::fs::read_dir(results.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().ends_with(suffix))
            .count()
    };
    let deadline = Instant::now() + WAIT;
    while answered(".admitted") + answered(".refused") < HOOK_CHILDREN {
        assert!(
            Instant::now() < deadline,
            "{} admitted and {} refused of {HOOK_CHILDREN} hook children after {WAIT:?}",
            answered(".admitted"),
            answered(".refused")
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let (hooks_admitted, hooks_refused) = (answered(".admitted"), answered(".refused"));
    eprintln!(
        "own_session={own_session}: {hooks_admitted} hook children admitted, {hooks_refused} refused"
    );

    // The app: every connection stays open, as the app's do.
    let mut app = Vec::new();
    let mut app_admitted = 0;
    for _ in 0..APP_CONNECTIONS {
        let mut stream = std::os::unix::net::UnixStream::connect(&socket.path).unwrap();
        if admitted(&mut stream, "{\"id\":1,\"cmd\":\"ping\"}\n") {
            app_admitted += 1;
        }
        app.push(stream);
    }

    std::fs::write(results.path().join("stop"), b"").unwrap();
    eprintln!(
        "own_session={own_session}: the app has {app_admitted} of {APP_CONNECTIONS} connections"
    );
    drop(app);
    let _ = mux.close_surface(terminal.id);
    mux.shutdown();
    cleanup(&socket.path);
    Seen {
        hooks_admitted,
        hooks_refused,
        app_admitted,
        app_refused: APP_CONNECTIONS - app_admitted,
    }
}

/// Sends `line` and reads the answer. False for the busy line (`server.busy`) or a close: the
/// daemon refused the connection. A connection the daemon keeps and has not answered yet is
/// admitted.
fn admitted(stream: &mut std::os::unix::net::UnixStream, line: &str) -> bool {
    stream.set_read_timeout(Some(ANSWER_WAIT)).unwrap();
    // A connection refused at accept is closed already: the write may fail, the busy line is
    // still there to read.
    let _ = stream.write_all(line.as_bytes()).and_then(|()| stream.flush());
    let mut answer = String::new();
    match BufReader::new(&*stream).read_line(&mut answer) {
        Ok(0) => false,
        Ok(_) => {
            let answer: Value = serde_json::from_str(&answer).expect("one JSON line");
            answer["type"] != "refused"
        }
        Err(error) => {
            matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut)
        }
    }
}

/// The roles this binary plays inside the terminal. False in the test itself.
fn ran_as_a_terminal_process() -> bool {
    match std::env::var(ROLE).as_deref() {
        Ok("launcher") => start_hook_children(),
        Ok("client") => hold_one_hook_connection(),
        _ => return false,
    }
    true
}

/// The terminal's program: starts the hook children and stays until they end.
fn start_hook_children() {
    let own_session = std::env::var(OWN_SESSION).as_deref() == Ok("1");
    let exe = std::env::current_exe().unwrap();
    let children: Vec<_> = (0..HOOK_CHILDREN)
        .map(|index| {
            let mut command = Command::new(&exe);
            command
                .args(["--exact", PROCESS_TEST, "--nocapture", "--test-threads", "1"])
                .env(ROLE, "client")
                .env(INDEX, index.to_string())
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            if own_session {
                // What the hook helper does for its sending child (`detach_session`).
                // SAFETY: `setsid` is async-signal-safe and the closure allocates nothing.
                unsafe {
                    command.pre_exec(|| {
                        if libc::setsid() == -1 {
                            return Err(std::io::Error::last_os_error());
                        }
                        Ok(())
                    });
                }
            }
            command.spawn().unwrap()
        })
        .collect();
    for mut child in children {
        let _ = child.wait();
    }
}

/// One hook child: sends one agent hook report, says what the daemon answered, and keeps an
/// admitted connection until the test ends (as a child that waits for its receipt does).
fn hold_one_hook_connection() {
    let index = std::env::var(INDEX).unwrap();
    let results = PathBuf::from(std::env::var_os(RESULTS).unwrap());
    let mut stream = std::os::unix::net::UnixStream::connect(std::env::var_os(SOCKET).unwrap());
    let kept = match stream.as_mut() {
        Ok(stream) => admitted(stream, &hook_report_line(&index)),
        Err(_) => false,
    };
    if !kept {
        // The helper drops a refused connection before it waits to try again.
        drop(stream);
    }
    let name = format!("{index}.{}", if kept { "admitted" } else { "refused" });
    std::fs::write(results.join(name), b"").unwrap();
    let deadline = Instant::now() + WAIT + WAIT;
    while results.exists() && !results.join("stop").exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// The request line the hook helper sends (`cmux-tui-hook` `encode_request`), with the event
/// the helper builds for a provider's hook.
fn hook_report_line(index: &str) -> String {
    let terminal = std::env::var("CMUX_TUI_TERMINAL_ID").ok();
    let event = crate::agent_hook_journal_ingress(
        "codex",
        "Stop",
        terminal.as_deref(),
        json!({"session_id": format!("hook-lane-{index}")}),
    )
    .unwrap();
    let request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": format!("request_{index:0>32}"),
        "operation": "session.journal.append",
        "params": {"machine": "current", "session": "current", "event": event},
        "idempotency_key": format!("mutation_{index:0>32}"),
    });
    format!("{request}\n")
}
