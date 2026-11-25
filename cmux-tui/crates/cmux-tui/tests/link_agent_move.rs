//! `cmux link agent move`: the pump that moves an agent chat from this
//! Mac's daemon to a Cloud machine's daemon over `agent-transfer-v1`
//! (Move to Cloud, cmuxterm-hq#1874 slice 1c). The two daemons are fakes
//! that answer the spec's `agent-transfer-*` lines ("Agent chat transfer")
//! with the state the real daemons and their acpmux keep: the source
//! freezes the chat at begin and unfreezes it only on abort, and the target
//! lands the chat at finish and answers `landed` to a receive-abort, also
//! for a receive its finish already ended.
#![cfg(unix)]

use std::collections::{HashMap, HashSet};
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};

const SURFACE: u64 = 7;
const SESSION: &str = "acp_chat_1";

/// What a fake daemon does with one request line.
enum Reply {
    Data(Value),
    Error(&'static str, String),
    /// A refusal with `error_details`.
    Detailed(&'static str, String, Value),
    /// The connection closes without an answer (a lost answer).
    Drop,
}

/// Every call either fake took, in order, as `source:<cmd>` or
/// `target:<cmd>`.
type Log = Arc<Mutex<Vec<String>>>;

/// Serves request lines on `socket` with `handle` until the test ends; while
/// `down` is set every connection closes at once (a machine nobody reaches).
fn serve<H>(socket: &Path, side: &'static str, log: Log, down: Arc<AtomicBool>, handle: H)
where
    H: Fn(&Value) -> Reply + Send + Sync + 'static,
{
    let listener = UnixListener::bind(socket).unwrap();
    let handle = Arc::new(handle);
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            if down.load(Ordering::SeqCst) {
                continue;
            }
            let (handle, log, down) = (handle.clone(), log.clone(), down.clone());
            std::thread::spawn(move || serve_connection(connection, side, &log, &down, &*handle));
        }
    });
}

fn serve_connection(
    connection: UnixStream,
    side: &str,
    log: &Log,
    down: &AtomicBool,
    handle: &dyn Fn(&Value) -> Reply,
) {
    let mut writer = connection.try_clone().unwrap();
    for line in BufReader::new(connection).lines() {
        let Ok(line) = line else { return };
        if down.load(Ordering::SeqCst) {
            return;
        }
        let request: Value = serde_json::from_str(&line).unwrap();
        let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
        log.lock().unwrap().push(format!("{side}:{cmd}"));
        let answer = match handle(&request) {
            Reply::Data(data) => json!({"id": request["id"], "ok": true, "data": data}),
            Reply::Error(code, error) => {
                json!({"id": request["id"], "ok": false, "error": error, "error_code": code})
            }
            Reply::Detailed(code, error, details) => json!({"id": request["id"], "ok": false,
                "error": error, "error_code": code, "error_details": details}),
            Reply::Drop => return,
        };
        if writeln!(writer, "{answer}").is_err() {
            return;
        }
    }
}

fn refused(message: &str) -> Reply {
    Reply::Error("agent_transfer.refused", format!("acpmux refused the request: {message}"))
}

// MARK: The source daemon

/// The Mac daemon whose agent tab [`SURFACE`] holds chat [`SESSION`].
#[derive(Default)]
struct Source {
    files: Vec<(String, Vec<u8>)>,
    moving: Option<String>,
    begun: u32,
    committed: Option<String>,
    aborted: Vec<String>,
    /// The next begin freezes the chat and its answer is lost.
    lose_begin_answer: bool,
    /// The tab now shows another chat (its session id), not [`SESSION`].
    rebound: Option<String>,
    /// `agent-session-attach` calls (each marks the chat seen).
    attached: usize,
    /// Serves `agent-transfer-continues-v1` (else an older daemon).
    continues: bool,
    /// The `interrupt` of each begin, in order.
    interrupts: Vec<Value>,
    /// Serves `agent-transfer-begin-token-v1`: keeps a begin's `begin_token` with its move and
    /// hands it back in a `transfer.moving` refusal (else an older daemon).
    keeps_token: bool,
    /// The token the move in `moving` was begun with.
    moving_token: Option<String>,
    /// Serves `agent-transfer-history-later-v1` and its acpmux can.
    later: bool,
    /// Tail first: the staged last turns, and the history that follows.
    prefix: Vec<(String, Vec<u8>)>,
    history: Vec<(String, Vec<u8>)>,
    /// The begin took the staged prefix (its bundle lacks the prefix's events).
    began_staged: bool,
    /// Every `prepare_id` a begin named, in order.
    begin_prepares: Vec<Value>,
}

impl Source {
    fn handle(&mut self, request: &Value) -> Reply {
        let cmd = request["cmd"].as_str().unwrap_or_default();
        if request.get("surface").is_some() && request["surface"] != json!(SURFACE) {
            return Reply::Error("agent_transfer.unknown_tab", "not an agent tab".into());
        }
        let transfer = request["transfer_id"].as_str().map(str::to_string);
        if cmd == "agent-session-attach" {
            // Attaching marks the chat seen and logs it: a pump must not.
            self.attached += 1;
        }
        if self.rebound.is_some() && cmd != "agent-transfer-source" {
            // The tab's chat is another one, in no move.
            return match cmd {
                "agent-transfer-commit" | "agent-transfer-abort" => {
                    refused("transfer.unknown: the chat is not in this move")
                }
                _ => Reply::Error("agent_transfer.bad_request", format!("unexpected {cmd}")),
            };
        }
        match cmd {
            "identify" => {
                let mut capabilities = vec!["agent-transfer-v1"];
                if self.later {
                    capabilities.push("agent-transfer-history-later-v1");
                }
                if self.continues {
                    capabilities.push("agent-transfer-continues-v1");
                }
                if self.keeps_token {
                    capabilities.push("agent-transfer-begin-token-v1");
                }
                Reply::Data(json!({"capabilities": capabilities}))
            }
            "agent-transfer-history-ready" => Reply::Data(json!({"history_later": self.later})),
            "agent-transfer-prepare" => {
                assert!(self.moving.is_none(), "a prepare runs before the freeze");
                Reply::Data(json!({"prepare_id": "pre_1", "after_seq": 7, "history_later": true,
                                   "manifest": prefix_manifest("pre_1", &self.prefix)}))
            }
            "agent-transfer-history-export" => {
                assert_eq!(self.committed, transfer, "the history follows the commit");
                assert_eq!(request["have"], json!(0));
                Reply::Data(json!({"prepare_id": "pre_h", "through_seq": 7,
                                   "manifest": prefix_manifest("pre_h", &self.history)}))
            }
            "agent-transfer-source" => {
                let session = self.rebound.clone().unwrap_or_else(|| SESSION.to_string());
                Reply::Data(json!({"session": session}))
            }
            "agent-transfer-begin" => {
                self.interrupts.push(request["interrupt"].clone());
                self.begin_prepares.push(request["prepare_id"].clone());
                self.began_staged = request["prepare_id"] == json!("pre_1");
                if self.committed.is_some() {
                    return Reply::Error("agent_transfer.unknown_tab", "closed".into());
                }
                if let Some(moving) = &self.moving {
                    let mut details = json!({"transfer_id": moving});
                    if let Some(token) = &self.moving_token {
                        details["begin_token"] = json!(token);
                    }
                    return Reply::Detailed(
                        "agent_transfer.refused",
                        "acpmux refused the request: transfer.moving: this chat is already \
                         being moved"
                            .into(),
                        details,
                    );
                }
                self.begun += 1;
                let id = format!("xfer_{}", self.begun);
                self.moving = Some(id.clone());
                self.moving_token = if self.keeps_token {
                    request["begin_token"].as_str().map(str::to_string)
                } else {
                    None
                };
                if std::mem::take(&mut self.lose_begin_answer) {
                    return Reply::Drop;
                }
                let files: Vec<Value> = self
                    .bundle_files()
                    .iter()
                    .map(|(path, bytes)| json!({"path": path, "size": bytes.len()}))
                    .collect();
                let mut answer = json!({"transfer_id": id, "source_session": SESSION, "manifest": {
                    "schema": "acpmux.transfer.v1", "transferId": id, "sessionId": SESSION,
                    "files": files, "session": {"sessionId": SESSION, "harness": "claude"}}});
                if self.began_staged {
                    answer["staged"] = json!(true);
                    answer["history_later"] = json!(true);
                }
                Reply::Data(answer)
            }
            "agent-transfer-read" => {
                let files = match transfer.as_deref() {
                    Some("pre_1") if self.later => self.prefix.clone(),
                    Some("pre_h") if self.later => self.history.clone(),
                    _ if transfer == self.moving => self.bundle_files(),
                    _ => {
                        return Reply::Error("agent_transfer.unknown_transfer", "no move".into());
                    }
                };
                let path = request["path"].as_str().unwrap_or_default();
                let Some((_, bytes)) = files.iter().find(|(p, _)| p == path) else {
                    return Reply::Error("agent_transfer.bad_request", "not listed".into());
                };
                let offset = request["offset"].as_u64().unwrap() as usize;
                let limit = request["limit"].as_u64().unwrap_or(1 << 20) as usize;
                assert!((1..=4 << 20).contains(&limit), "limit {limit}");
                let start = offset.min(bytes.len());
                let end = (start + limit).min(bytes.len());
                Reply::Data(json!({"data": BASE64.encode(&bytes[start..end]), "next": end,
                                   "eof": end == bytes.len()}))
            }
            "agent-transfer-commit" if transfer.is_some() && transfer == self.moving => {
                self.moving_token = None;
                self.committed = self.moving.take();
                Reply::Data(json!({"committed": true}))
            }
            "agent-transfer-abort" if transfer.is_some() && transfer == self.moving => {
                self.moving_token = None;
                self.aborted.extend(self.moving.take());
                Reply::Data(json!({"aborted": true}))
            }
            "agent-transfer-commit" | "agent-transfer-abort" => {
                refused("transfer.unknown: the chat is not in this move")
            }
            _ => Reply::Error("agent_transfer.bad_request", format!("unexpected {cmd}")),
        }
    }
}

impl Source {
    /// The bundle a begin lists: without the staged prefix's events when it took it.
    fn bundle_files(&self) -> Vec<(String, Vec<u8>)> {
        let staged = |path: &str| self.began_staged && path.starts_with("events/");
        self.files.iter().filter(|(path, _)| !staged(path)).cloned().collect()
    }
}

/// A prepare's or export's manifest of `files`.
fn prefix_manifest(prepare_id: &str, files: &[(String, Vec<u8>)]) -> Value {
    let files: Vec<Value> =
        files.iter().map(|(path, bytes)| json!({"path": path, "size": bytes.len()})).collect();
    json!({"schema": "acpmux.transfer.prefix.v1", "prepareId": prepare_id,
           "sessionId": SESSION, "files": files})
}

// MARK: The target daemon

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum Finish {
    #[default]
    Answer,
    /// The chat lands, and the answer is lost.
    LandThenDrop,
    /// The answer is lost before the chat lands.
    DropWithoutLanding,
    /// The chat lands, then the machine goes away before answering.
    LandThenGoDown,
    /// The machine goes away before the chat lands.
    GoDown,
    /// The answer is lost while the finish still runs: the next receive-aborts answer "cannot
    /// say yet" (the real daemon's answer during a finish), then the chat lands.
    DropStillFinishing,
    /// The machine's processes are killed before the chat lands: the daemon is back at once,
    /// its acpmux a moment later, so the next receive-aborts answer `agent_transfer.unavailable`.
    KilledRestarting,
}

struct Receive {
    transfer_id: String,
    session_id: String,
    sizes: HashMap<String, usize>,
    files: HashMap<String, Vec<u8>>,
    finished: bool,
}

/// The Cloud machine's daemon.
#[derive(Default)]
struct Target {
    team_vm: bool,
    fail_write_at: Option<usize>,
    writes: usize,
    finish: Finish,
    receives: HashMap<String, Receive>,
    made: u32,
    /// Landed chats: session id to the move that brought it.
    landed: HashMap<String, String>,
    forgotten: HashSet<String>,
    received_cwd: Option<String>,
    /// Serves `agent-transfer-vm-kind-v1` (else an older daemon).
    takes_vm_kind: bool,
    /// The `vm_kind` of each receive and finish, in order.
    vm_kinds: Vec<Value>,
    /// Receive-aborts still answered "cannot say yet" before the running finish lands the chat.
    finishing_asks: u32,
    /// Receive-aborts still answered `agent_transfer.unavailable` while acpmux restarts.
    restarting_asks: u32,
    /// Serves `agent-transfer-history-later-v1` and its acpmux can.
    later: bool,
    /// The stage each receive took, in order.
    receive_stages: Vec<Value>,
    /// The chat's log here: staged prefixes, then the history installed after.
    log: Vec<u8>,
    /// Stages finished, by id.
    staged_done: HashSet<String>,
}

impl Target {
    fn handle(&mut self, request: &Value, down: &AtomicBool) -> Reply {
        let cmd = request["cmd"].as_str().unwrap_or_default();
        let receive_id = request["receive_id"].as_str().unwrap_or_default().to_string();
        if cmd == "agent-transfer-receive" || cmd == "agent-transfer-finish" {
            self.vm_kinds.push(request["vm_kind"].clone());
        }
        match cmd {
            "identify" if self.later => Reply::Data(json!({"capabilities":
                ["agent-transfer-v1", "agent-transfer-history-later-v1"]})),
            "agent-transfer-history-ready" => Reply::Data(json!({"history_later": self.later})),
            "agent-transfer-stage" => {
                self.made += 1;
                let id = format!("stg_{}", self.made);
                let manifest = &request["manifest"];
                let sizes = manifest["files"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|f| {
                        (
                            f["path"].as_str().unwrap().to_string(),
                            f["size"].as_u64().unwrap() as usize,
                        )
                    })
                    .collect();
                let stage = Receive {
                    transfer_id: manifest["prepareId"].as_str().unwrap().to_string(),
                    session_id: SESSION.into(),
                    sizes,
                    files: HashMap::new(),
                    finished: false,
                };
                self.receives.insert(id.clone(), stage);
                Reply::Data(json!({"stage_id": id}))
            }
            "agent-transfer-stage-finish" => {
                let stage_id = request["stage_id"].as_str().unwrap().to_string();
                let stage = self.receives.get_mut(&stage_id).unwrap();
                assert!(
                    stage.sizes.iter().all(|(p, n)| stage.files.get(p).map_or(0, Vec::len) == *n)
                );
                stage.finished = true;
                if stage.transfer_id == "pre_1" {
                    let mut paths: Vec<_> = stage.files.keys().cloned().collect();
                    paths.sort();
                    for path in paths {
                        self.log.extend_from_slice(&stage.files[&path]);
                    }
                }
                self.staged_done.insert(stage_id);
                Reply::Data(json!({"after_seq": 7, "records": 2}))
            }
            "agent-transfer-history-have" => {
                assert!(self.landed.contains_key(SESSION), "asked after the chat landed");
                Reply::Data(json!({"have": 0}))
            }
            "agent-transfer-history" => {
                let stage_id = request["stage_id"].as_str().unwrap();
                assert!(self.staged_done.contains(stage_id), "installed after its stage-finish");
                let stage = &self.receives[stage_id];
                let mut history = Vec::new();
                let mut paths: Vec<_> = stage.files.keys().cloned().collect();
                paths.sort();
                for path in paths {
                    history.extend_from_slice(&stage.files[&path]);
                }
                // The history goes before the tail.
                history.extend_from_slice(&self.log);
                self.log = history;
                Reply::Data(json!({"through_seq": 7, "records": 5}))
            }
            "identify" if self.takes_vm_kind => Reply::Data(json!({"capabilities":
                ["agent-transfer-v1", "agent-transfer-vm-kind-v1"]})),
            // An older daemon; it shows no sign of being a Cloud VM (a guest can hide any).
            "identify" => Reply::Data(json!({"capabilities": ["agent-transfer-v1"]})),
            "agent-transfer-receive" => self.receive(request),
            "agent-transfer-write" => self.write(&receive_id, request),
            "agent-transfer-finish" => self.finish(&receive_id, down),
            "agent-transfer-receive-abort" => {
                let Some(receive) = self.receives.get(&receive_id) else {
                    return Reply::Error("agent_transfer.unknown_receive", "no receive".into());
                };
                let (transfer, session) = (receive.transfer_id.clone(), receive.session_id.clone());
                if self.restarting_asks > 0 {
                    self.restarting_asks -= 1;
                    return Reply::Error(
                        "agent_transfer.unavailable",
                        "this daemon has no acpmux or host to move chats with".into(),
                    );
                }
                if self.finishing_asks > 0 {
                    self.finishing_asks -= 1;
                    if self.finishing_asks == 0 {
                        self.receives.get_mut(&receive_id).unwrap().finished = true;
                        self.landed.insert(session, transfer);
                    }
                    return Reply::Data(
                        json!({"dropped": false, "forgotten": false, "landed": null}),
                    );
                }
                if !receive.finished {
                    self.receives.remove(&receive_id);
                }
                self.forgotten.insert(transfer.clone());
                let landed = self.landed.get(&session) == Some(&transfer);
                Reply::Data(json!({"dropped": true, "forgotten": true, "landed": landed}))
            }
            _ => Reply::Error("agent_transfer.bad_request", format!("unexpected {cmd}")),
        }
    }

    fn receive(&mut self, request: &Value) -> Reply {
        if self.team_vm {
            return Reply::Error(
                "agent_session.team_vm_blocked",
                "agent chats cannot be moved onto a team VM".into(),
            );
        }
        self.receive_stages.push(request["stage_id"].clone());
        let manifest = &request["manifest"];
        let transfer_id = manifest["transferId"].as_str().unwrap().to_string();
        let session_id = manifest["sessionId"].as_str().unwrap().to_string();
        if self.forgotten.contains(&transfer_id) {
            return refused("transfer.forgotten");
        }
        if self.landed.contains_key(&session_id) {
            return refused("transfer.exists");
        }
        let sizes = manifest["files"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| {
                (f["path"].as_str().unwrap().to_string(), f["size"].as_u64().unwrap() as usize)
            })
            .collect();
        self.made += 1;
        let id = format!("rcv_{}", self.made);
        self.received_cwd = request["cwd"].as_str().map(str::to_string);
        let receive = Receive {
            transfer_id,
            session_id: session_id.clone(),
            sizes,
            files: HashMap::new(),
            finished: false,
        };
        self.receives.insert(id.clone(), receive);
        Reply::Data(json!({"receive_id": id, "session_id": session_id}))
    }

    fn write(&mut self, receive_id: &str, request: &Value) -> Reply {
        let Some(receive) = self.receives.get_mut(receive_id).filter(|r| !r.finished) else {
            return Reply::Error("agent_transfer.unknown_receive", "no receive".into());
        };
        self.writes += 1;
        if self.fail_write_at == Some(self.writes) {
            return refused("transfer.write: disk full");
        }
        let path = request["path"].as_str().unwrap().to_string();
        let data = BASE64.decode(request["data"].as_str().unwrap()).unwrap();
        let file = receive.files.entry(path.clone()).or_default();
        if request["offset"].as_u64() != Some(file.len() as u64) {
            return refused("transfer.offset");
        }
        file.extend_from_slice(&data);
        assert!(file.len() <= receive.sizes[&path], "{path} grew past its size");
        Reply::Data(json!({"next": file.len()}))
    }

    fn finish(&mut self, receive_id: &str, down: &AtomicBool) -> Reply {
        let Some(receive) = self.receives.get_mut(receive_id).filter(|r| !r.finished) else {
            return Reply::Error("agent_transfer.unknown_receive", "no receive".into());
        };
        let complete = receive
            .sizes
            .iter()
            .all(|(path, size)| receive.files.get(path).map_or(0, Vec::len) == *size);
        if !complete {
            return refused("transfer.incomplete");
        }
        match self.finish {
            Finish::DropWithoutLanding => return Reply::Drop,
            Finish::GoDown => {
                down.store(true, Ordering::SeqCst);
                return Reply::Drop;
            }
            Finish::DropStillFinishing => {
                self.finishing_asks = 3;
                return Reply::Drop;
            }
            Finish::KilledRestarting => {
                self.restarting_asks = 3;
                return Reply::Drop;
            }
            _ => {}
        }
        receive.finished = true;
        self.landed.insert(receive.session_id.clone(), receive.transfer_id.clone());
        match self.finish {
            Finish::Answer => Reply::Data(json!({"session": {"sessionId": receive.session_id}})),
            Finish::LandThenGoDown => {
                down.store(true, Ordering::SeqCst);
                Reply::Drop
            }
            _ => Reply::Drop,
        }
    }

    /// The bytes the landed chat's move brought.
    fn landed_files(&self) -> HashMap<String, Vec<u8>> {
        let transfer = &self.landed[SESSION];
        let receive = self.receives.values().find(|r| &r.transfer_id == transfer).unwrap();
        receive.files.clone()
    }
}

// MARK: The harness

struct World {
    _dir: tempfile::TempDir,
    from: PathBuf,
    to: PathBuf,
    cwd: String,
    state: PathBuf,
    source: Arc<Mutex<Source>>,
    target: Arc<Mutex<Target>>,
    target_down: Arc<AtomicBool>,
    log: Log,
}

/// A chat bundle with a file larger than one page and an empty one.
fn bundle() -> Vec<(String, Vec<u8>)> {
    let events: Vec<u8> = (0..(2 << 20) + 12345u32).map(|i| (i * 31 % 251) as u8).collect();
    vec![
        ("events/000001.ndjson".into(), events),
        ("manifest.json".into(), br#"{"schema":"acpmux.bundle.v1"}"#.to_vec()),
        ("native/claude/empty.jsonl".into(), Vec::new()),
        ("session.json".into(), br#"{"id":"acp_chat_1","cwd":"/Users/me/app"}"#.to_vec()),
    ]
}

impl World {
    fn new(target: Target) -> Self {
        // A socket path must stay under SUN_LEN; the temp folder can be deep.
        let dir = tempfile::Builder::new().prefix("cam").tempdir_in("/tmp").unwrap();
        let from = dir.path().join("mac.sock");
        let to = dir.path().join("vm.sock");
        let log: Log = Arc::default();
        let source = Arc::new(Mutex::new(Source { files: bundle(), ..Source::default() }));
        let target = Arc::new(Mutex::new(target));
        let source_down = Arc::new(AtomicBool::new(false));
        let target_down = Arc::new(AtomicBool::new(false));
        let handled = source.clone();
        serve(&from, "source", log.clone(), source_down, move |request| {
            handled.lock().unwrap().handle(request)
        });
        let handled = target.clone();
        let down = target_down.clone();
        serve(&to, "target", log.clone(), target_down.clone(), move |request| {
            handled.lock().unwrap().handle(request, &down)
        });
        let state = dir.path().join("state");
        Self {
            from,
            to,
            cwd: "/home/cmux/work/app".into(),
            state,
            source,
            target,
            target_down,
            log,
            _dir: dir,
        }
    }

    /// Runs the move; its exit code and its one JSON line.
    fn run_move(&self) -> (i32, Value) {
        self.run_move_with(&[])
    }

    /// `run_move` with `extra` flags.
    fn run_move_with(&self, extra: &[&str]) -> (i32, Value) {
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&self.from)
            .args(["--surface", &SURFACE.to_string(), "--to-socket"])
            .arg(&self.to)
            .args(["--cwd", &self.cwd, "--state-dir"])
            .arg(&self.state)
            .args(extra)
            // Tail first only when a test asks for it.
            .env_remove("ACPMUX_MOVE_HISTORY_LATER")
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(
            lines.len(),
            1,
            "one JSON line on stdout: {stdout}{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(self.source.lock().unwrap().attached, 0, "the pump never attaches the chat");
        (output.status.code().unwrap(), serde_json::from_str(lines[0]).unwrap())
    }

    fn calls(&self) -> Vec<String> {
        self.log.lock().unwrap().clone()
    }

    fn count(&self, call: &str) -> usize {
        self.calls().iter().filter(|c| *c == call).count()
    }

    /// The position of the first `call` in the log.
    fn first(&self, call: &str) -> usize {
        self.calls().iter().position(|c| c == call).unwrap_or_else(|| panic!("no {call}"))
    }
}

fn total_bytes() -> u64 {
    bundle().iter().map(|(_, bytes)| bytes.len() as u64).sum()
}

// MARK: Behavior

/// Named so one test filter (`agent_move`) runs exactly these.
mod agent_move {
    use super::*;

    #[test]
    fn usage_and_help() {
        let bin = env!("CARGO_BIN_EXE_cmux-tui");
        let help = Command::new(bin).args(["link", "agent", "move", "--help"]).output().unwrap();
        assert_eq!(help.status.code(), Some(0));
        assert!(String::from_utf8_lossy(&help.stdout).contains("--to-socket"));
        let bad =
            Command::new(bin).args(["link", "agent", "move", "--surface", "7"]).output().unwrap();
        assert_eq!(bad.status.code(), Some(64));
    }

    #[test]
    fn a_chat_moves_whole_and_the_source_commits() {
        let world = World::new(Target::default());
        let (code, answer) = world.run_move();
        assert_eq!(code, 0, "{answer}");
        assert_eq!(answer["ok"], json!(true));
        assert_eq!(answer["session_id"], json!(SESSION));
        assert_eq!(answer["transfer_id"], json!("xfer_1"));
        assert_eq!(answer["bytes"], json!(total_bytes()));
        let target = world.target.lock().unwrap();
        assert_eq!(target.received_cwd.as_deref(), Some(world.cwd.as_str()));
        let landed = target.landed_files();
        for (path, bytes) in bundle().into_iter().filter(|(_, bytes)| !bytes.is_empty()) {
            assert_eq!(landed.get(&path), Some(&bytes), "{path}");
        }
        let source = world.source.lock().unwrap();
        assert_eq!(source.committed.as_deref(), Some("xfer_1"));
        assert!(source.aborted.is_empty());
        assert!(
            world.first("target:agent-transfer-finish")
                < world.first("source:agent-transfer-commit")
        );
        assert_eq!(world.count("target:agent-transfer-receive-abort"), 0);
    }

    #[test]
    fn a_running_turn_is_stopped_only_on_a_source_that_continues_it() {
        // An older source would stop the turn for good: the begin asks for no Stop there.
        let older = World::new(Target::default());
        let (code, answer) = older.run_move_with(&["--interrupt"]);
        assert_eq!(code, 0, "{answer}");
        assert_eq!(older.source.lock().unwrap().interrupts, [json!(false)]);
        // One whose acpmux continues the turn where the chat lands gets the Stop.
        let current = World::new(Target::default());
        current.source.lock().unwrap().continues = true;
        let (code, answer) = current.run_move_with(&["--interrupt"]);
        assert_eq!(code, 0, "{answer}");
        assert_eq!(current.source.lock().unwrap().interrupts, [json!(true)]);
        // Without `--interrupt`, never.
        let plain = World::new(Target::default());
        plain.source.lock().unwrap().continues = true;
        let (code, answer) = plain.run_move();
        assert_eq!(code, 0, "{answer}");
        assert_eq!(plain.source.lock().unwrap().interrupts, [json!(false)]);
    }

    #[test]
    fn a_failure_mid_pump_drops_the_receive_then_gives_the_chat_back() {
        let world = World::new(Target { fail_write_at: Some(2), ..Target::default() });
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["ok"], json!(false));
        assert_eq!(answer["error_code"], json!("agent_transfer.refused"), "{answer}");
        assert_eq!(world.count("target:agent-transfer-finish"), 0);
        assert!(
            world.first("target:agent-transfer-receive-abort")
                < world.first("source:agent-transfer-abort")
        );
        let target = world.target.lock().unwrap();
        assert!(target.forgotten.contains("xfer_1"));
        assert!(target.landed.is_empty());
        let source = world.source.lock().unwrap();
        assert_eq!(source.aborted, ["xfer_1"]);
        assert!(source.moving.is_none() && source.committed.is_none());
    }

    #[test]
    fn a_lost_finish_answer_for_a_chat_that_landed_commits_the_source() {
        let world = World::new(Target { finish: Finish::LandThenDrop, ..Target::default() });
        let (code, answer) = world.run_move();
        assert_eq!(code, 0, "{answer}");
        assert_eq!(answer["session_id"], json!(SESSION));
        assert!(
            world.first("target:agent-transfer-receive-abort")
                < world.first("source:agent-transfer-commit")
        );
        let source = world.source.lock().unwrap();
        assert_eq!(source.committed.as_deref(), Some("xfer_1"));
        assert!(source.aborted.is_empty());
    }

    #[test]
    fn a_lost_finish_answer_while_the_finish_still_runs_waits_for_it_then_commits() {
        // kill-mid-move drill `mid-copy:cut`: the cut lost only the finish answer, and the
        // target said "cannot say yet" until its finish ended; the pump gave up at once and the
        // chat stayed open there and frozen here.
        let world = World::new(Target { finish: Finish::DropStillFinishing, ..Target::default() });
        let (code, answer) = world.run_move();
        assert_eq!(code, 0, "{answer}");
        assert_eq!(answer["session_id"], json!(SESSION));
        assert_eq!(world.count("target:agent-transfer-receive-abort"), 4);
        let source = world.source.lock().unwrap();
        assert_eq!(source.committed.as_deref(), Some("xfer_1"));
        assert!(source.aborted.is_empty());
    }

    #[test]
    fn a_target_killed_before_the_finish_is_waited_for_then_the_chat_is_given_back() {
        // kill-mid-move drill `local-cloud before-finish kill-dst` (run 45389153532): the
        // target's daemon came back at once but its acpmux did not, the receive-abort was
        // answered `agent_transfer.unavailable` and the pump (and its rerun 264 ms later)
        // said "cannot say": the chat stayed frozen here and its queued prompt never ran.
        let world = World::new(Target { finish: Finish::KilledRestarting, ..Target::default() });
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["error_code"], json!("move_failed"), "{answer}");
        assert_eq!(world.count("target:agent-transfer-receive-abort"), 4);
        assert!(world.target.lock().unwrap().forgotten.contains("xfer_1"));
        let source = world.source.lock().unwrap();
        assert_eq!(source.aborted, ["xfer_1"], "the chat is given back here");
        assert!(source.moving.is_none() && source.committed.is_none());
    }

    #[test]
    fn a_lost_finish_answer_for_a_chat_that_did_not_land_aborts_the_source() {
        let world = World::new(Target { finish: Finish::DropWithoutLanding, ..Target::default() });
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["ok"], json!(false));
        assert_eq!(answer["error_code"], json!("move_failed"), "{answer}");
        assert!(
            world.first("target:agent-transfer-receive-abort")
                < world.first("source:agent-transfer-abort")
        );
        // Forgotten there: a late finish of this move can never land the chat.
        assert!(world.target.lock().unwrap().forgotten.contains("xfer_1"));
        let source = world.source.lock().unwrap();
        assert_eq!(source.aborted, ["xfer_1"]);
        assert!(source.committed.is_none());
    }

    #[test]
    fn an_unreachable_target_after_the_full_read_leaves_the_move_unresolved_until_a_rerun() {
        let world = World::new(Target { finish: Finish::LandThenGoDown, ..Target::default() });
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["ok"], json!(false));
        assert_eq!(answer["error_code"], json!("move_unresolved"), "{answer}");
        assert_eq!(answer["transfer_id"], json!("xfer_1"));
        {
            // Neither committed nor given back: the chat stays frozen.
            let source = world.source.lock().unwrap();
            assert_eq!(source.moving.as_deref(), Some("xfer_1"));
            assert!(source.committed.is_none() && source.aborted.is_empty());
        }

        world.target_down.store(false, Ordering::SeqCst);
        world.target.lock().unwrap().finish = Finish::Answer;
        let (code, answer) = world.run_move();
        assert_eq!(code, 0, "{answer}");
        assert_eq!(answer["ok"], json!(true));
        assert_eq!(answer["session_id"], json!(SESSION));
        assert_eq!(answer["transfer_id"], json!("xfer_1"));
        let source = world.source.lock().unwrap();
        assert_eq!(source.committed.as_deref(), Some("xfer_1"));
        assert_eq!(source.begun, 1, "the rerun resolves the frozen move, it begins no other");
    }

    #[test]
    fn a_rerun_after_an_unresolved_move_that_did_not_land_moves_the_chat_again() {
        // The target goes away with the finish unanswered and the chat not there.
        let world = World::new(Target { finish: Finish::GoDown, ..Target::default() });
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["error_code"], json!("move_unresolved"), "{answer}");

        world.target_down.store(false, Ordering::SeqCst);
        world.target.lock().unwrap().finish = Finish::Answer;
        let (code, answer) = world.run_move();
        assert_eq!(code, 0, "{answer}");
        assert_eq!(answer["transfer_id"], json!("xfer_2"));
        let source = world.source.lock().unwrap();
        assert_eq!(source.aborted, ["xfer_1"]);
        assert_eq!(source.committed.as_deref(), Some("xfer_2"));
    }

    /// `--vm-kind`: the caller says the target is a Cloud machine, and the
    /// Cloud API's answer goes to a target that takes it, on the receive and
    /// the finish. An older target would trust its own record, so any kind but
    /// `owner` is refused there before the chat freezes, whatever it
    /// advertises, and `owner` moves without the param it would refuse.
    /// Without the flag the caller says it is not a Cloud machine (a Mac).
    #[test]
    fn the_cloud_apis_kind_reaches_the_target_or_an_older_one_is_refused() {
        let world = World::new(Target { takes_vm_kind: true, ..Target::default() });
        let (code, answer) = world.run_move_with(&["--vm-kind", "owner"]);
        assert_eq!(code, 0, "{answer}");
        let target = world.target.lock().unwrap();
        assert_eq!(target.vm_kinds, [json!("owner"), json!("owner")]);

        for kind in ["team", "none"] {
            let older = World::new(Target::default());
            let (code, answer) = older.run_move_with(&["--vm-kind", kind]);
            assert_eq!(code, 1, "{kind}");
            assert_eq!(answer["error_code"], json!("agent_session.host_unverified"), "{answer}");
            assert_eq!(answer["side"], json!("target"), "{answer}");
            assert_eq!(older.count("source:agent-transfer-begin"), 0, "the chat froze");
            assert_eq!(older.count("target:agent-transfer-receive"), 0);
        }
        let older = World::new(Target::default());
        let (code, answer) = older.run_move_with(&["--vm-kind", "owner"]);
        assert_eq!(code, 0, "{answer}");
        assert_eq!(older.target.lock().unwrap().vm_kinds, [Value::Null, Value::Null]);

        let mac = World::new(Target::default());
        let (code, answer) = mac.run_move();
        assert_eq!(code, 0, "a target the caller says is a Mac needs no kind: {answer}");
        assert_eq!(mac.target.lock().unwrap().vm_kinds, [Value::Null, Value::Null]);
    }

    /// `--to-pid`: the owner word belongs to the link process the caller read
    /// it from. When another process listens on the socket by the time the
    /// pump connects for the receive (the link was replaced while the source
    /// froze the chat), nothing is sent and the chat stays on this Mac; the
    /// same process moves it.
    #[test]
    fn the_owner_word_reaches_only_the_link_process_it_came_from() {
        let world = World::new(Target { takes_vm_kind: true, ..Target::default() });
        let replaced = (std::process::id() + 1).to_string();
        let (code, answer) = world.run_move_with(&["--vm-kind", "owner", "--to-pid", &replaced]);
        assert_eq!(code, 1, "{answer}");
        assert_eq!(answer["error_code"], json!("agent_session.host_unverified"), "{answer}");
        assert_eq!(answer["side"], json!("target"), "{answer}");
        assert_eq!(world.count("target:agent-transfer-receive"), 0);
        assert!(world.target.lock().unwrap().vm_kinds.is_empty());
        {
            let source = world.source.lock().unwrap();
            assert!(source.committed.is_none());
            assert_eq!(source.aborted, ["xfer_1"], "the chat stays on this Mac");
        }

        let world = World::new(Target { takes_vm_kind: true, ..Target::default() });
        let same = std::process::id().to_string();
        let (code, answer) = world.run_move_with(&["--vm-kind", "owner", "--to-pid", &same]);
        assert_eq!(code, 0, "{answer}");
        assert_eq!(world.target.lock().unwrap().vm_kinds, [json!("owner"), json!("owner")]);
    }

    #[test]
    fn a_team_vm_refusal_gives_the_chat_back_and_says_why() {
        let world = World::new(Target { team_vm: true, ..Target::default() });
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["ok"], json!(false));
        assert_eq!(answer["error_code"], json!("agent_session.team_vm_blocked"), "{answer}");
        assert!(answer["error"].as_str().unwrap().contains("team VM"));
        assert_eq!(world.count("target:agent-transfer-write"), 0);
        let source = world.source.lock().unwrap();
        assert_eq!(source.aborted, ["xfer_1"]);
        assert!(source.moving.is_none());
    }

    /// The kill-mid-move drill (`move_kill_drill.rs`, `after-begin:off-src`): the source went
    /// away right after it froze the chat, so the begin answer was lost. The rerun's begin is
    /// refused as `transfer.moving` with the token this command began that move with: it is
    /// this command's own and no target was ever asked to receive it, so the rerun gives it back
    /// and moves the chat at once instead of leaving it frozen for the source's lease.
    #[test]
    fn a_rerun_after_a_lost_begin_answer_ends_its_own_move_and_moves_the_chat_at_once() {
        let world = World::new(Target::default());
        {
            let mut source = world.source.lock().unwrap();
            source.keeps_token = true;
            source.lose_begin_answer = true;
        }
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["error_code"], json!("move_unresolved"), "{answer}");
        let token = world.source.lock().unwrap().moving_token.clone();
        assert!(token.as_deref().is_some_and(|t| t.len() >= 32), "a random token: {token:?}");
        assert_eq!(world.source.lock().unwrap().moving.as_deref(), Some("xfer_1"));

        let (code, answer) = world.run_move();
        assert_eq!(code, 0, "{answer}");
        assert_eq!(answer["transfer_id"], json!("xfer_2"));
        let source = world.source.lock().unwrap();
        assert_eq!(source.aborted, ["xfer_1"]);
        assert_eq!(source.committed.as_deref(), Some("xfer_2"));
        drop(source);
        assert_eq!(world.count("target:agent-transfer-receive"), 1);
        assert!(
            world.first("source:agent-transfer-abort")
                < world.first("target:agent-transfer-receive")
        );
    }

    /// A source that keeps no begin token (an older daemon): nothing tells the lost move is
    /// this command's, so it waits out the source's lease, as before.
    #[test]
    fn a_lost_begin_answer_waits_for_the_source_lease_then_moves_the_chat() {
        let world = World::new(Target::default());
        world.source.lock().unwrap().lose_begin_answer = true;
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["error_code"], json!("move_unresolved"), "{answer}");
        assert_eq!(world.source.lock().unwrap().moving.as_deref(), Some("xfer_1"));

        // A move the pump never recorded is never ended by it.
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["error_code"], json!("move_unresolved"), "{answer}");
        assert_eq!(answer["transfer_id"], json!("xfer_1"));
        assert_eq!(answer["retry_after_seconds"], json!(300));
        assert_eq!(world.count("source:agent-transfer-abort"), 0);

        // The source's lease aborts the unread move on its own.
        world.source.lock().unwrap().moving = None;
        let (code, answer) = world.run_move();
        assert_eq!(code, 0, "{answer}");
        assert_eq!(answer["transfer_id"], json!("xfer_2"));
        assert_eq!(world.count("source:agent-transfer-abort"), 0);
        assert_eq!(world.count("target:agent-transfer-receive"), 1);
        assert_eq!(world.source.lock().unwrap().committed.as_deref(), Some("xfer_2"));
    }

    #[test]
    fn another_clients_move_after_a_lost_begin_answer_is_never_aborted() {
        // An older source, a source that keeps tokens with another client's token on the move,
        // and one whose move carries none.
        for (keeps_token, theirs) in [(false, None), (true, Some("tok_theirs")), (true, None)] {
            let world = World::new(Target::default());
            {
                let mut source = world.source.lock().unwrap();
                source.keeps_token = keeps_token;
                source.lose_begin_answer = true;
            }
            let (code, _) = world.run_move();
            assert_eq!(code, 1);
            {
                // The lease ended that move; another client moved the chat since.
                let mut source = world.source.lock().unwrap();
                source.moving = Some("xfer_theirs".into());
                source.moving_token = theirs.map(str::to_string);
            }
            let (code, answer) = world.run_move();
            assert_eq!(code, 1);
            assert_eq!(answer["error_code"], json!("move_unresolved"), "{answer}");
            assert_eq!(answer["transfer_id"], json!("xfer_theirs"));
            assert_eq!(world.count("source:agent-transfer-abort"), 0);
            assert_eq!(world.count("source:agent-transfer-commit"), 0);
            assert_eq!(world.source.lock().unwrap().moving.as_deref(), Some("xfer_theirs"));
        }
    }

    #[test]
    fn a_tab_that_now_shows_another_chat_is_not_resolved() {
        let world = World::new(Target { finish: Finish::LandThenGoDown, ..Target::default() });
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["error_code"], json!("move_unresolved"), "{answer}");
        world.target_down.store(false, Ordering::SeqCst);
        world.source.lock().unwrap().rebound = Some("acp_other_chat".into());
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["error_code"], json!("move_unresolved"), "{answer}");
        assert_eq!(answer["transfer_id"], json!("xfer_1"));
        assert_eq!(world.count("source:agent-transfer-commit"), 0);
        assert_eq!(world.count("source:agent-transfer-abort"), 0);
    }

    #[test]
    fn a_frozen_move_this_pump_never_began_is_left_alone() {
        let world = World::new(Target::default());
        world.source.lock().unwrap().moving = Some("xfer_other".into());
        let (code, answer) = world.run_move();
        assert_eq!(code, 1);
        assert_eq!(answer["error_code"], json!("move_unresolved"), "{answer}");
        assert_eq!(answer["transfer_id"], json!("xfer_other"));
        assert_eq!(world.count("source:agent-transfer-abort"), 0);
        assert_eq!(world.count("target:agent-transfer-receive"), 0);
        assert_eq!(world.source.lock().unwrap().moving.as_deref(), Some("xfer_other"));
    }

    // MARK: Tail first, history after

    /// A world whose two sides serve tail first (`later`), with a chat whose
    /// history is `history_bytes` and whose last turns are `tail_bytes`.
    fn later_world(source_later: bool, target_later: bool, history_bytes: usize) -> World {
        let world = World::new(Target { later: target_later, ..Target::default() });
        let history: Vec<u8> = (0..history_bytes).map(|i| (i * 31 % 251) as u8).collect();
        let tail: Vec<u8> = (0..64 * 1024usize).map(|i| (i * 7 % 13) as u8).collect();
        let mut source = world.source.lock().unwrap();
        source.later = source_later;
        source.files[0].1.clone_from(&history);
        source.history = vec![("events/history.cspb".into(), history)];
        source.prefix = vec![("events/000002.ndjson".into(), tail)];
        drop(source);
        world
    }

    /// The source's chat log: its history, then its last turns.
    fn source_log(world: &World) -> Vec<u8> {
        let source = world.source.lock().unwrap();
        [source.history[0].1.clone(), source.prefix[0].1.clone()].concat()
    }

    /// The move calls, without the capability probes.
    fn move_calls(world: &World) -> Vec<String> {
        let probe = |call: &String| call.ends_with(":identify") || call.ends_with("history-ready");
        world.calls().into_iter().filter(|call| !probe(call)).collect()
    }

    #[test]
    fn tail_first_moves_only_the_tail_before_live_then_the_history_arrives() {
        let world = later_world(true, true, (2 << 20) + 12345);
        let (code, answer) = world.run_move_with(&["--history-later", "4"]);
        assert_eq!(code, 0, "{answer}");
        assert!(answer["live_ms"].is_u64(), "{answer}");
        assert_eq!(answer["history_records"], json!(5), "{answer}");
        assert_eq!(answer["history_through_seq"], json!(7));
        let order = [
            "source:agent-transfer-prepare",
            "target:agent-transfer-stage",
            "target:agent-transfer-stage-finish",
            "source:agent-transfer-begin",
            "target:agent-transfer-receive",
            "target:agent-transfer-finish",
            "source:agent-transfer-commit",
            "target:agent-transfer-history-have",
            "source:agent-transfer-history-export",
            "target:agent-transfer-history",
        ];
        let at: Vec<usize> = order.iter().map(|call| world.first(call)).collect();
        assert!(at.windows(2).all(|w| w[0] < w[1]), "{:?}", world.calls());
        let source = world.source.lock().unwrap();
        assert_eq!(source.begin_prepares, [json!("pre_1")]);
        assert_eq!(source.committed.as_deref(), Some("xfer_1"));
        let history_len = source.history[0].1.len();
        drop(source);
        let target = world.target.lock().unwrap();
        assert_eq!(target.receive_stages, [json!("stg_1")]);
        // Before live only the tail moved: the frozen bundle held no events.
        let landed = target.landed_files();
        assert!(landed.keys().all(|path| !path.starts_with("events/")), "{:?}", landed.keys());
        let frozen_bytes = answer["bytes"].as_u64().unwrap();
        assert!(frozen_bytes < history_len as u64, "{frozen_bytes} of {history_len}");
        // Then the history arrived: the target's log is the source's.
        assert!(target.log == source_log(&world), "the target log equals the source's");
    }

    #[test]
    fn switched_off_or_a_side_without_it_makes_todays_calls() {
        // Today's move: no flag, a source and target that could.
        let today = later_world(true, true, 4096);
        let (code, answer) = today.run_move();
        assert_eq!(code, 0, "{answer}");
        let calls = move_calls(&today);
        assert!(answer.get("live_ms").is_none() && answer.get("history_ms").is_none());
        assert_eq!(today.count("source:agent-transfer-history-ready"), 0, "off asks nothing");
        assert_eq!(today.source.lock().unwrap().begin_prepares, [Value::Null]);
        assert_eq!(today.target.lock().unwrap().receive_stages, [Value::Null]);
        // The env is read like the flag; 0 is off.
        for (source_later, target_later, flag) in
            [(true, false, "4"), (false, true, "4"), (false, false, "4"), (true, true, "0")]
        {
            let world = later_world(source_later, target_later, 4096);
            let (code, answer) = world.run_move_with(&["--history-later", flag]);
            assert_eq!(code, 0, "{answer}");
            assert_eq!(move_calls(&world), calls, "{source_later} {target_later} {flag}");
            assert_eq!(world.source.lock().unwrap().begin_prepares, [Value::Null]);
            assert!(answer.get("history_ms").is_none(), "{answer}");
        }
    }

    /// `cargo test -p cmux-tui --test link_agent_move -- --ignored tail_first_bench --nocapture`:
    /// a `CMUX_MOVE_BENCH_MB` (55) chat through the pump over loopback, off and on.
    #[test]
    #[ignore = "a bench: run it by name"]
    fn tail_first_bench() {
        let mb: usize =
            std::env::var("CMUX_MOVE_BENCH_MB").ok().and_then(|v| v.parse().ok()).unwrap_or(55);
        let off = later_world(true, true, mb << 20);
        let started = std::time::Instant::now();
        let (code, answer) = off.run_move();
        let off_ms = started.elapsed().as_millis();
        assert_eq!(code, 0, "{answer}");
        let on = later_world(true, true, mb << 20);
        let started = std::time::Instant::now();
        let (code, answer_on) = on.run_move_with(&["--history-later", "4"]);
        let on_ms = started.elapsed().as_millis();
        assert_eq!(code, 0, "{answer_on}");
        assert!(on.target.lock().unwrap().log == source_log(&on));
        println!(
            "tail_first_bench: {mb} MB off: live {off_ms} ms (total_ms {}, phases {}); on: live_ms {}, history_ms {}, history_bytes {}, total {on_ms} ms (phases {})",
            answer["total_ms"],
            answer["phases"],
            answer_on["live_ms"],
            answer_on["history_ms"],
            answer_on["history_bytes"],
            answer_on["phases"]
        );
    }
}
