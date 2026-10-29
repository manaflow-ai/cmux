//! Behavior of `browser-runtime-v1` over a daemon control connection, with a
//! stand-in host (a Python script that speaks the host's start protocol):
//! opt-in, install detection, the secret on stdin only, the first page, the
//! host's port reached over loopback, and stop by request and by disconnect.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::{MessageWriter, RequestHead, handle_connection, routes, transport};
use super::{BROWSER_RUNTIME_CAPABILITY, executable_in};
use crate::mux::Mux;

const WAIT: Duration = Duration::from_secs(10);

/// Reads the secret line, listens on loopback, prints the listening line,
/// sends each connection the secret, writes its argv to `argv`, and writes
/// `stopped` when its stdin (the lifeline) ends.
const STAND_IN_HOST: &str = r#"#!/usr/bin/env python3
import json, os, socket, sys, threading
here = os.path.dirname(os.path.realpath(__file__))
open(os.path.join(here, "argv"), "w").write(json.dumps(sys.argv[1:]))
secret = sys.stdin.readline().strip()
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen()
print(json.dumps({"listening": "127.0.0.1:%d" % server.getsockname()[1]}), flush=True)
def serve():
    while True:
        conn, _ = server.accept()
        conn.sendall((secret + "\n").encode())
        conn.close()
threading.Thread(target=serve, daemon=True).start()
sys.stdin.read()
open(os.path.join(here, "stopped"), "w").write("1")
"#;

const FAILING_HOST: &str = "#!/bin/sh\necho 'cef: no display for this session' >&2\nexit 3\n";

struct Client {
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    next_id: u64,
    handler: Option<JoinHandle<()>>,
}

impl Client {
    fn connect(mux: &Arc<Mux>, directory: &Path) -> Self {
        let path = directory.join("s.sock");
        let listener = transport::listen(&path).unwrap();
        let client = transport::connect(&path).unwrap();
        let server = listener.accept().unwrap();
        let server_mux = mux.clone();
        let handler = std::thread::spawn(move || handle_connection(server_mux, server));
        let reader = client.try_clone_box().unwrap();
        reader.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        Self { writer: client, reader: BufReader::new(reader), next_id: 1, handler: Some(handler) }
    }

    fn request(&mut self, mut value: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        value["id"] = json!(id);
        self.request_line(id, &value.to_string())
    }

    /// Sends `line` as written and returns the reply whose `id` is `id`.
    fn request_line(&mut self, id: u64, line: &str) -> Value {
        writeln!(self.writer, "{line}").unwrap();
        self.writer.flush().unwrap();
        let deadline = Instant::now() + WAIT;
        let mut line = String::new();
        while Instant::now() < deadline {
            match self.reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) if line.ends_with('\n') => {
                    let reply: Value = serde_json::from_str(&line).unwrap();
                    line.clear();
                    if reply["id"] == json!(id) {
                        return reply;
                    }
                }
                Ok(_) => {}
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(error) => panic!("read failed: {error}"),
            }
        }
        panic!("no reply to {line}");
    }

    fn opt_in(&mut self) {
        let reply = self.request(json!({
            "cmd": "set-client-info",
            "name": "browser-runtime-test",
            "capabilities": [BROWSER_RUNTIME_CAPABILITY],
        }));
        assert_eq!(reply["ok"], true, "{reply}");
    }

    fn close(mut self) {
        let _ = self.writer.shutdown(Shutdown::Both);
        if let Some(handler) = self.handler.take() {
            let _ = handler.join();
        }
    }
}

/// Hands `message` to the route its head's `cmd` names (server/routes.rs), as
/// the connection's dispatch does: `None` when no route takes it.
fn through_route(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    let head = RequestHead::parse(message);
    let route = head.cmd().and_then(routes::find)?;
    (route.entry)(&routes::RouteLine { mux, client, message, writer, head: &head })
}

fn scratch(label: &str) -> PathBuf {
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    let directory = std::env::temp_dir().join(format!(
        "cmux-rt-{label}-{}-{}",
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&directory).unwrap();
    directory
}

/// Installs `script` as version `version` under `root` and points
/// `current` at it; returns the version directory.
fn install(root: &Path, version: &str, script: &str) -> PathBuf {
    let directory = root.join(version);
    let executable = executable_in(&directory);
    std::fs::create_dir_all(executable.parent().unwrap()).unwrap();
    std::fs::write(&executable, script).unwrap();
    std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::os::unix::fs::symlink(&directory, root.join("current")).unwrap();
    // The stand-in writes its markers beside itself.
    executable.parent().unwrap().to_path_buf()
}

fn daemon(label: &str, root: &Path) -> Arc<Mux> {
    let mux = Mux::new_for_test(label, crate::SurfaceOptions::default());
    mux.control_clients.browser_runtimes.set_root(root.to_path_buf());
    mux
}

fn wait_for_file(path: &Path) -> bool {
    let deadline = Instant::now() + WAIT;
    while Instant::now() < deadline {
        if path.exists() {
            return true;
        }
        // Test harness wait for a file the stand-in writes on exit.
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

/// The install is on disk: `browser-runtime-status` reads it on a work item
/// and the reader thread goes on (p02-threads 220). Panic mode: a read left
/// on the reader thread fails here at its call site.
#[test]
fn status_reads_the_install_off_the_reader_thread() {
    use super::super::request_thread_tests::{next_reply, on_request_thread_with};
    use super::super::{BoundedOutbound, ClientTransport, QueuedSink};

    let root = scratch("status-offreq");
    install(&root, "v-offreq", STAND_IN_HOST);
    let mux = daemon("rt-status-offreq", &root);
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.control_clients
        .set_info(client, None, None, Some(vec![BROWSER_RUNTIME_CAPABILITY.to_owned()]))
        .unwrap();
    let line = json!({"id": 1, "cmd": "browser-runtime-status"}).to_string();
    let handled =
        on_request_thread_with(&mux, move |mux| through_route(mux, client, &line, &writer));
    assert_eq!(handled, Some(true));
    let reply = next_reply(&outbound);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"]["installed"], json!("v-offreq"), "{reply}");
    let _ = std::fs::remove_dir_all(&root);
}

/// `browser-runtime-start` reads the install on its start thread, not the
/// reader thread (p02-threads 220): with nothing installed the start answers
/// not-installed and frees its start slot; once installed it starts. Panic
/// mode: a read left on the reader thread fails here at its call site.
#[test]
fn start_reads_the_install_off_the_reader_thread() {
    use super::super::request_thread_tests::{next_reply, on_request_thread_with};
    use super::super::{BoundedOutbound, ClientTransport, QueuedSink};

    let root = scratch("start-offreq");
    let mux = daemon("rt-start-offreq", &root);
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.control_clients
        .set_info(client, None, None, Some(vec![BROWSER_RUNTIME_CAPABILITY.to_owned()]))
        .unwrap();
    let start = |id: u64| {
        let line = json!({"id": id, "cmd": "browser-runtime-start"}).to_string();
        let writer = writer.clone();
        on_request_thread_with(&mux, move |mux| through_route(mux, client, &line, &writer))
    };

    assert_eq!(start(1), Some(true));
    let refused = next_reply(&outbound);
    assert_eq!(refused["error_code"], "browser-runtime.not-installed", "{refused}");
    assert_eq!(mux.control_clients.browser_runtimes.lock().count(client), 0, "slot kept");

    install(&root, "v-start-offreq", STAND_IN_HOST);
    assert_eq!(start(2), Some(true));
    let started = next_reply(&outbound);
    assert_eq!(started["ok"], json!(true), "{started}");
    assert_eq!(started["data"]["installed"], json!("v-start-offreq"), "{started}");
    mux.control_clients.browser_runtimes.disconnect(client);
    let _ = std::fs::remove_dir_all(&root);
}

/// A stop waits out the host's grace on a `mux` work item, not a
/// `mux-browser-runtime-stop` thread (p02-threads 230): the host exits on
/// its closed lifeline, is reaped, and its log goes. Without a bound owner
/// (no work) the log would stay.
#[test]
fn a_stop_reaps_the_host_on_a_work_item() {
    use super::super::request_thread_tests::{next_reply, on_request_thread_with};
    use super::super::{BoundedOutbound, ClientTransport, MessageWriter, QueuedSink};

    let root = scratch("stop-work");
    let markers = install(&root, "v-stop-work", STAND_IN_HOST);
    let mux = daemon("rt-stop-work", &root);
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.control_clients
        .set_info(client, None, None, Some(vec![BROWSER_RUNTIME_CAPABILITY.to_owned()]))
        .unwrap();
    let line = json!({"id": 1, "cmd": "browser-runtime-start"}).to_string();
    let handled =
        on_request_thread_with(&mux, move |mux| through_route(mux, client, &line, &writer));
    assert_eq!(handled, Some(true));
    let started = next_reply(&outbound);
    assert_eq!(started["ok"], json!(true), "{started}");
    let logs = || std::fs::read_dir(root.join("logs")).map_or(0, Iterator::count);
    assert_eq!(logs(), 1, "the started host has a log");
    mux.control_clients.browser_runtimes.disconnect(client);
    assert!(wait_for_file(&markers.join("stopped")), "the host outlived its stop");
    let deadline = Instant::now() + WAIT;
    while logs() != 0 {
        assert!(Instant::now() < deadline, "the stop item did not finish");
        // Test harness wait for the stop item.
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// Status reads wait on the files lane: past the per-connection bound a
/// status is refused at once, so one connection cannot fill the lane.
#[test]
fn status_reads_in_flight_are_bounded_per_connection() {
    use super::super::{BoundedOutbound, ClientTransport, QueuedSink};
    use super::{MAX_STATUS_READS_PER_CLIENT, StatusRead};

    let root = scratch("status-bound");
    let mux = daemon("rt-status-bound", &root);
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.control_clients
        .set_info(client, None, None, Some(vec![BROWSER_RUNTIME_CAPABILITY.to_owned()]))
        .unwrap();
    // Reads still waiting for the lane hold their slots.
    let held: Vec<StatusRead> = (0..MAX_STATUS_READS_PER_CLIENT)
        .map(|_| StatusRead::take(&mux, client).expect("a slot"))
        .collect();
    let line = json!({"id": 1, "cmd": "browser-runtime-status"}).to_string();
    assert_eq!(through_route(&mux, client, &line, &writer), Some(true));
    let refused: Value = serde_json::from_str(&outbound.try_pop().expect("an answer")).unwrap();
    assert_eq!(refused["error_code"], "browser-runtime.limit", "{refused}");
    // Another connection is not refused for this one's reads.
    let other = mux.control_clients.register(ClientTransport::Unix, writer);
    assert!(StatusRead::take(&mux, other).is_some());
    drop(held);
    assert!(StatusRead::take(&mux, client).is_some(), "a finished read frees its slot");
    let _ = std::fs::remove_dir_all(&root);
}

/// The route is found by the line's decoded `cmd`, so a `cmd` spelled with a
/// JSON escape reaches the handler. The substring scan this replaced missed
/// it, and the `Command` parse answered with an unknown command.
#[test]
fn an_escaped_browser_runtime_cmd_reaches_its_route() {
    let root = scratch("escaped");
    let mux = daemon("rt-escaped", &root);
    let mut client = Client::connect(&mux, &root);
    // The JSON escape of `-`.
    let reply = client.request_line(7, r#"{"id":7,"cmd":"browser\u002druntime-status"}"#);
    assert_eq!(reply["error_code"], "browser-runtime.not-enabled", "{reply}");
    client.close();
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn browser_runtime_is_refused_until_the_connection_opts_in() {
    let root = scratch("opt-in");
    let mux = daemon("rt-opt-in", &root);
    let mut client = Client::connect(&mux, &root);
    let reply = client.request(json!({"cmd": "browser-runtime-status"}));
    assert_eq!(reply["error_code"], "browser-runtime.not-enabled", "{reply}");
    client.close();
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn browser_runtime_starts_the_installed_host_and_stops_it() {
    let root = scratch("start");
    let mux = daemon("rt-start", &root);
    let mut client = Client::connect(&mux, &root);
    client.opt_in();
    let empty = client.request(json!({"cmd": "browser-runtime-status"}));
    assert_eq!(empty["data"]["installed"], Value::Null, "{empty}");
    let refused = client.request(json!({"cmd": "browser-runtime-start"}));
    assert_eq!(refused["error_code"], "browser-runtime.not-installed", "{refused}");

    let markers = install(&root, "v-test-1", STAND_IN_HOST);
    let status = client.request(json!({"cmd": "browser-runtime-status"}));
    assert_eq!(status["data"]["installed"], "v-test-1", "{status}");
    let bad = client.request(json!({"cmd": "browser-runtime-start", "url": "file:///etc/passwd"}));
    assert_eq!(bad["error_code"], "browser-runtime.bad-url", "{bad}");

    let started =
        client.request(json!({"cmd": "browser-runtime-start", "url": "https://example.com/"}));
    assert_eq!(started["ok"], true, "{started}");
    let data = &started["data"];
    let secret = data["secret"].as_str().unwrap().to_string();
    assert_eq!(secret.len(), 64);
    let port = u16::try_from(data["port"].as_u64().unwrap()).unwrap();
    // The host got the secret on stdin and serves on the loopback port.
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let mut echoed = String::new();
    stream.read_to_string(&mut echoed).unwrap();
    assert_eq!(echoed.trim(), secret);
    // The first page is its only argument; the secret is not in argv.
    let argv = std::fs::read_to_string(markers.join("argv")).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&argv).unwrap(),
        json!([
            "--serve",
            "--listen",
            "127.0.0.1:0",
            "--lifeline",
            "--url",
            "https://example.com/"
        ])
    );
    let listed = client.request(json!({"cmd": "browser-runtime-status"}));
    assert_eq!(listed["data"]["runtimes"][0]["port"], port, "{listed}");

    let stopped =
        client.request(json!({"cmd": "browser-runtime-stop", "runtime": data["runtime"]}));
    assert_eq!(stopped["data"]["stopped"], true, "{stopped}");
    assert!(wait_for_file(&markers.join("stopped")), "the host did not see its lifeline end");
    let again = client.request(json!({"cmd": "browser-runtime-stop", "runtime": data["runtime"]}));
    assert_eq!(again["error_code"], "browser-runtime.unknown", "{again}");
    client.close();
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn browser_runtime_stops_when_its_connection_ends() {
    let root = scratch("disconnect");
    let mux = daemon("rt-disconnect", &root);
    let markers = install(&root, "v-test-2", STAND_IN_HOST);
    let mut client = Client::connect(&mux, &root);
    client.opt_in();
    let started = client.request(json!({"cmd": "browser-runtime-start"}));
    assert_eq!(started["ok"], true, "{started}");
    client.close();
    assert!(wait_for_file(&markers.join("stopped")), "the host outlived its connection");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn browser_runtime_reports_why_a_host_did_not_start() {
    let root = scratch("fails");
    let mux = daemon("rt-fails", &root);
    install(&root, "v-test-3", FAILING_HOST);
    let mut client = Client::connect(&mux, &root);
    client.opt_in();
    let reply = client.request(json!({"cmd": "browser-runtime-start"}));
    assert_eq!(reply["error_code"], "browser-runtime.start-failed", "{reply}");
    let message = reply["error"].as_str().unwrap();
    assert!(message.contains("no display for this session"), "{message}");
    client.close();
    let _ = std::fs::remove_dir_all(&root);
}

/// The SDK schema (spec/sdk-schema.json) describes every
/// command this module serves: local-admin (Unix only), the capability
/// `identify` advertises, and a method id in the `browser` family. The
/// names come from serde's own list of the variants, so a new one is
/// checked at once.
#[test]
fn every_browser_runtime_command_is_in_the_sdk_schema() {
    let error = serde_json::from_value::<super::RuntimeCommand>(json!({"cmd": "__none__"}))
        .err()
        .expect("an unknown command is refused")
        .to_string();
    let list = error.split("expected one of ").nth(1).expect("serde lists the variants");
    let names: Vec<&str> = list.split(", ").map(|name| name.trim().trim_matches('`')).collect();
    assert_eq!(names, ["browser-runtime-status", "browser-runtime-start", "browser-runtime-stop"]);
    let schema: Value =
        serde_json::from_str(include_str!("../../../../spec/sdk-schema.json")).unwrap();
    let family = schema["families"]["browser"]["id"].as_u64().expect("the browser family");
    for name in names {
        let command = &schema["commands"][name];
        assert_eq!(command["authority"], "local-admin", "{name}");
        assert_eq!(command["capability"], BROWSER_RUNTIME_CAPABILITY, "{name}");
        assert_eq!(command["method_id"].as_u64().expect("a method id") >> 8, family, "{name}");
    }
}
