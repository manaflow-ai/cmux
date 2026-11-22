//! The fake cmux.wire/1 backend: serves `backend/catalog/cloud-vectors.json`
//! (shared with the backend tests) keyed by (principal, op, params, key),
//! with per-key replay: attempt i of one key gets `responses[i]`, later
//! attempts the last entry, so a cut-off case answers
//! `mutation.indeterminate` first and the stored result on the same-key
//! retry. It folds each recorded HTTP answer into a wire reply the way the
//! host does. It never touches a network.

#![allow(dead_code)]

use cmux_cloud::{RelayError, SessionStatus, WireCall, WireError, WireReply, WireResult};
use serde_json::{Value, json};
use std::path::Path;

/// The vectors file, read by path (no copy).
pub fn vectors() -> Value {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../backend/catalog/cloud-vectors.json");
    let raw = std::fs::read_to_string(&path).expect("cloud-vectors.json");
    serde_json::from_str(&raw).expect("vectors JSON")
}

/// One served route: a vector case or a test's own answer.
struct Route {
    name: String,
    agent: bool,
    op: String,
    params: Value,
    key: Option<String>,
    /// Recorded HTTP answers `{http: {path, status}, body}`, in attempt order.
    responses: Vec<Value>,
    attempts: usize,
}

pub struct WireFake {
    routes: Vec<Route>,
    /// Every call that reached the backend, in order.
    pub calls: Vec<WireCall>,
    /// Calls are made with an agent (chief) token.
    pub agent: bool,
    pub signed_in: bool,
    /// The next N calls fail before they reach the backend.
    pub fail_next: usize,
    /// The next N calls reach the backend (the attempt counts), but the
    /// answer is lost on the way back.
    pub lose_next: usize,
}

/// `machine` record `n` of the vectors (`vm_m…0n`).
pub fn vm(n: u32) -> String {
    format!("vm_m{n:019}")
}

pub fn snap(n: u32) -> String {
    format!("snap_s{n:019}")
}

pub fn host(n: u32) -> String {
    format!("host_h{n:019}")
}

impl WireFake {
    /// Every case of the vectors file.
    pub fn load() -> Self {
        let doc = vectors();
        let mut fake = Self {
            routes: Vec::new(),
            calls: Vec::new(),
            agent: false,
            signed_in: true,
            fail_next: 0,
            lose_next: 0,
        };
        for case in doc["cases"].as_array().expect("cases") {
            // The server calls only the ops it serves; a backend-only op
            // (`cloud.machine.link_token`, minted for `cmux link`) is never
            // its request, and its session and install vectors may share
            // params because the backend keys them by principal kind.
            let op = case["op"].as_str().expect("op");
            if cmux_cloud::ops::canonical_name(op).is_none() {
                continue;
            }
            let agent = case["principal"].get("agent").is_some_and(|a| !a.is_null());
            let route = Route {
                name: case["name"].as_str().expect("name").to_owned(),
                agent,
                op: case["op"].as_str().expect("op").to_owned(),
                params: case["params"].clone(),
                key: case["idempotency_key"].as_str().map(str::to_owned),
                responses: case["responses"].as_array().expect("responses").clone(),
                attempts: 0,
            };
            assert!(
                !fake.routes.iter().any(|r| r.agent == route.agent
                    && r.op == route.op
                    && r.params == route.params
                    && r.key == route.key),
                "two vector cases share a request: {}",
                route.name
            );
            fake.routes.push(route);
        }
        fake
    }

    /// The `data` of the named event case.
    pub fn event(name: &str) -> (String, Value) {
        let doc = vectors();
        let e = doc["events"]
            .as_array()
            .expect("events")
            .iter()
            .find(|e| e["name"] == name)
            .unwrap_or_else(|| panic!("no event vector {name}"))
            .clone();
        (e["event"].as_str().expect("event").to_owned(), e["data"].clone())
    }

    /// Adds (or replaces) an answer for one request, ahead of the vectors.
    /// `answer` is a wire value for a success, or an `{error: {...}}` object.
    pub fn answer(&mut self, op: &str, params: Value, key: Option<&str>, answer: Value) {
        let path = if key.is_some() { "/v1/ops" } else { "/v1/read" };
        let body = match answer.get("error") {
            Some(error) => json!({ "ok": false, "op": op, "error": error, "transaction": "",
                "idempotency_key": key.unwrap_or_default(), "replayed": false, "stream": "", "sequence": 0 }),
            None if key.is_some() => {
                json!({ "ok": true, "op": op, "value": answer, "transaction": "tx_test",
                "idempotency_key": key, "revision": "1", "replayed": false, "stream": "", "sequence": 1 })
            }
            None => json!({ "op": op, "value": answer, "stream": "", "revision": "1" }),
        };
        // A read error rides the envelope too in a test answer (folded the same way).
        let response = json!({ "http": { "path": path, "status": 200 }, "body": body });
        self.routes
            .retain(|r| !(r.op == op && r.params == params && r.key.as_deref() == key && !r.agent));
        self.routes.insert(
            0,
            Route {
                name: format!("test:{op}"),
                agent: false,
                op: op.to_owned(),
                params,
                key: key.map(str::to_owned),
                responses: vec![response],
                attempts: 0,
            },
        );
    }

    /// Calls of `op` that reached the backend.
    pub fn count(&self, op: &str) -> usize {
        self.calls.iter().filter(|c| c.op == op).count()
    }

    /// Calls of `op`, their keys in order.
    pub fn keys(&self, op: &str) -> Vec<Option<String>> {
        self.calls.iter().filter(|c| c.op == op).map(|c| c.idempotency_key.clone()).collect()
    }

    /// The backend side of one call.
    pub fn reply(&mut self, call: &WireCall) -> Result<WireReply, RelayError> {
        self.calls.push(call.clone());
        if !self.signed_in {
            return Err(RelayError::NotSignedIn);
        }
        if self.fail_next > 0 {
            self.fail_next -= 1;
            return Err(RelayError::Unavailable("the host did not answer".into()));
        }
        let agent = self.agent;
        let Some(route) = self.routes.iter_mut().find(|r| {
            r.agent == agent
                && r.op == call.op
                && r.params == call.params
                && r.key == call.idempotency_key
        }) else {
            return Ok(WireReply::Error(WireError {
                code: "vector.missing".into(),
                message: format!(
                    "no vector for {} {} key {:?}",
                    call.op, call.params, call.idempotency_key
                ),
                details: None,
                retryable: false,
            }));
        };
        let response = route.responses[route.attempts.min(route.responses.len() - 1)].clone();
        route.attempts += 1;
        if self.lose_next > 0 {
            self.lose_next -= 1;
            return Err(RelayError::Unavailable("the answer was lost".into()));
        }
        Ok(fold(&response))
    }

    /// Attempts the backend saw for the named case.
    pub fn attempts(&self, name: &str) -> usize {
        self.routes.iter().find(|r| r.name == name).map_or(0, |r| r.attempts)
    }

    pub fn session_status(&self) -> Result<SessionStatus, RelayError> {
        Ok(SessionStatus {
            signed_in: self.signed_in,
            team: Some("team_t0000000000000000001".into()),
        })
    }
}

/// The host's fold of one HTTP answer into a wire reply: a 200 from
/// `/v1/ops` is the `OpResponse` (`ok` with `value` or `error`), a 200 from
/// `/v1/read` the `ReadResponse`, any other status the error body
/// `{_tag, code, message}` (retryable when the backend says so or on 503).
pub fn fold(response: &Value) -> WireReply {
    let status = response["http"]["status"].as_u64().expect("status");
    let body = &response["body"];
    if status != 200 {
        return WireReply::Error(WireError {
            code: body["code"].as_str().expect("code").to_owned(),
            message: body["message"].as_str().unwrap_or_default().to_owned(),
            details: body.get("details").cloned(),
            retryable: body["retryable"].as_bool().unwrap_or(status == 503),
        });
    }
    let error = match body.get("ok") {
        Some(Value::Bool(false)) => Some(&body["error"]),
        _ => None,
    };
    if let Some(error) = error {
        return WireReply::Error(serde_json::from_value(error.clone()).expect("OpError"));
    }
    WireReply::Result(WireResult {
        value: body["value"].clone(),
        revision: body["revision"].as_str().map(str::to_owned),
        replayed: body["replayed"].as_bool().unwrap_or(false),
    })
}

impl cmux_cloud::ControlPlane for WireFake {
    fn call(&mut self, call: &WireCall) -> Result<WireReply, RelayError> {
        self.reply(call)
    }

    fn session(&mut self) -> Result<SessionStatus, RelayError> {
        self.session_status()
    }
}
