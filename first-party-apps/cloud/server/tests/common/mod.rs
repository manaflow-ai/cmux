//! The fake control plane: serves recorded `/api/vm` responses from
//! `tests/fixtures/` and records every call. It never touches a network.

#![allow(dead_code)]

use cmux_cloud::{ControlPlane, HttpCall, HttpReply, RelayError, SessionStatus};
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;

pub struct FakeControlPlane {
    routes: HashMap<(String, String), (u16, Value)>,
    pub calls: Vec<HttpCall>,
    pub signed_in: bool,
    /// The next N calls fail as if the host or network did not answer.
    pub fail_next: usize,
    /// The next N calls reach the Cloud API (the route answers and any
    /// change happens), but the answer is lost on the way back.
    pub lose_next: usize,
    /// Like the Cloud API (`beginCreate`): a POST with a known key replays
    /// the first answer and creates nothing.
    by_key: HashMap<String, (u16, Value)>,
    /// POSTs that reached the provider (not replayed by key).
    pub provider_posts: usize,
}

impl FakeControlPlane {
    /// Loads the named fixtures (`tests/fixtures/<name>.json`).
    pub fn with(names: &[&str]) -> Self {
        let mut fake = Self {
            routes: HashMap::new(),
            calls: Vec::new(),
            signed_in: true,
            fail_next: 0,
            lose_next: 0,
            by_key: HashMap::new(),
            provider_posts: 0,
        };
        for name in names {
            fake.serve(name);
        }
        fake
    }

    /// Adds (or replaces) the route of one fixture.
    pub fn serve(&mut self, name: &str) {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("tests/fixtures/{name}.json"));
        let raw = std::fs::read_to_string(&path).expect("fixture");
        let fixture: Value = serde_json::from_str(&raw).expect("fixture JSON");
        let method = fixture["request"]["method"].as_str().expect("method").to_owned();
        let path = fixture["request"]["path"].as_str().expect("path").to_owned();
        let status = u16::try_from(fixture["status"].as_u64().expect("status")).expect("u16");
        self.routes.insert((method, path), (status, fixture["body"].clone()));
    }

    /// Sets the answer of one route directly (for example a list without a
    /// machine the last list had).
    pub fn respond(&mut self, method: &str, path: &str, status: u16, body: Value) {
        self.routes.insert((method.to_owned(), path.to_owned()), (status, body));
    }

    /// The body of a fixture, for tests that change it.
    pub fn fixture_body(name: &str) -> Value {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("tests/fixtures/{name}.json"));
        let raw = std::fs::read_to_string(&path).expect("fixture");
        serde_json::from_str::<Value>(&raw).expect("fixture JSON")["body"].clone()
    }

    pub fn count(&self, method: &str, path: &str) -> usize {
        self.calls.iter().filter(|c| c.method == method && c.path == path).count()
    }
}

impl ControlPlane for FakeControlPlane {
    fn call(&mut self, call: &HttpCall) -> Result<HttpReply, RelayError> {
        self.calls.push(call.clone());
        if !self.signed_in {
            return Err(RelayError::NotSignedIn);
        }
        if self.fail_next > 0 {
            self.fail_next -= 1;
            return Err(RelayError::Unavailable("the host did not answer".into()));
        }
        if let (Some(key), "POST") = (&call.idempotency_key, call.method)
            && let Some((status, body)) = self.by_key.get(key).cloned()
        {
            return Ok(HttpReply { status, body, error_code: None });
        }
        let (status, body) = self
            .routes
            .get(&(call.method.to_owned(), call.path.clone()))
            .cloned()
            .unwrap_or((404, serde_json::json!({ "error": "vm_not_found" })));
        if call.method == "POST" {
            self.provider_posts += 1;
            if let Some(key) = &call.idempotency_key {
                self.by_key.insert(key.clone(), (status, body.clone()));
            }
        }
        if self.lose_next > 0 {
            self.lose_next -= 1;
            return Err(RelayError::Unavailable("the answer was lost".into()));
        }
        Ok(HttpReply { status, body, error_code: None })
    }

    fn session(&mut self) -> Result<SessionStatus, RelayError> {
        Ok(SessionStatus { signed_in: self.signed_in, team: Some("team-test".into()) })
    }
}
