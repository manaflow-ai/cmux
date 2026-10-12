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

use super::super::{handle_connection, transport};
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
        writeln!(self.writer, "{value}").unwrap();
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
        panic!("no reply to {value}");
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
