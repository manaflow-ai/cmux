use super::AttemptKey;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReplyIssue {
    InvalidJson(String),
    SchemaMismatch { instance_path: String, schema_path: String, message: String },
}

#[derive(Debug, Clone, PartialEq)]
pub enum ReplyDecision {
    Ignore,
    Accept(Value),
    Correct { prompt: String, issues: Vec<ReplyIssue> },
    Fail { issues: Vec<ReplyIssue> },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("invalid workflow reply schema: {0}")]
pub struct SchemaError(pub String);

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReplyState {
    pub key: AttemptKey,
    pub last_sequence: Option<u64>,
    pub correction_requested: bool,
    pub finished: bool,
}

impl ReplyState {
    pub fn new(key: AttemptKey) -> Self {
        Self { key, last_sequence: None, correction_requested: false, finished: false }
    }
}

pub struct ReplyPolicy {
    state: ReplyState,
}

impl ReplyPolicy {
    pub fn new(_schema: &Value, state: ReplyState) -> Result<Self, SchemaError> {
        Ok(Self { state })
    }

    pub fn state(&self) -> &ReplyState {
        &self.state
    }

    pub fn observe(&mut self, _key: &AttemptKey, _sequence: u64, text: &str) -> ReplyDecision {
        ReplyDecision::Accept(serde_json::from_str(text).unwrap_or(Value::Null))
    }
}
