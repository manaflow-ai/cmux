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
}

impl FakeControlPlane {
    /// Loads the named fixtures (`tests/fixtures/<name>.json`).
    pub fn with(names: &[&str]) -> Self {
        let mut fake = Self { routes: HashMap::new(), calls: Vec::new(), signed_in: true };
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
        let (status, body) = self
            .routes
            .get(&(call.method.to_owned(), call.path.clone()))
            .cloned()
            .unwrap_or((404, serde_json::json!({ "error": "vm_not_found" })));
        Ok(HttpReply { status, body, error_code: None })
    }

    fn session(&mut self) -> Result<SessionStatus, RelayError> {
        Ok(SessionStatus { signed_in: self.signed_in, team: Some("team-test".into()) })
    }
}
