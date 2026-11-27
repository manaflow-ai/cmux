//! `session/signature`: each named session's dot glyph (`cmux_wallpaper::signature`).

use std::collections::BTreeMap;

use cmux_wallpaper::Glyph;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The most ids one request names.
pub const MAX_SESSION_IDS: usize = 512;

/// `session/signature` params.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
// skew: strict schema only: keeps the web param type closed; serde ignores new fields
#[schemars(deny_unknown_fields)]
pub struct SignatureParams {
    /// At most 512 session ids. Any string gets a glyph: it is a pure function of the id.
    pub session_ids: Vec<String>,
    #[serde(rename = "_meta", default, skip_serializing_if = "Option::is_none")]
    pub meta: Option<Value>,
}

/// `session/signature` result: one glyph per distinct id asked.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SignatureResult {
    pub signatures: BTreeMap<String, Glyph>,
}
