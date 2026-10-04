//! One op request as the app supervisor sends it (`apps-run`: op, args,
//! idempotency key; the origin is stamped by the supervisor).

use serde::Deserialize;
use serde_json::Value;

/// Who started the request (OWNERSHIP-PRINCIPLES: absent = `cli`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    /// A person, with a gesture (palette, menu, native confirmation sheet).
    User,
    #[default]
    Cli,
    Mcp,
    Script,
    Remote,
    Agent,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Request {
    pub op: String,
    #[serde(default)]
    pub args: Value,
    #[serde(default)]
    pub origin: Origin,
    #[serde(default)]
    pub idempotency_key: Option<String>,
}

impl Request {
    pub fn new(op: &str, args: Value) -> Self {
        Self { op: op.to_owned(), args, origin: Origin::Cli, idempotency_key: None }
    }

    pub fn origin(mut self, origin: Origin) -> Self {
        self.origin = origin;
        self
    }

    pub fn key(mut self, key: &str) -> Self {
        self.idempotency_key = Some(key.to_owned());
        self
    }
}
