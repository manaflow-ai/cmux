//! The fake control plane of the attach, files and ports tests: wire ops
//! come from the vectors fake (`wire_common`, `backend/catalog/cloud-vectors.json`);
//! the TRANSITIONAL classic routes the link and file code still calls
//! (attach endpoint, scp endpoint, file routes) come from the recorded
//! answers in `tests/fixtures/`. It never touches a network.
//!
//! The link tests name their machines `vm-alpha01` and `vm-beta02`, which no
//! vector holds. Three names in [`FakeControlPlane::with`] serve them:
//! `vm-get` (every `cloud.machine.get` answers a running machine of that id),
//! `vm-list` (`cloud.machine.list {}` answers `vm-alpha01` running and
//! `vm-beta02` paused) and `vm-resume` (every `cloud.machine.start` answers
//! the machine running).

#![allow(dead_code)]

#[path = "../wire_common/mod.rs"]
pub mod wire_common;

#[allow(unused_imports)]
pub use wire_common::{WireFake, host, snap, vm};

use cmux_cloud::{
    ControlPlane, HttpCall, HttpReply, RelayError, SessionStatus, WireCall, WireReply, WireResult,
};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;

pub struct FakeControlPlane {
    /// The vectors backend; its `calls` are the wire calls.
    pub wire: WireFake,
    get_any: bool,
    list_two: bool,
    start_any: bool,
    routes: HashMap<(String, String), (u16, Value)>,
    /// Classic route calls (attach, scp and file routes), in order.
    pub calls: Vec<HttpCall>,
}

/// A link-test machine record (contract 1.2 shape).
pub fn link_machine(id: &str, status: &str) -> Value {
    json!({ "id": id, "team": "team_t0000000000000000001", "name": id, "status": status,
        "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 },
        "host": if status == "running" { json!(format!("host-{id}")) } else { Value::Null },
        "classic": false, "revision": "1" })
}

impl FakeControlPlane {
    /// The vectors plus the named classic fixtures (`tests/fixtures/<name>.json`)
    /// and the link-test names `vm-get`, `vm-list`, `vm-resume`.
    pub fn with(names: &[&str]) -> Self {
        let mut fake = Self {
            wire: WireFake::load(),
            get_any: false,
            list_two: false,
            start_any: false,
            routes: HashMap::new(),
            calls: Vec::new(),
        };
        for name in names {
            match *name {
                "vm-get" => fake.get_any = true,
                "vm-list" => fake.list_two = true,
                "vm-resume" => fake.start_any = true,
                other => fake.serve(other),
            }
        }
        fake
    }

    /// Adds (or replaces) the route of one classic fixture.
    pub fn serve(&mut self, name: &str) {
        let fixture = Self::fixture(name);
        let method = fixture["request"]["method"].as_str().expect("method").to_owned();
        let path = fixture["request"]["path"].as_str().expect("path").to_owned();
        let status = u16::try_from(fixture["status"].as_u64().expect("status")).expect("u16");
        self.routes.insert((method, path), (status, fixture["body"].clone()));
    }

    fn fixture(name: &str) -> Value {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("tests/fixtures/{name}.json"));
        let raw = std::fs::read_to_string(&path).unwrap_or_else(|_| panic!("fixture {name}"));
        serde_json::from_str(&raw).expect("fixture JSON")
    }

    /// Sets the answer of one classic route directly.
    pub fn respond(&mut self, method: &str, path: &str, status: u16, body: Value) {
        self.routes.insert((method.to_owned(), path.to_owned()), (status, body));
    }

    /// The body of a classic fixture, for tests that change it.
    pub fn fixture_body(name: &str) -> Value {
        Self::fixture(name)["body"].clone()
    }

    /// Classic route calls of `method` and `path`.
    pub fn count(&self, method: &str, path: &str) -> usize {
        self.calls.iter().filter(|c| c.method == method && c.path == path).count()
    }

    /// True when nothing reached the backend, wire or classic.
    pub fn no_calls(&self) -> bool {
        self.calls.is_empty() && self.wire.calls.is_empty()
    }

    /// The wire ops called, in order.
    pub fn ops(&self) -> Vec<String> {
        self.wire.calls.iter().map(|c| c.op.clone()).collect()
    }

    /// The link-test answer for a call no vector holds.
    fn link_answer(&self, call: &WireCall) -> Option<Value> {
        let machine = call.params.get("machine").and_then(Value::as_str);
        match (call.op.as_str(), machine) {
            ("cloud.machine.get", Some(id)) if self.get_any => Some(link_machine(id, "running")),
            ("cloud.machine.start", Some(id)) if self.start_any => {
                let mut running = link_machine(id, "running");
                running["revision"] = json!("2");
                Some(json!({ "machine": running }))
            }
            ("cloud.machine.list", None) if self.list_two && call.params == json!({}) => {
                Some(json!({ "machines": [link_machine("vm-alpha01", "running"),
                    link_machine("vm-beta02", "paused")], "next_cursor": null, "revision": "1" }))
            }
            _ => None,
        }
    }
}

impl ControlPlane for FakeControlPlane {
    fn call(&mut self, call: &WireCall) -> Result<WireReply, RelayError> {
        // The link-test names answer first: `vm-list` replaces the vectors'
        // `list {}` for the tests that name it.
        if self.wire.signed_in
            && let Some(value) = self.link_answer(call)
        {
            self.wire.calls.push(call.clone());
            return Ok(WireReply::Result(WireResult {
                value,
                revision: Some("1".into()),
                replayed: false,
            }));
        }
        self.wire.reply(call)
    }

    fn session(&mut self) -> Result<SessionStatus, RelayError> {
        self.wire.session_status()
    }

    fn classic(&mut self, call: &HttpCall) -> Result<HttpReply, RelayError> {
        self.calls.push(call.clone());
        if !self.wire.signed_in {
            return Err(RelayError::NotSignedIn);
        }
        let (status, body) = self
            .routes
            .get(&(call.method.to_owned(), call.path.clone()))
            .cloned()
            .unwrap_or((404, json!({ "error": "route_not_found" })));
        Ok(HttpReply { status, body, error_code: None })
    }
}
