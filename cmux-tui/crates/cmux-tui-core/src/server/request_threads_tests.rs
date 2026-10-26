//! Request dispatch threads (p02-threads task 211): request threads run at
//! UserInitiated with blocking disallowed, so a checked blocking call on one
//! is a recorded site; writers run at UserInitiated and accept loops at
//! `ACCEPT_THREAD_QOS`; each is a registered `cmux_threads` row.

use std::net::TcpStream;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_threads::ThreadQos;
use serde_json::{Value, json};
use tungstenite::{Message, WebSocket};

use super::super::listen::ACCEPT_THREAD_QOS;
use super::super::{
    BoundedOutbound, ClientTransport, Command, ConnectionSurfaceScheduler, MessageWriter,
    QueuedSink, Request, serve_websocket,
};
use super::{REQUEST_THREAD_QOS, spawn_request_thread};

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

#[test]
fn request_dispatch_runs_user_initiated_and_accept_loops_run_at_accept_qos() {
    assert_eq!(REQUEST_THREAD_QOS, ThreadQos::UserInitiated);
    #[cfg(target_vendor = "apple")]
    assert_eq!(ACCEPT_THREAD_QOS, ThreadQos::Utility);
    // A Linux accept loop at nice 5 would start every connection thread there.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    assert_eq!(ACCEPT_THREAD_QOS, REQUEST_THREAD_QOS);
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
        sites
            .iter()
            .any(|site| site.file == file!()
                && site.kinds.contains(cmux_threads::BlockingKind::Sleep)),
        "no sleep site in {}: {sites:?}",
        file!()
    );
    assert!(cmux_threads::snapshot().iter().all(|row| row.name != NAME), "the row leaves");
}

/// A connection's queued requests run on `mux-control-dispatch`, a request
/// thread.
#[test]
fn the_connection_dispatcher_is_a_user_initiated_request_thread() {
    let mux =
        crate::Mux::new_for_test("request-threads-dispatch", crate::SurfaceOptions::default());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let mut list = Some(Request { id: Some(json!(1)), cmd: Command::ListWorkspaces });
    assert_eq!(scheduler.dispatch(mux, client, &mut list, 0, writer), Some(true));
    // The dispatcher stays up until the scheduler finishes.
    assert_declared("mux-control-dispatch", ThreadQos::UserInitiated);
    scheduler.finish_and_wait();
    let reply: Value = serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
}

fn send_json(websocket: &mut WebSocket<TcpStream>, value: Value) {
    websocket.send(Message::Text(value.to_string().into())).unwrap();
}

fn read_reply(websocket: &mut WebSocket<TcpStream>, id: u64) -> Value {
    loop {
        match websocket.read().expect("a frame") {
            Message::Text(text) => {
                let value: Value = serde_json::from_str(&text).unwrap();
                if value["id"] == id {
                    return value;
                }
            }
            Message::Ping(data) => websocket.send(Message::Pong(data)).unwrap(),
            other => panic!("expected a JSON text frame, got {other:?}"),
        }
    }
}

/// The WebSocket listener: accept loop at `ACCEPT_THREAD_QOS`; the connection
/// thread (it runs its frames' requests), its writer and an events writer at
/// UserInitiated.
#[test]
fn websocket_threads_declare_accept_and_request_classes() {
    const TOKEN: &str = "request-threads-token";
    let mux = crate::Mux::new_for_test("request-threads-ws", crate::SurfaceOptions::default());
    let server =
        serve_websocket(mux, "127.0.0.1:0".parse().unwrap(), Some(TOKEN.to_string()), false)
            .expect("serve the WebSocket listener");
    assert_declared("mux-ws-server", ACCEPT_THREAD_QOS);

    let addr = server.local_addr();
    let stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut websocket = tungstenite::client(format!("ws://{addr}/"), stream).unwrap().0;
    send_json(&mut websocket, json!({"auth": {"token": TOKEN}}));
    send_json(&mut websocket, json!({"id": 1, "cmd": "subscribe"}));
    assert_eq!(read_reply(&mut websocket, 1)["ok"], true);

    assert_declared("mux-ws-conn", REQUEST_THREAD_QOS);
    assert_declared("mux-ws-out", REQUEST_THREAD_QOS);
    assert_declared("mux-events-out", REQUEST_THREAD_QOS);
    let _ = websocket.close(None);
}

/// The Unix socket: accept loop at `ACCEPT_THREAD_QOS`, connection readers
/// set to UserInteractive rather than inherited from it.
#[cfg(unix)]
#[test]
fn unix_accept_loop_declares_accept_qos_and_sets_its_connection_threads() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;

    let mux = crate::Mux::new_for_test("request-threads-unix", crate::SurfaceOptions::default());
    let socket =
        std::env::temp_dir().join(format!("cmux-rq-threads-{}", std::process::id())).join("s.sock");
    super::super::serve(mux, Some(socket.clone())).expect("serve the control socket");
    assert_declared("mux-server", ACCEPT_THREAD_QOS);

    let mut stream = UnixStream::connect(&socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    writeln!(stream, r#"{{"id":1,"cmd":"identify"}}"#).unwrap();
    let mut line = String::new();
    BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
    let reply: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(reply["id"], 1, "{reply}");
    assert_declared("mux-conn", ThreadQos::UserInteractive);
}
