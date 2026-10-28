//! Request dispatch threads (p02-threads task 211): request threads run at
//! UserInitiated with blocking disallowed, so a checked blocking call on one
//! is a recorded site; writers and accept loops run at UserInitiated; each is
//! a registered `cmux_threads` row.
//!
//! The site table is process-wide, so a test reads the count of the site its
//! own request reaches before and after it runs.

use std::net::TcpStream;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_threads::work::Lane;
use cmux_threads::{BlockingKind, ThreadQos};
use serde_json::{Value, json};
use tungstenite::{Message, WebSocket};

use super::super::terminal_io_wire::ClearHistoryParams;
use super::super::{
    BoundedOutbound, ClientTransport, Command, ConnectionSurfaceScheduler, MessageWriter,
    QueuedSink, Request, serve_websocket,
};
use super::spawn_request_thread;

/// The declared QoS of every live thread named `name`, waiting (bounded)
/// until there is one. Tests running in parallel may start threads of the
/// same name; every one of them declares the same class.
fn declared(name: &str) -> Vec<ThreadQos> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let rows: Vec<ThreadQos> = cmux_threads::snapshot()
            .into_iter()
            .filter(|row| row.name == name)
            .map(|row| row.declared)
            .collect();
        if !rows.is_empty() {
            return rows;
        }
        assert!(Instant::now() < deadline, "no {name} thread row");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn assert_declared(name: &str, qos: ThreadQos) {
    let rows = declared(name);
    assert!(rows.iter().all(|row| *row == qos), "{name}: {rows:?}, expected {qos}");
}

/// The recorded count of `kind` blocking sites whose file path contains
/// `path`, summed over their lines.
fn site_count(path: &str, kind: BlockingKind) -> u64 {
    cmux_threads::blocking::snapshot()
        .sites
        .iter()
        .filter(|site| site.file.contains(path) && site.kinds.contains(kind))
        .map(|site| site.count)
        .sum()
}

/// A request thread declares UserInitiated and disallows blocking for its
/// life: a checked blocking call on it lands in the site table (the
/// `server.blocking` list) in record mode and panics in panic mode.
#[test]
fn a_request_thread_disallows_blocking_and_records_the_site() {
    const NAME: &str = "mux-test-request-thread";
    let (disallowed, rows) = spawn_request_thread(NAME, || {
        // Panic mode panics after recording; record mode returns.
        let _ = std::panic::catch_unwind(|| cmux_threads::checked::sync::sleep(Duration::ZERO));
        (cmux_threads::blocking::is_blocking_disallowed(), declared(NAME))
    })
    .expect("start the request thread")
    .join()
    .expect("the request thread returns");
    assert!(disallowed, "a request thread disallows blocking");
    assert_eq!(rows, [ThreadQos::UserInitiated]);
    // This file's only checked blocking call is the sleep above.
    let sites = cmux_threads::blocking::snapshot().sites;
    assert!(
        sites.iter().any(|site| site.file == file!() && site.kinds.contains(BlockingKind::Sleep)),
        "no sleep site in {}: {sites:?}",
        file!()
    );
    assert!(cmux_threads::snapshot().iter().all(|row| row.name != NAME), "the row leaves");
}

/// A connection's queued requests are taken by its control sequence on the
/// sequenced pool's `mux-seq-control` workers, UserInitiated request threads
/// that disallow blocking, and run on the connection's request sequence (a
/// System-lane work item), so the registry read `list-workspaces` makes
/// (server.rs `list_workspaces_reply`) is no blocking site on a request
/// thread.
#[test]
fn the_control_sequence_hands_its_requests_to_the_work_lane() {
    let mux =
        crate::Mux::new_for_test("request-threads-dispatch", crate::SurfaceOptions::default());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let before = site_count("src/server.rs", BlockingKind::Sqlite);
    let mut list = Some(Request { id: Some(json!(1)), cmd: Command::ListWorkspaces });
    assert_eq!(scheduler.dispatch(mux, client, &mut list, 0, writer), Some(true));
    // The pool's workers stay up with the mux.
    assert_declared("mux-seq-control", ThreadQos::UserInitiated);
    scheduler.finish_and_wait();
    let reply: Value = serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(
        site_count("src/server.rs", BlockingKind::Sqlite),
        before,
        "list-workspaces read the registry on a thread that disallows blocking"
    );
}

/// The line of an idle pool worker's wait for its next task in
/// sequenced_pool.rs.
fn idle_worker_wait_line() -> u32 {
    let source = include_str!("sequenced_pool.rs");
    let start = source.find("fn run_worker(").expect("run_worker");
    let wait = start + source[start..].find(".idle().wait(").expect("an idle worker waits");
    u32::try_from(source[..wait].lines().count()).expect("line")
}

/// A connection's control sequence holds no thread; an idle control worker
/// waits for the next task of any connection while idle (Chromium's
/// `WaitableEvent::declare_only_used_while_idle`): on a request thread, a
/// wait far over the 2 ms lock-wait budget records no site.
#[test]
fn an_idle_control_worker_waiting_for_its_next_task_records_no_site() {
    use super::super::sequenced_pool::{PoolConfig, SequencePriority, SequencedPool};
    const IDLE: Duration = Duration::from_millis(20);
    let pool = SequencedPool::new(PoolConfig::for_cores(4));
    let sequence = pool.sequence(SequencePriority::Control);
    let (ran_tx, ran_rx) = std::sync::mpsc::channel();
    sequence.post(move || ran_tx.send(Instant::now()).expect("ran")).expect("posted");
    let ran = ran_rx.recv_timeout(Duration::from_secs(5)).expect("the worker runs the task");
    std::thread::sleep(IDLE);
    let (again_tx, again_rx) = std::sync::mpsc::channel();
    sequence.post(move || again_tx.send(()).expect("ran")).expect("posted");
    again_rx.recv_timeout(Duration::from_secs(5)).expect("the idle worker wakes");
    assert!(ran.elapsed() >= IDLE);
    let file = file!().replace("request_threads_tests.rs", "sequenced_pool.rs");
    let line = idle_worker_wait_line();
    assert_eq!(
        cmux_threads::blocking::snapshot().site(&file, line).copied(),
        None,
        "{file}:{line}"
    );
}

/// A clear-history request runs as a `Mux::work` item on the system lane, not
/// on a thread of its own (p02-threads 230): a person's request at
/// UserBlocking, on a UserInitiated foreground worker. The test holds the
/// terminal lock the item takes, to see it running.
#[test]
fn a_clear_history_request_is_a_work_item_not_a_thread() {
    let mux = crate::Mux::new_for_test("request-threads-clear", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let mut clear = Some(Request {
        id: Some(json!(1)),
        cmd: Command::ClearHistory(ClearHistoryParams { surface: surface.id, fallback_key: None }),
    });
    let held = surface.with_terminal(|_| {
        assert_eq!(scheduler.dispatch(mux.clone(), client, &mut clear, 0, writer), Some(true));
        let deadline = Instant::now() + Duration::from_secs(5);
        while mux.work.stats()[Lane::System as usize].running == 0 {
            assert!(Instant::now() < deadline, "the clear-history item never started");
            std::thread::yield_now();
        }
        assert_declared("mux-sys-fg", ThreadQos::UserInitiated);
        assert!(
            cmux_threads::snapshot().iter().all(|row| row.name != "mux-surface-control"),
            "a clear-history request started its own thread"
        );
    });
    assert!(held.is_some(), "a PTY surface");
    scheduler.finish_and_wait();
    let reply: Value = serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap();
    assert_eq!(reply["id"], 1, "{reply}");
    mux.close_surface(surface.id).unwrap();
}

fn send_json(websocket: &mut WebSocket<TcpStream>, value: Value) {
    websocket.send(Message::Text(value.to_string().into())).unwrap();
}

fn read_reply(websocket: &mut WebSocket<TcpStream>, id: &Value) -> Value {
    loop {
        match websocket.read().expect("a frame") {
            Message::Text(text) => {
                let value: Value = serde_json::from_str(&text).unwrap();
                if value["id"] == *id {
                    return value;
                }
            }
            Message::Ping(data) => websocket.send(Message::Pong(data)).unwrap(),
            other => panic!("expected a JSON text frame, got {other:?}"),
        }
    }
}

/// The WebSocket listener: the accept loop, the connection thread and its
/// writer run at UserInitiated; a subscription is a pump on the sequenced
/// pool, not an events writer thread. The connection
/// thread disallows blocking and hands a v2 resource line to the
/// connection's request sequence, so the registry read of `workspace.list`
/// (under resource_router/) is no blocking site on it.
#[test]
fn websocket_threads_are_user_initiated_and_the_connection_hands_off_its_blocking() {
    const TOKEN: &str = "request-threads-token";
    let mux = crate::Mux::new_for_test("request-threads-ws", crate::SurfaceOptions::default());
    let server =
        serve_websocket(mux, "127.0.0.1:0".parse().unwrap(), Some(TOKEN.to_string()), false)
            .expect("serve the WebSocket listener");
    assert_declared("mux-ws-server", ThreadQos::UserInitiated);

    let addr = server.local_addr();
    let stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut websocket = tungstenite::client(format!("ws://{addr}/"), stream).unwrap().0;
    send_json(&mut websocket, json!({"auth": {"token": TOKEN}}));
    send_json(&mut websocket, json!({"id": 1, "cmd": "subscribe"}));
    assert_eq!(read_reply(&mut websocket, &json!(1))["ok"], true);

    let before = site_count("src/resource_router/", BlockingKind::Sqlite);
    send_json(
        &mut websocket,
        json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": "list",
            "operation": "workspace.list",
            "params": {"machine": "current", "session": "current"},
        }),
    );
    let list = read_reply(&mut websocket, &json!("list"));
    assert_eq!(list["ok"], true, "{list}");
    assert_eq!(
        site_count("src/resource_router/", BlockingKind::Sqlite),
        before,
        "workspace.list read the registry on a thread that disallows blocking"
    );

    assert_declared("mux-ws-conn", ThreadQos::UserInitiated);
    assert_declared("mux-ws-out", ThreadQos::UserInitiated);
    assert!(
        cmux_threads::snapshot().iter().all(|row| row.name != "mux-events-out"),
        "a subscription started its own thread"
    );
    let _ = websocket.close(None);
}

/// The Unix socket's accept loop runs at UserInitiated: every connection waits
/// on it. Task 210 owns the `mux-conn` rows it starts.
#[cfg(unix)]
#[test]
fn unix_accept_loop_is_user_initiated() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;

    let mux = crate::Mux::new_for_test("request-threads-unix", crate::SurfaceOptions::default());
    let socket =
        std::env::temp_dir().join(format!("cmux-rq-threads-{}", std::process::id())).join("s.sock");
    super::super::serve(mux, Some(socket.clone())).expect("serve the control socket");
    assert_declared("mux-server", ThreadQos::UserInitiated);

    let mut stream = UnixStream::connect(&socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    writeln!(stream, r#"{{"id":1,"cmd":"identify"}}"#).unwrap();
    let mut line = String::new();
    BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
    let reply: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(reply["id"], 1, "{reply}");
}
