//! Part of `Hub`; see `hub/mod.rs`. The tools a chat has (cx-thur3), for
//! the pane's tool list: cmux's own (`agent_tools.rs`), recorded at each
//! spawn as the spawn gives them (none for a session they leave out), then
//! the MCP servers, plugins and skills Claude Code's system/init reports.
//! The user's own harness config files are never read here.
//!
//! `_acpmux/set_tools` turns one MCP server on or off where the harness can
//! do that mid-session: only Claude Code (`mcp_toggle` on its control
//! channel). Anything else is refused, never a silent no-op.

use super::*;

use crate::store::ToolRow;

/// `data.reason` of a set on a chat whose harness takes its tools at
/// session start only (every ACP harness).
pub const TOOLS_IMMUTABLE: &str = "tools.immutable";
/// `data.reason` of a set on a row that cannot change mid-session (a skill
/// or a plugin).
pub const TOOL_FIXED: &str = "tools.fixed";

impl Hub {
    /// What `ensure_child` records before it starts an agent: its launch
    /// roots (`launch_roots.rs`) and cmux's tools as this spawn gives them.
    /// A new agent starts with every server on; what Claude Code reported for
    /// the last one stays until its next system/init.
    pub(super) async fn record_spawn_inputs(&self, session: &Session, profile: &HarnessProfile) {
        self.record_launch_roots(session, profile).await;
        let claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
        // Claude Code also leaves them out for `--strict-mcp-config`; an ACP
        // harness gets them in `mcpServers` whatever its args.
        let args: &[String] = if claude { &profile.argv } else { &[] };
        let remote = session.meta().remote_origin;
        let cmux = if crate::agent_tools::left_out(remote, &profile.env, args) {
            Vec::new()
        } else {
            crate::agent_tools::current().tool_rows(claude, claude)
        };
        let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let reported = m.tools.rows.iter().filter(|r| r.source != "cmux").cloned();
        let rows = cmux.into_iter().chain(reported).collect();
        m.tools = crate::store::ToolInventory { rows, mutable: claude };
    }

    /// Claude Code's system/init (`_meta.claude` of its session_info_update):
    /// the rows it reports replace the last ones; cmux's own rows stay, on or
    /// off as Claude Code reports them.
    pub(super) fn absorb_reported_tools(&self, session: &Session, claude: &Value) {
        let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let mut rows: Vec<ToolRow> =
            m.tools.rows.iter().filter(|r| r.source == "cmux").cloned().collect();
        for row in reported_rows(claude, m.tools.mutable) {
            match rows.iter_mut().find(|own| own.id == row.id) {
                Some(own) => own.enabled = row.enabled,
                None => rows.push(row),
            }
        }
        if rows == m.tools.rows {
            return;
        }
        m.tools.rows = rows;
        drop(m);
        self.append(session, "mux", "tools", json!({"reported": true}));
        self.save_meta(session);
    }

    /// `_acpmux/set_tools`: turn the chat's tool `id` on or off. Claude Code
    /// gets `mcp_toggle` for an MCP server; the row changes once it accepted.
    pub async fn set_tools(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let id = params
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("id is required"))?;
        let enabled = params
            .get("enabled")
            .and_then(Value::as_bool)
            .ok_or_else(|| RpcError::invalid_params("enabled is required (true or false)"))?;
        // A started agent has recorded its tools and whether they change.
        self.child_for(session).await?;
        let tools = session.meta().tools;
        if !tools.mutable {
            return Err(RpcError::new(
                -32000,
                "this chat's harness takes its tools when the chat starts and cannot turn one on or off",
            )
            .with_data(json!({"reason": TOOLS_IMMUTABLE})));
        }
        let row = tools
            .rows
            .iter()
            .find(|r| r.id == id)
            .ok_or_else(|| RpcError::not_found(format!("this chat has no tool {id:?}")))?;
        let server = id.strip_prefix("mcp:").filter(|_| row.can_toggle).ok_or_else(|| {
            RpcError::new(
                -32000,
                format!("{} cannot be turned on or off in a running chat", row.name),
            )
            .with_data(json!({"reason": TOOL_FIXED}))
        })?;
        self.forward(
            session,
            method::MUX_SET_TOOLS,
            json!({"serverName": server, "enabled": enabled}),
        )
        .await?;
        {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(row) = m.tools.rows.iter_mut().find(|r| r.id == id) {
                row.enabled = enabled;
            }
        }
        // Watchers hear it as `_acpmux/session_changed` kind `tools`.
        self.append(session, "mux", "tools", json!({"id": id, "enabled": enabled}));
        self.save_meta(session);
        let tools = session.meta().tools;
        Ok(json!({"sessionId": session.id, "tools": tools.rows, "toolsMutable": tools.mutable}))
    }
}

/// The rows of Claude Code's system/init: its MCP servers (`{name, status}`,
/// off when `disabled`), which `toggles` says it turns on or off, then its
/// plugins and skills (a name, or `{name}`). cmux's own plugin is listed by
/// its skills only. The `tools` names are not rows: an MCP tool belongs to
/// its server, a built-in tool to Claude Code.
fn reported_rows(claude: &Value, toggles: bool) -> Vec<ToolRow> {
    let list = |key: &str| claude.get(key).and_then(Value::as_array).into_iter().flatten();
    let name =
        |v: &Value| v.as_str().or_else(|| v.get("name").and_then(Value::as_str)).map(str::to_owned);
    let row = |kind: &str, name: String, enabled: bool, can_toggle: bool| ToolRow {
        id: format!("{kind}:{name}"),
        name,
        kind: kind.to_owned(),
        source: "claude".to_owned(),
        enabled,
        can_toggle,
    };
    let mut rows = Vec::new();
    for server in list("mcp_servers") {
        if let Some(n) = name(server) {
            let on = server.get("status").and_then(Value::as_str) != Some("disabled");
            rows.push(row("mcp", n, on, toggles));
        }
    }
    let plugins = list("plugins").filter_map(name).filter(|n| n != crate::agent_tools::PLUGIN_NAME);
    rows.extend(plugins.map(|n| row("plugin", n, true, false)));
    rows.extend(list("skills").filter_map(name).map(|n| row("skill", n, true, false)));
    rows
}
