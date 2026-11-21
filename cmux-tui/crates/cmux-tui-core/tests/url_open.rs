#![cfg(unix)]

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

fn connect(path: &Path) -> BufReader<UnixStream> {
    let stream = UnixStream::connect(path).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
    BufReader::new(stream)
}

#[test]
fn file_preview_open_socket_delivery_exclusive_claim_expiry_and_validation() {
    let mux = Mux::new("file-preview-open-integration", SurfaceOptions::default());
    let surface = mux.new_workspace(Some("preview".into()), Some((80, 24))).unwrap();
    let terminal = surface.terminal_public_id().unwrap().to_string();
    let socket = std::env::temp_dir()
        .join(format!("cmux-file-preview-open-{}", std::process::id()))
        .join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let open = || {
        json!({
            "id": 1,
            "cmd": "file-preview-open",
            "terminal_id": terminal,
            "path": "/srv/notes.md",
            "line": 12,
        })
    };

    assert_eq!(rpc(&socket, open())["data"]["opened"], false);
    let mut first = connect(&socket);
    send(&mut first, json!({"id": 1, "cmd": "url-open-subscribe", "terminal_ids": [terminal]}));
    assert_eq!(read(&mut first)["data"]["url_open_ready"], true);

    let mut guest = connect(&socket);
    send(&mut guest, open());
    let event = read(&mut first);
    assert_eq!(event["event"], "file-preview-open");
    assert_eq!(event["kind"], "file-preview");
    assert_eq!(event["terminal_id"], terminal);
    assert_eq!(event["path"], "/srv/notes.md");
    assert_eq!(event["line"], 12);
    assert_eq!(
        rpc(
            &socket,
            json!({"id": 1, "cmd": "file-preview-open-claim", "request_id": event["request_id"]})
        )["data"]["claimed"],
        true
    );
    assert_eq!(
        rpc(
            &socket,
            json!({"id": 1, "cmd": "file-preview-open-result", "request_id": event["request_id"], "opened": true})
        )["data"]["accepted"],
        true
    );
    assert_eq!(read(&mut guest)["data"]["opened"], true);

    // A buffered file event cannot be claimed after the guest's deadline.
    send(&mut guest, open());
    let stale = read(&mut first);
    assert_eq!(read(&mut guest)["data"]["opened"], false);
    assert_eq!(
        rpc(
            &socket,
            json!({"id": 1, "cmd": "file-preview-open-claim", "request_id": stale["request_id"]})
        )["data"]["claimed"],
        false
    );

    for request in [
        json!({"id": 1, "cmd": "file-preview-open", "terminal_id": terminal, "path": "notes.md"}),
        json!({"id": 1, "cmd": "file-preview-open", "terminal_id": terminal, "path": "/srv/notes\n.md"}),
        json!({"id": 1, "cmd": "file-preview-open", "terminal_id": terminal, "path": "/srv/notes.md", "line": 0}),
    ] {
        assert_eq!(rpc(&socket, request)["data"]["opened"], false);
    }

    // With two frontends subscribed, the broker refuses to pick one. Checked last, with
    // `second` kept open: dropping it would race the server noticing the disconnect.
    let mut second = connect(&socket);
    send(&mut second, json!({"id": 1, "cmd": "url-open-subscribe", "terminal_ids": [terminal]}));
    assert_eq!(read(&mut second)["data"]["url_open_ready"], true);
    assert_eq!(rpc(&socket, open())["data"]["opened"], false);
    assert!(mux.resource_notifications(256).is_empty());
    mux.shutdown();
    server::cleanup(&socket);
}

fn send(stream: &mut BufReader<UnixStream>, value: Value) {
    writeln!(stream.get_mut(), "{value}").unwrap();
}

fn read(stream: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    assert_ne!(stream.read_line(&mut line).unwrap(), 0);
    serde_json::from_str(&line).unwrap()
}

fn rpc(path: &Path, value: Value) -> Value {
    let mut stream = connect(path);
    send(&mut stream, value);
    read(&mut stream)
}

#[test]
fn url_open_socket_delivery_ack_headless_and_expiration() {
    let mux = Mux::new("url-open-integration", SurfaceOptions::default());
    let surface = mux.new_workspace(Some("auth".into()), Some((80, 24))).unwrap();
    let terminal = surface.terminal_public_id().unwrap().to_string();
    let other = mux.new_workspace(Some("headless".into()), Some((80, 24))).unwrap();
    let other_terminal = other.terminal_public_id().unwrap().to_string();
    let socket =
        std::env::temp_dir().join(format!("cmux-url-open-{}", std::process::id())).join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let url = "HTTPS://github.com/login/device?state=AbC%2f%2B&code=xyz#fragment";
    let open = || json!({"id": 1, "cmd": "url-open", "terminal_id": terminal, "url": url});

    // Headless commands never make a durable browser/notification resource.
    assert_eq!(rpc(&socket, open())["data"]["opened"], false);
    let mut frontend = connect(&socket);
    send(&mut frontend, json!({"id": 1, "cmd": "url-open-subscribe", "terminal_ids": [terminal]}));
    assert_eq!(read(&mut frontend)["data"]["url_open_ready"], true);
    let headless = rpc(
        &socket,
        json!({"id": 1, "cmd": "url-open", "terminal_id": other_terminal, "url": url}),
    );
    assert_eq!(headless["data"]["opened"], false);

    let mut guest = connect(&socket);
    send(&mut guest, open());
    let event = read(&mut frontend);
    assert_eq!(event["event"], "url-open");
    assert_eq!(event["terminal_id"], terminal);
    assert_eq!(event["url"], url);
    let claimed =
        rpc(&socket, json!({"id": 1, "cmd": "url-open-claim", "request_id": event["request_id"]}));
    assert_eq!(claimed["data"]["claimed"], true);
    let accepted = rpc(
        &socket,
        json!({"id": 1, "cmd": "url-open-result", "request_id": event["request_id"], "opened": true}),
    );
    assert_eq!(accepted["data"]["accepted"], true);
    assert_eq!(read(&mut guest)["data"]["opened"], true);

    // The guest's deadline is an actual protocol completion signal. A queued
    // frontend event cannot be claimed after it, even after later reconnects.
    send(&mut guest, open());
    let stale = read(&mut frontend);
    assert_eq!(read(&mut guest)["data"]["opened"], false);
    let claimed =
        rpc(&socket, json!({"id": 1, "cmd": "url-open-claim", "request_id": stale["request_id"]}));
    assert_eq!(claimed["data"]["claimed"], false);

    send(&mut guest, open());
    let _event = read(&mut frontend);
    drop(frontend);
    assert_eq!(read(&mut guest)["data"]["opened"], false);
    assert!(mux.resource_notifications(256).is_empty());
    mux.shutdown();
    server::cleanup(&socket);
}
