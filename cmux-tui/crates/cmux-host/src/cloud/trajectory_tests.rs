//! The trajectory mirror against a fake server with the backend's rules
//! (`backend/apps/api/src/cloud-trajectory-store.ts`): one machine sends
//! its acpmux sessions, a replacement machine of the same lineage restores
//! them and continues the chat (#25584).

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::sender::Answer;
use super::trajectory::*;

const CREATED: u64 = 1_761_000_000_000;
const SID: &str = "0b7c2f4e-1111-4222-8333-944445555666";

#[derive(Default)]
struct Kept {
    generation: u64,
    meta: Value,
    lines: Vec<String>,
    native: BTreeMap<(String, String), Vec<u8>>,
}

/// The backend's store, in memory: contiguous logs, byte-identical
/// retries, generations, native files as appended byte ranges.
/// One copy per machine; `machine` is the caller, `parent` its restore source.
#[derive(Default)]
struct FakeServer {
    stores: BTreeMap<String, BTreeMap<String, Kept>>,
    machine: String,
    parent: Option<String>,
    calls: Vec<(String, Value)>,
    disabled: bool,
}

impl FakeServer {
    fn at(machine: &str) -> FakeServer {
        FakeServer { machine: machine.to_owned(), ..FakeServer::default() }
    }

    /// Calls as `machine`, restored from `parent`.
    fn as_machine(&mut self, machine: &str, parent: Option<&str>) {
        self.machine = machine.to_owned();
        self.parent = parent.map(str::to_owned);
    }

    fn sessions(&self) -> &BTreeMap<String, Kept> {
        static EMPTY: BTreeMap<String, Kept> = BTreeMap::new();
        self.stores.get(&self.machine).unwrap_or(&EMPTY)
    }
}

fn ok(value: Value) -> Answer {
    Answer::Http { status: 200, body: json!({ "ok": true, "value": value }) }
}

fn refuse(status: u16, code: &str, details: Value) -> Answer {
    Answer::Http {
        status,
        body: json!({ "ok": false, "error": { "code": code, "message": code, "details": details } }),
    }
}

impl Api for FakeServer {
    fn call(&mut self, action: &str, body: &Value) -> Answer {
        self.calls.push((action.to_owned(), body.clone()));
        if self.disabled {
            return refuse(404, "cloud.trajectory.disabled", Value::Null);
        }
        let session = body["session"].as_str().unwrap_or("").to_owned();
        let from_parent = body["from"] == "parent";
        if from_parent && matches!(action, "append" | "native") {
            return refuse(403, "auth.forbidden", Value::Null);
        }
        let store = if from_parent { self.parent.clone() } else { Some(self.machine.clone()) };
        let Some(store) = store else {
            return match action {
                "list" => ok(json!({ "sessions": [] })),
                _ => refuse(404, "cloud.trajectory.not_found", Value::Null),
            };
        };
        let sessions = self.stores.entry(store).or_default();
        match action {
            "list" => ok(json!({ "sessions": sessions.iter().map(|(id, k)| json!({
                "session": id,
                "generation": k.generation,
                "last_seq": k.lines.len(),
                "meta": k.meta,
                "native": k.native.iter().map(|((l, p), b)| json!({ "label": l, "path": p, "size": b.len() })).collect::<Vec<_>>(),
            })).collect::<Vec<_>>() })),
            "append" => {
                let generation = body["generation"].as_u64().unwrap();
                if sessions.get(&session).is_some_and(|k| generation < k.generation) {
                    return refuse(409, "cloud.trajectory.stale_generation", json!({}));
                }
                if sessions.get(&session).is_some_and(|k| generation > k.generation) {
                    sessions.remove(&session);
                }
                if !sessions.contains_key(&session) {
                    if body.get("meta").is_none() {
                        return refuse(404, "cloud.trajectory.not_found", Value::Null);
                    }
                    sessions.insert(session.clone(), Kept { generation, ..Kept::default() });
                }
                let kept = sessions.get_mut(&session).unwrap();
                if let Some(meta) = body.get("meta") {
                    kept.meta = meta.clone();
                }
                for line in body["lines"].as_array().unwrap() {
                    let line = line.as_str().unwrap();
                    let seq = line_seq(line).unwrap() as usize;
                    if seq <= kept.lines.len() {
                        if kept.lines[seq - 1] != line {
                            return refuse(409, "cloud.trajectory.conflict", json!({ "seq": seq }));
                        }
                    } else if seq == kept.lines.len() + 1 {
                        kept.lines.push(line.to_owned());
                    } else {
                        return refuse(
                            409,
                            "cloud.trajectory.gap",
                            json!({ "last_seq": kept.lines.len() }),
                        );
                    }
                }
                ok(json!({ "last_seq": kept.lines.len() }))
            }
            "native" => {
                let Some(kept) = sessions.get_mut(&session) else {
                    return refuse(404, "cloud.trajectory.not_found", Value::Null);
                };
                let key = (
                    body["label"].as_str().unwrap().to_owned(),
                    body["path"].as_str().unwrap().to_owned(),
                );
                assert!(native_path(&key.0, &key.1), "{key:?}");
                let offset = body["offset"].as_u64().unwrap() as usize;
                let data = decode_base64(body["data"].as_str().unwrap()).unwrap();
                let file = kept.native.entry(key).or_default();
                if offset != 0 && offset != file.len() {
                    return refuse(409, "cloud.trajectory.offset", json!({ "size": file.len() }));
                }
                file.truncate(offset);
                file.extend_from_slice(&data);
                ok(json!({ "size": file.len() }))
            }
            "read" => {
                let kept = &sessions[&session];
                let after = body["after_seq"].as_u64().unwrap() as usize;
                // Small pages, so a restore reads more than one.
                let lines: Vec<&String> = kept.lines.iter().skip(after).take(2).collect();
                ok(json!({
                    "generation": kept.generation,
                    "last_seq": kept.lines.len(),
                    "lines": lines,
                    "has_more": after + lines.len() < kept.lines.len(),
                }))
            }
            "native-read" => {
                let kept = &sessions[&session];
                let key = (
                    body["label"].as_str().unwrap().to_owned(),
                    body["path"].as_str().unwrap().to_owned(),
                );
                let file = &kept.native[&key];
                let offset = body["offset"].as_u64().unwrap() as usize;
                let end = file.len().min(offset + 5);
                ok(json!({ "size": file.len(), "data": encode_base64(&file[offset..end]) }))
            }
            other => panic!("unexpected action {other}"),
        }
    }
}

/// One machine: its acpmux home under a temp dir.
struct Machine {
    _dir: tempfile::TempDir,
    layout: Layout,
}

impl Machine {
    fn new() -> Machine {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let layout = Layout {
            sessions: home.join(".acpmux/sessions"),
            home: home.clone(),
            staging: dir.path().join("staging"),
        };
        fs::create_dir_all(&layout.sessions).unwrap();
        Machine { _dir: dir, layout }
    }

    fn session_dir(&self, id: &str) -> PathBuf {
        self.layout.sessions.join(id)
    }

    fn write_meta(&self, id: &str, last_seq: u64, created: u64) {
        let meta = meta(id, last_seq, created, &self.layout.home);
        fs::create_dir_all(self.session_dir(id).join("events")).unwrap();
        fs::write(self.session_dir(id).join("session.json"), serde_json::to_vec(&meta).unwrap())
            .unwrap();
    }

    /// Appends raw text to one log segment (acpmux's append).
    fn append(&self, id: &str, segment: u32, text: &str) {
        use std::io::Write;
        let path = self.session_dir(id).join("events").join(format!("{segment:06}.ndjson"));
        let mut f = fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        f.write_all(text.as_bytes()).unwrap();
    }

    fn claude_file(&self) -> PathBuf {
        self.layout.home.join(".claude/projects/-work").join(format!("{SID}.jsonl"))
    }

    fn mirror(&self) -> Mirror {
        Mirror::new(self.layout.clone(), |_| {})
    }
}

fn meta(id: &str, last_seq: u64, created: u64, home: &Path) -> Value {
    json!({
        "schema": "acpmux.session.v1",
        "id": id,
        "name": "fix-tests",
        "harness": "claude",
        "cwd": home.join("work"),
        "agentSessionId": SID,
        "status": "ready",
        "createdAt": created,
        "updatedAt": created,
        "lastSeq": last_seq,
    })
}

fn line(seq: u64) -> String {
    json!({ "seq": seq, "at": CREATED + seq, "dir": "in", "kind": "session/update", "msg": { "text": format!("turn {seq}") } }).to_string()
}

fn lines(from: u64, to: u64) -> String {
    (from..=to).map(|s| format!("{}\n", line(s))).collect()
}

fn kept_lines(server: &FakeServer, id: &str) -> Vec<String> {
    server.sessions()[id].lines.clone()
}

#[test]
fn sends_complete_records_verbatim_in_order_across_segments_and_only_once() {
    let m = Machine::new();
    m.write_meta("chat-a", 3, CREATED);
    m.append("chat-a", 1, &lines(1, 2));
    m.append("chat-a", 2, &lines(3, 3));
    // acpmux is writing record 4: half a line.
    m.append("chat-a", 2, &line(4)[..10]);
    let mut server = FakeServer::at("m1");
    let mut mirror = m.mirror();
    assert_eq!(mirror.prime(&mut server).unwrap(), 0);
    assert_eq!(mirror.sync(&mut server, 0), Pass::Idle);
    assert_eq!(kept_lines(&server, "chat-a"), (1..=3).map(line).collect::<Vec<_>>());
    assert_eq!(server.sessions()["chat-a"].meta["lastSeq"], 3);
    // Nothing new: no call.
    let calls = server.calls.len();
    assert_eq!(mirror.sync(&mut server, 1), Pass::Idle);
    assert_eq!(server.calls.len(), calls);
    // The line completes, one more follows.
    m.append("chat-a", 2, &format!("{}\n", &line(4)[10..]));
    m.append("chat-a", 2, &lines(5, 5));
    assert_eq!(mirror.sync(&mut server, 2), Pass::Idle);
    assert_eq!(kept_lines(&server, "chat-a"), (1..=5).map(line).collect::<Vec<_>>());
    let (_, last) = server.calls.last().unwrap();
    assert_eq!(last["lines"], json!([line(4), line(5)]));
}

#[test]
fn a_restarted_agent_continues_from_the_server_without_sending_again() {
    let m = Machine::new();
    m.write_meta("chat-a", 2, CREATED);
    m.append("chat-a", 1, &lines(1, 2));
    let mut server = FakeServer::at("m1");
    let mut first = m.mirror();
    first.prime(&mut server).unwrap();
    first.sync(&mut server, 0);
    m.append("chat-a", 1, &lines(3, 4));
    let mut second = m.mirror();
    second.prime(&mut server).unwrap();
    server.calls.clear();
    assert_eq!(second.sync(&mut server, 0), Pass::Idle);
    assert_eq!(server.calls.len(), 1);
    assert_eq!(server.calls[0].1["lines"], json!([line(3), line(4)]));
    assert_eq!(kept_lines(&server, "chat-a").len(), 4);
}

#[test]
fn a_server_that_lost_the_chat_gets_it_again_from_the_first_record() {
    let m = Machine::new();
    m.write_meta("chat-a", 3, CREATED);
    m.append("chat-a", 1, &lines(1, 3));
    let mut server = FakeServer::at("m1");
    let mut mirror = m.mirror();
    mirror.prime(&mut server).unwrap();
    mirror.sync(&mut server, 0);
    server.stores.clear();
    m.append("chat-a", 1, &lines(4, 4));
    // not_found: start over (with the record), then everything again.
    assert_eq!(mirror.sync(&mut server, 1), Pass::More);
    assert_eq!(mirror.sync(&mut server, 2), Pass::Idle);
    assert_eq!(kept_lines(&server, "chat-a"), (1..=4).map(line).collect::<Vec<_>>());
}

#[test]
fn a_recreated_session_replaces_the_copy_and_disabled_stops_the_pass() {
    let m = Machine::new();
    m.write_meta("chat-a", 2, CREATED);
    m.append("chat-a", 1, &lines(1, 2));
    let mut server = FakeServer::at("m1");
    let mut mirror = m.mirror();
    mirror.prime(&mut server).unwrap();
    mirror.sync(&mut server, 0);
    fs::remove_dir_all(m.session_dir("chat-a")).unwrap();
    m.write_meta("chat-a", 1, CREATED + 5);
    m.append("chat-a", 1, &lines(1, 1));
    assert_eq!(mirror.sync(&mut server, 1), Pass::Idle);
    assert_eq!(server.sessions()["chat-a"].generation, CREATED + 5);
    assert_eq!(kept_lines(&server, "chat-a"), vec![line(1)]);
    server.disabled = true;
    m.append("chat-a", 1, &lines(2, 2));
    assert_eq!(mirror.sync(&mut server, 2), Pass::Disabled);
    assert_eq!(mirror.prime(&mut server).unwrap_err(), Pass::Disabled);
}

#[test]
fn the_agents_resume_file_goes_as_whole_lines_and_again_from_zero_when_rewritten() {
    let m = Machine::new();
    m.write_meta("chat-a", 1, CREATED);
    m.append("chat-a", 1, &lines(1, 1));
    fs::create_dir_all(m.claude_file().parent().unwrap()).unwrap();
    fs::write(m.claude_file(), "{\"a\":1}\n{\"b\":").unwrap();
    let mut server = FakeServer::at("m1");
    let mut mirror = m.mirror();
    mirror.prime(&mut server).unwrap();
    mirror.sync(&mut server, 0);
    let key = ("claude-project".to_owned(), format!(".claude/projects/-work/{SID}.jsonl"));
    assert_eq!(server.sessions()["chat-a"].native[&key], b"{\"a\":1}\n");
    fs::write(m.claude_file(), "{\"a\":1}\n{\"b\":2}\n").unwrap();
    m.append("chat-a", 1, &lines(2, 2));
    mirror.sync(&mut server, 1);
    assert_eq!(server.sessions()["chat-a"].native[&key], b"{\"a\":1}\n{\"b\":2}\n");
    let (_, last) = server.calls.last().unwrap();
    assert_eq!(last["offset"], 8);
    // Compacted by the agent: smaller than kept, sent again from 0.
    fs::write(m.claude_file(), "{\"c\":3}\n").unwrap();
    m.append("chat-a", 1, &lines(3, 3));
    mirror.sync(&mut server, 2);
    assert_eq!(server.sessions()["chat-a"].native[&key], b"{\"c\":3}\n");
}

/// Imports a bundle the way acpmux `import_into` does: the record, the log
/// verbatim, the agent file into the home, then acpmux's own `imported`
/// record. `running` is whether acpmux runs; `fail` fails that many imports.
struct FakeAcpmux {
    layout: Layout,
    running: bool,
    fail: u32,
    imported: Vec<String>,
}

impl Importer for FakeAcpmux {
    fn ready(&self) -> bool {
        self.running
    }

    fn import(&mut self, bundle: &Path, meta: &Value) -> Result<(), String> {
        if self.fail > 0 {
            self.fail -= 1;
            return Err("acpmux refused".to_owned());
        }
        let id = meta["id"].as_str().unwrap();
        assert_eq!(bundle, self.layout.staging.join(id));
        let dir = self.layout.sessions.join(id);
        fs::create_dir_all(dir.join("events")).unwrap();
        fs::copy(bundle.join("session.json"), dir.join("session.json")).unwrap();
        let mut log = fs::read_to_string(bundle.join("events/000001.ndjson")).unwrap();
        let last = log.lines().filter_map(line_seq).max().unwrap();
        log.push_str(&format!("{}\n", line(last + 1)));
        fs::write(dir.join("events/000001.ndjson"), log).unwrap();
        let native = bundle
            .join("native/claude-project/.claude/projects/-work")
            .join(format!("{SID}.jsonl"));
        let target = self.layout.home.join(".claude/projects/-work").join(format!("{SID}.jsonl"));
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::copy(native, target).unwrap();
        self.imported.push(id.to_owned());
        Ok(())
    }
}

/// The first machine (`m1`) keeps a chat mid-way with its Claude resume
/// file, and a cmux-harness chat.
fn first_machine(server: &mut FakeServer) -> Machine {
    let first = Machine::new();
    first.write_meta("chat-a", 5, CREATED);
    first.append("chat-a", 1, &lines(1, 5));
    fs::create_dir_all(first.claude_file().parent().unwrap()).unwrap();
    fs::write(first.claude_file(), "{\"turn\":1}\n{\"turn\":2}\n").unwrap();
    first.write_meta("chat-h", 1, CREATED);
    let mut h = meta("chat-h", 1, CREATED, &first.layout.home);
    h["harness"] = json!("cmux-harness");
    fs::write(first.session_dir("chat-h").join("session.json"), h.to_string()).unwrap();
    first.append("chat-h", 1, &lines(1, 1));
    server.as_machine("m1", None);
    let mut mirror = first.mirror();
    mirror.prime(server).unwrap();
    assert_eq!(mirror.sync(server, 0), Pass::Idle);
    first
}

#[test]
fn a_replacement_machine_restores_the_chat_and_the_chat_continues() {
    let mut server = FakeServer::at("m1");
    let _first = first_machine(&mut server);
    // The replacement (`m2`, restored from m1): empty acpmux, plus a chat of its own.
    let second = Machine::new();
    second.write_meta("chat-own", 1, CREATED);
    second.append("chat-own", 1, &lines(1, 1));
    server.as_machine("m2", Some("m1"));
    let mut acpmux =
        FakeAcpmux { layout: second.layout.clone(), running: false, fail: 0, imported: vec![] };
    let mut replacement = second.mirror();
    // chat-a waits; the cmux-harness chat is not restored (its journal is not bundled).
    assert_eq!(replacement.prime(&mut server).unwrap(), 1);
    // acpmux is not running yet: nothing is imported, nothing is started.
    assert_eq!(replacement.restore(&mut server, &mut acpmux), 0);
    assert_eq!(replacement.pending(), 1);
    acpmux.running = true;
    assert_eq!(replacement.restore(&mut server, &mut acpmux), 1);
    assert_eq!(acpmux.imported, vec!["chat-a"]);
    assert!(!second.layout.staging.join("chat-a").exists(), "the stage is removed");
    assert_eq!(fs::read(second.claude_file()).unwrap(), b"{\"turn\":1}\n{\"turn\":2}\n");
    let restored =
        fs::read_to_string(second.session_dir("chat-a").join("events/000001.ndjson")).unwrap();
    assert!(restored.starts_with(&lines(1, 5)), "the history is intact, verbatim");

    // The chat continues on the replacement, into the replacement's own copy.
    second.append("chat-a", 1, &lines(7, 7));
    fs::write(second.claude_file(), "{\"turn\":1}\n{\"turn\":2}\n{\"turn\":3}\n").unwrap();
    assert_eq!(replacement.sync(&mut server, 10), Pass::Idle);
    assert_eq!(kept_lines(&server, "chat-a"), (1..=7).map(line).collect::<Vec<_>>());
    let key = ("claude-project".to_owned(), format!(".claude/projects/-work/{SID}.jsonl"));
    assert_eq!(
        server.sessions()["chat-a"].native[&key],
        b"{\"turn\":1}\n{\"turn\":2}\n{\"turn\":3}\n"
    );
    assert_eq!(kept_lines(&server, "chat-own"), vec![line(1)]);
    // The source's copy is untouched.
    assert_eq!(server.stores["m1"]["chat-a"].lines.len(), 5);
    // Once imported it is this machine's chat: deleted here, it is not brought back.
    fs::remove_dir_all(second.session_dir("chat-a")).unwrap();
    let mut restarted = second.mirror();
    assert_eq!(restarted.prime(&mut server).unwrap(), 0);
}

#[test]
fn a_failed_import_is_tried_again_and_a_chat_on_the_snapshot_disk_is_not_imported() {
    let mut server = FakeServer::at("m1");
    let _first = first_machine(&mut server);
    let second = Machine::new();
    server.as_machine("m2", Some("m1"));
    let mut acpmux =
        FakeAcpmux { layout: second.layout.clone(), running: true, fail: 1, imported: vec![] };
    let mut replacement = second.mirror();
    assert_eq!(replacement.prime(&mut server).unwrap(), 1);
    assert_eq!(replacement.restore(&mut server, &mut acpmux), 0);
    assert_eq!(replacement.pending(), 1);
    assert_eq!(replacement.restore(&mut server, &mut acpmux), 1);
    // A machine whose disk has the chat already (the snapshot's point) continues from there.
    let third = Machine::new();
    third.write_meta("chat-a", 3, CREATED);
    third.append("chat-a", 1, &lines(1, 3));
    server.as_machine("m3", Some("m1"));
    let mut mirror = third.mirror();
    assert_eq!(mirror.prime(&mut server).unwrap(), 0);
    assert_eq!(mirror.sync(&mut server, 0), Pass::Idle);
    assert_eq!(kept_lines(&server, "chat-a"), (1..=3).map(line).collect::<Vec<_>>());
}

#[test]
fn a_record_too_large_stops_only_its_own_chat() {
    let m = Machine::new();
    m.write_meta("chat-a", 1, CREATED);
    m.append("chat-a", 1, &format!("{}\n", json!({ "seq": 1, "msg": "x".repeat(RECORD_MAX) })));
    m.write_meta("chat-b", 1, CREATED);
    m.append("chat-b", 1, &lines(1, 1));
    let mut server = FakeServer::at("m1");
    let mut mirror = m.mirror();
    mirror.prime(&mut server).unwrap();
    assert_eq!(mirror.sync(&mut server, 0), Pass::Idle);
    assert!(!server.sessions().contains_key("chat-a"));
    assert_eq!(kept_lines(&server, "chat-b"), vec![line(1)]);
}

#[test]
fn a_resume_file_larger_than_one_pass_is_sent_over_passes_without_new_records() {
    let m = Machine::new();
    m.write_meta("chat-a", 1, CREATED);
    m.append("chat-a", 1, &lines(1, 1));
    fs::create_dir_all(m.claude_file().parent().unwrap()).unwrap();
    let row = format!("{}\n", "y".repeat(1023));
    let big = row.repeat(9 * 1024); // 9 MiB of whole lines, over one pass's 4 MiB
    fs::write(m.claude_file(), &big).unwrap();
    let mut server = FakeServer::at("m1");
    let mut mirror = m.mirror();
    mirror.prime(&mut server).unwrap();
    let mut passes = 0;
    while mirror.sync(&mut server, passes) == Pass::More {
        passes += 1;
        assert!(passes < 10);
    }
    let key = ("claude-project".to_owned(), format!(".claude/projects/-work/{SID}.jsonl"));
    assert_eq!(server.sessions()["chat-a"].native[&key].len(), big.len());
    // Written later, with no new record: sent at the next pass.
    fs::write(m.claude_file(), format!("{big}{row}")).unwrap();
    assert_eq!(mirror.sync(&mut server, 100), Pass::Idle);
    assert_eq!(server.sessions()["chat-a"].native[&key].len(), big.len() + row.len());
}

#[test]
fn a_resume_file_line_longer_than_one_pass_is_sent_in_parts() {
    let m = Machine::new();
    m.write_meta("chat-a", 1, CREATED);
    m.append("chat-a", 1, &lines(1, 1));
    fs::create_dir_all(m.claude_file().parent().unwrap()).unwrap();
    // One 5 MiB line (a pasted image), over one pass's 4 MiB, then a short one.
    let long = format!("{}\n{{\"b\":2}}\n", "z".repeat(5 * 1024 * 1024));
    fs::write(m.claude_file(), &long).unwrap();
    let mut server = FakeServer::at("m1");
    let mut mirror = m.mirror();
    mirror.prime(&mut server).unwrap();
    let mut passes = 0;
    while mirror.sync(&mut server, passes) == Pass::More {
        passes += 1;
        assert!(passes < 10);
    }
    let key = ("claude-project".to_owned(), format!(".claude/projects/-work/{SID}.jsonl"));
    assert_eq!(server.sessions()["chat-a"].native[&key], long.as_bytes());
}

#[test]
fn a_restore_keeps_only_whole_lines_of_a_resume_file_cut_mid_line() {
    let mut server = FakeServer::at("m1");
    let _first = first_machine(&mut server);
    // The machine was lost between two parts of a long line.
    let key = ("claude-project".to_owned(), format!(".claude/projects/-work/{SID}.jsonl"));
    server
        .stores
        .get_mut("m1")
        .unwrap()
        .get_mut("chat-a")
        .unwrap()
        .native
        .get_mut(&key)
        .unwrap()
        .extend_from_slice(b"{\"turn\":3,");
    let second = Machine::new();
    server.as_machine("m2", Some("m1"));
    let mut acpmux =
        FakeAcpmux { layout: second.layout.clone(), running: true, fail: 0, imported: vec![] };
    let mut replacement = second.mirror();
    assert_eq!(replacement.prime(&mut server).unwrap(), 1);
    assert_eq!(replacement.restore(&mut server, &mut acpmux), 1);
    assert_eq!(fs::read(second.claude_file()).unwrap(), b"{\"turn\":1}\n{\"turn\":2}\n");
}

#[test]
fn base64_round_trips_every_length() {
    for n in 0..70_u8 {
        let data: Vec<u8> = (0..n).map(|i| i.wrapping_mul(37)).collect();
        assert_eq!(decode_base64(&encode_base64(&data)).unwrap(), data);
    }
    assert_eq!(encode_base64(b"{\"a\":1}\n"), "eyJhIjoxfQo=");
    assert!(decode_base64("not base64!").is_none());
}

#[test]
fn only_the_agents_own_files_are_paths() {
    assert!(native_path("claude-project", ".claude/projects/-w/x.jsonl"));
    assert!(native_path("codex-rollout", ".codex/sessions/2026/10/26/rollout-1-x.jsonl"));
    assert!(!native_path("claude-project", ".claude/projects/../../.ssh/x.jsonl"));
    assert!(!native_path("claude-project", ".codex/sessions/x.jsonl"));
    assert!(!native_path("other", ".claude/projects/-w/x.jsonl"));
}
