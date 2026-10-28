#![cfg(unix)]
//! The old/new compat matrix of the framed IPC program, daemon side
//! (plans/cmux-next/chrome-parity/p05-ipc.md, task 118; acceptance IPC-13).
//! The app side, with the pinned old daemon, is CmuxNextDaemonTests'
//! IpcCompatMatrixTests.
//!
//! An old client is a build from before the program: it declares no
//! `api_revision`, echoes none of the framed IPC capabilities, never names a
//! `stream` and opens a connection per view. [`OLD_CLIENT_HANDSHAKE`] is the
//! fixture of what it sends. On this daemon it must read byte-identical
//! JSON: every reply and subscribe event equals, byte for byte, what a new
//! client holding the grants reads for the same request, and every item of
//! its per-view attach equals the new client's stream item with the leading
//! `"stream":N` member removed (spec/events.md "Attach streams": the stream id
//! is the item's first member, the rest is unchanged). An old client never
//! reads a frame (no `0xFF` byte) and never a `stream` member.
//!
//! The new pair here is a new client on this daemon. The test process is the
//! daemon's own executable, so the daemon classifies its connections as a
//! byte bridge (server/origin_gate.rs `classify_peer_process`): the new pair
//! gets streams and never frames, the bridge row of transports.md "Framed IPC
//! grants". Frames on a direct local peer are checked from the app side.
//!
//! Chrome keeps old and new ends talking the same way: a versioned interface
//! answers an older peer in its own version's shape
//! (mojo/public/tools/bindings/README.md, "Versioning").

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine as _;
use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};

/// What the old client sends on each connection before its first request:
/// the pre-program app's handshake (`identify`, then `set-client-info` with
/// no `api_revision` and no framed IPC capability).
const OLD_CLIENT_HANDSHAKE: [&str; 2] = [
    r#"{"id":1,"cmd":"identify"}"#,
    r#"{"id":2,"cmd":"set-client-info","name":"cmux-next","kind":"gui","capabilities":["view-attachment-lease-v1","attach-initial-size"]}"#,
];

/// The old client's subscription: tree deltas, as the app subscribes.
const OLD_CLIENT_SUBSCRIBE: &str = r#"{"id":3,"cmd":"subscribe","tree_events":"deltas"}"#;

/// The bench ops (perf-lead.md) whose replies both clients must read the same.
const BENCH_OPS: [&str; 3] = ["list-workspaces", "list-terminals", "list-tab-groups"];

/// The framed IPC capabilities a new client echoes.
const STREAMS: &str = "attach-streams-v1";
const FRAMES: &str = "ipc-frames-v2";

/// The first stream the new client mints.
const STREAM: u16 = 1;

/// One client connection that keeps every line it reads as raw bytes.
struct Client {
    reader: BufReader<UnixStream>,
    /// Lines read while waiting for something else, oldest first.
    backlog: Vec<Vec<u8>>,
}

impl Client {
    fn open(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).expect("connect");
        stream.set_read_timeout(Some(Duration::from_secs(20))).expect("read timeout");
        Self { reader: BufReader::new(stream), backlog: Vec::new() }
    }

    fn write_line(&mut self, line: &str) {
        let socket = self.reader.get_mut();
        socket.write_all(line.as_bytes()).expect("write");
        socket.write_all(b"\n").expect("write");
    }

    /// The next line from the socket, its newline removed.
    fn read_raw(&mut self) -> Vec<u8> {
        let mut line = Vec::new();
        let read = self.reader.read_until(b'\n', &mut line).expect("read");
        assert_ne!(read, 0, "daemon closed the connection");
        assert_ne!(line[0], 0xFF, "a frame on a connection that never negotiated frames");
        assert_eq!(line.pop(), Some(b'\n'), "a line without its newline");
        line
    }

    /// The first line (kept or read) for which `matches` holds.
    fn take(&mut self, matches: impl Fn(&Value) -> bool) -> Vec<u8> {
        if let Some(index) = self.backlog.iter().position(|line| matches(&parse(line))) {
            return self.backlog.remove(index);
        }
        loop {
            let line = self.read_raw();
            if matches(&parse(&line)) {
                return line;
            }
            self.backlog.push(line);
        }
    }

    /// Sends `line` and returns its reply's bytes.
    fn request(&mut self, line: &str) -> Vec<u8> {
        let id = parse(line.as_bytes())["id"].clone();
        self.write_line(line);
        let reply = self.take(|message| message.get("event").is_none() && message["id"] == id);
        assert_eq!(parse(&reply)["ok"], true, "{line} -> {}", String::from_utf8_lossy(&reply));
        reply
    }

    fn rpc(&mut self, request: Value) -> Value {
        parse(&self.request(&request.to_string()))
    }
}

fn parse(line: &[u8]) -> Value {
    serde_json::from_slice(line).expect("a JSON line")
}

/// An old client's connection, its handshake sent.
fn old_client(socket: &Path) -> Client {
    let mut client = Client::open(socket);
    for line in OLD_CLIENT_HANDSHAKE {
        client.request(line);
    }
    client
}

/// A new client's connection: `identify {revisions}`, then `set-client-info`
/// at the daemon's revision echoing both framed IPC capabilities it offers.
/// Returns the connection and what `identify` offered.
fn new_client(socket: &Path) -> (Client, Vec<String>) {
    let mut client = Client::open(socket);
    let identity = client.rpc(json!({"id": 1, "cmd": "identify", "revisions": true}));
    let revision = identity["data"]["api_revision"].as_u64().expect("api_revision");
    let offered: Vec<String> = identity["data"]["capabilities"]
        .as_array()
        .expect("capabilities")
        .iter()
        .filter_map(|capability| capability.as_str().map(str::to_owned))
        .collect();
    client.rpc(json!({
        "id": 2, "cmd": "set-client-info", "name": "cmux-next", "kind": "gui",
        "capabilities": ["view-attachment-lease-v1", "attach-initial-size", STREAMS, FRAMES],
        "api_revision": revision,
    }));
    (client, offered)
}

struct Daemon {
    mux: std::sync::Arc<Mux>,
    socket: PathBuf,
}

impl Daemon {
    fn start(name: &str) -> Self {
        let mux = Mux::new(
            name,
            SurfaceOptions {
                command: Some(vec!["cat".to_string()]),
                // Outside any git checkout, so no git branch arrives later.
                cwd: Some(std::env::temp_dir().to_string_lossy().into_owned()),
                ..SurfaceOptions::default()
            },
        );
        let socket =
            std::env::temp_dir().join(format!("cmux-{name}-{}", std::process::id())).join("s.sock");
        server::serve(mux.clone(), Some(socket.clone())).expect("serve");
        Self { mux, socket }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.mux.shutdown();
        server::cleanup(&self.socket);
    }
}

/// Sends `line` to the old client, the new client, then the old client
/// again, and checks the new client's reply equals the old client's. Two old
/// replies that differ mean the daemon's state moved between the reads (a
/// terminal's title or git branch arrives on its own), so it reads again.
fn same_reply(old: &mut Client, new: &mut Client, line: &str) {
    for _ in 0..50 {
        let before = old.request(line);
        let new_reply = new.request(line);
        let after = old.request(line);
        if before == after {
            assert_eq!(
                String::from_utf8_lossy(&before),
                String::from_utf8_lossy(&new_reply),
                "{line}: the old client's reply differs from the new client's"
            );
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("{line}: the daemon's answer never held still");
}

/// The bytes of `line` without its leading `"stream":N,` member, or None when
/// it does not start with that member.
fn without_leading_stream(line: &[u8], stream: u16) -> Option<Vec<u8>> {
    let prefix = format!(r#"{{"stream":{stream},"#);
    let rest = line.strip_prefix(prefix.as_bytes())?;
    Some([b"{".as_slice(), rest].concat())
}

fn has_stream_member(line: &[u8]) -> bool {
    parse(line).get("stream").is_some()
}

/// The terminal bytes of the attach `output` items in `lines`.
fn output_bytes(lines: &[Vec<u8>]) -> Vec<u8> {
    lines
        .iter()
        .map(|line| parse(line))
        .filter(|item| item["event"] == "output")
        .flat_map(|item| {
            base64::engine::general_purpose::STANDARD
                .decode(item["data"].as_str().expect("output data"))
                .expect("base64 output")
        })
        .collect()
}

/// Reads `client`'s items until their output holds `needle`; returns them.
fn items_until_output(
    client: &mut Client,
    is_item: impl Fn(&Value) -> bool,
    needle: &[u8],
) -> Vec<Vec<u8>> {
    let mut items = Vec::new();
    while !output_bytes(&items).windows(needle.len()).any(|window| window == needle) {
        items.push(client.take(&is_item));
    }
    items
}

/// Old client + new daemon: byte-identical JSON for the bench ops, the
/// subscribe events and the attach items, while a new client on the same
/// daemon holds the stream grant and attaches the same terminal as a stream.
#[test]
fn an_old_client_reads_byte_identical_json_beside_a_new_client() {
    let daemon = Daemon::start("ipc-compat-old-client");
    let surface = daemon
        .mux
        .new_workspace_as(&cmux_tui_core::Actor::Daemon, None, Some((80, 24)))
        .expect("terminal")
        .id;

    let mut old = old_client(&daemon.socket);
    let (mut new, _) = new_client(&daemon.socket);
    old.request(OLD_CLIENT_SUBSCRIBE);
    new.request(OLD_CLIENT_SUBSCRIBE);

    // Replies: the same request (same id) on each connection reads the same
    // bytes ([`same_reply`]).
    for (index, op) in BENCH_OPS.iter().enumerate() {
        same_reply(&mut old, &mut new, &json!({"id": 100 + index, "cmd": op}).to_string());
    }

    // Attach: the old client's own view connection and the new client's
    // stream on its control connection, of the same terminal.
    let mut old_view = old_client(&daemon.socket);
    let old_attach = old_view.request(
        &json!({"id": 10, "cmd": "attach-surface", "surface": surface, "cols": 80, "rows": 24})
            .to_string(),
    );
    new.request(
        &json!({"id": 10, "cmd": "attach-surface", "surface": surface, "cols": 80, "rows": 24,
                "stream": STREAM})
        .to_string(),
    );
    assert!(!has_stream_member(&old_attach), "{}", String::from_utf8_lossy(&old_attach));
    let old_ready = old_view.take(|item| item["event"] == "vt-state");
    let new_ready = new.take(|item| item["stream"] == STREAM && item["event"] == "vt-state");
    assert_eq!(
        String::from_utf8_lossy(&old_ready),
        String::from_utf8_lossy(&without_leading_stream(&new_ready, STREAM).expect("stream first")),
        "the old view's READY is the stream's READY without its stream member"
    );

    // Output and events: a third client types into the terminal and adds a
    // workspace.
    let mut cli = old_client(&daemon.socket);
    cli.rpc(json!({"id": 20, "cmd": "send", "surface": surface, "text": "compat-ping\n"}));
    cli.rpc(json!({"id": 21, "cmd": "new-workspace", "name": "compat"}));

    let old_items = items_until_output(
        &mut old_view,
        |item| item.get("id").is_none() && item["surface"] == json!(surface),
        b"compat-ping",
    );
    let new_items = items_until_output(&mut new, |item| item["stream"] == STREAM, b"compat-ping");
    assert!(old_items.iter().all(|item| !has_stream_member(item)));
    assert_eq!(output_bytes(&old_items), output_bytes(&new_items));
    // Every item is the stream's item without its member. Each connection's
    // pump cuts output into chunks of its own, so output compares as bytes
    // (above) and every other item byte for byte, in order.
    let stripped: Vec<_> = new_items
        .iter()
        .map(|item| without_leading_stream(item, STREAM).expect("stream first"))
        .collect();
    let not_output = |items: &[Vec<u8>]| -> Vec<String> {
        items
            .iter()
            .filter(|item| parse(item)["event"] != "output")
            .map(|item| String::from_utf8_lossy(item).into_owned())
            .collect()
    };
    assert_eq!(not_output(&old_items), not_output(&stripped));
    for item in old_items.iter().chain(&stripped).filter(|item| parse(item)["event"] == "output") {
        assert!(item.starts_with(br#"{"event":"output","#), "{}", String::from_utf8_lossy(item));
    }

    // Subscribe events: each subscriber reads the new workspace's tree deltas
    // (the only tree change since they subscribed) as the same bytes, in the
    // same order.
    let tree_delta = |message: &Value| {
        message.get("stream").is_none()
            && message["event"].as_str().is_some_and(|event| {
                ["workspace-", "screen-", "pane-", "tab-"]
                    .iter()
                    .any(|kind| event.starts_with(kind))
            })
    };
    let screen_added = |message: &Value| tree_delta(message) && message["event"] == "screen-added";
    let old_events = deltas_until(&mut old, tree_delta, screen_added);
    let new_events = deltas_until(&mut new, tree_delta, screen_added);
    assert!(old_events.iter().all(|event| !has_stream_member(event)));
    assert_eq!(
        old_events.iter().map(|event| String::from_utf8_lossy(event)).collect::<Vec<_>>(),
        new_events.iter().map(|event| String::from_utf8_lossy(event)).collect::<Vec<_>>(),
        "the subscribers read different tree deltas"
    );
    assert!(!old.backlog.iter().chain(&old_view.backlog).any(|line| has_stream_member(line)));
}

/// The lines of `client` for which `keep` holds, up to and including the
/// first for which `last` holds.
fn deltas_until(
    client: &mut Client,
    keep: impl Fn(&Value) -> bool,
    last: impl Fn(&Value) -> bool,
) -> Vec<Vec<u8>> {
    let mut kept = Vec::new();
    loop {
        let line = client.take(&keep);
        let done = last(&parse(&line));
        kept.push(line);
        if done {
            return kept;
        }
    }
}

/// The new pair through a bridge: streams are offered and granted, frames
/// are neither offered nor answered, and the schema digest is not sent.
#[test]
fn a_new_client_through_a_bridge_gets_streams_and_never_frames() {
    let daemon = Daemon::start("ipc-compat-bridge");
    let surface = daemon
        .mux
        .new_workspace_as(&cmux_tui_core::Actor::Daemon, None, Some((80, 24)))
        .expect("terminal")
        .id;
    let (mut new, offered) = new_client(&daemon.socket);
    assert!(offered.iter().any(|capability| capability == STREAMS), "{offered:?}");
    assert!(!offered.iter().any(|capability| capability == FRAMES), "{offered:?}");
    let identity = new.rpc(json!({"id": 3, "cmd": "identify", "revisions": true}));
    assert!(identity["data"].get("sdk_schema_digest").is_none(), "{identity}");
    assert!(identity["data"].get("framed_methods").is_none(), "{identity}");

    // The stream grant holds: an attach as a stream answers, its READY is
    // tagged, and cancel-stream ends it.
    new.request(
        &json!({"id": 4, "cmd": "attach-surface", "surface": surface, "stream": STREAM})
            .to_string(),
    );
    let ready = new.take(|item| item["stream"] == STREAM && item["event"] == "vt-state");
    assert!(without_leading_stream(&ready, STREAM).is_some());
    let canceled = new.rpc(json!({"id": 5, "cmd": "cancel-stream", "stream": STREAM}));
    assert_eq!(canceled["data"]["outcome"], "applied", "{canceled}");
    new.take(|item| item["stream"] == STREAM && item["event"] == "stream-end");
}

/// An old client that names a stream without the grant is refused, and its
/// connection keeps answering as before.
#[test]
fn an_old_client_that_names_a_stream_is_refused_and_keeps_its_connection() {
    let daemon = Daemon::start("ipc-compat-no-grant");
    let surface = daemon
        .mux
        .new_workspace_as(&cmux_tui_core::Actor::Daemon, None, Some((80, 24)))
        .expect("terminal")
        .id;
    let mut old = old_client(&daemon.socket);
    old.write_line(
        &json!({"id": 4, "cmd": "attach-surface", "surface": surface, "stream": STREAM})
            .to_string(),
    );
    let refused = parse(&old.take(|message| message["id"] == 4));
    assert_eq!(refused["ok"], false, "{refused}");
    assert!(
        refused["error"].as_str().is_some_and(|error| error.starts_with("streams_not_granted")),
        "{refused}"
    );
    old.request(r#"{"id":5,"cmd":"list-workspaces"}"#);
    assert!(!old.backlog.iter().any(|line| has_stream_member(line)));
}
