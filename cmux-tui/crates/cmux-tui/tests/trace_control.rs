//! `trace-start`, `trace-status` and `trace-stop` on a real daemon with a
//! real terminal host (p09-observability-015): the daemon records into its
//! state root and forwards to the host, which records next to its discovery
//! record; both rings are on disk, decode, and name their role and process.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_trace::Role;
use serde_json::{Value, json};

struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Client {
    /// The reply to `request`: `Ok(data)` or `Err(error text)`.
    fn call(&mut self, mut request: Value) -> Result<Value, String> {
        self.next += 1;
        request["id"] = json!(self.next);
        writeln!(self.writer, "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the socket");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == json!(self.next) && reply.get("ok").is_some() {
                return if reply["ok"] == true {
                    Ok(reply["data"].clone())
                } else {
                    Err(reply["error"].to_string())
                };
            }
        }
    }
}

fn process<'a>(reply: &'a Value, role: &str) -> Vec<&'a Value> {
    reply["processes"].as_array().unwrap().iter().filter(|p| p["role"] == role).collect()
}

/// The ring at `path` decodes as a ring of `role` written by `pid`.
fn assert_ring(path: &Path, role: Role, pid: u64) {
    let bytes = fs::read(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let decoded = cmux_trace::decode(&bytes)
        .unwrap_or_else(|error| panic!("{} does not decode: {error:?}", path.display()));
    assert_eq!(decoded.header.role, role as u16, "{}", path.display());
    assert_eq!(u64::from(decoded.header.pid), pid, "{}", path.display());
}

#[test]
fn trace_control_records_the_daemon_and_its_terminal_host() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-trace-ctl-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let mut daemon = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--headless", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("state"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("SHELL", "/bin/sh")
        .env_remove("CMUX_TUI_TERMINAL_HOST_MODEL")
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_TTY")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    let stream = loop {
        if let Ok(stream) = UnixStream::connect(&socket) {
            break stream;
        }
        assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
        std::thread::sleep(Duration::from_millis(25));
    };
    stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
    let mut client =
        Client { writer: stream.try_clone().unwrap(), reader: BufReader::new(stream), next: 0 };
    client.call(json!({"cmd": "new-workspace", "name": "traced", "cols": 80, "rows": 24})).unwrap();

    // `key` is refused without `keys`; a path is not a parameter.
    let refused = client.call(json!({"cmd": "trace-start", "categories": ["key"]}));
    assert!(refused.is_err(), "{refused:?}");
    let started = client
        .call(json!({"cmd": "trace-start", "categories": ["frame"], "path": "/etc"}))
        .unwrap();
    assert_eq!(started["recording"], true, "{started}");
    assert_eq!(started["categories"], json!(["frame"]));

    let daemon_report = process(&started, "daemon");
    assert_eq!(daemon_report.len(), 1, "{started}");
    assert_eq!(daemon_report[0]["state"], "recording", "{started}");
    let daemon_ring = PathBuf::from(daemon_report[0]["recording_path"].as_str().unwrap());
    assert!(daemon_ring.starts_with(dir.join("state")), "{}", daemon_ring.display());
    assert_ring(&daemon_ring, Role::Daemon, daemon_report[0]["pid"].as_u64().unwrap());

    let hosts = process(&started, "terminal-host");
    assert!(!hosts.is_empty(), "no terminal host was asked: {started}");
    for host in &hosts {
        assert_eq!(host["state"], "recording", "{started}");
        let ring = PathBuf::from(host["recording_path"].as_str().unwrap());
        assert!(ring.starts_with(dir.join("state")), "{}", ring.display());
        assert_ring(&ring, Role::TerminalHost, host["pid"].as_u64().unwrap());
    }
    let total = started["total_bytes"].as_u64().unwrap();
    assert!(total <= started["total_cap_bytes"].as_u64().unwrap(), "{started}");
    assert_eq!(
        started["bytes_by_role"]["terminal-host"].as_u64(),
        Some(hosts.len() as u64 * Role::TerminalHost.recording_bytes())
    );

    let again = client.call(json!({"cmd": "trace-start"})).unwrap();
    assert_eq!(process(&again, "daemon")[0]["error"], "already_recording", "{again}");
    assert_eq!(process(&again, "terminal-host").len(), 0, "a refused start went on: {again}");

    let status = client.call(json!({"cmd": "trace-status"})).unwrap();
    assert_eq!(status["recording"], true, "{status}");
    assert!(process(&status, "terminal-host").iter().all(|host| host["state"] == "recording"));

    let stopped = client.call(json!({"cmd": "trace-stop"})).unwrap();
    assert_eq!(stopped["recording"], false, "{stopped}");
    assert!(process(&stopped, "terminal-host").iter().all(|host| host["state"] == "idle"));
    // The rings stay for the exporter after the stop.
    assert!(daemon_ring.exists());

    let identity = client.call(json!({"cmd": "identify"})).unwrap();
    client
        .call(json!({"cmd": "shutdown-daemon", "pid": identity["pid"],
            "generation": identity["generation"], "force": true, "end_terminals": true}))
        .unwrap();
    let _ = daemon.wait();
    let _ = fs::remove_dir_all(&dir);
}
