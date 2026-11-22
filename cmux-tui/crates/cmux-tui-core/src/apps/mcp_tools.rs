//! `apps-mcp-tools`: installed extensions' ops as `cmux mcp` tools
//! (plans/cmux-next/app-commands-codemode.md section 2). An op is a tool
//! when its catalog entry offers it to agents (`mcp.expose: "default"`) and
//! its app is installed, turned on and, when hidden, open to MCP. `opt_in`
//! ops wait for the person to turn them on, which nothing records yet, so
//! they are not offered; `never` and a missing `mcp` are not offered either
//! (fail closed, as `agent_view` reads them).
//!
//! The list is read from the supervisor's catalog on every `tools/list`, so
//! an install, an uninstall or a saved local app shows at once, with no
//! restart of the MCP server. A call runs through `apps-run` with origin
//! `mcp`, where [`not_offered`] refuses an op that is not offered however
//! the agent names it (`apps.op.not_offered`).

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::supervisor::{ApiError, Supervisor};
use crate::panic_free::RecoverPoison as _;

/// Whether a catalog entry offers its op to agents.
pub(super) fn offered(entry: &Value) -> bool {
    entry.pointer("/mcp/expose").and_then(Value::as_str) == Some("default")
}

/// The refusal for an agent's run of an op its catalog does not offer.
pub(super) fn not_offered(app: &str, op: &str) -> ApiError {
    ApiError::new(
        "apps.op.not_offered",
        format!("{app} does not offer {op} to agents; the person can run it from cmux"),
    )
}

impl Supervisor {
    /// `apps-mcp-tools`: `{tools: [{name, app, op, description, inputSchema,
    /// annotations}]}`. Two ops that make one tool name both drop out (each
    /// still runs as `cmux apps run <app> <op>`).
    pub fn mcp_tools(&self) -> Value {
        let inner = self.inner.lock().recover_poison();
        let mut by_name: BTreeMap<String, Vec<Value>> = BTreeMap::new();
        for package in inner.catalog.packages.values() {
            let Some(record) = inner.mirror.apps.get(&package.id) else { continue };
            if !record.installed || !record.enabled || (record.hidden && !record.hidden_access.mcp)
            {
                continue;
            }
            for (op, entry) in package.catalog_ops() {
                if !offered(&entry) {
                    continue;
                }
                let name = cmux_app_manifest::mcp_tool_name(&op);
                let read_only = entry.get("class").and_then(Value::as_str) == Some("read");
                let destructive = entry.get("risk").and_then(Value::as_str) == Some("destructive");
                let docs = entry.get("docs").and_then(Value::as_str).unwrap_or_default();
                let title =
                    package.manifest.get("name").and_then(Value::as_str).unwrap_or(&package.id);
                by_name.entry(name.clone()).or_default().push(json!({
                    "name": name,
                    "app": package.id,
                    "op": op,
                    "description": format!("{title} ({}): {docs}", package.id),
                    "inputSchema": entry.get("input").cloned().unwrap_or_else(|| json!({ "type": "object" })),
                    "annotations": { "readOnlyHint": read_only, "destructiveHint": destructive },
                }));
            }
        }
        let tools: Vec<Value> =
            by_name.into_values().filter(|same| same.len() == 1).flatten().collect();
        json!({ "tools": tools })
    }
}

#[cfg(test)]
mod tests {
    use super::offered;
    use serde_json::json;

    #[test]
    fn only_a_default_expose_offers_an_op() {
        assert!(offered(&json!({ "mcp": { "expose": "default" } })));
        for entry in [
            json!({ "mcp": { "expose": "opt_in" } }),
            json!({ "mcp": { "expose": "never" } }),
            json!({ "mcp": {} }),
            json!({}),
        ] {
            assert!(!offered(&entry), "{entry}");
        }
    }
}
