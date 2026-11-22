//! The real tunnel (`loopback-forward-v1` on the link socket) against a fake
//! machine daemon on a Unix socket in a temp folder (no network listener).

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_cloud::link::Carrier;
use cmux_cloud::ports::{LoopbackTunnel, PortTunnel, TunnelError};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

fn socket_path(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cxl-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("s")
}

fn carrier(socket: PathBuf) -> Carrier {
    Carrier {
        id: "cloud-vm/vm-alpha01#1".into(),
        target: "vm-alpha01".into(),
        generation: 1,
        socket,
    }
}

/// Queues one line for the daemon's writer thread.
fn send(out: &std::sync::mpsc::Sender<Value>, value: Value) {
    let _ = out.send(value);
}

/// A daemon that answers the handshake, then echoes every data frame back
/// (with credit) and logs every command it got. Like the real daemon, it
/// reads and writes on separate threads, so a full socket in one direction
/// never stops the other.
fn fake_daemon(path: &PathBuf, capable: bool) -> Arc<Mutex<Vec<Value>>> {
    let listener = UnixListener::bind(path).unwrap();
    let log = Arc::new(Mutex::new(Vec::new()));
    let seen = Arc::clone(&log);
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut socket = stream.try_clone().unwrap();
        let (out, lines) = std::sync::mpsc::channel::<Value>();
        std::thread::spawn(move || {
            for value in lines {
                let mut line = value.to_string();
                line.push('\n');
                if socket.write_all(line.as_bytes()).is_err() {
                    break;
                }
            }
        });
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { break };
            let message: Value = serde_json::from_str(&line).unwrap();
            seen.lock().unwrap().push(message.clone());
            let id = message["id"].clone();
            match message["cmd"].as_str().unwrap_or_default() {
                "identify" => {
                    let caps = if capable { json!(["loopback-forward-v1"]) } else { json!([]) };
                    send(
                        &out,
                        json!({"id": id, "ok": true, "data": {"app": "cmux-tui", "capabilities": caps}}),
                    );
                }
                "set-client-info" => send(&out, json!({"id": id, "ok": true, "data": {}})),
                "loopback-open" => {
                    if message["port"] == 22 {
                        send(
                            &out,
                            json!({"id": id, "ok": false, "error": "port denied",
                            "error_code": "loopback.denied-port"}),
                        );
                    } else {
                        send(
                            &out,
                            json!({"id": id, "ok": true,
                            "data": {"stream": 1, "address": "127.0.0.1:3000", "window": 262_144}}),
                        );
                    }
                }
                "loopback-data" => {
                    let bytes = STANDARD.decode(message["data"].as_str().unwrap()).unwrap();
                    send(
                        &out,
                        json!({"event": "loopback-credit", "stream": 1, "bytes": bytes.len()}),
                    );
                    send(
                        &out,
                        json!({"event": "loopback-data", "stream": 1, "data": STANDARD.encode(bytes)}),
                    );
                }
                "loopback-shutdown" => {
                    send(&out, json!({"event": "loopback-eof", "stream": 1}));
                    send(&out, json!({"event": "loopback-closed", "stream": 1}));
                }
                _ => {}
            }
        }
    });
    log
}

#[test]
fn the_real_tunnel_handshakes_and_carries_bytes_with_credit() {
    let path = socket_path("ok");
    let log = fake_daemon(&path, true);
    let conn = LoopbackTunnel.open(&carrier(path), "localhost", 3000).unwrap();
    let (mut reader, mut writer) = (conn.reader, conn.writer);
    let payload: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    let sent = payload.clone();
    let up = std::thread::spawn(move || {
        writer.write_all(&sent).unwrap();
        writer.shutdown_write().unwrap();
    });
    let mut back = Vec::new();
    reader.read_to_end(&mut back).unwrap();
    up.join().unwrap();
    assert_eq!(back, payload);
    let log = log.lock().unwrap().clone();
    let commands: Vec<String> =
        log.iter().filter_map(|m| m["cmd"].as_str().map(str::to_owned)).collect();
    assert_eq!(&commands[..3], ["identify", "set-client-info", "loopback-open"]);
    assert_eq!(log[1]["capabilities"], json!(["loopback-forward-v1"]));
    let open = &log[2];
    assert_eq!((open["host"].as_str(), open["port"].as_u64()), (Some("localhost"), Some(3000)));
    assert!(commands.contains(&"loopback-credit".to_owned()), "the client grants credit back");
    let shutdown = commands.iter().position(|c| c == "loopback-shutdown").expect("half close");
    let last_data = commands.iter().rposition(|c| c == "loopback-data").expect("data");
    assert!(last_data < shutdown, "the half close follows every data frame");
}

#[test]
fn a_machine_without_the_capability_or_a_refused_port_is_a_typed_error() {
    let path = socket_path("old");
    fake_daemon(&path, false);
    assert!(matches!(
        LoopbackTunnel.open(&carrier(path), "localhost", 3000),
        Err(TunnelError::Unsupported(_))
    ));
    let path = socket_path("deny");
    fake_daemon(&path, true);
    match LoopbackTunnel.open(&carrier(path), "localhost", 22) {
        Err(TunnelError::Refused { code, .. }) => assert_eq!(code, "loopback.denied-port"),
        other => panic!("expected a refusal, got {:?}", other.err()),
    }
    let gone = socket_path("gone");
    assert!(matches!(
        LoopbackTunnel.open(&carrier(gone), "localhost", 3000),
        Err(TunnelError::Down(_))
    ));
}
