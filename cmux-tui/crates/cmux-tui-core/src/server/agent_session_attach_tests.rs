//! Behavior of `agent-session-attach-v1` (plans/cmux-next/remote-agent-attach.md):
//! a trusted local client attaches to an agent tab of this daemon's store
//! and streams and drives its acpmux session through the daemon. A fake
//! acpmux on a private unix socket records every frame the daemon sends.
//!
//! Policy tests (AGENTS.md "Remote CLI relay"): the verbs are refused on the
//! remote relay and on WebSocket clients, scoped to agent tabs of this store
//! with a bound session, carry no command-bearing or session params, prompts
//! are one text block, and permission answers name only a request acpmux
//! announced on the attachment.
use super::agent_session_attach::{AGENT_SESSION_ATTACH_CAPABILITY, MAX_ATTACHMENTS_PER_CLIENT};
use super::*;
use serde_json::{Value, json};
use std::collections::{HashSet, VecDeque};
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

pub(super) const WAIT: Duration = Duration::from_secs(5);
pub(super) const SESSION: &str = "acp_session_1";

// MARK: Fake acpmux

/// A fake acpmux daemon: answers attach, events, prompt (with
/// `prompt_accepted`) and permission_respond, and lets a test push
/// notifications to the newest connection.
pub(super) struct FakeAcpmux {
    directory: PathBuf,
    pub(super) socket: PathBuf,
    pub(super) frames: Receiver<Value>,
    connections: Receiver<UnixStream>,
    current: Option<UnixStream>,
    transfer_blocked: Arc<Mutex<HashSet<String>>>,
}

impl FakeAcpmux {
    pub(super) fn start(label: &str) -> Self {
        Self::start_with(label, Fixture::default())
    }

    /// A fake whose attach page and watch answer carry `fixture`'s extras.
    pub(super) fn start_with(label: &str, fixture: Fixture) -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let directory = PathBuf::from(format!(
            "/tmp/cmux-asa-{label}-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let socket = directory.join("a.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let (frame_tx, frames) = channel();
        let (connection_tx, connections) = channel();
        let transfer_blocked = Arc::new(Mutex::new(HashSet::new()));
        let shared_transfers = transfer_blocked.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let _ = connection_tx.send(stream.try_clone().unwrap());
                let frame_tx = frame_tx.clone();
                let fixture = fixture.clone();
                let transfers = shared_transfers.clone();
                std::thread::spawn(move || serve(stream, frame_tx, &fixture, &transfers));
            }
        });
        Self { directory, socket, frames, connections, current: None, transfer_blocked }
    }

    /// Models an acpmux watcher abort, independently of any cmux transfer request.
    pub(super) fn set_transfer_blocked(&self, session: &str, blocked: bool) {
        let mut transfers = self.transfer_blocked.lock().unwrap();
        if blocked {
            transfers.insert(session.to_owned());
        } else {
            transfers.remove(session);
        }
    }

    /// The next frame the daemon sent to acpmux.
    /// The next frame the daemon sent to acpmux (its session watch skipped).
    pub(super) fn frame(&self) -> Value {
        loop {
            let frame = self.frames.recv_timeout(WAIT).expect("a frame to acpmux");
            if frame["method"] != json!("_acpmux/watch") {
                return frame;
            }
        }
    }

    /// The next frame the daemon sent to acpmux, its session watch included.
    pub(super) fn raw_frame(&self) -> Value {
        self.frames.recv_timeout(WAIT).expect("a frame to acpmux")
    }

    /// The next frame the daemon sent to acpmux within `timeout`, if any.
    pub(super) fn next_frame(&self, timeout: Duration) -> Option<Value> {
        self.frames.recv_timeout(timeout).ok()
    }

    pub(super) fn no_frame(&self) {
        let deadline = Instant::now() + Duration::from_millis(200);
        while let Some(left) = deadline.checked_duration_since(Instant::now()) {
            match self.frames.recv_timeout(left) {
                Ok(frame) if frame["method"] == json!("_acpmux/watch") => continue,
                Ok(frame) => panic!("the daemon must not reach acpmux: {frame}"),
                Err(_) => return,
            }
        }
    }

    pub(super) fn no_connection(&self) {
        assert!(
            self.connections.recv_timeout(Duration::from_millis(200)).is_err(),
            "the daemon must not connect to acpmux"
        );
    }

    fn connection(&mut self) -> &mut UnixStream {
        if self.current.is_none() {
            self.current = Some(self.connections.recv_timeout(WAIT).expect("a connection"));
        }
        self.current.as_mut().unwrap()
    }

    pub(super) fn notify(&mut self, method: &str, params: Value) {
        let line = json!({"jsonrpc":"2.0","method":method,"params":params}).to_string();
        let stream = self.connection();
        writeln!(stream, "{line}").unwrap();
        stream.flush().unwrap();
    }

    fn hang_up(&mut self) {
        let _ = self.connection().shutdown(Shutdown::Both);
    }
}

impl Drop for FakeAcpmux {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

/// What a test adds to the fake's answers: records after the attach page's
/// own, and sessions after the watch answer's own.
#[derive(Clone, Default)]
pub(super) struct Fixture {
    /// Enable the first-chat catalog/new-session fixture, with this trust decision.
    pub(super) start_folder_trusted: Option<bool>,
    pub(super) page: Vec<Value>,
    pub(super) watch: Vec<Value>,
    /// The records an `_acpmux/events` (history) page answers.
    pub(super) history: Vec<Value>,
    /// Records every history page answers after [`Fixture::history`], added while the fake runs.
    pub(super) history_later: Arc<Mutex<Vec<Value>>>,
    /// When set, the attach answer waits for one message on it (at most [`WAIT`]).
    pub(super) attach_gate: Option<Arc<Mutex<Receiver<()>>>>,
    /// `_acpmux/sessions` answers its list in two pages, as acpmux does past its
    /// largest reply: the first rows with a `nextCursor`, the rest from that cursor.
    pub(super) sessions_pages: bool,
    /// The watch answers only its first row with a `nextCursor`; `_acpmux/sessions`
    /// from that cursor answers the rest ([`Fixture::watch`]).
    pub(super) watch_pages: bool,
    /// With [`Fixture::watch_pages`], the page after the watch's cursor lists no sessions.
    pub(super) watch_bad_page: bool,
    /// With [`Fixture::watch_pages`], the page after the watch's cursor is an error.
    pub(super) watch_page_error: bool,
    /// When set, each history page and each prompt's acceptance waits for one message on it (at
    /// most [`WAIT`], or until its sender is gone).
    pub(super) events_gate: Option<Arc<Mutex<Receiver<()>>>>,
    pub(super) prompt_gate: Option<Arc<Mutex<Receiver<()>>>>,
    /// When set, each prompt's acceptance comes this long after the prompt (a cold chat's).
    pub(super) accept_after: Option<Duration>,
    /// acpmux's Cloud mobile floor for a phone's start (agent_session_start_phone_tests.rs).
    pub(super) phone: Option<PhoneFloor>,
    /// When set, `_acpmux/harnesses` answers this long after it is asked: a starting acpmux
    /// holds its catalog until its login shell read ends (`Hub::harnesses_reply`).
    pub(super) catalog_after: Option<Duration>,
    /// `_acpmux/harnesses` asks the fake hangs up on (its connection closed, no answer) before it
    /// answers one: an acpmux restarting under the start (the app's keyed restart).
    pub(super) catalog_hang_ups: Arc<AtomicU64>,
    /// When set, `_acpmux/status` reports a person key for this acpmux run (`personInstance`);
    /// each catalog hang-up ([`Fixture::catalog_hang_ups`]) brings the run named `restarted`.
    pub(super) keyed_run: Option<KeyedRun>,
}

/// The acpmux run the fake reports a person key for, and the run a restart brings.
#[derive(Clone)]
pub(super) struct KeyedRun {
    pub(super) current: Arc<Mutex<&'static str>>,
    pub(super) restarted: &'static str,
}

/// The fake's Cloud mobile floor: whether it reports one, the family a new session runs, and
/// the session's mode (`session/set_mode` changes it, unless `stuck`).
#[derive(Clone)]
pub(super) struct PhoneFloor {
    pub(super) strict: bool,
    pub(super) family: &'static str,
    pub(super) mode: Arc<Mutex<String>>,
    pub(super) stuck: bool,
    /// When set, the start's first `_acpmux/web_modes` (the table, before any session) waits
    /// for one message on it (at most [`WAIT`], or until its sender is gone).
    pub(super) table_gate: Option<Arc<Mutex<Receiver<()>>>>,
}

impl PhoneFloor {
    /// acpmux's `Hub::cloud_mobile_mode_asks` for a Claude or Codex bridge session.
    fn asks(&self) -> bool {
        let mode = self.mode.lock().unwrap();
        match self.family {
            "claude" => matches!(mode.as_str(), "default" | "plan"),
            "codex" => mode.as_str() == "ask",
            _ => false,
        }
    }
}

fn serve(
    stream: UnixStream,
    frames: Sender<Value>,
    fixture: &Fixture,
    transfers: &Mutex<HashSet<String>>,
) {
    let mut writer = stream.try_clone().unwrap();
    // acpmux takes 2 `_acpmux/typing` a second per connection: the fake refuses the third.
    let mut typing_calls = 0;
    for line in BufReader::new(stream).lines() {
        let Ok(line) = line else { return };
        let frame: Value = serde_json::from_str(&line).unwrap();
        let _ = frames.send(frame.clone());
        let id = frame["id"].clone();
        let params = &frame["params"];
        let reply = match frame["method"].as_str().unwrap_or_default() {
            "_acpmux/web_modes" if fixture.phone.is_some() => {
                let phone = fixture.phone.as_ref().unwrap();
                if params.get("sessionId").is_none()
                    && let Some(gate) = &phone.table_gate
                {
                    let _ = gate.lock().unwrap_or_else(|e| e.into_inner()).recv_timeout(WAIT);
                }
                // acpmux's own table: Codex and opencode are refused Web families, and a Codex
                // bridge session holds to the phone floor only through `cloudMobileAsks`.
                let mut table = json!({
                    "families": {"claude": ["default", "plan"]},
                    "refusedFamilies": ["codex", "opencode"],
                    "session": {"family": phone.family, "mode": phone.mode.lock().unwrap().clone(),
                                "cloudMobileAsks": phone.asks()},
                });
                if phone.strict {
                    table["cloudMobileStrictFloor"] = json!(1);
                } else {
                    table["session"].as_object_mut().unwrap().remove("cloudMobileAsks");
                }
                Some(table)
            }
            // acpmux's catalog lists every family it runs, opencode included, so a family with
            // no phone mode resolves and is refused by the phone floor, not the catalog.
            "_acpmux/harnesses"
                if fixture.phone.is_some()
                    && fixture
                        .catalog_hang_ups
                        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
                        .is_ok() =>
            {
                if let Some(run) = &fixture.keyed_run {
                    *run.current.lock().unwrap() = run.restarted;
                }
                // The test holds a clone of this stream: close it for every holder.
                let _ = writer.shutdown(Shutdown::Both);
                return;
            }
            "_acpmux/status" if fixture.keyed_run.is_some() => Some(json!({
                "personKey": true,
                "personInstance": *fixture.keyed_run.as_ref().unwrap().current.lock().unwrap(),
                "ready": true, "agentHosts": true, "liveAgents": 0, "remoteSessions": 0,
            })),
            "_acpmux/harnesses" if fixture.phone.is_some() => Some({
                if let Some(delay) = fixture.catalog_after {
                    std::thread::sleep(delay);
                }
                json!({
                "defaultHarness": fixture.phone.as_ref().unwrap().family,
                "families": {"claude": {}, "codex": {}, "opencode": {}},
                "harnesses": {},
                })
            }),
            "session/set_mode" if fixture.phone.is_some() => {
                let phone = fixture.phone.as_ref().unwrap();
                if !phone.stuck {
                    *phone.mode.lock().unwrap() =
                        params["modeId"].as_str().unwrap_or_default().to_owned();
                }
                Some(json!({}))
            }
            "_acpmux/kill" => Some(json!({})),
            "_acpmux/web_modes" if fixture.start_folder_trusted.is_some() => Some(json!({
                "families": {"claude": ["default"]}, "refusedFamilies": [],
                "session": {"family": "claude", "mode": "default"},
            })),
            "_acpmux/harnesses" if fixture.start_folder_trusted.is_some() => Some(json!({
                "defaultHarness": "claude", "families": {"claude": {}}, "harnesses": {},
            })),
            "acp.trust.get" | "acp.trust.set" if fixture.start_folder_trusted.is_some() => {
                Some(json!({"cwd": params["cwd"], "decided": true,
                    "level": if fixture.start_folder_trusted == Some(true) { "trusted" } else { "untrusted" }}))
            }
            "session/new" if fixture.start_folder_trusted.is_some() => Some(json!({
                "sessionId": SESSION, "_meta": {"acpmux": {"harness": "claude"}},
            })),
            "_acpmux/attach" => {
                if let Some(gate) = &fixture.attach_gate {
                    let _ = gate.lock().unwrap_or_else(|e| e.into_inner()).recv_timeout(WAIT);
                }
                // A running turn: acpmux subscribes first, so a live record
                // can reach the daemon before the attach reply.
                let early = json!({"jsonrpc":"2.0","method":"_acpmux/event","params":{
                    "sessionId": SESSION, "seq": 2, "dir": "in", "kind": "agent_message", "msg": {}}});
                writeln!(writer, "{early}").unwrap();
                let mut events = vec![
                    json!({"sessionId": SESSION, "seq": 1, "dir": "mux", "kind": "user_message", "msg": {}}),
                ];
                events.extend(fixture.page.iter().cloned());
                Some(json!({
                    "session": {"sessionId": SESSION, "name": "sub", "status": "running",
                                "pending": [{"permissionId": "perm_attach", "options": []}]},
                    "events": events,
                    "hasMore": false,
                    "lastSeq": 1,
                }))
            }
            "_acpmux/watch" => {
                let mut sessions = vec![json!({"sessionId": "acp_unrelated"})];
                if fixture.watch_pages {
                    Some(json!({"sessions": sessions, "nextCursor": "w1"}))
                } else {
                    sessions.extend(fixture.watch.iter().cloned());
                    Some(json!({"sessions": sessions}))
                }
            }
            "_acpmux/sessions" if params["cursor"] == json!("w1") => {
                Some(if fixture.watch_bad_page {
                    json!({"nextCursor": null})
                } else if fixture.watch_page_error {
                    json!({FAKE_ERROR: "list.paced"})
                } else {
                    json!({"sessions": fixture.watch})
                })
            }
            // The machine's whole list: the attached session's family and others
            // (agent_session_children_tests.rs), its older rows first, as acpmux's byte
            // pages (in no time order) can come.
            "_acpmux/sessions" if fixture.sessions_pages => {
                let mut rows = machine_sessions()["sessions"].as_array().unwrap().clone();
                let older = rows.split_off(3);
                Some(if params["cursor"] == json!("c1") {
                    json!({"sessions": rows})
                } else {
                    json!({"sessions": older, "nextCursor": "c1"})
                })
            }
            "_acpmux/sessions" => Some(machine_sessions()),
            "_acpmux/info" => Some(json!({
                "sessionId": params["sessionId"],
                "transferBlocked": transfers.lock().unwrap().contains(
                    params["sessionId"].as_str().unwrap_or_default()
                ),
            })),
            "_acpmux/events" => {
                if let Some(gate) = &fixture.events_gate {
                    let _ = gate.lock().unwrap_or_else(|e| e.into_inner()).recv_timeout(WAIT);
                }
                let mut events = fixture.history.clone();
                events.extend(fixture.history_later.lock().unwrap().iter().cloned());
                Some(json!({"events": events, "hasMore": false, "lastSeq": 1}))
            }
            "_acpmux/typing" => {
                typing_calls += 1;
                Some(if typing_calls > 2 {
                    json!({FAKE_ERROR: "typing too fast",
                           FAKE_ERROR_DATA: {"reason": "typing.rate_limited"}})
                } else {
                    json!({})
                })
            }
            "_acpmux/permission_respond" | "_acpmux/view" => Some(json!({})),
            // The media reader (agent_session_media_tests.rs): one video, [`FAKE_VIDEO`].
            "_acpmux/media_open" | "_acpmux/media_range" => Some(media_reply(&frame)),
            // A fork through turn 7 makes a copy acpmux then refuses to tag (side chat tests).
            "acp.session.fork" => Some(json!({"sessionId":
                if params["throughSeq"] == json!(7) { "acp_untaggable" } else { "acp_side_1" }})),
            "_acpmux/side" if params["sessionId"] == json!("acp_untaggable") => {
                Some(json!({FAKE_ERROR: "no chat with that id"}))
            }
            "_acpmux/side" => {
                Some(json!({"sessionId": params["sessionId"], "tags": {"side": params["chat"]}}))
            }
            "_acpmux/context" | "_acpmux/context_override" => Some(json!({
                "sessionId": params["sessionId"],
                "parts": [{"source": "cmux", "text": "Read early.", "tokens": 3}],
                "overrides": {"scope": params["scope"], "text": params["text"]},
            })),
            "session/set_model" | "session/set_mode" => Some(json!({})),
            // A side question (`/btw`): a harness with no read-only mode is refused with its reason.
            "_acpmux/btw" if params["question"] == json!("no read-only mode") => Some(json!({
                FAKE_ERROR: "this agent has no read-only mode",
                FAKE_ERROR_DATA: {"reason": "btw.no_read_only_mode"}})),
            // The folder is not trusted yet: acpmux's trust gate refuses it.
            "_acpmux/btw" if params["question"] == json!("untrusted folder") => Some(json!({
                FAKE_ERROR: "trust the folder first",
                FAKE_ERROR_DATA: {"reason": "trust.pending"}})),
            // An acpmux from before inline answers opens a lasting side session.
            "_acpmux/btw" if params["question"] == json!("old acpmux") => {
                Some(json!({"sessionId": "acp_side", "model": null, "readOnly": "mode"}))
            }
            "_acpmux/btw" => Some(json!({"text": "It flaked on a timeout."})),
            // A Cloud chat's sign-in: a wrong code is refused with acpmux's reason.
            "_acpmux/agent_login/start" if params["agent"] == json!("grok") => {
                Some(json!({"loginId": "login_2", "url": "https://accounts.x.ai/device",
                    "userCode": "WDJB-MJHT", "needsCode": false}))
            }
            "_acpmux/agent_login/start" => Some(json!({"loginId": "login_1",
                "url": "https://claude.ai/oauth/authorize", "needsCode": true})),
            "_acpmux/agent_login/finish" if params["code"] == json!("wrong") => {
                Some(json!({FAKE_ERROR: "bad code", FAKE_ERROR_DATA: {"reason": "bad_code"}}))
            }
            "_acpmux/agent_login/finish" => Some(json!({"signedIn": true, "restarted": true})),
            "_acpmux/agent_login/api_key" => Some(json!({"saved": true, "restarted": true})),
            "_acpmux/agent_login/cancel" => Some(json!({})),
            // The agent answers its whole option list, the value just set included.
            "session/set_config_option" => Some(json!({"configOptions": [{
                "id": params["configId"], "currentValue": params["value"]}]})),
            // `acpmux.transfer.v1` with the guarded receive (agent_transfer_tests.rs).
            method if method.starts_with("_acpmux/transfer_") => {
                let reply = transfer_reply(method, params);
                if let Some(answer) = &reply
                    && answer.get(FAKE_ERROR).is_none()
                {
                    let session = answer["sessionId"].as_str().unwrap_or_default();
                    let mut transfers = transfers.lock().unwrap();
                    match method {
                        "_acpmux/transfer_begin" | "_acpmux/transfer_commit" => {
                            transfers.insert(session.to_owned());
                        }
                        "_acpmux/transfer_abort" | "_acpmux/transfer_finish" => {
                            transfers.remove(session);
                        }
                        _ => {}
                    }
                }
                reply
            }
            "session/prompt" => {
                if let Some(gate) = &fixture.prompt_gate {
                    let _ = gate.lock().unwrap_or_else(|e| e.into_inner()).recv_timeout(WAIT);
                }
                if let Some(delay) = fixture.accept_after {
                    std::thread::sleep(delay);
                }
                let accepted = json!({"jsonrpc":"2.0","method":"_acpmux/prompt_accepted","params":{
                    "sessionId": params["sessionId"], "promptId": params["_meta"]["acpmux"]["promptId"],
                    "turnId": "turn_1", "queued": false}});
                writeln!(writer, "{accepted}").unwrap();
                None
            }
            _ => None,
        };
        if let Some(result) = reply {
            let frame = match result.get(FAKE_ERROR) {
                Some(message) => {
                    let mut error = json!({"code":-32000,"message":message});
                    if let Some(data) = result.get(FAKE_ERROR_DATA) {
                        error["data"] = data.clone();
                    }
                    json!({"jsonrpc":"2.0","id":id,"error":error})
                }
                None => json!({"jsonrpc":"2.0","id":id,"result":result}),
            };
            writeln!(writer, "{frame}").unwrap();
        }
    }
}

/// A fake answer carrying this key is sent as a JSON-RPC error.
const FAKE_ERROR: &str = "__fake_error";
/// The `data` of that error, when the fake answer carries one.
const FAKE_ERROR_DATA: &str = "__fake_error_data";

/// The fake's `_acpmux/transfer_*` answers: a receive whose manifest names
/// [`UNGUARDED_CHAT`] is answered as an acpmux without the guard would, one
/// whose manifest `transferId` is `xfer_many_<n>` gets receive id `rcv_<n>`,
/// a finish named `exists` or `incomplete` fails as acpmux's would, one named
/// `slow` answers after 800 ms, a forget of move `xfer_forget_fails` fails, a forget
/// of move `xfer_landed` answers that its chat landed, and an abort of
/// [`ABORT_FAILS_CHAT`] fails, and a begin of [`MOVING_CHAT`] answers that
/// it is being moved already, with that move's id as acpmux's error data.
fn transfer_reply(method: &str, params: &Value) -> Option<Value> {
    use base64::Engine as _;
    let base64 = base64::engine::general_purpose::STANDARD;
    Some(match method {
        "_acpmux/transfer_receive" => {
            let chat = params["manifest"]["sessionId"].clone();
            let many = params["manifest"]["transferId"].as_str().unwrap_or("");
            if chat == json!(UNGUARDED_CHAT) {
                json!({"receiveId": "rcv_old", "sessionId": chat})
            } else if let Some(n) = many.strip_prefix("xfer_many_") {
                json!({"receiveId": format!("rcv_{n}"), "sessionId": chat, "guarded": true})
            } else {
                json!({"receiveId": "rcv_1", "sessionId": chat, "guarded": true})
            }
        }
        "_acpmux/transfer_write" => json!({"next": 3}),
        "_acpmux/transfer_finish" if params["name"] == json!("exists") => {
            json!({FAKE_ERROR: "transfer.exists: chat acp_moving is here already"})
        }
        "_acpmux/transfer_finish" if params["name"] == json!("incomplete") => {
            json!({FAKE_ERROR: "transfer.incomplete: \"events/0.ndjson\": 0 of 3"})
        }
        "_acpmux/transfer_finish" if params["name"] == json!("slow") => {
            std::thread::sleep(Duration::from_millis(800));
            json!({"sessionId": "acp_moved", "cwd": params["cwd"]})
        }
        "_acpmux/transfer_finish" => json!({"sessionId": "acp_moved", "cwd": params["cwd"]}),
        "_acpmux/transfer_begin" if params["sessionId"] == json!(MOVING_CHAT) => json!({
            FAKE_ERROR: "transfer.moving: this chat is already being moved",
            FAKE_ERROR_DATA: {"transferId": "xfer_frozen"},
        }),
        "_acpmux/transfer_begin" => json!({
            "schema": "acpmux.transfer.v1", "transferId": "xfer_1",
            "sessionId": params["sessionId"],
            "files": [{"path": "events/0.ndjson", "size": 3},
                      {"path": "manifest.json", "size": BUNDLE_MANIFEST.len()},
                      {"path": "session.json", "size": BUNDLE_SESSION.len()}],
            "session": {"sessionId": params["sessionId"], "harness": "claude"},
        }),
        "_acpmux/transfer_read" if params["path"] == json!("manifest.json") => {
            json!({"data": base64.encode(BUNDLE_MANIFEST), "next": BUNDLE_MANIFEST.len(),
                   "eof": true})
        }
        "_acpmux/transfer_read" if params["path"] == json!("session.json") => {
            json!({"data": base64.encode(BUNDLE_SESSION), "next": BUNDLE_SESSION.len(),
                   "eof": true})
        }
        "_acpmux/transfer_read" => json!({"data": base64.encode("abc"), "next": 3, "eof": true}),
        "_acpmux/transfer_forget" if params["transferId"] == json!("xfer_forget_fails") => {
            json!({FAKE_ERROR: "transfer: disk full"})
        }
        "_acpmux/transfer_forget" => json!({"transferId": params["transferId"],
                                           "landed": params["transferId"] == json!("xfer_landed")}),
        "_acpmux/transfer_commit" => json!({"sessionId": params["sessionId"], "committed": true}),
        "_acpmux/transfer_abort" if params["sessionId"] == json!(ABORT_FAILS_CHAT) => {
            json!({FAKE_ERROR: "transfer.closed: the move committed"})
        }
        "_acpmux/transfer_abort" => json!({"sessionId": params["sessionId"], "aborted": true}),
        _ => return None,
    })
}

/// A chat the fake says is already being moved (move `xfer_frozen`).
pub(super) const MOVING_CHAT: &str = "acp_moving_already";
/// A chat whose move the fake refuses to abort.
pub(super) const ABORT_FAILS_CHAT: &str = "acp_abort_fails";
/// A bundle's `session.json` (acpmux `SessionMeta`), with the source
/// machine's launch settings.
pub(super) const BUNDLE_SESSION: &str = r#"{"schema":"acpmux.session.v1","id":"acp_session_1","name":"chat","harness":"claude","harnessArgv":["--dangerously-skip-permissions"],"preset":"yolo","cwd":"/Users/someone/code/p","status":"idle","createdAt":1,"updatedAt":2,"sessionEnv":{"API_BASE":"http://127.0.0.1:9"},"harnessRoots":[{"path":"/Users/someone/.claude"}],"tags":{"lane":["x",0]},"permissionPolicy":"ask"}"#;
/// A chat the fake receives without applying the guard.
pub(super) const UNGUARDED_CHAT: &str = "acp_unguarded";
/// A bundle's `manifest.json` (acpmux `hub/transfer.rs` export), naming the
/// native store's absolute path on the source machine.
pub(super) const BUNDLE_MANIFEST: &str = r#"{"schema":"acpmux.bundle.v1","id":"acp_session_1","eventCount":1,"lastSeq":1,"native":[{"label":"claude","path":"native/claude/s.jsonl","source":"/Users/someone/.claude/projects/p/s.jsonl"}]}"#;

// MARK: Client

/// One control connection served by `handle_connection` on a private socket.
pub(super) struct Client {
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    events: VecDeque<Value>,
    next_id: u64,
    directory: PathBuf,
    handler: Option<JoinHandle<()>>,
}

impl Client {
    pub(super) fn connect(mux: &Arc<Mux>, label: &str) -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let directory = PathBuf::from(format!(
            "/tmp/cmux-asc-{label}-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("s.sock");
        let listener = transport::listen(&path).unwrap();
        let client = transport::connect(&path).unwrap();
        let server = listener.accept().unwrap();
        let server_mux = mux.clone();
        let handler = std::thread::spawn(move || handle_connection(server_mux, server));
        let reader = client.try_clone_box().unwrap();
        reader.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        Self {
            writer: client,
            reader: BufReader::new(reader),
            events: VecDeque::new(),
            next_id: 1,
            directory,
            handler: Some(handler),
        }
    }

    fn read_line(&mut self, deadline: Instant) -> Option<Value> {
        let mut line = String::new();
        while Instant::now() < deadline {
            match self.reader.read_line(&mut line) {
                Ok(0) => return None,
                Ok(_) if line.ends_with('\n') => return Some(serde_json::from_str(&line).unwrap()),
                Ok(_) => continue,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue;
                }
                Err(error) => panic!("read failed: {error}"),
            }
        }
        None
    }

    pub(super) fn request(&mut self, value: Value) -> Value {
        let id = self.send(value);
        self.answer(id)
    }

    /// Writes raw bytes on the connection, as a client would (a blank line).
    pub(super) fn raw(&mut self, bytes: &str) {
        self.writer.write_all(bytes.as_bytes()).unwrap();
        self.writer.flush().unwrap();
    }

    /// Sends a request without waiting for its answer; returns its id.
    pub(super) fn send(&mut self, mut value: Value) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        value["id"] = json!(id);
        writeln!(self.writer, "{value}").unwrap();
        self.writer.flush().unwrap();
        id
    }

    /// The answer to request `id`.
    pub(super) fn answer(&mut self, id: u64) -> Value {
        self.answer_within(id, WAIT)
    }

    /// The answer to request `id`, waiting at most `timeout`.
    pub(super) fn answer_within(&mut self, id: u64, timeout: Duration) -> Value {
        let deadline = Instant::now() + timeout;
        loop {
            let line = self.read_line(deadline).expect("no response before the deadline");
            if line.get("event").is_some() {
                self.events.push_back(line);
            } else if line["id"] == json!(id) {
                return line;
            }
        }
    }

    /// The next event with this exact name (buffered first).
    pub(super) fn named_event(&mut self, name: &str, timeout: Duration) -> Option<Value> {
        if let Some(index) = self.events.iter().position(|e| e["event"] == name) {
            return self.events.remove(index);
        }
        let deadline = Instant::now() + timeout;
        loop {
            let line = self.read_line(deadline)?;
            if line["event"] == name {
                return Some(line);
            }
        }
    }

    /// Whether the daemon ends this connection (end of stream) within `timeout`; any line read
    /// before it is dropped.
    pub(super) fn ends_within(&mut self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut line = String::new();
        while Instant::now() < deadline {
            line.clear();
            match self.reader.read_line(&mut line) {
                Ok(0) => return true,
                Ok(_) => continue,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue;
                }
                // A reset is the connection ending too.
                Err(_) => return true,
            }
        }
        false
    }

    /// The next `agent-session-*` event (buffered first).
    pub(super) fn event(&mut self, timeout: Duration) -> Option<Value> {
        if let Some(index) = self.events.iter().position(is_agent_event) {
            return self.events.remove(index);
        }
        let deadline = Instant::now() + timeout;
        loop {
            let line = self.read_line(deadline)?;
            if is_agent_event(&line) {
                return Some(line);
            }
        }
    }
}

fn is_agent_event(line: &Value) -> bool {
    line["event"].as_str().is_some_and(|event| event.starts_with("agent-session-"))
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.writer.shutdown(Shutdown::Both);
        if let Some(handler) = self.handler.take() {
            let _ = handler.join();
        }
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

// MARK: Fixtures

pub(super) fn mux_with(fake: &FakeAcpmux, label: &str) -> Arc<Mux> {
    let mux = Mux::new_for_test(label, crate::SurfaceOptions::default());
    mux.set_acpmux_socket(Some(fake.socket.clone()));
    mux
}

pub(super) fn run(mux: &Arc<Mux>, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer).unwrap()
}

/// A workspace with one terminal; returns (terminal surface, its pane).
pub(super) fn terminal_pane(mux: &Arc<Mux>) -> (SurfaceId, PaneId) {
    let terminal = mux.new_workspace(None, None).unwrap().id;
    (terminal, mux.with_state(|state| state.pane_of(terminal)).unwrap())
}

pub(super) fn agent_tab(mux: &Arc<Mux>, session: Option<&str>) -> SurfaceId {
    let (_, pane) = terminal_pane(mux);
    let created = run(
        mux,
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":"install:brain","session":session,"harness":"claude"}}),
    );
    created["surface"].as_u64().unwrap()
}

fn attach(client: &mut Client, surface: SurfaceId) -> Value {
    client.request(json!({"cmd":"agent-session-attach","surface":surface,"limit":400,
                          "kinds":["transcript"]}))
}

pub(super) fn assert_code(reply: &Value, code: &str) {
    assert_eq!(reply["ok"], json!(false), "{reply}");
    assert_eq!(reply["error_code"], json!(code), "{reply}");
}

include!("agent_session_observe_tests.rs");
include!("agent_session_answers_tests.rs");
include!("agent_session_children_tests.rs");
include!("agent_session_context_tests.rs");
include!("agent_session_media_tests.rs");

// MARK: Capability and trust

#[test]
fn the_capability_is_advertised_only_with_an_acpmux_socket() {
    let fake = FakeAcpmux::start("cap");
    let mux = mux_with(&fake, "asa-cap");
    let identity = run(&mux, json!({"cmd":"identify"}));
    let advertised = |identity: &Value| {
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == AGENT_SESSION_ATTACH_CAPABILITY)
    };
    assert!(advertised(&identity));
    mux.set_acpmux_socket(None);
    assert!(!advertised(&run(&mux, json!({"cmd":"identify"}))));
}

#[test]
fn the_remote_relay_denies_every_agent_session_verb() {
    let fake = FakeAcpmux::start("relay");
    let mux = mux_with(&fake, "asa-relay");
    let surface = agent_tab(&mux, Some(SESSION));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Remote, writer.clone());
    for frame in every_verb(surface) {
        assert!(remote_relay::gate::check_frame(&frame.to_string()).is_err());
        remote_relay::handle_frame(&mux, client, &frame.to_string(), &writer);
        let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_code(&reply, "remote_denied");
    }
    fake.no_connection();
}

/// One frame of every verb on `surface`.
fn every_verb(surface: SurfaceId) -> Vec<Value> {
    vec![
        json!({"id":1,"cmd":"agent-session-attach","surface":surface}),
        json!({"id":2,"cmd":"agent-session-events","surface":surface}),
        json!({"id":3,"cmd":"agent-session-prompt","surface":surface,"prompt_id":"p1","text":"hi"}),
        json!({"id":12,"cmd":"agent-session-prompt","surface":surface,"prompt_id":"content",
               "content":[{"type":"image","mimeType":"image/png","data":"eA=="}]}),
        json!({"id":4,"cmd":"agent-session-cancel","surface":surface}),
        json!({"id":5,"cmd":"agent-session-permission","surface":surface,
               "permission_id":"perm_attach","option_id":"allow"}),
        json!({"id":6,"cmd":"agent-session-detach","surface":surface}),
        json!({"id":7,"cmd":"agent-session-typing","surface":surface,"on":true}),
        json!({"id":8,"cmd":"agent-session-view","surface":surface,"visible":true}),
        json!({"id":9,"cmd":"agent-session-set-model","surface":surface,"model_id":"opus"}),
        json!({"id":10,"cmd":"agent-session-set-mode","surface":surface,"mode_id":"plan"}),
        json!({"id":11,"cmd":"agent-session-set-config","surface":surface,
               "config_id":"effort","value":"high"}),
        json!({"id":13,"cmd":"agent-session-context","surface":surface,"op":"get"}),
        json!({"id":14,"cmd":"agent-session-context","surface":surface,"op":"set",
               "scope":"user","text":"Read early."}),
        json!({"id":15,"cmd":"agent-session-btw","surface":surface,"question":"why?"}),
        json!({"id":15,"cmd":"agent-session-side","surface":surface,"live":true}),
    ]
}

#[test]
fn every_verb_is_refused_on_every_untrusted_connection() {
    let fake = FakeAcpmux::start("untrusted");
    let mux = mux_with(&fake, "asa-untrusted");
    let surface = agent_tab(&mux, Some(SESSION));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let websocket = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
    // A Unix connection that carries a paired install's link stamp is remote.
    mux.record_remote_check("inst_peer").unwrap();
    let stamped = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let peer = crate::remote_relay_state::LinkPeer {
        install: "inst_peer".into(),
        user: "42".into(),
        team: "team_a".into(),
    };
    mux.bind_remote_peer(stamped, &peer).unwrap();
    let unregistered = 999_999;
    for client in [websocket, stamped, unregistered] {
        for frame in every_verb(surface) {
            let handled =
                agent_session_attach::try_handle(&mux, client, &frame.to_string(), &writer);
            assert_eq!(handled, Some(true));
            let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
            assert_code(&reply, "agent_session.not_trusted");
        }
    }
    fake.no_connection();
}

// MARK: Scope

#[test]
fn attach_is_scoped_to_agent_tabs_of_this_store_with_a_session() {
    let fake = FakeAcpmux::start("scope");
    let mux = mux_with(&fake, "asa-scope");
    let (terminal, _) = terminal_pane(&mux);
    let unbound = agent_tab(&mux, None);
    let mut client = Client::connect(&mux, "scope");
    for surface in [terminal, unbound, 987_654] {
        assert_code(&attach(&mut client, surface), "agent_session.unknown_tab");
    }
    fake.no_connection();
}

#[test]
fn verbs_refuse_session_cwd_and_command_params() {
    let fake = FakeAcpmux::start("params");
    let mux = mux_with(&fake, "asa-params");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "params");
    for extra in [
        json!({"session":"other"}),
        json!({"sessionId":"other"}),
        json!({"cwd":"/"}),
        json!({"command":"rm -rf /"}),
        json!({"initial_command":"x"}),
        json!({"mcpServers":[]}),
        json!({"agent":"codex"}),
    ] {
        let mut frame = json!({"cmd":"agent-session-attach","surface":surface});
        for (key, value) in extra.as_object().unwrap() {
            frame[key] = value.clone();
        }
        assert_code(&client.request(frame), "agent_session.bad_request");
    }
    fake.no_connection();
}

#[test]
fn prompt_cancel_and_permission_need_an_attachment() {
    let fake = FakeAcpmux::start("unattached");
    let mux = mux_with(&fake, "asa-unattached");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "unattached");
    for frame in [
        json!({"cmd":"agent-session-prompt","surface":surface,"prompt_id":"p1","text":"hi"}),
        json!({"cmd":"agent-session-cancel","surface":surface}),
        json!({"cmd":"agent-session-events","surface":surface}),
        json!({"cmd":"agent-session-permission","surface":surface,
               "permission_id":"perm_attach","option_id":"allow"}),
    ] {
        assert_code(&client.request(frame), "agent_session.not_attached");
    }
    fake.no_connection();
}

/// cx-kpd0v: the agent pane asks for every kind it draws (9 since prompt
/// bookmarks); an attach with that list passes to acpmux unchanged, and a list
/// above the cap is still a bad request.
#[test]
fn attach_takes_the_agent_panes_whole_kind_list() {
    let fake = FakeAcpmux::start("kinds");
    let mux = mux_with(&fake, "asa-kinds");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "kinds");
    let kinds = json!([
        "transcript",
        "available_commands_update",
        "usage_update",
        "config_option_update",
        "bookmarks",
        "secret_request",
        "secret_decision",
        "session_offer",
        "session_offer_decision"
    ]);
    let too_many: Vec<String> =
        (0..33).map(|n| format!("kind_{}", "x".repeat(n % 5 + 1))).collect();
    let refused = client.request(json!({"cmd":"agent-session-attach","surface":surface,
                                        "kinds":too_many}));
    assert_code(&refused, "agent_session.bad_request");
    let reply = client.request(json!({"cmd":"agent-session-attach","surface":surface,
                                      "limit":400,"kinds":kinds}));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/attach"));
    assert_eq!(sent["params"]["kinds"], kinds);
}

// MARK: Streaming

#[test]
fn attach_replays_the_page_and_streams_live_records_of_that_session_only() {
    let mut fake = FakeAcpmux::start("stream");
    let mux = mux_with(&fake, "asa-stream");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "stream");
    let reply = attach(&mut client, surface);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"]["lastSeq"], json!(1));
    assert_eq!(reply["data"]["events"][0]["seq"], json!(1));
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/attach"));
    assert_eq!(sent["params"]["sessionId"], json!(SESSION), "session comes from the store record");
    assert_eq!(sent["params"]["eventStream"], json!(true));
    assert_eq!(sent["params"]["kinds"], json!(["transcript"]));
    assert_eq!(
        sent["params"]["waitLogs"],
        json!(false),
        "the open's page does not wait for a restarted daemon's log restore"
    );

    // The record acpmux sent before its reply follows the reply.
    let early = client.event(WAIT).expect("the early record");
    assert_eq!(early["event"], json!("agent-session-record"));
    assert_eq!(early["record"]["seq"], json!(2));

    fake.notify("_acpmux/event", json!({"sessionId":"acp_other","seq":9,"kind":"agent_message"}));
    fake.notify("_acpmux/session_changed", json!({"sessionId":"acp_other","kind":"status"}));
    fake.notify("_acpmux/event", json!({"sessionId":SESSION,"seq":3,"kind":"agent_message"}));
    fake.notify(
        "_acpmux/session_changed",
        json!({"sessionId":SESSION,"kind":"status","session":{"status":"idle"}}),
    );
    let event = client.event(WAIT).expect("a live record");
    assert_eq!(event["event"], json!("agent-session-record"));
    assert_eq!(event["surface"], json!(surface));
    assert_eq!(event["record"]["seq"], json!(3), "a record of another session is not forwarded");
    let changed = client.event(WAIT).expect("the session's status change");
    assert_eq!(changed["event"], json!("agent-session-changed"));
    assert_eq!(changed["change"]["session"]["status"], json!("idle"));
    assert!(client.event(Duration::from_millis(200)).is_none(), "nothing of other sessions");
}

#[test]
fn a_rebound_tab_ends_its_attachment_at_the_next_record() {
    let mut fake = FakeAcpmux::start("rebound");
    let mux = mux_with(&fake, "asa-rebound");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "rebound");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = client.event(WAIT).expect("the early record");
    run(
        &mux,
        json!({"cmd":"bind-conversation-tab-session","surface":surface,
               "session":"acp_session_2","expected_session":SESSION}),
    );
    fake.notify("_acpmux/event", json!({"sessionId":SESSION,"seq":3,"kind":"agent_message"}));
    let closed = client.event(WAIT).expect("a close");
    assert_eq!(
        closed,
        json!({"event":"agent-session-closed","surface":surface,"reason":"detached"})
    );
}

#[test]
fn pages_are_bounded_in_bytes_keeping_the_records_next_to_the_cursor() {
    use super::agent_session_attach::{MAX_PAGE_BYTES, bound_page};
    let big = "x".repeat(MAX_PAGE_BYTES / 3);
    let events: Vec<Value> = (1..=5).map(|seq| json!({"seq": seq, "text": big})).collect();
    let page = json!({"events": events, "hasMore": false});
    let seqs = |page: &Value| {
        page["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["seq"].as_u64().unwrap())
            .collect::<Vec<_>>()
    };
    let newest = bound_page(page.clone(), true);
    assert_eq!(seqs(&newest), vec![4, 5]);
    assert_eq!(newest["hasMore"], json!(true));
    assert_eq!(seqs(&bound_page(page, false)), vec![1, 2]);
}

#[test]
fn events_pages_on_the_attachment_for_a_replay_after_a_gap() {
    let fake = FakeAcpmux::start("events");
    let mux = mux_with(&fake, "asa-events");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "events");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let reply = client.request(json!({"cmd":"agent-session-events","surface":surface,
                                      "after_seq":1,"limit":100000}));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/events"));
    assert_eq!(sent["params"]["sessionId"], json!(SESSION));
    assert_eq!(sent["params"]["afterSeq"], json!(1));
    assert_eq!(sent["params"]["limit"], json!(500), "pages are bounded");
}

#[test]
fn lag_and_acpmux_exit_end_the_attachment_with_a_reason() {
    let mut fake = FakeAcpmux::start("lag");
    let mux = mux_with(&fake, "asa-lag");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "lag");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = client.event(WAIT).expect("the early record");
    fake.notify("_acpmux/lagged", json!({"dropped": 3}));
    let closed = client.event(WAIT).expect("a close");
    assert_eq!(closed, json!({"event":"agent-session-closed","surface":surface,"reason":"lagged"}));
    // Attach again (the replay path), then acpmux goes away.
    let mut fake2 = FakeAcpmux::start("lag2");
    mux.set_acpmux_socket(Some(fake2.socket.clone()));
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = client.event(WAIT).expect("the early record");
    fake2.hang_up();
    let closed = client.event(WAIT).expect("a close");
    assert_eq!(closed["reason"], json!("acpmux_closed"));
}

// MARK: Driving the session

#[test]
fn a_prompt_is_one_text_block_on_the_pinned_session() {
    let fake = FakeAcpmux::start("prompt");
    let mux = mux_with(&fake, "asa-prompt");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "prompt");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let reply = client.request(json!({"cmd":"agent-session-prompt","surface":surface,
                                      "prompt_id":"prompt-1","text":"hello there"}));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"]["turn_id"], json!("turn_1"));
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("session/prompt"));
    assert_eq!(
        sent["params"],
        json!({"sessionId":SESSION,"prompt":[{"type":"text","text":"hello there"}],
               "_meta":{"acpmux":{"promptId":"prompt-1"}}})
    );
    for bad in [
        json!({"prompt_id":"p 2","text":"x"}),
        json!({"prompt_id":"p2","text":"   "}),
        json!({"prompt_id":"p2","text":"x".repeat(agent_session_attach::MAX_PROMPT_BYTES + 1)}),
        json!({"prompt_id":"p2","text":"x","prompt":[{"type":"resource_link","uri":"file:///etc"}]}),
    ] {
        let mut frame = json!({"cmd":"agent-session-prompt","surface":surface});
        for (key, value) in bad.as_object().unwrap() {
            frame[key] = value.clone();
        }
        assert_code(&client.request(frame), "agent_session.bad_request");
    }
    fake.no_frame();
}

#[test]
fn a_prompt_acpmux_accepts_after_a_cold_start_is_sent_not_timed_out() {
    // HQ run 42617701877's phone-start row: the first prompt of a chat started a moment before
    // was accepted after more than 5 s, and the phone was told `agent_session.timeout`.
    let late = Duration::from_secs(6);
    assert!(late < agent_session_attach::PROMPT_ACCEPT_TIMEOUT);
    let fixture = Fixture { accept_after: Some(late), ..Fixture::default() };
    let fake = FakeAcpmux::start_with("prompt-late", fixture);
    let mux = mux_with(&fake, "asa-prompt-late");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "prompt-late");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let id = client.send(json!({"cmd":"agent-session-prompt","surface":surface,
                                "prompt_id":"prompt-late","text":"hello"}));
    let reply = client.answer_within(id, late + WAIT);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"]["turn_id"], json!("turn_1"));
}

#[test]
fn a_content_prompt_preserves_order_bytes_and_pasted_metadata_on_the_pinned_session() {
    let fake = FakeAcpmux::start("prompt-content");
    let mux = mux_with(&fake, "asa-prompt-content");
    let surface = agent_tab(&mux, Some(SESSION));
    let identity = run(&mux, json!({"cmd":"identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| { value == agent_session_attach::AGENT_SESSION_CONTENT_CAPABILITY })
    );
    let mut client = Client::connect(&mux, "prompt-content");
    assert_eq!(attach(&mut client, surface)["ok"], true);
    let _ = fake.frame();
    let image = json!({"type":"image", "mimeType":"image/png", "name":"shot.png",
        "data":"AAAA".repeat(agent_session_attach::MAX_PROMPT_BYTES / 4 + 1)});
    let mixed = json!([
        {"type":"text", "text":"before"}, image,
        {"type":"text", "text":"pasted", "_meta":{"cmux":{"pasted":true}}},
        {"type":"document", "mimeType":"application/pdf", "data":"JVBERi0=", "name":"a.pdf"},
        {"type":"audio", "mimeType":"audio/wav", "data":"UklGRg=="},
        {"type":"resource_link", "uri":"file:///home/cmux/work/shot.png", "name":"shot.png"},
        {"type":"text", "text":"after"}
    ]);
    let spaced = json!([
        {"type":"text", "text":" "}, image, {"type":"text", "text":" "}, image,
        {"type":"text", "text":"\n"}
    ]);
    for (id, content) in
        [("mixed", mixed), ("attachment-only", json!([image])), ("spaced-images", spaced)]
    {
        let reply = client.request(json!({"cmd":"agent-session-prompt", "surface":surface,
            "prompt_id":id, "content":content}));
        assert_eq!(reply["ok"], true, "{reply}");
        assert_eq!(
            fake.frame()["params"],
            json!({"sessionId":SESSION, "prompt":content,
            "_meta":{"acpmux":{"promptId":id}}})
        );
    }
    for invalid in [
        json!({"content":[]}),
        json!({"content":[null]}),
        json!({"content":[{"type":"text", "text":" "}]}),
        json!({"content":[{"type":"text", "text":""}, {"type":"text", "text":" \n"}]}),
        json!({"text":"legacy", "content":[{"type":"text", "text":"other"}]}),
        json!({"content":[{"type":"image", "mimeType":"image/png", "data":""}]}),
        json!({"content":[{"type":"resource_link", "uri":""}]}),
        json!({"content":[{"type":"text", "text":"x", "_meta":{"acpmux":{"author":"owner"}}}]}),
        json!({"content":[{"type":"command", "text":"x"}]}),
        json!({"content":[{"type":"text", "text":"x", "sessionId":"other"}]}),
    ] {
        let mut frame = json!({"cmd":"agent-session-prompt", "surface":surface, "prompt_id":"bad"});
        for (key, value) in invalid.as_object().unwrap() {
            frame[key] = value.clone();
        }
        assert_code(&client.request(frame), "agent_session.bad_request");
    }
    fake.no_frame();
}

#[test]
fn cancel_goes_to_the_pinned_session() {
    let fake = FakeAcpmux::start("cancel");
    let mux = mux_with(&fake, "asa-cancel");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "cancel");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    assert_eq!(
        client.request(json!({"cmd":"agent-session-cancel","surface":surface}))["ok"],
        json!(true)
    );
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("session/cancel"));
    assert_eq!(sent["params"], json!({"sessionId": SESSION}));
    assert!(sent.get("id").is_none(), "cancel is a notification");
}

// MARK: Sign-in

/// A Cloud chat's own sign-in (`agent-session-login-v1`): each step goes to acpmux's
/// `_acpmux/agent_login/*` with the tab's own session where it names one, and acpmux's refusal
/// comes back as an answer with its reason, so the app's card says why.
#[test]
fn login_steps_go_to_acpmux_on_the_pinned_session() {
    let fake = FakeAcpmux::start("login");
    let mux = mux_with(&fake, "asa-login");
    let identity = run(&mux, json!({"cmd":"identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == agent_session_attach::AGENT_SESSION_LOGIN_CAPABILITY)
    );
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "login");
    assert_code(
        &client.request(json!({"cmd":"agent-session-login","surface":surface,"op":"start",
                               "agent":"claude"})),
        "agent_session.not_attached",
    );
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    for (frame, method, params, data) in [
        (
            json!({"cmd":"agent-session-login","surface":surface,"op":"start","agent":"claude"}),
            "_acpmux/agent_login/start",
            json!({"agent": "claude", "sessionId": SESSION}),
            json!({"loginId": "login_1", "url": "https://claude.ai/oauth/authorize",
                   "needsCode": true}),
        ),
        (
            json!({"cmd":"agent-session-login","surface":surface,"op":"finish",
                   "login_id":"login_1","code":"wrong"}),
            "_acpmux/agent_login/finish",
            json!({"loginId": "login_1", "sessionId": SESSION, "code": "wrong"}),
            json!({"refused": {"reason": "bad_code"}}),
        ),
        (
            json!({"cmd":"agent-session-login","surface":surface,"op":"finish",
                   "login_id":"login_1","code":"abc#def"}),
            "_acpmux/agent_login/finish",
            json!({"loginId": "login_1", "sessionId": SESSION, "code": "abc#def"}),
            json!({"signedIn": true, "restarted": true}),
        ),
        (
            json!({"cmd":"agent-session-login","surface":surface,"op":"api_key",
                   "agent":"codex","key":"sk-test"}),
            "_acpmux/agent_login/api_key",
            json!({"agent": "codex", "key": "sk-test", "sessionId": SESSION}),
            json!({"saved": true, "restarted": true}),
        ),
        // Gemini saves a key; Grok runs its device flow (acpmux words each refusal).
        (
            json!({"cmd":"agent-session-login","surface":surface,"op":"api_key",
                   "agent":"gemini","key":"AIzaTest"}),
            "_acpmux/agent_login/api_key",
            json!({"agent": "gemini", "key": "AIzaTest", "sessionId": SESSION}),
            json!({"saved": true, "restarted": true}),
        ),
        (
            json!({"cmd":"agent-session-login","surface":surface,"op":"start","agent":"grok"}),
            "_acpmux/agent_login/start",
            json!({"agent": "grok", "sessionId": SESSION}),
            json!({"loginId": "login_2", "url": "https://accounts.x.ai/device",
                   "userCode": "WDJB-MJHT", "needsCode": false}),
        ),
        (
            json!({"cmd":"agent-session-login","surface":surface,"op":"cancel",
                   "login_id":"login_1"}),
            "_acpmux/agent_login/cancel",
            json!({"loginId": "login_1", "sessionId": SESSION}),
            json!({}),
        ),
    ] {
        let reply = client.request(frame);
        assert_eq!(reply["ok"], json!(true), "{reply}");
        assert_eq!(reply["data"], data, "{reply}");
        let sent = fake.frame();
        assert_eq!(sent["method"], json!(method));
        assert_eq!(sent["params"], params, "the session is the tab's own; nothing else is passed");
    }
    for bad in [
        json!({"cmd":"agent-session-login","surface":surface,"op":"start"}),
        json!({"cmd":"agent-session-login","surface":surface,"op":"start","agent":"opencode"}),
        json!({"cmd":"agent-session-login","surface":surface,"op":"finish"}),
        json!({"cmd":"agent-session-login","surface":surface,"op":"api_key","agent":"claude"}),
        json!({"cmd":"agent-session-login","surface":surface,"op":"run","agent":"claude"}),
        json!({"cmd":"agent-session-login","surface":surface,"op":"start","agent":"claude",
               "sessionId":"acp_other"}),
        json!({"cmd":"agent-session-login","surface":surface,"op":"finish","login_id":"l",
               "code":"x".repeat(5000)}),
    ] {
        assert_code(&client.request(bad), "agent_session.bad_request");
    }
    fake.no_frame();
}

// MARK: Side question

/// The composer's `/btw <question>` on a Cloud chat (`agent-session-btw-v1`): acpmux's inline
/// `_acpmux/btw` on the tab's own session, its `{text}` back unchanged, its refusal as an answer
/// with only its reason. Nothing but the question passes.
#[test]
fn a_side_question_goes_inline_to_the_pinned_session() {
    let fake = FakeAcpmux::start("btw");
    let mux = mux_with(&fake, "asa-btw");
    let identity = run(&mux, json!({"cmd":"identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == agent_session_attach::AGENT_SESSION_BTW_CAPABILITY)
    );
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "btw");
    assert_code(
        &client.request(json!({"cmd":"agent-session-btw","surface":surface,"question":"why?"})),
        "agent_session.not_attached",
    );
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    for (question, sent, data) in [
        (" why did it flake? ", "why did it flake?", json!({"text": "It flaked on a timeout."})),
        (
            "no read-only mode",
            "no read-only mode",
            json!({"refused": {"reason": "btw.no_read_only_mode"}}),
        ),
        ("untrusted folder", "untrusted folder", json!({"refused": {"reason": "trust.pending"}})),
    ] {
        let reply = client
            .request(json!({"cmd":"agent-session-btw","surface":surface,"question":question}));
        assert_eq!(reply["ok"], json!(true), "{reply}");
        assert_eq!(reply["data"], data, "{reply}");
        let frame = fake.frame();
        assert_eq!(frame["method"], json!("_acpmux/btw"));
        assert_eq!(
            frame["params"],
            json!({"sessionId": SESSION, "question": sent, "inline": true,
                   "_meta": {"acpmux": {"via": "app"}}}),
            "the tab's own session, inline, held to the app's folder-trust gate; nothing else"
        );
    }
    // An older acpmux opened a lasting side session instead: it is ended, and the answer says so.
    let reply = client
        .request(json!({"cmd":"agent-session-btw","surface":surface,"question":"old acpmux"}));
    assert_eq!(reply["data"], json!({"refused": {"reason": "unsupported"}}), "{reply}");
    assert_eq!(fake.frame()["method"], json!("_acpmux/btw"));
    let kill = fake.frame();
    assert_eq!(kill["method"], json!("_acpmux/kill"));
    assert_eq!(kill["params"], json!({"sessionId": "acp_side", "purge": true}));
    for bad in [
        json!({"cmd":"agent-session-btw","surface":surface}),
        json!({"cmd":"agent-session-btw","surface":surface,"question":"  "}),
        json!({"cmd":"agent-session-btw","surface":surface,"question":"x".repeat(17 * 1024)}),
        json!({"cmd":"agent-session-btw","surface":surface,"question":"why?","sessionId":"acp_other"}),
        json!({"cmd":"agent-session-btw","surface":surface,"question":"why?","model":"opus"}),
        json!({"cmd":"agent-session-btw","surface":surface,"question":"why?","inline":false}),
        json!({"cmd":"agent-session-btw","surface":surface,"question":"why?",
               "_meta":{"acpmux":{"via":"app"}}}),
    ] {
        assert_code(&client.request(bad), "agent_session.bad_request");
    }
    fake.no_frame();
}

// MARK: Settings

/// A chat on another machine: the person's model, mode and option picks go to acpmux on the tab's
/// own session, and acpmux's answer comes back unchanged (`agent-session-settings-v1`).
#[test]
fn model_mode_and_option_picks_go_to_the_pinned_session() {
    let fake = FakeAcpmux::start("settings");
    let mux = mux_with(&fake, "asa-settings");
    let identity = run(&mux, json!({"cmd":"identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == agent_session_attach::AGENT_SESSION_SETTINGS_CAPABILITY)
    );
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "settings");
    for frame in [
        json!({"cmd":"agent-session-set-model","surface":surface,"model_id":"claude-opus-5-5"}),
        json!({"cmd":"agent-session-set-mode","surface":surface,"mode_id":"acceptEdits"}),
    ] {
        assert_code(&client.request(frame), "agent_session.not_attached");
    }
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    for (frame, method, params) in [
        (
            json!({"cmd":"agent-session-set-model","surface":surface,
                   "model_id":"claude-opus-5-5[1m]"}),
            "session/set_model",
            json!({"sessionId": SESSION, "modelId": "claude-opus-5-5[1m]"}),
        ),
        (
            json!({"cmd":"agent-session-set-mode","surface":surface,"mode_id":"acceptEdits"}),
            "session/set_mode",
            json!({"sessionId": SESSION, "modeId": "acceptEdits"}),
        ),
        (
            json!({"cmd":"agent-session-set-config","surface":surface,
                   "config_id":"effort","value":"high"}),
            "session/set_config_option",
            json!({"sessionId": SESSION, "configId": "effort", "value": "high"}),
        ),
    ] {
        let reply = client.request(frame);
        assert_eq!(reply["ok"], json!(true), "{reply}");
        let sent = fake.frame();
        assert_eq!(sent["method"], json!(method));
        assert_eq!(sent["params"], params, "the session is the tab's own; nothing else is passed");
        if method == "session/set_config_option" {
            assert_eq!(
                reply["data"],
                json!({"configOptions": [{"id": "effort", "currentValue": "high"}]}),
                "acpmux's answer goes back unchanged"
            );
        }
    }
    for bad in [
        json!({"cmd":"agent-session-set-model","surface":surface}),
        json!({"cmd":"agent-session-set-model","surface":surface,"model_id":""}),
        json!({"cmd":"agent-session-set-model","surface":surface,"model_id":"--dangerously"}),
        json!({"cmd":"agent-session-set-model","surface":surface,"model_id":"a b"}),
        json!({"cmd":"agent-session-set-model","surface":surface,"model_id":"x".repeat(257)}),
        json!({"cmd":"agent-session-set-model","surface":surface,"model_id":"opus",
               "sessionId":"acp_other"}),
        json!({"cmd":"agent-session-set-mode","surface":surface,"mode_id":7}),
        json!({"cmd":"agent-session-set-mode","surface":surface,"mode_id":"plan",
               "_meta":{"cmuxGesture":"t"}}),
        json!({"cmd":"agent-session-set-config","surface":surface,"config_id":"effort"}),
        json!({"cmd":"agent-session-set-config","surface":surface,"config_id":"effort",
               "value":true}),
        json!({"cmd":"agent-session-set-config","surface":surface,"config_id":"effort",
               "value":"$(id)"}),
    ] {
        assert_code(&client.request(bad), "agent_session.bad_request");
    }
    fake.no_frame();
}

// MARK: Presence

/// Chat multiplayer (hq#4389): the person's typing and view go to acpmux on the tab's own session,
/// and who is in the chat comes back as `agent-session-presence`, for that session only.
#[test]
fn typing_and_view_go_to_the_pinned_session_and_presence_streams_back() {
    let mut fake = FakeAcpmux::start("presence");
    let mux = mux_with(&fake, "asa-presence");
    let identity = run(&mux, json!({"cmd":"identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == agent_session_attach::AGENT_SESSION_PRESENCE_CAPABILITY)
    );
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "presence");
    let info = client.request(json!({"cmd":"set-client-info","name":"presence test",
        "capabilities":[agent_session_attach::AGENT_SESSION_PRESENCE_CAPABILITY]}));
    assert_eq!(info["ok"], json!(true), "{info}");
    let attached = attach(&mut client, surface);
    let _ = fake.frame();
    let _ = client.event(WAIT).expect("the early record");
    assert_eq!(attached["ok"], json!(true), "{attached}");
    for (frame, method, params) in [
        (
            json!({"cmd":"agent-session-typing","surface":surface,"on":true}),
            "_acpmux/typing",
            json!({"sessionId": SESSION, "on": true}),
        ),
        (
            json!({"cmd":"agent-session-view","surface":surface,"visible":false}),
            "_acpmux/view",
            json!({"sessionId": SESSION, "visible": false}),
        ),
    ] {
        let reply = client.request(frame);
        assert_eq!(reply["ok"], json!(true), "{reply}");
        let sent = fake.frame();
        assert_eq!(sent["method"], json!(method));
        assert_eq!(sent["params"], params, "the session is the tab's own; nothing else is passed");
    }
    for bad in [
        json!({"cmd":"agent-session-typing","surface":surface}),
        json!({"cmd":"agent-session-typing","surface":surface,"on":"yes"}),
        json!({"cmd":"agent-session-typing","surface":surface,"on":true,"sessionId":"acp_other"}),
        json!({"cmd":"agent-session-view","surface":surface,"visible":true,
               "_meta":{"acpmux":{"author":{"id":"tailnet:x","name":"x"}}}}),
    ] {
        assert_code(&client.request(bad), "agent_session.bad_request");
    }
    fake.no_frame();
    let people = json!({"sessionId": SESSION, "participants": [
        {"id": "owner", "name": "Owner", "devices": 2, "viewing": true, "typing": false}]});
    fake.notify("_acpmux/presence", json!({"sessionId": "acp_other", "participants": []}));
    fake.notify("_acpmux/presence", people.clone());
    let event = client.event(WAIT).expect("the chat's presence");
    assert_eq!(event["event"], json!("agent-session-presence"));
    assert_eq!(event["surface"], json!(surface));
    assert_eq!(event["presence"], people);
    assert!(client.event(Duration::from_millis(200)).is_none(), "no other chat's presence");
    // Past acpmux's rate (the fake took one typing call above): the attachment's bound.
    let again = json!({"cmd":"agent-session-typing","surface":surface,"on":true});
    assert_eq!(client.request(again.clone())["ok"], json!(true));
    assert_eq!(fake.frame()["method"], json!("_acpmux/typing"));
    assert_code(&client.request(again), "agent_session.limit");
}

/// An app from before `agent-session-presence-v1` ends its attachment on an `agent-session-*`
/// event it does not know, so a connection that did not echo the capability never gets one.
#[test]
fn presence_reaches_only_a_connection_that_asked_for_it() {
    let mut fake = FakeAcpmux::start("presence-legacy");
    let mux = mux_with(&fake, "asa-presence-legacy");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "presence-legacy");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let _ = client.event(WAIT).expect("the early record");
    fake.notify("_acpmux/presence", json!({"sessionId": SESSION, "participants": []}));
    fake.notify("_acpmux/event", json!({"sessionId": SESSION, "seq": 3, "kind": "agent_message"}));
    let next = client.event(WAIT).expect("the record after the presence");
    assert_eq!(next["event"], json!("agent-session-record"), "no presence event: {next}");
    assert!(client.event(Duration::from_millis(200)).is_none());
}

#[test]
fn typing_needs_an_attachment() {
    let fake = FakeAcpmux::start("typing-unattached");
    let mux = mux_with(&fake, "asa-typing-unattached");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "typing-unattached");
    for frame in [
        json!({"cmd":"agent-session-typing","surface":surface,"on":true}),
        json!({"cmd":"agent-session-view","surface":surface,"visible":true}),
    ] {
        assert_code(&client.request(frame), "agent_session.not_attached");
    }
    fake.no_connection();
}

#[test]
fn permission_answers_only_announced_requests_once_and_never_by_itself() {
    let mut fake = FakeAcpmux::start("perm");
    let mux = mux_with(&fake, "asa-perm");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "perm");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let answer = |client: &mut Client, permission: &str| {
        client.request(json!({"cmd":"agent-session-permission","surface":surface,
                              "permission_id":permission,"option_id":"allow"}))
    };
    assert_code(&answer(&mut client, "perm_never_asked"), "agent_session.unknown_permission");
    let _ = client.event(WAIT).expect("the early record");
    fake.notify(
        "_acpmux/permission_pending",
        json!({"sessionId":SESSION,"permissionId":"perm_live",
                                                       "options":[{"optionId":"allow"}]}),
    );
    let shown = client.event(WAIT).expect("the request is shown to the user");
    assert_eq!(shown["event"], json!("agent-session-permission"));
    assert_eq!(shown["request"]["permissionId"], json!("perm_live"));
    // The daemon did not answer it by itself.
    fake.no_frame();
    assert_eq!(answer(&mut client, "perm_live")["ok"], json!(true));
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/permission_respond"));
    assert_eq!(
        sent["params"],
        json!({"sessionId":SESSION,"permissionId":"perm_live","optionId":"allow"})
    );
    assert_code(&answer(&mut client, "perm_live"), "agent_session.unknown_permission");
    // A request pending at attach time is answerable too.
    assert_eq!(answer(&mut client, "perm_attach")["ok"], json!(true));
}

/// cx-0q7o slice 2b: an answer from the person's app on another machine
/// carries the person's decision proof (and who answered) to acpmux
/// unchanged, as `_meta.acpmux`; acpmux decides, never this daemon. A proof
/// field that is not 64 lowercase hex characters is a bad request.
#[test]
fn a_permission_answer_carries_the_decision_proof_to_acpmux_unchanged() {
    let mut fake = FakeAcpmux::start("proof");
    let mux = mux_with(&fake, "asa-proof");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "proof");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let _ = client.event(WAIT).expect("the early record");
    fake.notify(
        "_acpmux/permission_pending",
        json!({"sessionId":SESSION,"permissionId":"perm_live","decisionNonce":"n",
               "personInstance":"i","options":[{"optionId":"allow"}]}),
    );
    let shown = client.event(WAIT).expect("the request is shown to the user");
    assert_eq!(shown["request"]["decisionNonce"], json!("n"), "{shown}");
    assert_eq!(shown["request"]["personInstance"], json!("i"), "{shown}");
    let nonce = "ab".repeat(32);
    let proof = "cd".repeat(32);
    let malformed = client.request(json!({"cmd":"agent-session-permission","surface":surface,
        "permission_id":"perm_live","option_id":"allow","decision_nonce":nonce,
        "person_decision":"not-hex"}));
    assert_code(&malformed, "agent_session.bad_request");
    let bad_device = client.request(json!({"cmd":"agent-session-permission","surface":surface,
        "permission_id":"perm_live","option_id":"allow","decision_nonce":nonce,
        "person_decision":proof,"answered_by":{"device":"my phone!","feed_item":"feed-1"}}));
    assert_code(&bad_device, "agent_session.bad_request");
    fake.no_frame();
    let reply = client.request(json!({"cmd":"agent-session-permission","surface":surface,
        "permission_id":"perm_live","option_id":"allow","decision_nonce":nonce,
        "person_decision":proof,"answered_by":{"device":"iphone-1","feed_item":"feed-1"}}));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/permission_respond"));
    assert_eq!(
        sent["params"],
        json!({"sessionId":SESSION,"permissionId":"perm_live","optionId":"allow",
               "_meta":{"acpmux":{"decisionNonce":nonce,"personDecision":proof,
                                  "answeredBy":{"device":"iphone-1","feedItem":"feed-1"}}}})
    );
}

// MARK: Lifecycle and bounds

#[test]
fn detach_and_disconnect_close_the_acpmux_link() {
    let fake = FakeAcpmux::start("detach");
    let mux = mux_with(&fake, "asa-detach");
    let first = agent_tab(&mux, Some(SESSION));
    let second = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "detach");
    assert_eq!(attach(&mut client, first)["ok"], json!(true));
    assert_eq!(mux.control_clients.agent_sessions.attachment_count(), 1);
    assert_eq!(
        client.request(json!({"cmd":"agent-session-detach","surface":first}))["ok"],
        json!(true)
    );
    assert_eq!(mux.control_clients.agent_sessions.attachment_count(), 0);
    assert_eq!(fake.frame()["method"], json!("_acpmux/attach"));
    assert_eq!(attach(&mut client, second)["ok"], json!(true));
    drop(client);
    let deadline = Instant::now() + WAIT;
    while mux.control_clients.agent_sessions.attachment_count() != 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(mux.control_clients.agent_sessions.attachment_count(), 0);
}

#[test]
fn attachments_per_connection_are_bounded() {
    let fake = FakeAcpmux::start("limit");
    let mux = mux_with(&fake, "asa-limit");
    let mut client = Client::connect(&mux, "limit");
    for _ in 0..MAX_ATTACHMENTS_PER_CLIENT {
        let surface = agent_tab(&mux, Some(SESSION));
        assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    }
    let surface = agent_tab(&mux, Some(SESSION));
    assert_code(&attach(&mut client, surface), "agent_session.limit");
}

#[test]
fn a_closed_tab_ends_its_attachment() {
    let fake = FakeAcpmux::start("closed");
    let mux = mux_with(&fake, "asa-closed");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "closed");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    run(&mux, json!({"cmd":"close-surface","surface":surface}));
    let reply = client.request(json!({"cmd":"agent-session-prompt","surface":surface,
                                      "prompt_id":"p1","text":"hi"}));
    assert_code(&reply, "agent_session.unknown_tab");
    let mut closed = client.event(WAIT).expect("a close");
    if closed["event"] == json!("agent-session-record") {
        closed = client.event(WAIT).expect("a close");
    }
    assert_eq!(closed["reason"], json!("detached"));
    fake.no_frame();
}

// MARK: Scope (security review)

#[test]
fn a_record_that_names_a_session_only_by_prefix_is_not_attached() {
    let fake = FakeAcpmux::start("prefix");
    let mux = mux_with(&fake, "asa-prefix");
    // acpmux resolves a unique prefix; the fake resolves anything to SESSION.
    let surface = agent_tab(&mux, Some("acp_sess"));
    let mut client = Client::connect(&mux, "prefix");
    assert_code(&attach(&mut client, surface), "agent_session.unknown_tab");
    assert_eq!(mux.control_clients.agent_sessions.attachment_count(), 0);
}

#[test]
fn another_connection_cannot_drive_an_attachment() {
    let fake = FakeAcpmux::start("other");
    let mux = mux_with(&fake, "asa-other");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "owner");
    assert_eq!(attach(&mut owner, surface)["ok"], json!(true));
    let _ = fake.frame();
    let mut stranger = Client::connect(&mux, "stranger");
    for frame in every_verb(surface).into_iter().skip(1).take(4) {
        let mut frame = frame;
        frame.as_object_mut().unwrap().remove("id");
        assert_code(&stranger.request(frame), "agent_session.not_attached");
    }
    fake.no_frame();
}

#[test]
fn every_verb_refuses_session_cwd_command_and_meta_params() {
    let fake = FakeAcpmux::start("allparams");
    let mux = mux_with(&fake, "asa-allparams");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "allparams");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    for extra in [
        json!({"sessionId":"other"}),
        json!({"cwd":"/"}),
        json!({"command":"x"}),
        json!({"_meta":{"acpmux":{"steer":true}}}),
        json!({"prompt":[{"type":"text","text":"x"}]}),
    ] {
        for mut frame in every_verb(surface).into_iter().skip(1).take(4) {
            frame.as_object_mut().unwrap().remove("id");
            for (key, value) in extra.as_object().unwrap() {
                frame[key] = value.clone();
            }
            assert_code(&client.request(frame), "agent_session.bad_request");
        }
    }
    fake.no_frame();
}

#[test]
fn a_permission_of_another_session_is_not_answerable() {
    let mut fake = FakeAcpmux::start("otherperm");
    let mux = mux_with(&fake, "asa-otherperm");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "otherperm");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let _ = client.event(WAIT).expect("the early record");
    fake.notify(
        "_acpmux/permission_pending",
        json!({"sessionId":"acp_other","permissionId":"perm_other","options":[]}),
    );
    assert!(client.event(Duration::from_millis(200)).is_none(), "not shown");
    let reply = client.request(json!({"cmd":"agent-session-permission","surface":surface,
                                      "permission_id":"perm_other","option_id":"allow"}));
    assert_code(&reply, "agent_session.unknown_permission");
    fake.no_frame();
}

// MARK: Side chat

/// New side chat and `/side [prompt]` of a Cloud chat (agent_session_side.rs): acpmux on the
/// chat's machine forks the tab's own session, tags the fork its side chat and prompts it there.
#[test]
fn a_side_chat_forks_the_pinned_session_tags_it_and_prompts_it() {
    let fake = FakeAcpmux::start("side");
    let mux = mux_with(&fake, "asa-side");
    let identity = run(&mux, json!({"cmd":"identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == agent_session_attach::AGENT_SESSION_SIDE_CAPABILITY)
    );
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "side");
    assert_code(
        &client.request(json!({"cmd":"agent-session-side","surface":surface,"live":true})),
        "agent_session.not_attached",
    );
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    // A finished chat forks through its turn; with no prompt, none is sent.
    let reply =
        client.request(json!({"cmd":"agent-session-side","surface":surface,"through_seq":4}));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"], json!({"sessionId": "acp_side_1", "prompted": false}));
    let fork = fake.frame();
    assert_eq!(fork["method"], json!("acp.session.fork"));
    assert_eq!(fork["params"], json!({"sessionId": SESSION, "throughSeq": 4}));
    let tag = fake.frame();
    assert_eq!(tag["method"], json!("_acpmux/side"));
    assert_eq!(tag["params"], json!({"sessionId": "acp_side_1", "chat": SESSION}));
    fake.no_frame();
    // A working chat forks as it is now, and `/side <prompt>` prompts the side chat, not the chat.
    let reply = client.request(json!({"cmd":"agent-session-side","surface":surface,"live":true,
                                      "prompt":"Try it in Rust","prompt_id":"side-p1"}));
    assert_eq!(reply["data"], json!({"sessionId": "acp_side_1", "prompted": true}), "{reply}");
    assert_eq!(fake.frame()["params"], json!({"sessionId": SESSION, "live": true}));
    assert_eq!(fake.frame()["method"], json!("_acpmux/side"));
    let prompt = fake.frame();
    assert_eq!(prompt["method"], json!("session/prompt"));
    assert_eq!(
        prompt["params"],
        json!({"sessionId": "acp_side_1", "prompt": [{"type": "text", "text": "Try it in Rust"}],
               "_meta": {"acpmux": {"promptId": "side-p1"}}})
    );
    fake.no_frame();
    // A fork acpmux would not tag is taken back: no untagged copy stays in the lists.
    let reply =
        client.request(json!({"cmd":"agent-session-side","surface":surface,"through_seq":7}));
    assert_code(&reply, "agent_session.refused");
    let _ = fake.frame();
    let _ = fake.frame();
    let kill = fake.frame();
    assert_eq!(kill["method"], json!("_acpmux/kill"));
    assert_eq!(
        kill["params"],
        json!({"sessionId": "acp_untaggable", "purge": true, "cancelFork": true})
    );
    for bad in [
        json!({"cmd":"agent-session-side","surface":surface}),
        json!({"cmd":"agent-session-side","surface":surface,"through_seq":0}),
        json!({"cmd":"agent-session-side","surface":surface,"through_seq":4,"live":true}),
        json!({"cmd":"agent-session-side","surface":surface,"live":true,"prompt":"hi"}),
        json!({"cmd":"agent-session-side","surface":surface,"live":true,"prompt":" ","prompt_id":"p"}),
        json!({"cmd":"agent-session-side","surface":surface,"live":true,"sessionId":"acp_other"}),
        json!({"cmd":"agent-session-side","surface":surface,"live":true,"cwd":"/"}),
    ] {
        assert_code(&client.request(bad), "agent_session.bad_request");
    }
    fake.no_frame();
}

/// A phone on the Cloud carrier never gets a side chat with a looser asking policy than its chat:
/// its channel reaches only hostd's adapter commands (`phone_carrier.rs`, cmux-next-ios/SECURITY.md),
/// and `agent-session-side` is not one of them (a side chat is a fork, which that channel is
/// refused). The side chat is refused `remote_denied` and nothing reaches acpmux. Should a phone's
/// side chat be allowed later, `submit_prompt` already marks its first prompt `via: cloud-mobile`.
#[test]
fn a_phones_side_chat_is_refused_on_its_carrier_channel() {
    let fake = FakeAcpmux::start("side-phone");
    let mux = mux_with(&fake, "asa-side-phone");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "side-phone");
    assert_eq!(client.request(json!({"cmd":"carrier-role","vmk":"owner"}))["ok"], json!(true));
    let info = client.request(json!({"cmd":"set-client-info","kind":"ios",
        "capabilities":["cloud-mobile-chat-v1","conversation-tabs-v1","agent-session-tabs-v1"]}));
    assert_eq!(info["ok"], json!(true), "{info}");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let reply = client.request(json!({"cmd":"agent-session-side","surface":surface,"live":true,
                                      "prompt":"Try it in Rust","prompt_id":"side-p2"}));
    assert_code(&reply, "remote_denied");
    fake.no_frame();
}
