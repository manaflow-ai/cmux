//! `fs-v1` on the wire: the exact gate, the transports, the refusal on a
//! host that is not a Cloud host, and the request lines of the contract
//! (`daemon-fs-for-cloud.md`, "Exact wire JSON") replayed with their
//! answer shapes recorded for cmux-cloud.

use std::io::{BufRead, BufReader, Write as _};
use std::os::unix::net::UnixStream;

use serde_json::{Value, json};

use super::super::{LinkVerifier, serve_remote_entry};
use super::*;
use crate::fs_ops::{FsService, Roots};

pub(super) fn test_mux() -> Arc<Mux> {
    let mux = Mux::new_for_test("fs-wire", crate::SurfaceOptions::default());
    // The remote relay serves only an install with a good control-plane
    // check (server-remote-conversations.md section 10).
    mux.record_remote_check("inst_1").unwrap();
    mux
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
