//! `fs-v1` on the wire: the exact gate, the transports, the refusal on a
//! host that is not a Cloud host, and the request lines of the contract
//! (`daemon-fs-for-cloud.md`, "Exact wire JSON") replayed with their
//! answer shapes recorded for cmux-cloud.

use std::io::{BufRead, BufReader, Read as _, Write as _};
use std::os::unix::net::UnixStream;

use serde_json::{Value, json};

use super::super::{LinkVerifier, serve_remote_entry};
use super::*;
use crate::fs_ops::{FS_CAPABILITY, FS_COMMANDS, FS_SYMLINK_COMMANDS, FsService, Roots};

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
    for cmd in FS_COMMANDS.iter().chain(&FS_SYMLINK_COMMANDS) {
        assert!(gate.admit(&peer(), &json!({ "id": 1, "cmd": cmd, "path": "/x" }).to_string()));
    }
    for cmd in crate::git_seed::GIT_SEED_COMMANDS {
        assert!(gate.admit(&peer(), &json!({ "id": 1, "cmd": cmd, "job": "x" }).to_string()));
    }
    for cmd in crate::blob_fetch::BLOB_FETCH_COMMANDS {
        assert!(gate.admit(&peer(), &json!({ "id": 1, "cmd": cmd, "job": "x" }).to_string()));
    }
    assert!(!gate.admit(&peer(), r#"{"id":1,"cmd":"blob.fetch.list"}"#));
    for frame in [
        r#"{"id":1,"cmd":"git.seed.cancel"}"#,
        r#"{"id":1,"cmd":"git.seed.start","protocol":"cmux.protocol/2"}"#,
        r#"{"id":1,"cmd":"GIT.SEED.START"}"#,
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
    for cmd in FS_COMMANDS.iter().chain(&FS_SYMLINK_COMMANDS) {
        let answer = answer_line(None, true, "owner", &json!({ "id": 7, "cmd": cmd }).to_string());
        assert_eq!(answer["id"], 7);
        assert_eq!(answer["ok"], false);
        assert_eq!(answer["error_code"], "fs.unavailable", "{cmd}");
        assert!(answer["error"].as_str().unwrap().contains("Cloud"));
    }
}

/// `fs.stat` of a folder says how many bytes the machine still has for a
/// writer there, so a copy can be refused before it starts; a file's stat
/// does not. RED before the stat said it: a folder copy could only learn of
/// a full disk from a refused write partway.
#[test]
fn a_folder_stat_names_the_free_bytes_and_a_file_stat_does_not() {
    let home = Home::new("free");
    let service = home.service();
    let line = home.map(r#"{"id":1,"cmd":"fs.stat","path":"/home/cmux"}"#);
    let answer = answer_line(Some(&service), true, "owner", &line);
    assert_eq!(answer["ok"], true, "{answer}");
    assert!(answer["data"]["available_bytes"].as_u64().is_some_and(|free| free > 0), "{answer}");

    let write = home.map(
        r#"{"id":2,"cmd":"fs.write","path":"/home/cmux/a.txt","text":"a","mode":"create"}"#,
    );
    assert_eq!(answer_line(Some(&service), true, "owner", &write)["ok"], true);
    let line = home.map(r#"{"id":3,"cmd":"fs.stat","path":"/home/cmux/a.txt"}"#);
    let answer = answer_line(Some(&service), true, "owner", &line);
    assert_eq!(answer["ok"], true, "{answer}");
    assert!(answer["data"].get("available_bytes").is_none(), "{answer}");
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

/// Sends `line` and `body` on one dial and returns what the daemon answered.
/// The daemon may refuse a write stream before it has read all of `body`
/// (a deflate stream past its `decoded_size`, a failed disk write): it
/// answers and closes, and the rest of `body` then meets a closed socket.
/// A client stops sending there and reads the answer, so this does too.
/// Whether that happens depends on the socket buffer (a few KiB on macOS,
/// a few hundred on Linux), not on the daemon.
fn routed(home: &Home, line: &str, body: &[u8]) -> (Option<()>, Vec<u8>) {
    let (daemon_side, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let entry = home.entry();
    let daemon = std::thread::spawn(move || {
        route_first_line(&test_mux(), daemon_side, &FsGate, &peer(), entry).map(drop)
    });
    let mut sent = home.map(line).into_bytes();
    sent.push(b'\n');
    sent.extend_from_slice(body);
    // A daemon that answers a short body at once can also be gone before
    // the shutdown (macOS then says NotConnected).
    let closed = |error: &std::io::Error| {
        matches!(
            error.kind(),
            std::io::ErrorKind::BrokenPipe
                | std::io::ErrorKind::ConnectionReset
                | std::io::ErrorKind::NotConnected
        )
    };
    let sent = client.write_all(&sent).and_then(|()| client.shutdown(std::net::Shutdown::Write));
    if let Err(error) = sent {
        assert!(
            closed(&error),
            "only a daemon that already answered and closed stops the body: {error}"
        );
    }
    let mut output = Vec::new();
    let _ = client.read_to_end(&mut output);
    (daemon.join().unwrap(), output)
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
fn file_stream_roundtrips_binary_mebibytes_and_cleans_an_interrupted_write() {
    let home = Home::new("large-stream");
    let bytes: Vec<u8> = (0..8 * 1024 * 1024).map(|i| (i % 251) as u8).collect();
    let write = json!({ "id": 1, "cmd": "fs.write", "path": "/home/cmux/up.bin",
        "mode": "create", "stream": true, "size": bytes.len() })
    .to_string();
    let (left, output) = routed(&home, &write, &bytes);
    assert!(left.is_none());
    let replies: Vec<Value> = output
        .split(|b| *b == b'\n')
        .filter(|l| !l.is_empty())
        .map(|l| serde_json::from_slice(l).unwrap())
        .collect();
    assert_eq!(replies[0]["data"]["ready"], true);
    assert_eq!(replies[1]["data"]["entry"]["size"], bytes.len());
    let (_, output) =
        routed(&home, r#"{"id":2,"cmd":"fs.read","path":"/home/cmux/up.bin","stream":true}"#, &[]);
    let mut output = BufReader::new(output.as_slice());
    let mut line = String::new();
    output.read_line(&mut line).unwrap();
    let header: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(header["data"]["length"], bytes.len());
    let mut received = vec![0u8; bytes.len()];
    output.read_exact(&mut received).unwrap();
    assert_eq!(received, bytes);
    line.clear();
    output.read_line(&mut line).unwrap();
    let end: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(end["ok"], true);
    assert_eq!(end["data"]["revision"], header["data"]["revision"]);

    let interrupted = write.replace("up.bin", "partial.bin");
    let (_, output) = routed(&home, &interrupted, &bytes[..4 * 1024 * 1024]);
    assert!(String::from_utf8(output).unwrap().contains("\"ready\":true"));
    assert!(!home.path.join("partial.bin").exists());
    assert_eq!(std::fs::read_dir(&home.path).unwrap().count(), 1, "no temporary remains");
}

#[test]
fn file_stream_above_64_gib_checks_the_write_mode_instead_of_refusing_its_size() {
    let home = Home::new("uncapped-stream");
    let line = json!({ "id": 1, "cmd": "fs.write", "path": "/home/cmux/up.bin",
        "mode": "invalid", "stream": true, "size": 64u64 * 1024 * 1024 * 1024 + 1 });
    let (left, output) = routed(&home, &line.to_string(), &[]);
    assert!(left.is_none());
    let answer: Value = serde_json::from_slice(&output).unwrap();
    assert_eq!(answer["error_code"], "params.invalid", "{answer}");
    assert!(answer["error"].as_str().unwrap().contains("mode"));
    assert!(std::fs::read_dir(&home.path).unwrap().next().is_none());
}

#[test]
fn a_dial_that_is_not_a_stream_keeps_its_first_line() {
    let home = Home::new("route-line");
    let (daemon_side, mut client) = UnixStream::pair().unwrap();
    client.write_all(b"{\"id\":1,\"cmd\":\"identify\"}\nnext\n").unwrap();
    let mut stream = route_first_line(&test_mux(), daemon_side, &FsGate, &peer(), home.entry())
        .expect("a line dial is handed back");
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

/// One `fs.stat` line through `try_handle` (the remote frame path's fs hook);
/// the answer's error code.
fn fs_stat_code(mux: &Arc<Mux>, client: u64) -> Value {
    let (writer, outbound) = fs_writer();
    let line = r#"{"id":1,"cmd":"fs.stat","path":"/home/cmux"}"#;
    assert_eq!(try_handle(mux, client, line, &writer), Some(true));
    let answer: Value = serde_json::from_str(&outbound.try_pop().expect("an answer")).unwrap();
    answer["error_code"].clone()
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

/// `fs-symlink-v1`: a relative symlink that stays inside the root is made
/// (never over anything) and read back as written, never followed; a target
/// that is absolute or climbs out of the root, counted from where the link's
/// folder really is, is refused and nothing is made.
#[test]
fn a_symlink_is_made_inside_the_root_and_one_leaving_it_is_refused() {
    let home = Home::new("symlink");
    let service = home.service();
    let root = home.path.display().to_string();
    std::fs::create_dir_all(home.path.join("work/app/src")).unwrap();
    std::fs::write(home.path.join("work/app/src/a.txt"), "a").unwrap();
    std::fs::write(home.path.join("x"), "x").unwrap();
    let call = |cmd: &str, params: Value| service.call("owner", cmd, params);

    let made = call("fs.symlink", json!({"path": format!("{root}/work/app/lib"), "target": "src"}))
        .unwrap();
    assert_eq!(made["entry"]["kind"], "symlink", "{made}");
    assert_eq!(
        std::fs::read_link(home.path.join("work/app/lib")).unwrap(),
        std::path::Path::new("src")
    );
    let read = call("fs.readlink", json!({"path": format!("{root}/work/app/lib")})).unwrap();
    assert_eq!(read["target"], "src");
    assert!(read["revision"].as_str().is_some());
    // Never over what is there.
    let again = call("fs.symlink", json!({"path": format!("{root}/work/app/lib"), "target": "x"}));
    assert_eq!(again.unwrap_err().code(), "fs.exists");
    // Up to the root is fine; past it is not, nor an absolute target.
    call("fs.symlink", json!({"path": format!("{root}/work/app/up"), "target": "../../work"}))
        .unwrap();
    for target in ["../../../etc", "/etc", "", "a\nb"] {
        let path = format!("{root}/work/app/bad");
        let refused = call("fs.symlink", json!({"path": path, "target": target}));
        assert!(refused.is_err(), "{target:?} was made");
        assert!(std::fs::symlink_metadata(home.path.join("work/app/bad")).is_err());
    }
    // Counted from where the folder is after the links on the way: `up`
    // is the home's `work`, one below the root.
    let through = format!("{root}/work/app/up/bad");
    assert_eq!(
        call("fs.symlink", json!({"path": through, "target": "../../x"})).unwrap_err().code(),
        "fs.permission_denied"
    );
    call("fs.symlink", json!({"path": format!("{root}/work/app/up/ok"), "target": "../x"}))
        .unwrap();
    // A target that climbs out through another link is taken away again,
    // and so is one naming nothing.
    call("fs.symlink", json!({"path": format!("{root}/alias"), "target": "."})).unwrap();
    let leak = call("fs.symlink", json!({"path": format!("{root}/leak"), "target": "alias/../x"}));
    assert_eq!(leak.unwrap_err().code(), "fs.permission_denied");
    assert!(std::fs::symlink_metadata(home.path.join("leak")).is_err());
    let gone = call("fs.symlink", json!({"path": format!("{root}/gone"), "target": "nothing"}));
    assert!(gone.is_err());
    assert!(std::fs::symlink_metadata(home.path.join("gone")).is_err());
    // A file is not a symlink to read.
    let file = call("fs.readlink", json!({"path": format!("{root}/work/app/src/a.txt")}));
    assert!(file.is_err());
}

fn deflated(bytes: &[u8]) -> Vec<u8> {
    let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::new(3));
    encoder.write_all(bytes).unwrap();
    encoder.finish().unwrap()
}

fn reply_lines(output: &[u8]) -> Vec<Value> {
    output
        .split(|b| *b == b'\n')
        .filter(|l| !l.is_empty())
        .map(|l| serde_json::from_slice(l).unwrap())
        .collect()
}

fn mode_of(path: &std::path::Path) -> u32 {
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

/// `fs-write-deflate-v1`: a 40 MiB file goes as one write stream of
/// deflate bytes, decoded as they come, with the permissions it asked for.
#[test]
fn a_deflate_write_stream_decodes_one_large_file_with_its_permissions() {
    let home = Home::new("deflate-stream");
    let bytes: Vec<u8> =
        (0..40 * 1024 * 1024).map(|i: u32| b"fn main() {}\n"[(i % 13) as usize]).collect();
    let wire = deflated(&bytes);
    let write = json!({ "id": 1, "cmd": "fs.write", "path": "/home/cmux/big.rs",
        "mode": "create", "stream": true, "size": wire.len(), "permissions": 0o755,
        "encoding": "deflate", "decoded_size": bytes.len() })
    .to_string();
    let (left, output) = routed(&home, &write, &wire);
    assert!(left.is_none());
    let replies = reply_lines(&output);
    assert_eq!(replies[0]["data"]["ready"], true, "{replies:?}");
    assert_eq!(replies[1]["data"]["entry"]["size"], bytes.len(), "{replies:?}");
    let path = home.path.join("big.rs");
    assert!(std::fs::read(&path).unwrap() == bytes);
    assert_eq!(mode_of(&path), 0o755);
}

/// A stream that decodes past `decoded_size` is refused at the bound and
/// leaves neither the file nor its temporary.
#[test]
fn a_deflate_write_stream_over_its_decoded_size_leaves_no_file() {
    let home = Home::new("deflate-bomb");
    let wire = deflated(&vec![0u8; 64 * 1024 * 1024]);
    let write = json!({ "id": 1, "cmd": "fs.write", "path": "/home/cmux/bomb.bin",
        "mode": "create", "stream": true, "size": wire.len(),
        "encoding": "deflate", "decoded_size": 1024 * 1024 })
    .to_string();
    let (_, output) = routed(&home, &write, &wire);
    let replies = reply_lines(&output);
    assert_eq!(replies[0]["data"]["ready"], true, "{replies:?}");
    assert_eq!(replies[1]["error_code"], "params.invalid", "{replies:?}");
    assert!(std::fs::read_dir(&home.path).unwrap().next().is_none(), "nothing remains");
}

/// The line op takes deflate bytes too (the Cloud link carries lines), and
/// refuses a payload that decodes to more than it declared.
#[test]
fn a_deflate_line_write_decodes_and_refuses_an_overrun() {
    use base64::Engine as _;
    let home = Home::new("deflate-line");
    let service = home.service();
    let text = "let x = 1;\n".repeat(50_000);
    let encoded = base64::engine::general_purpose::STANDARD.encode(deflated(text.as_bytes()));
    let line = |name: &str, decoded: usize| {
        json!({ "id": 3, "cmd": "fs.write", "path": format!("{}/{name}", home.path.display()),
            "mode": "overwrite", "permissions": 0o600, "bytes_base64": encoded,
            "encoding": "deflate", "decoded_size": decoded })
        .to_string()
    };
    let answer = answer_line(Some(&service), true, "owner", &line("a.rs", text.len()));
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(std::fs::read_to_string(home.path.join("a.rs")).unwrap(), text);
    assert_eq!(mode_of(&home.path.join("a.rs")), 0o600);
    let answer = answer_line(Some(&service), true, "owner", &line("b.rs", text.len() - 1));
    assert_eq!(answer["error_code"], "params.invalid", "{answer}");
    assert!(!home.path.join("b.rs").exists());
}

/// `fs-write-nofollow-v1`: a write that says `no_follow` never goes through
/// a symlink, as a folder on the way or as the file itself; one that does
/// not say it follows links inside the root as before.
#[test]
fn a_no_follow_write_refuses_a_symlink_anywhere_on_its_path() {
    use std::os::unix::fs::symlink;
    let home = Home::new("nofollow");
    let service = home.service();
    let root = home.path.display().to_string();
    std::fs::create_dir_all(home.path.join("real/deep")).unwrap();
    std::fs::write(home.path.join("real/kept.txt"), "kept").unwrap();
    symlink("real", home.path.join("app")).unwrap();
    symlink("kept.txt", home.path.join("real/link.txt")).unwrap();
    let write = |path: String, no_follow: bool| {
        let line = json!({ "id": 1, "cmd": "fs.write", "path": path, "mode": "overwrite",
            "text": "new", "no_follow": no_follow })
        .to_string();
        answer_line(Some(&service), true, "owner", &line)
    };

    for path in [
        format!("{root}/app/a.txt"),
        format!("{root}/app/deep/a.txt"),
        format!("{root}/real/link.txt"),
    ] {
        let answer = write(path.clone(), true);
        assert_eq!(answer["error_code"], "fs.symlink_in_path", "{path}: {answer}");
    }
    assert!(!home.path.join("real/a.txt").exists());
    assert!(!home.path.join("real/deep/a.txt").exists());
    assert_eq!(std::fs::read_to_string(home.path.join("real/kept.txt")).unwrap(), "kept");
    assert!(std::fs::symlink_metadata(home.path.join("real/link.txt")).unwrap().is_symlink());
    // Appending to a part file behind a linked folder is refused too.
    std::fs::write(home.path.join("real/part"), "p").unwrap();
    let stat = service.call("owner", "fs.stat", json!({"path": format!("{root}/real/part")}));
    let revision = stat.unwrap()["revision"].as_str().unwrap().to_string();
    let append = json!({ "id": 2, "cmd": "fs.write", "path": format!("{root}/app/part"),
        "mode": "append", "expected": revision, "text": "q", "no_follow": true })
    .to_string();
    let answer = answer_line(Some(&service), true, "owner", &append);
    assert_eq!(answer["error_code"], "fs.symlink_in_path", "{answer}");
    assert_eq!(std::fs::read_to_string(home.path.join("real/part")).unwrap(), "p");

    // A plain path is written, and without no_follow a link inside the
    // root is followed as before.
    assert_eq!(write(format!("{root}/real/deep/b.txt"), true)["ok"], true);
    assert_eq!(write(format!("{root}/app/c.txt"), false)["ok"], true);
    assert_eq!(std::fs::read_to_string(home.path.join("real/c.txt")).unwrap(), "new");
}

/// A no-follow write stream is refused before `ready`, and a symlink put at
/// the target after the write began fails its commit and leaves no file.
#[test]
fn a_no_follow_write_stream_and_a_late_symlink_are_refused() {
    use std::os::unix::fs::symlink;
    let home = Home::new("nofollow-stream");
    std::fs::create_dir_all(home.path.join("real")).unwrap();
    symlink("real", home.path.join("app")).unwrap();
    let write = json!({ "id": 1, "cmd": "fs.write", "path": "/home/cmux/app/up.bin",
        "mode": "overwrite", "stream": true, "size": 5, "no_follow": true })
    .to_string();
    let (_, output) = routed(&home, &write, b"hello");
    let replies = reply_lines(&output);
    assert_eq!(replies[0]["error_code"], "fs.symlink_in_path", "{replies:?}");
    assert!(!home.path.join("real/up.bin").exists());

    let service = home.service();
    let target = format!("{}/real/late.txt", home.path.display());
    let mut pending = crate::fs_ops::PendingWrite::begin_no_follow(
        service.roots(),
        &target,
        crate::fs_ops::WriteMode::Overwrite,
        Some(3),
    )
    .unwrap();
    pending.write(b"new").unwrap();
    std::fs::write(home.path.join("real/elsewhere"), "theirs").unwrap();
    symlink("elsewhere", home.path.join("real/late.txt")).unwrap();
    assert_eq!(pending.commit().unwrap_err().code(), "fs.symlink_in_path");
    assert!(std::fs::symlink_metadata(home.path.join("real/late.txt")).unwrap().is_symlink());
    assert_eq!(std::fs::read_to_string(home.path.join("real/elsewhere")).unwrap(), "theirs");
    let left: Vec<_> = std::fs::read_dir(home.path.join("real")).unwrap().collect();
    assert_eq!(left.len(), 2, "only the link and its target remain: {left:?}");
}
