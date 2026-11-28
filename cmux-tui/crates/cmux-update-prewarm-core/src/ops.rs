//! The JSON ops of the C ABI (`cmux_update_prewarm_call`): one op name and
//! one request object in, one reply object out.
//!
//! - `marker.encode` `{build, state, reason?}` -> `{line}`; `state` is
//!   `started`, `main`, `full` or `skipped` (`reason` is read only then).
//! - `marker.verdict` `{build, marker: string|null}` ->
//!   `{pre_warmed, reason, consume}`; `marker` is the file's text, null
//!   when there is no file.

use crate::{MarkerState, encode_marker, launch_verdict};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

/// Why an op gave no reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpError {
    /// The op is not one of these.
    Unknown,
    /// The request is not the object the op takes.
    Invalid,
}

fn de<T: DeserializeOwned>(request: &Value) -> Result<T, OpError> {
    serde_json::from_value(request.clone()).map_err(|_| OpError::Invalid)
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum StateWord {
    Started,
    Main,
    Full,
    Skipped,
}

#[derive(Deserialize)]
struct Encode {
    build: String,
    state: StateWord,
    #[serde(default)]
    reason: String,
}

#[derive(Deserialize)]
struct ReadVerdict {
    build: String,
    #[serde(default)]
    marker: Option<String>,
}

/// Runs one op.
pub fn call(op: &str, request: &Value) -> Result<Value, OpError> {
    match op {
        "marker.encode" => {
            let r: Encode = de(request)?;
            let state = match r.state {
                StateWord::Started => MarkerState::Started,
                StateWord::Main => MarkerState::Main,
                StateWord::Full => MarkerState::Full,
                StateWord::Skipped => MarkerState::Skipped(r.reason),
            };
            let line = encode_marker(&r.build, &state).ok_or(OpError::Invalid)?;
            Ok(json!({ "line": line }))
        }
        "marker.verdict" => {
            let r: ReadVerdict = de(request)?;
            serde_json::to_value(launch_verdict(&r.build, r.marker.as_deref()))
                .map_err(|_| OpError::Invalid)
        }
        _ => Err(OpError::Unknown),
    }
}
