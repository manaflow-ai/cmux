//! ACP schema conformance: every standard ACP frame on a recorded conversation with the
//! daemon, and every `session/update` of the recorded worked turn (`tests/sim/worked_turn.json`),
//! validates against the upstream ACP v1 schema vendored in `schema/acp/v1/` (its tag and
//! sha256 in `schema/acp/v1/PIN`; `scripts/acp-schema.sh latest` names the newest upstream tag).
//! `_acpmux/*` methods are acpmux's own and are not checked; `_meta` is open in the schema.
//! Methods acpmux serves that ACP v1 has only as unstable (`session/fork`, `session/set_model`)
//! are not in the stable schema and are skipped.

use super::*;
use jsonschema::Validator;
use sha2::{Digest, Sha256};
use std::collections::HashMap;

const SCHEMA: &str = include_str!("../../schema/acp/v1/schema.json");
const META: &str = include_str!("../../schema/acp/v1/meta.json");
const PIN: &str = include_str!("../../schema/acp/v1/PIN");

/// Each stable ACP v1 method: its params type and, for a request, its result type.
const METHODS: &[(&str, &str, Option<&str>)] = &[
    ("initialize", "InitializeRequest", Some("InitializeResponse")),
    ("authenticate", "AuthenticateRequest", Some("AuthenticateResponse")),
    ("logout", "LogoutRequest", Some("LogoutResponse")),
    ("session/new", "NewSessionRequest", Some("NewSessionResponse")),
    ("session/load", "LoadSessionRequest", Some("LoadSessionResponse")),
    ("session/list", "ListSessionsRequest", Some("ListSessionsResponse")),
    ("session/delete", "DeleteSessionRequest", Some("DeleteSessionResponse")),
    ("session/resume", "ResumeSessionRequest", Some("ResumeSessionResponse")),
    ("session/close", "CloseSessionRequest", Some("CloseSessionResponse")),
    ("session/set_mode", "SetSessionModeRequest", Some("SetSessionModeResponse")),
    (
        "session/set_config_option",
        "SetSessionConfigOptionRequest",
        Some("SetSessionConfigOptionResponse"),
    ),
    ("session/prompt", "PromptRequest", Some("PromptResponse")),
    ("session/cancel", "CancelNotification", None),
    ("session/update", "SessionNotification", None),
    ("session/request_permission", "RequestPermissionRequest", Some("RequestPermissionResponse")),
    ("fs/read_text_file", "ReadTextFileRequest", Some("ReadTextFileResponse")),
    ("fs/write_text_file", "WriteTextFileRequest", Some("WriteTextFileResponse")),
    ("terminal/create", "CreateTerminalRequest", Some("CreateTerminalResponse")),
    ("terminal/output", "TerminalOutputRequest", Some("TerminalOutputResponse")),
    ("terminal/release", "ReleaseTerminalRequest", Some("ReleaseTerminalResponse")),
    ("terminal/wait_for_exit", "WaitForTerminalExitRequest", Some("WaitForTerminalExitResponse")),
    ("terminal/kill", "KillTerminalRequest", Some("KillTerminalResponse")),
    ("elicitation/create", "CreateElicitationRequest", Some("CreateElicitationResponse")),
    ("elicitation/complete", "CompleteElicitationNotification", None),
    ("$/cancel_request", "CancelRequestNotification", None),
];

/// Validators for the schema's `$defs`, built once per type.
struct Acp {
    root: Value,
    validators: HashMap<String, Validator>,
}

impl Acp {
    fn load() -> Self {
        Self { root: serde_json::from_str(SCHEMA).unwrap(), validators: HashMap::new() }
    }

    fn has(&self, def: &str) -> bool {
        self.root["$defs"].get(def).is_some()
    }

    /// The mismatches of `value` against `$defs/<def>`: "`<pointer>`: <message>" each.
    fn check(&mut self, def: &str, value: &Value) -> Vec<String> {
        let root = &self.root;
        let validator = self.validators.entry(def.to_owned()).or_insert_with(|| {
            let schema = json!({
                "$schema": root["$schema"],
                "$defs": root["$defs"],
                "$ref": format!("#/$defs/{def}"),
            });
            jsonschema::validator_for(&schema).unwrap()
        });
        validator.iter_errors(value).map(|e| format!("`{}`: {e}", e.instance_path)).collect()
    }
}

fn pinned_sha(file: &str) -> &'static str {
    PIN.lines()
        .find_map(|l| l.strip_prefix(&format!("{file} sha256=")))
        .unwrap_or_else(|| panic!("schema/acp/v1/PIN names no sha256 for {file}"))
}

/// The vendored files are the pinned upstream release, and every method its
/// `meta.json` names has a row in [`METHODS`] whose types the schema defines,
/// so a bump that adds a method fails here until the row is added.
#[test]
fn the_vendored_acp_schema_is_the_pinned_release_and_every_method_is_mapped() {
    for (file, text) in [("schema.json", SCHEMA), ("meta.json", META)] {
        let sha = format!("{:x}", Sha256::digest(text.as_bytes()));
        assert_eq!(sha, pinned_sha(file), "schema/acp/v1/{file} is not the pinned upstream file");
    }
    let acp = Acp::load();
    let meta: Value = serde_json::from_str(META).unwrap();
    for group in ["agentMethods", "clientMethods", "protocolMethods"] {
        for name in meta[group].as_object().unwrap().values() {
            let name = name.as_str().unwrap();
            assert!(
                METHODS.iter().any(|(m, ..)| *m == name),
                "ACP method {name} ({group}) has no row in METHODS"
            );
        }
    }
    for (m, params, result) in METHODS {
        for def in std::iter::once(params).chain(result.as_ref()) {
            assert!(acp.has(def), "{m}: the schema has no $defs/{def}");
        }
    }
}

/// Every `session/update` of the recorded worked turn the simulation replays.
#[test]
fn the_recorded_worked_turn_conforms_to_acp() {
    let fixture: Value = serde_json::from_str(include_str!("../sim/worked_turn.json")).unwrap();
    let mut acp = Acp::load();
    let mut failures = Vec::new();
    for (i, step) in fixture["steps"].as_array().unwrap().iter().enumerate() {
        let params = json!({"sessionId": "worked", "update": step["update"]});
        for e in acp.check("SessionNotification", &params) {
            failures.push(format!("session/update (worked_turn.json step {i}) params{e}"));
        }
    }
    assert!(failures.is_empty(), "ACP schema mismatches:\n{}", failures.join("\n"));
}

/// Which side sent a frame.
#[derive(Clone, Copy, Debug)]
enum Side {
    Client,
    Daemon,
}

/// A client that records every frame both ways and answers the daemon's
/// permission asks (`session/request_permission`, `_acpmux/permission_pending`).
struct Recorder {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
    frames: Vec<(Side, Value)>,
}

impl Recorder {
    fn open(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
        Self { tx: in_tx, rx: out_rx, next: 0, frames: Vec::new() }
    }

    async fn send(&mut self, frame: Value) {
        self.tx.send(frame.to_string()).await.unwrap();
        self.frames.push((Side::Client, frame));
    }

    async fn notify(&mut self, m: &str, params: Value) {
        self.send(json!({"jsonrpc": "2.0", "method": m, "params": params})).await;
    }

    async fn start(&mut self, m: &str, params: Value) -> i64 {
        self.next += 1;
        let id = self.next;
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": m, "params": params})).await;
        id
    }

    /// Read frames until `done` holds for one, answering asks on the way.
    async fn read_until(&mut self, done: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout waiting for the daemon")
                .expect("connection closed");
            let frame: Value = serde_json::from_str(&line).unwrap();
            self.frames.push((Side::Daemon, frame.clone()));
            if frame["method"] == method::SESSION_REQUEST_PERMISSION && frame.get("id").is_some() {
                let option = frame["params"]["options"][0]["optionId"].clone();
                let answer = json!({"outcome": {"outcome": "selected", "optionId": option}});
                self.send(json!({"jsonrpc": "2.0", "id": frame["id"], "result": answer})).await;
            } else if frame["method"] == method::MUX_PERMISSION_PENDING {
                let p = &frame["params"];
                let option = p["request"]["options"][0]["optionId"].clone();
                let respond = json!({
                    "sessionId": p["sessionId"], "permissionId": p["permissionId"], "optionId": option,
                });
                self.start(method::MUX_PERMISSION_RESPOND, respond).await;
            }
            if done(&frame) {
                return frame;
            }
        }
    }

    async fn request(&mut self, m: &str, params: Value) -> Value {
        let id = self.start(m, params).await;
        let reply = self.read_until(|f| f["id"] == id && f.get("method").is_none()).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }

    /// The ACP handshake, then the person's proof (`hub/person.rs`).
    async fn become_person(&mut self) {
        let init = self
            .request(
                method::INITIALIZE,
                json!({
                    "protocolVersion": 1,
                    "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}},
                    "clientInfo": {"name": "acp-schema", "version": "1"},
                }),
            )
            .await;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        self.request("_acpmux/person_prove", json!({"proof": proof})).await;
    }
}

/// Validate one connection's recorded frames: requests and notifications by method, a response by the
/// method of the request it answers (its error as ACP's `Error`).
fn conformance_failures(frames: &[(Side, Value)], answered: &mut Vec<String>) -> Vec<String> {
    let mut acp = Acp::load();
    let mut asked: HashMap<(bool, String), String> = HashMap::new();
    let mut failures = Vec::new();
    for (from, frame) in frames {
        let by_client = matches!(from, Side::Client);
        if let Some(m) = frame["method"].as_str() {
            if let Some(id) = frame.get("id") {
                asked.insert((by_client, id.to_string()), m.to_owned());
            }
            let Some((_, params, _)) = METHODS.iter().find(|(name, ..)| *name == m) else {
                continue;
            };
            for e in acp.check(params, &frame["params"]) {
                failures.push(format!("{m} ({from:?}) params{e}"));
            }
            continue;
        }
        let Some(m) = asked.remove(&(!by_client, frame["id"].to_string())) else { continue };
        let Some((_, _, Some(result))) = METHODS.iter().find(|(name, ..)| *name == m) else {
            continue;
        };
        answered.push(m.clone());
        let (def, value, part) = match frame.get("error") {
            Some(error) => ("Error", error, "error"),
            None => (*result, &frame["result"], "result"),
        };
        for e in acp.check(def, value) {
            failures.push(format!("{m} ({from:?}) {part}{e}"));
        }
    }
    failures
}

/// A conversation through the standard ACP surface: handshake, new, prompt (one answered
/// through acpmux's `_acpmux/permission_pending`, which is not checked), cancel, set_mode, list, load on a second connection, resume on a
/// third, close. Every standard frame either side sent validates against ACP v1.
#[tokio::test]
async fn a_recorded_acp_conversation_conforms_to_acp() {
    let (hub, _c) = setup(PermissionPolicy::Ask).await;
    let mut c = Recorder::open(&hub);
    c.become_person().await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let text = |t: &str| json!({"sessionId": id, "prompt": [{"type": "text", "text": t}]});
    c.request(method::SESSION_PROMPT, text("hello")).await;
    c.request(method::SESSION_PROMPT, text("ask: write")).await;
    let slow = c.start(method::SESSION_PROMPT, text("slow")).await;
    c.read_until(|f| f["params"]["update"]["sessionUpdate"] == "agent_message_chunk").await;
    c.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    c.read_until(|f| f["id"] == slow && f.get("method").is_none()).await;
    c.request(method::SESSION_SET_MODE, json!({"sessionId": id, "modeId": "strict"})).await;
    c.request(method::SESSION_LIST, json!({})).await;

    let mut loaded = Recorder::open(&hub);
    loaded.become_person().await;
    loaded
        .request(method::SESSION_LOAD, json!({"sessionId": id, "cwd": cwd(), "mcpServers": []}))
        .await;
    let mut resumed = Recorder::open(&hub);
    resumed.become_person().await;
    resumed
        .request(method::SESSION_RESUME, json!({"sessionId": id, "cwd": cwd(), "mcpServers": []}))
        .await;
    resumed.request(method::SESSION_CLOSE, json!({"sessionId": id})).await;

    // Request ids are per connection, so each connection's frames are checked on their own.
    let connections = [c.frames, loaded.frames, resumed.frames];
    let checked: Vec<&str> = connections
        .iter()
        .flatten()
        .filter_map(|(_, f)| f["method"].as_str())
        .filter(|m| METHODS.iter().any(|(name, ..)| name == m))
        .collect();
    for m in ["initialize", "session/new", "session/prompt", "session/update", "session/load"] {
        assert!(checked.contains(&m), "the recording has no {m} frame: {checked:?}");
    }
    let mut answered = Vec::new();
    let failures: Vec<String> =
        connections.iter().flat_map(|f| conformance_failures(f, &mut answered)).collect();
    for m in ["initialize", "session/new", "session/prompt", "session/list", "session/load"] {
        assert!(answered.iter().any(|a| a == m), "no {m} response was checked: {answered:?}");
    }
    assert!(failures.is_empty(), "ACP schema mismatches:\n{}", failures.join("\n"));
}
