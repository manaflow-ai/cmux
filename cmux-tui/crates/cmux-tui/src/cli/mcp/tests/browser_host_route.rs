//! Code mode reaches a browser host without manual steps: the app daemon's
//! host (the in-app browser) first, else a host it starts itself, as
//! `cmux-browser-host eval` does (plans/cmux-next/computer-use-lead.md,
//! Codemode parity).

use std::ffi::OsString;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};

use super::super::transport::{HostRoute, Reach, browser_host, browser_host_routes};
use super::*;

fn env<'a>(pairs: &'a [(&'a str, &'a OsString)]) -> impl Fn(&str) -> Option<OsString> + 'a {
    move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).clone())
}

/// A file at the socket path a daemon's host listens on (the daemon binds
/// it when it has a host binary).
fn daemon_with_host(dir: &Path) -> (PathBuf, PathBuf) {
    let daemon = dir.join("d.sock");
    let host = cmux_tui_core::browser_host::socket_path_for(&daemon);
    std::fs::create_dir_all(host.parent().unwrap()).unwrap();
    std::fs::write(&host, b"").unwrap();
    (daemon, host)
}

#[test]
fn codemode_parity_the_app_daemons_host_comes_before_a_private_one() {
    let dir = cmux_unix_socket::short_test_dir("bhroute");
    let (daemon, host) = daemon_with_host(dir.path());
    let own: OsString = dir.path().join("own.sock").into();
    let pairs = [("CMUX_BROWSER_HOST_SOCKET", &own)];
    let binary = PathBuf::from("/bundle/bin/cmux-browser-host");
    let routes = browser_host_routes(&env(&pairs), Some(&daemon), Some(binary.clone()));
    assert_eq!(
        routes,
        vec![
            HostRoute { socket: host, reach: Reach::DaemonHost },
            HostRoute { socket: PathBuf::from(&own), reach: Reach::Start(binary.clone()) },
        ],
        "an acpmux agent (no CMUX_TUI_SOCKET) reaches the app's in-app browser first"
    );

    // A daemon without a host (no socket file): only the private host.
    let bare = dir.path().join("bare.sock");
    let routes = browser_host_routes(&env(&pairs), Some(&bare), Some(binary.clone()));
    assert_eq!(
        routes,
        vec![HostRoute { socket: PathBuf::from(&own), reach: Reach::Start(binary) }]
    );
}

#[test]
fn codemode_parity_a_daemon_terminal_waits_for_its_daemons_host() {
    let dir = cmux_unix_socket::short_test_dir("bhroute");
    let named: OsString = dir.path().join("bh").join("browser-host.sock").into();
    let daemon: OsString = dir.path().join("d.sock").into();
    let pairs = [("CMUX_BROWSER_HOST_SOCKET", &named), ("CMUX_TUI_SOCKET", &daemon)];
    let routes = browser_host_routes(
        &env(&pairs),
        Some(Path::new(&daemon)),
        Some(PathBuf::from("/bundle/bin/cmux-browser-host")),
    );
    assert_eq!(routes, vec![HostRoute { socket: PathBuf::from(&named), reach: Reach::Daemon }]);
}

/// The lead's measurement (2026-10-23): with no host on the socket every
/// `browser_repl_*` call failed `browser_host.unavailable`. The server
/// starts the host binary's `serve --socket <socket>` and sends the call.
#[test]
fn codemode_parity_a_missing_host_is_started_and_answers() {
    let dir = cmux_unix_socket::short_test_dir("bhstart");
    let socket = dir.path().join("h.sock");
    let started = dir.path().join("started");
    let fifo = std::ffi::CString::new(started.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: a NUL-terminated path; mkfifo(2) only creates the node.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    // The fake host says how it was started, then lives a while; this test
    // serves the socket for it once it ran.
    let fake = dir.path().join("fake-host");
    std::fs::write(
        &fake,
        format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nexec sleep 20\n", started.display()),
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let server_socket = socket.clone();
    let server = std::thread::spawn(move || {
        let mut args = String::new();
        std::fs::File::open(&started).unwrap().read_to_string(&mut args).unwrap();
        let listener = UnixListener::bind(&server_socket).unwrap();
        let (stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        let reply = json!({"id": request["id"], "result": {"sessions": []}});
        (&stream).write_all(format!("{reply}\n").as_bytes()).unwrap();
        (args, request)
    });
    let routes = [HostRoute { socket: socket.clone(), reach: Reach::Start(fake) }];
    let result =
        browser_host(&routes, "browser.repl.list", json!({}), Duration::from_secs(10), false);
    assert_eq!(result.ok(), Some(json!({"sessions": []})));
    let (args, request) = server.join().unwrap();
    assert_eq!(args, format!("serve\n--socket\n{}\n", socket.display()));
    assert_eq!(request["method"], "browser.repl.list");
    assert_eq!(request["origin"], "mcp");
}

/// An agent chat's call without `session` uses the chat's own session, so
/// it gets the in-app browser (the host keeps the implicit `default` off the
/// person's tabs) and two chats never share one page.
#[test]
fn codemode_parity_an_agent_chat_gets_its_own_named_session() {
    let eval = browser_tools::find("browser_repl_eval").unwrap();
    let request =
        eval.request(json!({"code": "1"}).as_object().unwrap(), Some("s_7f/a b")).unwrap();
    assert_eq!(request.params["session"], "agent-s_7f-a-b");
    let named = json!({"code": "1", "session": "work"});
    let request = eval.request(named.as_object().unwrap(), Some("s_7f")).unwrap();
    assert_eq!(request.params["session"], "work", "an explicit session wins");
    let request = eval.request(json!({"code": "1"}).as_object().unwrap(), None).unwrap();
    assert_eq!(request.params.get("session"), None, "outside a chat the host's default stays");
    let list = browser_tools::find("browser_repl_list").unwrap();
    let request = list.request(&Map::new(), Some("s_7f")).unwrap();
    assert_eq!(request.params, json!({}), "an operation without a session field gets none");
    let long = "x".repeat(100);
    assert_eq!(browser_tools::agent_session_name(&long).unwrap().len(), 64);
    assert_eq!(browser_tools::agent_session_name("  "), None);
}
