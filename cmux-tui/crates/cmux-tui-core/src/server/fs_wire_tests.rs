//! `fs-v1` on the wire: the exact gate, the transports, the refusal on a
//! host that is not a Cloud host, and the request lines of the contract
//! (`daemon-fs-for-cloud.md`, "Exact wire JSON") replayed with their
//! answer shapes recorded for cmux-cloud.

use std::io::{BufRead, BufReader, Read as _, Write as _};
use std::os::unix::net::UnixStream;

use serde_json::{Value, json};

use super::super::{LinkVerifier, serve_remote_entry};
use super::*;
use crate::fs_ops::{FS_CAPABILITY, FS_COMMANDS, FsService, Roots};

pub(super) fn test_mux() -> Arc<Mux> {
    let mux = Mux::new_for_test("fs-wire", crate::SurfaceOptions::default());
    // The remote relay serves only an install with a good control-plane
    // check (server-remote-conversations.md section 10).
    mux.record_remote_check("inst_1").unwrap();
    mux
}

pub(super) fn peer() -> RemotePeer {
    RemotePeer { install: "inst_1".into(), user: "42".into(), team: "team_a".into() }
}

/// A temporary `/home/cmux` stand-in, removed on drop.
pub(super) struct Home {
    pub(super) path: std::path::PathBuf,
}

impl Home {
    pub(super) fn new(label: &str) -> Self {
        let mut random = [0u8; 6];
        getrandom::fill(&mut random).unwrap();
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-fswire-{label}-{suffix}"));
        std::fs::create_dir_all(&path).unwrap();
        Self { path: std::fs::canonicalize(path).unwrap() }
    }

    fn service(&self) -> FsService {
        FsService::new(Roots::new([self.path.clone()]))
    }

    /// This home as the remote entry's fs owner (leaked: the entry keeps a
    /// `'static` owner, as the daemon's installed one is).
    pub(super) fn entry(&self) -> EntryFs {
        EntryFs {
            service: Some(Box::leak(Box::new(self.service()))),
            first_line_deadline: FIRST_LINE_DEADLINE,
        }
    }

    /// `line` with the contract's `/home/cmux` mapped onto this home.
    pub(super) fn map(&self, line: &str) -> String {
        line.replace("/home/cmux", &self.path.display().to_string())
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

#[test]
fn the_gate_admits_exactly_the_seven_fs_ops() {
    let gate = FsGate;
    for cmd in FS_COMMANDS {
        assert!(gate.admit(&peer(), &json!({ "id": 1, "cmd": cmd, "path": "/x" }).to_string()));
    }
    for frame in [
        r#"{"id":1,"cmd":"identify"}"#,
        r#"{"id":1,"cmd":"fs.trash","paths":["/x"]}"#,
        r#"{"id":1,"cmd":"fs.statx","path":"/x"}"#,
        r#"{"id":1,"cmd":"FS.STAT","path":"/x"}"#,
        r#"{"id":1,"cmd":"new-tab","note":"\"cmd\":\"fs.stat\""}"#,
        r#"{"id":1,"op":"fs.stat","path":"/x"}"#,
        r#"{"id":1,"cmd":["fs.stat"]}"#,
        r#"[{"id":1,"cmd":"fs.stat"}]"#,
        // Review fix: a frame that also names the resource protocol would
        // reach the resource router, not the fs adapter.
        r#"{"id":1,"cmd":"fs.stat","path":"/x","protocol":"cmux.protocol/2"}"#,
        "fs.stat",
        "",
    ] {
        assert!(!gate.admit(&peer(), frame), "{frame}");
    }
}

/// RED (decision D4): a daemon that is not a Cloud host does not advertise
/// fs-v1 and refuses every fs op with a clear error.
#[test]
fn a_host_without_the_fs_owner_does_not_advertise_and_refuses_every_op() {
    assert!(crate::fs_ops::installed().is_none(), "tests never install the process owner");
    assert!(!super::super::advertised_capabilities(false).contains(&FS_CAPABILITY));
    assert!(!super::super::advertised_capabilities(true).contains(&FS_CAPABILITY));
    for cmd in FS_COMMANDS {
        let answer = answer_line(None, true, "owner", &json!({ "id": 7, "cmd": cmd }).to_string());
        assert_eq!(answer["id"], 7);
        assert_eq!(answer["ok"], false);
        assert_eq!(answer["error_code"], "fs.unavailable", "{cmd}");
        assert!(answer["error"].as_str().unwrap().contains("Cloud"));
    }
}

#[test]
fn a_websocket_client_is_refused() {
    let home = Home::new("ws");
    let line = home.map(r#"{"id":1,"cmd":"fs.stat","path":"/home/cmux"}"#);
    let answer = answer_line(Some(&home.service()), false, "owner", &line);
    assert_eq!(answer["error_code"], "fs.permission_denied");
}

#[test]
fn a_stream_request_on_the_line_path_is_refused() {
    let home = Home::new("linestream");
    let line = home.map(r#"{"id":1,"cmd":"fs.read","path":"/home/cmux/x","stream":true}"#);
    let answer = answer_line(Some(&home.service()), true, "owner", &line);
    assert_eq!(answer["error_code"], "params.invalid");
}

/// Each op decodes through the one `cmd`-tagged enum spec/sdk-schema.json
/// types: a missing or mistyped param is `params.invalid`,
/// and a field no op reads is ignored, as before.
#[test]
fn each_op_decodes_its_params_by_its_cmd() {
    let home = Home::new("decode");
    std::fs::write(home.path.join("f"), b"hi").unwrap();
    let service = home.service();
    let answer =
        |line: Value| answer_line(Some(&service), true, "owner", &home.map(&line.to_string()));
    for line in [
        json!({"id":1,"cmd":"fs.stat"}),
        json!({"id":1,"cmd":"fs.read","path":"/home/cmux/f"}),
        json!({"id":1,"cmd":"fs.read","path":"/home/cmux/f","max_bytes":"2"}),
        json!({"id":1,"cmd":"fs.mkdir","path":"/home/cmux"}),
        json!({"id":1,"cmd":"fs.delete","paths":"/home/cmux/f","permanent":true}),
        json!({"id":1,"cmd":"fs.list","path":"/home/cmux","sort":{"key":"color"}}),
    ] {
        assert_eq!(answer(line.clone())["error_code"], "params.invalid", "{line}");
    }
    let read =
        answer(json!({"id":2,"cmd":"fs.read","path":"/home/cmux/f","max_bytes":2,"extra":1}));
    assert_eq!(read["data"]["text"], "hi", "{read}");
    let stat = answer(json!({"id":3,"cmd":"fs.stat","path":"/home/cmux/f"}));
    assert_eq!(stat["data"]["kind"], "file", "{stat}");
}

/// Replaces values that change per run (mtimes, revisions, listing ids)
/// with fixed ones, so the recorded answers are stable.
fn normalize(value: &mut Value) {
    match value {
        Value::Object(map) => {
            // A folder's size depends on the file system; its revision is
            // recorded with size 0.
            let folder = map.get("kind") == Some(&json!("dir")) || map.contains_key("entries");
            for (key, field) in map.iter_mut() {
                match (key.as_str(), &*field) {
                    ("mtime", Value::Number(_)) => *field = json!(1_791_100_000_000_u64),
                    ("listing", Value::String(_)) => *field = json!("lst_0"),
                    ("revision" | "current", Value::String(text)) => {
                        let size =
                            if folder { "s0" } else { text.split('-').next().unwrap_or("s0") };
                        *field = json!(format!("{size}-m1791100000000"));
                    }
                    ("owner_display", Value::String(_)) => *field = json!("cmux"),
                    ("mode_display", Value::String(_)) => *field = json!("rw-r--r--"),
                    _ => normalize(field),
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(normalize),
        _ => {}
    }
}

/// The contract's request lines, in order, against one home that starts
/// with `notes.txt` (12 bytes), `a.txt` (12 bytes) and `old.txt`.
const CONTRACT_LINES: [&str; 9] = [
    r#"{"id":1,"cmd":"fs.stat","path":"/home/cmux/notes.txt"}"#,
    r#"{"id":1,"cmd":"fs.list","path":"/home/cmux","limit":1000}"#,
    r#"{"id":1,"cmd":"fs.read","path":"/home/cmux/notes.txt","offset":0,"max_bytes":16777216}"#,
    r#"{"id":1,"cmd":"fs.read","path":"/home/cmux/notes.txt","offset":1048576,"max_bytes":1048576}"#,
    r#"{"id":1,"cmd":"fs.write","path":"/home/cmux/a.txt","bytes_base64":"aGk=","mode":"replace","expected":"s12-m1791100000000"}"#,
    r#"{"id":1,"cmd":"fs.write","path":"/home/cmux/a.txt","bytes_base64":"aGk=","mode":"overwrite"}"#,
    r#"{"id":1,"cmd":"fs.write","path":"/home/cmux/upload.txt","bytes_base64":"cGF5bG9hZA==","mode":"create"}"#,
    r#"{"id":1,"cmd":"fs.mkdir","path":"/home/cmux","name":"new"}"#,
    r#"{"id":1,"cmd":"fs.delete","paths":["/home/cmux/old.txt"],"permanent":true}"#,
];

const FIXTURE: &str = "src/fs_ops/fixtures/fs-v1-contract-answers.jsonl";

/// Cross-side test (request file "Exact wire JSON"): every request line
/// cmux-cloud sends gets the answer shape it parses. The normalized
/// answers are recorded in `FIXTURE` for cmux-cloud's own test; set
/// `CMUX_FS_UPDATE_FIXTURE=1` to rewrite it.
#[test]
fn the_contract_request_lines_get_the_answer_shapes_cmux_cloud_reads() {
    let home = Home::new("contract");
    let mtime = std::time::UNIX_EPOCH + Duration::from_millis(1_791_100_000_000);
    for (name, body) in
        [("notes.txt", "hello world\n"), ("a.txt", "twelve bytes"), ("old.txt", "x")]
    {
        let path = home.path.join(name);
        std::fs::write(&path, body).unwrap();
        std::fs::File::options().write(true).open(&path).unwrap().set_modified(mtime).unwrap();
    }
    let service = home.service();
    let mut recorded = Vec::new();
    for line in CONTRACT_LINES {
        let answer = answer_line(Some(&service), true, "remote_inst_1", &home.map(line));
        assert_eq!(answer["id"], 1, "{line}");
        assert_eq!(answer["ok"], true, "{line} -> {answer}");
        let mut normalized = answer.clone();
        normalize(&mut normalized);
        recorded.push(json!({ "request": line, "answer": normalized }));
    }
    let data: Vec<&Value> = recorded.iter().map(|r| &r["answer"]["data"]).collect();
    // fs.stat
    assert_eq!(
        *data[0],
        json!({ "name": "notes.txt", "kind": "file", "size": 12, "mtime": 1_791_100_000_000_u64,
            "revision": "s12-m1791100000000", "mode_display": "rw-r--r--",
            "owner_display": "cmux" })
    );
    // fs.list: entries[].{name, kind, size, mtime}, one batch.
    let names: Vec<&str> = data[1]["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["a.txt", "notes.txt", "old.txt"]);
    assert_eq!(data[1]["total"], 3);
    assert_eq!(data[1]["cursor"], Value::Null);
    // fs.read: the whole file, then a range past the end.
    assert_eq!(
        *data[2],
        json!({ "text": "hello world\n", "truncated": false, "size": 12, "encoding": "utf-8" })
    );
    assert_eq!(
        *data[3],
        json!({ "text": "", "truncated": false, "size": 12, "encoding": "utf-8" })
    );
    // fs.write: entry.revision.
    assert_eq!(data[4]["entry"]["revision"], "s2-m1791100000000");
    assert_eq!(data[5]["entry"]["revision"], "s2-m1791100000000");
    assert_eq!(data[6]["entry"]["revision"], "s7-m1791100000000");
    assert_eq!(std::fs::read(home.path.join("upload.txt")).unwrap(), b"payload");
    assert_eq!(data[7]["entry"]["kind"], "dir");
    assert_eq!(*data[8], json!({}));
    assert!(!home.path.join("old.txt").exists());
    // The error answer shape (decision D1: the v12 envelope).
    let missing = answer_line(
        Some(&service),
        true,
        "remote_inst_1",
        &home.map(r#"{"id":1,"cmd":"fs.stat","path":"/home/cmux/x"}"#),
    );
    assert_eq!(missing["error_code"], "fs.not_found");
    recorded.push(json!({ "request": r#"{"id":1,"cmd":"fs.stat","path":"/home/cmux/x"}"#,
        "answer": missing }));
    let text: String = recorded.iter().map(|record| format!("{record}\n")).collect();
    let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(FIXTURE);
    if std::env::var_os("CMUX_FS_UPDATE_FIXTURE").is_some() {
        std::fs::write(&fixture, &text).unwrap();
    }
    assert_eq!(
        std::fs::read_to_string(&fixture).unwrap_or_default(),
        text,
        "the recorded answers changed: rerun with CMUX_FS_UPDATE_FIXTURE=1 and tell cmux-cloud"
    );
}

fn routed(home: &Home, line: &str, body: &[u8]) -> (Option<()>, Vec<u8>) {
    let (daemon_side, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut sent = home.map(line).into_bytes();
    sent.push(b'\n');
    sent.extend_from_slice(body);
    client.write_all(&sent).unwrap();
    client.shutdown(std::net::Shutdown::Write).unwrap();
    let left = route_first_line(&test_mux(), daemon_side, &FsGate, &peer(), home.entry()).map(drop);
    let mut output = Vec::new();
    let _ = client.read_to_end(&mut output);
    (left, output)
}

#[test]
fn a_dial_whose_first_line_is_a_stream_is_served_raw() {
    let home = Home::new("route");
    let (left, output) = routed(
        &home,
        r#"{"id":1,"cmd":"fs.write","path":"/home/cmux/up.bin","mode":"create","stream":true,"size":5}"#,
        b"hello",
    );
    assert!(left.is_none(), "the stream was served on this dial");
    let lines: Vec<Value> = output
        .split(|b| *b == b'\n')
        .filter(|l| !l.is_empty())
        .map(|l| serde_json::from_slice(l).unwrap())
        .collect();
    assert_eq!(lines[0]["data"]["ready"], true);
    assert_eq!(lines[1]["data"]["entry"]["size"], 5);
    assert_eq!(std::fs::read(home.path.join("up.bin")).unwrap(), b"hello");
}

#[test]
fn a_dial_that_is_not_a_stream_keeps_its_first_line() {
    let home = Home::new("route-line");
    let (daemon_side, mut client) = UnixStream::pair().unwrap();
    client.write_all(b"{\"id\":1,\"cmd\":\"identify\"}\nnext\n").unwrap();
    let mut stream = route_first_line(&test_mux(), daemon_side, &FsGate, &peer(), home.entry())
        .expect("a line dial is handed back")
        .into_stream();
    let mut reader = BufReader::new(&mut *stream);
    let mut first = String::new();
    reader.read_line(&mut first).unwrap();
    assert_eq!(first, "{\"id\":1,\"cmd\":\"identify\"}\n");
    let mut second = String::new();
    reader.read_line(&mut second).unwrap();
    assert_eq!(second, "next\n");
}

#[test]
fn a_stream_dial_on_a_host_without_the_owner_is_refused() {
    let (daemon_side, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    client
        .write_all(b"{\"id\":4,\"cmd\":\"fs.read\",\"path\":\"/home/cmux/x\",\"stream\":true}\n")
        .unwrap();
    let entry = EntryFs { service: None, first_line_deadline: FIRST_LINE_DEADLINE };
    assert!(route_first_line(&test_mux(), daemon_side, &FsGate, &peer(), entry).is_none());
    let mut reader = BufReader::new(client);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let answer: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(answer["id"], 4);
    assert_eq!(answer["error_code"], "fs.unavailable");
}

/// RED (decision D4): through the real remote entry with [`FsGate`], a
/// host without the owner answers `fs.unavailable` to every fs op, and
/// every other frame is still `remote_denied`.
#[test]
fn the_link_entry_of_a_non_cloud_host_refuses_fs_and_denies_the_rest() {
    let directory = cmux_unix_socket::short_test_dir("fsentry");
    let path = cmux_link::entry_path::remote_entry_socket_path(&directory.path().join("s.sock"));
    let mux = test_mux();
    let verifier: LinkVerifier = Arc::new(|_stream: &UnixStream| Ok(()));
    let server =
        serve_remote_entry(mux, &path, verifier, Arc::new(FsGate), Default::default()).unwrap();
    let stamp = r#"{"link_peer":{"install":"inst_1","user":"42","team":"team_a"}}"#;
    for line in CONTRACT_LINES.iter().chain([&r#"{"id":1,"cmd":"identify"}"#]) {
        let mut stream = UnixStream::connect(server.path()).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut banner = String::new();
        reader.read_line(&mut banner).unwrap();
        stream.write_all(format!("{stamp}\n{line}\n").as_bytes()).unwrap();
        let mut answer = String::new();
        reader.read_line(&mut answer).unwrap();
        let answer: Value = serde_json::from_str(&answer).unwrap();
        let expected = if line.contains("\"fs.") { "fs.unavailable" } else { "remote_denied" };
        assert_eq!(answer["error_code"], expected, "{line}");
        assert_eq!(answer["id"], 1);
    }
}

fn fs_writer() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    (MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None }), outbound)
}

/// Hands `line` to the route its head's `cmd` names (server/routes.rs), as
/// the connection's dispatch does; the reply.
fn through_route(mux: &Arc<Mux>, client: u64, line: &str) -> Value {
    let (writer, outbound) = fs_writer();
    let head = super::super::RequestHead::parse(line);
    let route = head.cmd().and_then(super::super::routes::find).expect("an fs route");
    let route_line = RouteLine { mux, client, message: line, writer: &writer, head: &head };
    assert_eq!((route.entry)(&route_line), Some(true));
    serde_json::from_str(&outbound.try_pop().expect("an answer")).unwrap()
}

/// One `fs.stat` line through its route; the answer's error code.
fn fs_stat_code(mux: &Arc<Mux>, client: u64) -> Value {
    through_route(mux, client, r#"{"id":1,"cmd":"fs.stat","path":"/home/cmux"}"#)["error_code"]
        .clone()
}

/// The reply of the remote relay's frame path to `line` and the JSON parses
/// it took.
fn remote_frame(mux: &Arc<Mux>, client: u64, line: &str) -> (Value, u64) {
    let (writer, outbound) = fs_writer();
    let stats = crate::diagnostics::IpcStats::default();
    {
        let _scope = crate::diagnostics::JsonParseScope::enter(
            &stats,
            crate::diagnostics::IpcTransport::Lines,
        );
        super::super::remote_relay::handle_watched_frame(
            mux,
            client,
            line,
            &writer,
            std::time::Instant::now(),
            None,
        );
    }
    let answer = serde_json::from_str(&outbound.try_pop().expect("an answer")).unwrap();
    (answer, stats.snapshot().parses.lines.json_parses)
}

/// The fs ops are found by their decoded `cmd`, never a
/// substring of the line, on the local route and on the remote relay alike.
/// An escaped op name answers as its plain spelling (the remote entry's
/// [`FsGate`] already admits it), an op takes two parses (the head and the
/// handler's decode), and a line that only mentions an op still reaches the
/// relay's gate.
#[test]
fn the_fs_ops_are_routed_by_their_decoded_cmd_on_both_paths() {
    let mux = test_mux();
    let escaped = r#"{"id":4,"cmd":"fs\u002estat","path":"/home/cmux"}"#;
    assert!(FsGate.admit(&peer(), escaped));
    let local = mux.control_clients.register(ClientTransport::Unix, fs_writer().0);
    let answer = through_route(&mux, local, escaped);
    assert_eq!(answer["error_code"], "fs.unavailable", "{answer}");
    assert_eq!(answer["id"], 4);

    let remote = mux.control_clients.register(ClientTransport::Remote, fs_writer().0);
    mux.bind_remote_peer(remote, &peer()).unwrap();
    let (answer, parses) = remote_frame(&mux, remote, escaped);
    assert_eq!(answer["error_code"], "fs.unavailable", "{answer}");
    assert_eq!(answer["id"], 4);
    assert_eq!(parses, 2, "the head and the fs handler's decode");

    let mention = r#"{"id":5,"cmd":"no-such-op","path":"\"fs.stat"}"#;
    let (answer, _) = remote_frame(&mux, remote, mention);
    assert_eq!(answer["error_code"], "remote_denied", "{answer}");
    assert_eq!(answer["id"], 5);
}

/// Lane 10 finding A: the fs hook checks the principal on every frame. A
/// revoked install is refused before its stream closes, and a remote client
/// without a bound peer is refused. (Tests install no fs owner, so an
/// admitted frame answers `fs.unavailable`.)
#[test]
fn the_fs_hook_refuses_a_revoked_install_and_a_remote_client_without_a_peer() {
    let mux = test_mux();
    let client = mux.control_clients.register(ClientTransport::Remote, fs_writer().0);
    assert_eq!(fs_stat_code(&mux, client), "fs.permission_denied", "no peer bound yet");
    mux.bind_remote_peer(client, &peer()).unwrap();
    assert_eq!(fs_stat_code(&mux, client), "fs.unavailable");
    mux.remote_relay().revocation.lock().unwrap().record_revoked("inst_1");
    assert_eq!(fs_stat_code(&mux, client), "fs.permission_denied", "revoked, stream still open");
}

/// Lane 10 finding B: a poisoned client registry refuses fs (fail closed).
#[test]
fn the_fs_hook_refuses_on_a_poisoned_registry_lock() {
    let mux = test_mux();
    let client = mux.control_clients.register(ClientTransport::Unix, fs_writer().0);
    assert_eq!(fs_stat_code(&mux, client), "fs.unavailable");
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _held = mux.control_clients.state.lock().unwrap();
        panic!("poisons the registry lock for a fail-closed test");
    }));
    assert_eq!(fs_stat_code(&mux, client), "fs.permission_denied");
}
