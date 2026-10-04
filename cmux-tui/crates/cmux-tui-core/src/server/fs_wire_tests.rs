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

fn peer() -> RemotePeer {
    RemotePeer { install: "inst_1".into(), user: "42".into(), team: "team_a".into() }
}

/// A temporary `/home/cmux` stand-in, removed on drop.
struct Home {
    path: std::path::PathBuf,
}

impl Home {
    fn new(label: &str) -> Self {
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

    /// `line` with the contract's `/home/cmux` mapped onto this home.
    fn map(&self, line: &str) -> String {
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
    let service = home.service();
    let mut sent = home.map(line).into_bytes();
    sent.push(b'\n');
    sent.extend_from_slice(body);
    client.write_all(&sent).unwrap();
    client.shutdown(std::net::Shutdown::Write).unwrap();
    let left = route_first_line(daemon_side, &FsGate, &peer(), Some(&service)).map(drop);
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
    let mut stream = route_first_line(daemon_side, &FsGate, &peer(), Some(&home.service()))
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
    assert!(route_first_line(daemon_side, &FsGate, &peer(), None).is_none());
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
    let mux = Mux::new_for_test("fs-entry", crate::SurfaceOptions::default());
    let verifier: LinkVerifier = Arc::new(|_stream: &UnixStream| Ok(()));
    let server = serve_remote_entry(mux, &path, verifier, Arc::new(FsGate)).unwrap();
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
