//! See `ui/mod.rs`.

use serde_json::Value;

use super::Answer;

pub(crate) fn handle(_name: &str, _args: &Value) -> Answer {
    None
}
