//! `browser-host-provider` (browser-host.md step c2): only the verified
//! local app gets the browser host's provider credentials; with them it dials
//! the host the daemon started, proves the secret, and receives the session
//! end's `tabs.close {reason: session_end}` for a tab an agent session opened.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::server::origin_gate::{
    set_peer_key_for_test, set_role_for_test, set_verified_app_for_test,
};
use crate::server::*;

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("bh-provider-{label}"), crate::SurfaceOptions::default())
}

fn connect(mux: &Arc<Mux>, transport: ClientTransport) -> Conn {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(transport, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    Conn { client, writer, outbound, scheduler }
}

fn verified_app(mux: &Arc<Mux>, transport: ClientTransport) -> Conn {
    let conn = connect(mux, transport);
    set_role_for_test(mux, conn.client, "main");
    set_peer_key_for_test(mux, conn.client, "token:100.1");
    set_verified_app_for_test(mux, conn.client, true);
    conn
}

fn provider(mux: &Arc<Mux>, conn: &Conn) -> Value {
    let request = json!({"id": 1, "cmd": "browser-host-provider"});
    assert!(handle_connection_message(
        mux,
        conn.client,
        &request.to_string(),
        &conn.writer,
        &conn.scheduler
    ));
    reply(conn)
}

/// The connection's next reply (v1 commands answer from a worker).
fn reply(conn: &Conn) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(message) = conn.outbound.try_pop() {
            return serde_json::from_str(&message).unwrap();
        }
        assert!(Instant::now() < deadline, "no reply");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Refused, with no credentials anywhere in the reply.
fn assert_refused(reply: &Value, code: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], code, "{reply}");
    assert!(reply.get("data").is_none_or(Value::is_null), "no credentials: {reply}");
    assert!(!reply.to_string().contains("secret"), "no secret: {reply}");
}

/// A daemon whose host binary does not exist: a refusal can never be
/// mistaken for a start failure, and a passed gate shows as engine_unavailable.
fn unstartable(label: &str) -> Arc<Mux> {
    let mux = mux(label);
    mux.control_clients
        .browser_host
        .configure(None, std::env::temp_dir().join("bh-unused/browser-host.sock"));
    mux
}

#[test]
fn a_connection_without_a_hello_is_refused() {
    let mux = unstartable("agent");
    let agent = connect(&mux, ClientTransport::Unix);
    assert_refused(&provider(&mux, &agent), "origin.forbidden");
}

#[test]
fn an_unproven_main_connection_is_refused() {
    let mux = unstartable("unproven");
    let main = connect(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, main.client, "main");
    assert_refused(&provider(&mux, &main), "origin.forbidden");
}

#[test]
fn a_page_relay_is_refused_even_with_the_apps_peer_and_a_verified_flag() {
    let mux = unstartable("relay");
    let relay = connect(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, relay.client, "page_relay");
    set_peer_key_for_test(&mux, relay.client, "token:100.1");
    set_verified_app_for_test(&mux, relay.client, true);
    let reply = provider(&mux, &relay);
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.get("data").is_none_or(Value::is_null), "{reply}");
}

#[test]
fn a_websocket_client_is_refused_even_when_verified() {
    let mux = unstartable("websocket");
    let web = verified_app(&mux, ClientTransport::WebSocket);
    assert_refused(&provider(&mux, &web), "origin.forbidden");
}

#[test]
fn a_remote_peer_is_refused_even_when_verified() {
    let mux = unstartable("remote");
    let remote = verified_app(&mux, ClientTransport::Remote);
    let reply = provider(&mux, &remote);
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.get("data").is_none_or(Value::is_null), "{reply}");
}

#[test]
fn the_verified_local_app_passes_the_gate() {
    let mux = unstartable("gate");
    let app = verified_app(&mux, ClientTransport::Unix);
    let reply = provider(&mux, &app);
    assert_refused(&reply, "engine_unavailable");
}

#[test]
fn identify_advertises_the_capability() {
    let mux = mux("identify");
    let agent = connect(&mux, ClientTransport::Unix);
    let request = json!({"id": 1, "cmd": "identify"});
    assert!(handle_connection_message(
        &mux,
        agent.client,
        &request.to_string(),
        &agent.writer,
        &agent.scheduler
    ));
    let reply = reply(&agent);
    let capabilities = reply["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|c| c == "browser-host-provider-v1"), "{reply}");
}

#[test]
fn terminals_get_the_host_socket_and_no_secret_when_the_daemon_runs_a_host() {
    let daemon = Path::new("/tmp/cmux-tui-test/daemon.sock");
    let socket = crate::browser_host::socket_path_for(daemon);
    assert_eq!(
        crate::browser_host::terminal_env(daemon, true),
        Some(("CMUX_BROWSER_HOST_SOCKET".to_string(), socket.display().to_string()))
    );
    assert_eq!(
        crate::browser_host::terminal_env(daemon, false),
        None,
        "without a host binary the daemon does not own a socket"
    );
    assert_eq!(socket.file_name().unwrap(), "browser-host.sock");
    assert_ne!(
        socket,
        crate::browser_host::socket_path_for(Path::new("/tmp/cmux-tui-test/other.sock")),
        "one host per daemon: another daemon socket gets another host socket"
    );
    assert!(crate::daemon_env::is_daemon_owned("CMUX_BROWSER_HOST_SOCKET"));
    let mut options = crate::SurfaceOptions::default();
    crate::daemon_env::add_daemon_socket_env(daemon, &mut options);
    let keys: Vec<&str> = options.extra_env.iter().map(|(key, _)| key.as_str()).collect();
    assert_eq!(&keys[..2], ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"]);
    assert!(options.extra_env.iter().all(|(_, value)| value.len() < 200));
}

/// The `cmux-browser-host` binary of this build (`CMUX_BROWSER_HOST_BIN`, else
/// built once into this test binary's target directory).
fn host_binary() -> PathBuf {
    static BINARY: OnceLock<PathBuf> = OnceLock::new();
    BINARY
        .get_or_init(|| {
            if let Some(path) = std::env::var_os("CMUX_BROWSER_HOST_BIN") {
                return PathBuf::from(path);
            }
            // target/<profile>/deps/<test> -> target/<profile>
            let exe = std::env::current_exe().unwrap();
            let profile_dir = exe.parent().unwrap().parent().unwrap().to_path_buf();
            let mut command = std::process::Command::new(env!("CARGO"));
            command
                .args(["build", "-p", "cmux-browser-host", "--bin", "cmux-browser-host"])
                .current_dir(env!("CARGO_MANIFEST_DIR"));
            if profile_dir.file_name().is_some_and(|name| name == "release") {
                command.arg("--release");
            }
            let status = command.status().expect("run cargo build for cmux-browser-host");
            assert!(status.success(), "cargo build -p cmux-browser-host: {status}");
            let binary = profile_dir.join("cmux-browser-host");
            assert!(binary.is_file(), "built {}", binary.display());
            binary
        })
        .clone()
}

fn write_frame(stream: &mut UnixStream, frame: &Value) {
    let body = serde_json::to_vec(frame).unwrap();
    stream.write_all(&(body.len() as u32).to_be_bytes()).unwrap();
    stream.write_all(&body).unwrap();
}

fn read_frame(stream: &mut UnixStream) -> Option<Value> {
    let mut header = [0_u8; 4];
    stream.read_exact(&mut header).ok()?;
    let mut body = vec![0_u8; u32::from_be_bytes(header) as usize];
    stream.read_exact(&mut body).ok()?;
    serde_json::from_slice(&body).ok()
}

fn hello(secret: &str) -> Value {
    json!({
        "t": "hello", "version": 1, "provider_id": "cmux-app:test", "install_id": "inst_test",
        "secret": secret, "engines": ["webkit"], "tabs": [],
    })
}

/// The pid at the other end of a Unix socket.
fn peer_pid(stream: &UnixStream) -> Option<u32> {
    use std::os::fd::AsRawFd;
    #[cfg(target_os = "linux")]
    {
        let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
        let mut len = size_of::<libc::ucred>() as libc::socklen_t;
        // SAFETY: an open Unix socket; cred and len describe a valid buffer.
        let rc = unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                (&mut cred as *mut libc::ucred).cast(),
                &mut len,
            )
        };
        (rc == 0).then_some(cred.pid as u32)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let mut pid: libc::pid_t = 0;
        let mut len = size_of::<libc::pid_t>() as libc::socklen_t;
        // SAFETY: an open Unix socket; pid and len describe a valid buffer.
        let rc = unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_LOCAL,
                libc::LOCAL_PEERPID,
                (&mut pid as *mut libc::pid_t).cast(),
                &mut len,
            )
        };
        (rc == 0).then_some(pid as u32)
    }
}

/// One agent request on the host's agent socket.
fn agent_request(socket: &Path, id: u64, method: &str, params: Value) -> Value {
    let mut stream = UnixStream::connect(socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
    let line = json!({"id": id, "method": method, "params": params, "origin": "cli"});
    writeln!(stream, "{line}").unwrap();
    let mut reply = String::new();
    BufReader::new(stream).read_line(&mut reply).unwrap();
    serde_json::from_str(&reply).unwrap()
}

fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn the_verified_app_dials_the_daemons_host_and_receives_the_session_end_close() {
    let dir = std::env::temp_dir().join(format!("cmux-bh-c2-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let agent_socket = dir.join("browser-host.sock");
    let mux = mux("happy");
    mux.control_clients.browser_host.configure(Some(host_binary()), agent_socket.clone());
    let app = verified_app(&mux, ClientTransport::Unix);

    let reply = provider(&mux, &app);
    assert_eq!(reply["ok"], true, "{reply}");
    let data = &reply["data"];
    let socket = PathBuf::from(data["socket"].as_str().unwrap());
    let secret = data["secret"].as_str().unwrap().to_string();
    let host_pid = data["host_pid"].as_u64().unwrap() as u32;
    assert_eq!(socket, dir.join("browser-host-provider.sock"));
    assert_eq!(secret.len(), 64, "32 random bytes as hex");
    assert!(secret.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()));
    assert_eq!(provider(&mux, &app)["data"], *data, "one host launch, one secret");

    // A wrong secret gets no hello.ack.
    let mut wrong = UnixStream::connect(&socket).unwrap();
    wrong.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    write_frame(&mut wrong, &hello(&"0".repeat(64)));
    assert!(read_frame(&mut wrong).is_none(), "a wrong secret is refused");

    let mut link = UnixStream::connect(&socket).unwrap();
    assert_eq!(peer_pid(&link), Some(host_pid), "the provider socket's peer is the host");
    link.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    write_frame(&mut link, &hello(&secret));
    let ack = read_frame(&mut link).expect("hello.ack");
    assert_eq!(ack["t"], "hello.ack", "{ack}");

    // The fake app answers every call; tabs.open opens T1.
    let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
    let recorded = calls.clone();
    let mut reader = link.try_clone().unwrap();
    reader.set_read_timeout(None).unwrap();
    std::thread::spawn(move || {
        while let Some(frame) = read_frame(&mut reader) {
            if frame["t"] != "call" {
                continue;
            }
            recorded.lock().unwrap().push(frame.clone());
            // The real app announces every tab it shows (its tab list observation).
            if frame["method"] == "tabs.open" {
                let announce = json!({"t": "event", "name": "tab.announced", "payload": {
                    "targetId": "T1", "engine": "webkit", "workspace": "w1", "profile": "default",
                    "url": "about:blank", "title": "", "visible": true}});
                write_frame(&mut link, &announce);
            }
            let answer = match frame["method"].as_str() {
                Some("tabs.open") => {
                    json!({"t": "result", "id": frame["id"], "result": {"targetId": "T1"}})
                }
                Some("tabs.close") => json!({"t": "result", "id": frame["id"], "result": null}),
                _ => json!({"t": "result", "id": frame["id"],
                    "error": {"code": "unsupported", "message": "fake app"}}),
            };
            write_frame(&mut link, &answer);
        }
    });

    let opened = agent_request(
        &agent_socket,
        1,
        "browser.repl.open",
        json!({"session": "c2", "engine": "webkit"}),
    );
    assert!(opened.get("error").is_none_or(Value::is_null), "{opened}");
    let evaluated = agent_request(
        &agent_socket,
        2,
        "browser.repl.eval",
        json!({"session": "c2", "code": "await tabs.open(); 1"}),
    );
    assert!(evaluated.get("error").is_none_or(Value::is_null), "{evaluated}");
    let closed = agent_request(&agent_socket, 3, "browser.repl.close", json!({"session": "c2"}));
    assert!(closed.get("error").is_none_or(Value::is_null), "{closed}");
    wait_until(&format!("the session end's tabs.close in {:?}", calls.lock().unwrap()), || {
        calls.lock().unwrap().iter().any(|call| {
            call["method"] == "tabs.close"
                && call["params"]["targetId"] == "T1"
                && call["params"]["reason"] == "session_end"
        })
    });

    assert_eq!(host_pid, std::process::id(), "the daemon holds the socket, so it is the peer");

    // A crashed host restarts with a new process and a new secret.
    let crashed = mux.control_clients.browser_host.running_pid().expect("a host");
    // SAFETY: signalling the host this test's daemon started.
    unsafe { libc::kill(crashed as libc::pid_t, libc::SIGKILL) };
    wait_until("a restarted host", || {
        mux.control_clients.browser_host.running_pid().is_some_and(|pid| pid != crashed)
    });
    let restarted = provider(&mux, &app);
    assert_eq!(restarted["ok"], true, "{restarted}");
    assert_ne!(restarted["data"]["secret"], data["secret"], "a new launch has a new secret");
    let _ = std::fs::remove_dir_all(&dir);
}

/// One request on a connection to the host's agent socket.
fn list_over(stream: &mut UnixStream) -> Value {
    stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    writeln!(stream, r#"{{"id":1,"method":"browser.repl.list","params":{{}}}}"#).unwrap();
    let mut reply = String::new();
    BufReader::new(stream.try_clone().unwrap()).read_line(&mut reply).unwrap();
    serde_json::from_str(&reply).unwrap()
}

#[test]
fn no_host_runs_until_the_first_agent_connect_starts_one() {
    let dir = std::env::temp_dir().join(format!("cmux-bh-act-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let supervisor = crate::browser_host::BrowserHostSupervisor::default();
    supervisor.configure(Some(host_binary()), dir.join("browser-host.sock"));
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(supervisor.running_pid(), None, "no host before anything asks");
    let mut agent =
        UnixStream::connect(dir.join("browser-host.sock")).expect("the daemon holds the socket");
    assert_eq!(
        list_over(&mut agent)["result"],
        json!([]),
        "the started host answers the queued connect"
    );
    // The host may answer before the daemon records it after its ready line.
    wait_until("the daemon to record the host", || supervisor.running_pid().is_some());
    drop(agent);
    drop(supervisor);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_idle_host_stops_and_the_next_connect_starts_a_new_one() {
    let dir = std::env::temp_dir().join(format!("cmux-bh-idle-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let socket = dir.join("browser-host.sock");
    let supervisor = crate::browser_host::BrowserHostSupervisor::default();
    supervisor.configure_with_idle_exit(
        Some(host_binary()),
        socket.clone(),
        Duration::from_millis(300),
    );
    let mut agent = UnixStream::connect(&socket).unwrap();
    assert_eq!(list_over(&mut agent)["result"], json!([]));
    wait_until("the daemon to record the host", || supervisor.running_pid().is_some());
    let first = supervisor.running_pid().expect("a host");
    drop(agent);
    wait_until("the idle stop", || supervisor.running_pid().is_none());
    // SAFETY: probing a pid with signal 0 sends nothing.
    wait_until("the idle host to exit", || unsafe { libc::kill(first as libc::pid_t, 0) } != 0);
    let mut again = UnixStream::connect(&socket).expect("the socket stays bound");
    assert_eq!(list_over(&mut again)["result"], json!([]));
    wait_until("the daemon to record the new host", || {
        supervisor.running_pid().is_some_and(|pid| pid != first)
    });
    let second = supervisor.running_pid().expect("a new host");
    assert_ne!(second, first);
    drop(again);
    drop(supervisor);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_activation_thread_ends_with_the_daemon_through_the_cancel_pipe() {
    let dir = std::env::temp_dir().join(format!("cmux-bh-cancel-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let socket = dir.join("browser-host.sock");
    let supervisor = crate::browser_host::BrowserHostSupervisor::default();
    supervisor.configure(Some(host_binary()), socket.clone());
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        // The drop cancels the poll and joins the activation thread.
        drop(supervisor);
        let _ = tx.send(());
    });
    rx.recv_timeout(Duration::from_secs(10)).expect("the drop returns: the thread ended");
    assert!(UnixStream::connect(&socket).is_err(), "the daemon closed its sockets");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A host that says ready and then exits non-zero: each launch appends a
/// line to `count`.
fn crashing_host(dir: &Path, count: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let script = dir.join("crashing-host.sh");
    std::fs::write(
        &script,
        format!("#!/bin/sh\necho launch >> '{}'\necho ready\nexit 1\n", count.display()),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    script
}

#[test]
fn a_crash_loop_keeps_the_backoff_and_never_restarts_at_connect_speed() {
    let dir = std::env::temp_dir().join(format!("cmux-bh-crash-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let count = dir.join("launches");
    let socket = dir.join("bh/browser-host.sock");
    let supervisor = crate::browser_host::BrowserHostSupervisor::default();
    supervisor.configure(Some(crashing_host(&dir, &count)), socket.clone());
    // A connect that no host ever accepts stays queued: activation sees it
    // on every wake.
    let _waiting = UnixStream::connect(&socket).unwrap();
    std::thread::sleep(Duration::from_millis(2500));
    let launches = std::fs::read_to_string(&count).unwrap_or_default().lines().count();
    assert!((1..=6).contains(&launches), "Backoff-paced restarts only, got {launches} launches");
    drop(supervisor);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_host_stops_when_its_supervisor_goes() {
    let dir = std::env::temp_dir().join(format!("cmux-bh-c2-stop-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let supervisor = crate::browser_host::BrowserHostSupervisor::default();
    supervisor.configure(Some(host_binary()), dir.join("browser-host.sock"));
    supervisor.credentials().expect("a started host");
    let pid = supervisor.running_pid().expect("the host process") as libc::pid_t;
    // SAFETY: probing a pid with signal 0 sends nothing.
    assert_eq!(unsafe { libc::kill(pid, 0) }, 0, "the host runs");
    drop(supervisor);
    // SAFETY: as above.
    wait_until("the host to stop with its daemon", || unsafe { libc::kill(pid, 0) } != 0);
    let _ = std::fs::remove_dir_all(&dir);
}
