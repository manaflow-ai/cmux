#![cfg(any(target_os = "linux", target_os = "macos"))]
//! Terminal ports over a real session socket: a program in a workspace's
//! terminal that listens on a TCP port and prints where (a dev server's
//! `Local: http://localhost:PORT/`) shows as that workspace's status entry
//! `ports` (":PORT"), which the app's sidebar row and hover card draw for the
//! machine the daemon runs on. When the port stops accepting and the terminal
//! prints again, the entry goes. A `ports` entry a person or a hook set is
//! left alone. Detection reads only the PTY the daemon holds and a loopback
//! connect (`cmux-local-url`), never the process table.

use cmux_tui_core::{Actor, Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

fn unique(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

struct Client {
    stream: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    fn connect(path: &Path) -> Self {
        let stream = UnixStream::connect(path).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
        Self { stream: BufReader::new(stream), next: 0 }
    }

    fn call(&mut self, operation: &str, mut params: Value, key: Option<&str>) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        if let Some(key) = key {
            request["idempotency_key"] = json!(key);
        }
        writeln!(self.stream.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.stream.read_line(&mut line).unwrap(), 0, "closed before {id}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                assert_eq!(reply["ok"], true, "{request} failed: {reply}");
                return reply["result"].clone();
            }
        }
    }

    /// The `ports` entry of every workspace that has one: `(workspace, text, icon)`.
    fn ports_entries(&mut self) -> Vec<(String, String, Option<String>)> {
        let listed = self.call("workspace_status.list", json!({}), None);
        let mut found = Vec::new();
        for workspace in listed.as_array().into_iter().flatten() {
            for entry in workspace["entries"].as_array().into_iter().flatten() {
                if entry["key"] == "ports" {
                    found.push((
                        workspace["workspace"]
                            .as_str()
                            .or_else(|| workspace["workspace_id"].as_str())
                            .unwrap_or_default()
                            .to_owned(),
                        entry["text"].as_str().unwrap_or_default().to_owned(),
                        entry["icon"].as_str().map(str::to_owned),
                    ));
                }
            }
        }
        found
    }

    fn wait_for_ports(
        &mut self,
        what: &str,
        done: impl Fn(&[(String, String, Option<String>)]) -> bool,
    ) {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let entries = self.ports_entries();
            if done(&entries) {
                return;
            }
            assert!(Instant::now() < deadline, "timed out waiting until {what}: {entries:?}");
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

/// A port no one listens on now (the kernel's pick, released at once).
fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

/// A shell that listens on `port` while the file `stop` is absent, with
/// python3 (on every fleet Linux and macOS image).
fn listening_shell(port: u16, stop: &Path) -> SurfaceOptions {
    let script = format!(
        "import os,socket,time\n\
         s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n\
         s.bind(('127.0.0.1', {port})); s.listen()\n\
         print('  Local:   http://localhost:{port}/', flush=True)\n\
         while not os.path.exists({stop:?}): time.sleep(0.05)\n\
         s.close(); print('server stopped', flush=True); time.sleep(600)\n",
        stop = stop.to_string_lossy(),
    );
    SurfaceOptions {
        command: Some(vec!["python3".into(), "-c".into(), script]),
        ..Default::default()
    }
}

#[test]
fn cmux_next_terminal_ports_a_listening_program_shows_on_its_workspace() {
    let dir = std::env::temp_dir().join(unique("tports"));
    std::fs::create_dir_all(&dir).unwrap();
    let port = free_port();
    let stop = dir.join("stop");
    let mux = Mux::new(unique("terminal-ports"), listening_shell(port, &stop));
    let surface = mux.new_workspace_as(&Actor::Daemon, None, None).unwrap();
    let socket = dir.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let mut client = Client::connect(&socket);

    let expected = format!(":{port}");
    client.wait_for_ports("the listening port shows on the workspace", |entries| {
        entries.iter().any(|(_, text, _)| *text == expected)
    });
    assert_eq!(client.ports_entries().len(), 1, "one workspace, one entry");

    // The program stops listening: the entry goes.
    std::fs::write(&stop, b"").unwrap();
    client.wait_for_ports("the closed port's entry is gone", |entries| entries.is_empty());

    mux.close_surface_as(&Actor::Daemon, surface.id).unwrap();
    server::cleanup(&socket);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cmux_next_terminal_ports_leave_a_ports_entry_a_person_set() {
    let dir = std::env::temp_dir().join(unique("tports-own"));
    std::fs::create_dir_all(&dir).unwrap();
    let port = free_port();
    let stop = dir.join("stop");
    let mux = Mux::new(unique("terminal-ports-own"), listening_shell(port, &stop));
    let surface = mux.new_workspace_as(&Actor::Daemon, None, None).unwrap();
    let socket = dir.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let mut client = Client::connect(&socket);
    let listed = client.call("workspace.list", json!({}), None);
    let workspace = listed
        .as_array()
        .and_then(|items| items.first())
        .and_then(|item| item["id"].as_str().map(str::to_owned))
        .unwrap_or_else(|| panic!("no workspace listed: {listed}"));
    client.call(
        "workspace_status.set",
        json!({"workspace": workspace, "key": "ports", "text": "api :8080"}),
        Some("own-ports"),
    );

    // Long enough for several scans to have seen the listener.
    let until = Instant::now() + Duration::from_secs(6);
    while Instant::now() < until {
        let entries = client.ports_entries();
        assert_eq!(entries.len(), 1, "{entries:?}");
        assert_eq!(entries[0].1, "api :8080", "the person's entry was replaced: {entries:?}");
        std::thread::sleep(Duration::from_millis(200));
    }

    mux.close_surface_as(&Actor::Daemon, surface.id).unwrap();
    server::cleanup(&socket);
    let _ = std::fs::remove_dir_all(&dir);
}
