//! Installed extensions' ops as tools (plans/cmux-next/app-commands-codemode.md
//! section 2). The daemon decides which ops are offered (`apps-mcp-tools`,
//! cmux-tui-core apps/mcp_tools.rs: the catalog's `mcp.expose: "default"` on
//! an installed, enabled app), and is asked again on every `tools/list`, so
//! an install or a saved local app is a tool with no restart of this server.
//! A call runs the op with `apps-run`, origin `mcp`; the daemon refuses an op
//! that is not offered (`apps.op.not_offered`) whatever this server lists.

use serde_json::{Map, Value, json};

use super::{Backend, failure_result, success};

/// One offered op: its tool descriptor and where it runs.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct AppOpTool {
    pub name: String,
    app: String,
    op: String,
    descriptor: Value,
}

impl AppOpTool {
    pub(super) fn descriptor_json(&self) -> Value {
        self.descriptor.clone()
    }

    /// Runs the op in its app with the tool's arguments as the op's input.
    pub(super) fn call(&self, backend: &impl Backend, arguments: &Map<String, Value>) -> Value {
        let request = json!({ "cmd": "apps-run", "origin": "mcp", "app": self.app,
            "op": self.op, "args": Value::Object(arguments.clone()) });
        let read_only = self.descriptor.pointer("/annotations/readOnlyHint") == Some(&json!(true));
        match backend.daemon(request) {
            Ok(value) => success(value, !read_only),
            Err(failure) => failure_result(failure),
        }
    }
}

/// The offered ops now, or `None` when the daemon does not answer
/// `apps-mcp-tools` (no daemon, or one older than this CLI).
pub(super) fn read(backend: &impl Backend) -> Option<Vec<AppOpTool>> {
    let listed = backend.daemon(json!({ "cmd": "apps-mcp-tools" })).ok()?;
    Some(from_list(&listed))
}

pub(super) fn from_list(listed: &Value) -> Vec<AppOpTool> {
    listed["tools"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|tool| {
            let name = tool["name"].as_str()?.to_owned();
            let descriptor = json!({
                "name": name,
                "description": tool["description"].as_str().unwrap_or_default(),
                "inputSchema": tool.get("inputSchema").cloned().unwrap_or_else(|| json!({ "type": "object" })),
                "annotations": tool.get("annotations").cloned().unwrap_or_else(|| json!({})),
            });
            Some(AppOpTool {
                name,
                app: tool["app"].as_str()?.to_owned(),
                op: tool["op"].as_str()?.to_owned(),
                descriptor,
            })
        })
        .collect()
}
