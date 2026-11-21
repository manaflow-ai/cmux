//! The pin of a server's tools (threat model T10): the SHA-256 of each tool
//! as the model sees it, so a description or schema that changes after the
//! person approved holds that tool until they approve again.

use std::collections::BTreeMap;

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::command::hex;

/// Each approved tool's digest, by name.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ToolPin {
    pub tools: BTreeMap<String, String>,
}

/// What changed between a pin and a new `tools/list`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Diff {
    /// New names: held until approved.
    pub added: Vec<String>,
    /// Same name, different text or schema: held until approved.
    pub changed: Vec<String>,
    /// Gone from the list: dropped, nothing to approve.
    pub removed: Vec<String>,
}

impl Diff {
    /// Whether the person must look again before these tools are listed.
    pub fn needs_approval(&self) -> bool {
        !self.added.is_empty() || !self.changed.is_empty()
    }
}

/// `value` written with object keys sorted at every level, so two lists
/// that differ only in key order have one digest.
fn canonical(value: &Value, out: &mut String) {
    match value {
        Value::Object(map) => {
            let sorted: BTreeMap<&String, &Value> = map.iter().collect();
            out.push('{');
            for (i, (k, v)) in sorted.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(k.clone()).to_string());
                out.push(':');
                canonical(v, out);
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (i, v) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical(v, out);
            }
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// The digest of one tool: its name, title, description, input schema and
/// annotations (what reaches the model or decides the policy).
pub fn tool_digest(tool: &Value) -> String {
    let mut seen = serde_json::Map::new();
    for k in ["name", "title", "description", "inputSchema", "annotations"] {
        if let Some(v) = tool.get(k) {
            seen.insert(k.to_owned(), v.clone());
        }
    }
    let mut text = String::new();
    canonical(&Value::Object(seen), &mut text);
    hex(&Sha256::digest(text.as_bytes()))
}

impl ToolPin {
    /// The pin of a `tools/list` result's `tools` array.
    pub fn of(tools: &[Value]) -> Self {
        Self {
            tools: tools
                .iter()
                .filter_map(|t| Some((t.get("name")?.as_str()?.to_owned(), tool_digest(t))))
                .collect(),
        }
    }

    /// What `tools` changes against this pin.
    pub fn diff(&self, tools: &[Value]) -> Diff {
        let now = Self::of(tools);
        let mut d = Diff::default();
        for (name, digest) in &now.tools {
            match self.tools.get(name) {
                None => d.added.push(name.clone()),
                Some(old) if old != digest => d.changed.push(name.clone()),
                Some(_) => {}
            }
        }
        d.removed = self.tools.keys().filter(|n| !now.tools.contains_key(*n)).cloned().collect();
        d
    }

    /// The tools of `tools` that may be listed to the agent: pinned and
    /// unchanged. Everything else waits for the person.
    pub fn approved<'a>(&self, tools: &'a [Value]) -> Vec<&'a Value> {
        tools
            .iter()
            .filter(|t| {
                t.get("name")
                    .and_then(Value::as_str)
                    .and_then(|n| self.tools.get(n))
                    .is_some_and(|d| *d == tool_digest(t))
            })
            .collect()
    }
}
