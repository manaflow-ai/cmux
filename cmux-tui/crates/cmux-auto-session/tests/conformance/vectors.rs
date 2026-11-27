//! The vectors file as serde types. Its `about` says what each field of a step means.

use cmux_auto_session::wire::Fence;
use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Deserialize)]
pub struct Vectors {
    pub cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Case {
    pub name: String,
    pub steps: Vec<Step>,
}

/// One call: who makes it, the request, and the answer or the refusal to expect.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Step {
    /// The clock moves on this much before the call.
    #[serde(default)]
    pub advance_ms: u64,
    /// `owner` or `machine:<machine id>`.
    pub by: String,
    /// The `AutoCloud` method.
    pub op: String,
    /// The chat; `$created` is the chat the case's last `create` made.
    pub id: Option<String>,
    pub body: Option<Value>,
    #[serde(default)]
    pub query: Query,
    /// A chunk's name, its bytes as UTF-8, and its writer.
    pub sha256: Option<String>,
    pub text: Option<String>,
    pub fence: Option<Fence>,
    pub expect: Option<Value>,
    pub refuse: Option<Refusal>,
    /// The answer asserted is the real store's today, and is thought to be wrong.
    pub disputed: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Query {
    pub after: Option<u64>,
    pub limit: Option<u32>,
    pub timeout_ms: Option<u64>,
}

/// A refusal: its status and code, and what the code promises beside them when the vectors
/// name it.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Refusal {
    pub status: u16,
    pub code: String,
    pub last_seq: Option<u64>,
    pub missing: Option<Vec<String>>,
    pub session: Option<Value>,
}
