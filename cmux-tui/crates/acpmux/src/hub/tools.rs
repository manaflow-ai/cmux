//! Part of `Hub`; see `hub/mod.rs`. The tools a chat has (cx-thur3), for
//! the pane's tool list: cmux's own (`agent_tools.rs`), recorded at each
//! spawn as the spawn gives them (none for a session they leave out), then
//! the MCP servers, plugins and skills Claude Code's system/init reports.
//! The user's own harness config files are never read here.
//!
//! `_acpmux/set_tools` turns one MCP server off or on again for one chat.
//! Only Claude Code can: the chat's choice is kept in its meta
//! (`ToolInventory::off`) and every start of its Claude Code gets
//! `--disallowedTools mcp__<server>` for each server that is off
//! (`spawn.rs`). An idle chat restarts now and resumes; a running turn keeps
//! its process, which restarts when the turn ends. Claude Code's own
//! `mcp_toggle` is never sent: it writes `disabledMcpServers` into the
//! folder's entry of `~/.claude.json`, which turns the server off for every
//! Claude session in that folder and outlives the chat. Anything else is
//! refused, never a silent no-op.

use super::*;

use crate::store::{ToolInventory, ToolRow};

/// `data.reason` of a set on a chat whose harness takes its tools at
/// session start only (every ACP harness).
pub const TOOLS_IMMUTABLE: &str = "tools.immutable";
/// `data.reason` of a set on a row that cannot change here (a skill, a
/// plugin, or a server the user's own Claude config turned off).
pub const TOOL_FIXED: &str = "tools.fixed";

impl Hub {
    /// What `ensure_child` records before it starts an agent: its launch
    /// roots (`launch_roots.rs`) and cmux's tools as this spawn gives them,
    /// with the chat's choices. What Claude Code reported for the last
    /// process stays until its next system/init.
    pub(super) async fn record_spawn_inputs(&self, session: &Session, profile: &HarnessProfile) {
        self.record_launch_roots(session, profile).await;
        let claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
        // Claude Code also leaves them out for `--strict-mcp-config`; an ACP
        // harness gets them in `mcpServers` whatever its args.
        let args: &[String] = if claude { &profile.argv } else { &[] };
        let remote = session.meta().remote_origin;
        let left_out = crate::agent_tools::left_out(remote, &profile.env, args);
        session.launched_with_tools.store(if left_out { 2 } else { 1 }, Ordering::SeqCst);
        self.record_preview_format(session, crate::agent::preview_format(profile));
        let mut cmux = if left_out {
            Vec::new()
        } else {
            crate::agent_tools::current().scoped(&profile.env).tool_rows(claude, claude)
        };
        let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        for row in &mut cmux {
            row.enabled = !m.tools.off.contains(&row.id);
            // What the harness last said of it stays until its next report.
            row.status =
                m.tools.rows.iter().find(|r| r.id == row.id).and_then(|r| r.status.clone());
        }
        let reported = m.tools.rows.iter().filter(|r| r.source != "cmux").cloned();
        m.tools.rows = cmux.into_iter().chain(reported).collect();
        m.tools.mutable = claude;
    }

    /// How the session's agent writes question previews: as recorded at its
    /// launch (`record_preview_format`), so an agent adopted after a daemon
    /// restart keeps the format it was started with.
    pub(super) fn preview_format(session: &Session) -> super::questions::PreviewFormat {
        let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        super::questions::PreviewFormat::from_flag(meta.html_previews)
    }

    /// Records how the session's agent writes its question previews. A launch
    /// records its profile's format first (`agent::preview_format`), then the
    /// one its command was pinned to (`agent::pinned_preview_format`): a cold
    /// start's, or a pooled agent's from its prewarm (`pool/`), which a later
    /// resolution of a `${env:…}` or keychain reference could disagree with.
    pub(super) fn record_preview_format(
        &self,
        session: &Session,
        format: super::questions::PreviewFormat,
    ) {
        let html = format == super::questions::PreviewFormat::Html;
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let was = std::mem::replace(&mut meta.html_previews, html);
        drop(meta);
        if was != html {
            self.save_meta(session);
        }
    }

    /// Claude Code's system/init (`_meta.claude` of its session_info_update):
    /// the rows it reports replace the last ones; cmux's own rows stay, on or
    /// off as Claude Code reports them. A server the chat turned off stays
    /// off; one Claude Code reports `disabled` (the user's own config) cannot
    /// be turned on here.
    pub(super) fn absorb_reported_tools(&self, session: &Session, claude: &Value) {
        let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let mut rows: Vec<ToolRow> =
            m.tools.rows.iter().filter(|r| r.source == "cmux").cloned().collect();
        for mut row in reported_rows(claude) {
            let off = m.tools.off.contains(&row.id);
            let toggles = m.tools.mutable && row.kind == "mcp" && (row.enabled || off);
            row.enabled &= !off;
            match rows.iter_mut().find(|own| own.id == row.id) {
                Some(own) => {
                    own.enabled = row.enabled;
                    own.can_toggle &= toggles;
                    own.status = row.status;
                }
                None => rows.push(ToolRow { can_toggle: toggles, ..row }),
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

    /// `_acpmux/set_tools`: record the chat's choice for tool `id`, then
    /// restart an idle chat's Claude Code on it (`applied: now`); during a
    /// turn, or with no process, it applies at the next start (`nextStart`).
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
        // From the harness alone: an idle chat is not started to be refused.
        let meta = session.meta();
        let kind = {
            let cfg = self.config.read().await;
            super::resolve::session_profile(&cfg, &meta.harness, &meta.cwd, meta.remote_origin)
                .map_err(RpcError::invalid_params)?
                .kind
        };
        if kind != crate::config::HarnessKind::ClaudeStdio {
            return Err(RpcError::new(
                -32000,
                "this chat's harness takes its tools when the chat starts and cannot turn one on or off",
            )
            .with_data(json!({"reason": TOOLS_IMMUTABLE})));
        }
        let row = meta
            .tools
            .rows
            .iter()
            .find(|r| r.id == id)
            .ok_or_else(|| RpcError::not_found(format!("this chat has no tool {id:?}")))?;
        if !row.can_toggle || !id.starts_with("mcp:") {
            return Err(RpcError::new(
                -32000,
                format!("{} cannot be turned on or off in this chat", row.name),
            )
            .with_data(json!({"reason": TOOL_FIXED})));
        }
        {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            m.tools.off.retain(|off| off != id);
            if !enabled {
                m.tools.off.push(id.to_owned());
            }
            if let Some(row) = m.tools.rows.iter_mut().find(|r| r.id == id) {
                row.enabled = enabled;
            }
        }
        // Watchers hear it as `_acpmux/session_changed` kind `tools`.
        self.append(session, "mux", "tools", json!({"id": id, "enabled": enabled}));
        self.save_meta(session);
        // The route switch's restart: the process ends, and a new one resumes
        // the same conversation (`route_switch.rs`). Holding the turn lock, no
        // prompt starts on the process being stopped; a turn that holds it
        // restarts the process when it ends (`turns.rs`).
        let applied = if session.child.lock().await.is_none() {
            "nextStart"
        } else if let Ok(_turn) = session.turn_lock.try_lock() {
            self.restart_on_route(session).await?;
            "now"
        } else {
            session.route_switch.store(true, Ordering::SeqCst);
            "afterTurn"
        };
        let tools = session.meta().tools;
        Ok(json!({
            "sessionId": session.id,
            "tools": tools.rows,
            "toolsMutable": tools.mutable,
            "applied": applied,
        }))
    }

    /// `_acpmux/mcp/reconnect`: Claude Code's `mcp_reconnect` for one of the
    /// chat's MCP servers (a failed or disconnected one), on the running
    /// process; it never starts one, as the next start connects every server.
    /// Once Claude Code reconnected it, its row reads connected until the next
    /// system/init says otherwise. Anything but Claude Code is refused.
    pub async fn reconnect_mcp(
        &self,
        session: &Arc<Session>,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let server = params
            .get("server")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| RpcError::invalid_params("server is required"))?;
        // From the harness alone, as `set_tools`: an idle chat is not started to be refused.
        let meta = session.meta();
        let kind = {
            let cfg = self.config.read().await;
            super::resolve::session_profile(&cfg, &meta.harness, &meta.cwd, meta.remote_origin)
                .map_err(RpcError::invalid_params)?
                .kind
        };
        if kind != crate::config::HarnessKind::ClaudeStdio {
            return Err(RpcError::new(-32000, "only Claude Code reconnects an MCP server")
                .with_data(json!({"reason": MCP_UNSUPPORTED})));
        }
        let id = format!("mcp:{server}");
        if !meta.tools.rows.iter().any(|r| r.id == id) {
            return Err(RpcError::not_found(format!("this chat has no MCP server {server:?}")));
        }
        let child = session.child.lock().await.clone();
        let alive = match &child {
            Some(child) => child.is_alive().await,
            None => false,
        };
        let Some(child) = child.filter(|_| alive) else {
            return Err(RpcError::invalid_params(
                "this chat's Claude Code is not running: its MCP servers connect when it starts",
            ));
        };
        let params = json!({"sessionId": meta.agent_session_id, "server": server});
        // The translator forgets its own entry when Claude Code answers, late or not; a late answer
        // then reaches no one here (`request_within`).
        match child
            .request_within(crate::claude_stdio::MCP_RECONNECT, params, RECONNECT_TIMEOUT)
            .await
        {
            Some(Ok(_)) => {}
            Some(Err(e)) => return Err(e),
            None => {
                return Err(RpcError::internal("Claude Code did not answer mcp_reconnect in time"));
            }
        }
        // The agent that answered must still be the chat's: one a failover or restart replaced
        // while it reconnected says nothing of the new one's servers (its start connects them).
        // The child lock is held over the write, as a replacement takes it to detach the old.
        let current = session.child.lock().await;
        if !current.as_ref().is_some_and(|c| Arc::ptr_eq(c, &child)) {
            return Ok(json!({}));
        }
        let changed = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            match m.tools.rows.iter_mut().find(|r| r.id == id) {
                Some(row) if row.status.as_deref() != Some("connected") => {
                    row.status = Some("connected".to_owned());
                    true
                }
                _ => false,
            }
        };
        drop(current);
        // Watchers hear it as `_acpmux/session_changed` kind `tools` (`mcpServers`).
        if changed {
            self.append(session, "mux", "tools", json!({"reconnected": server}));
            self.save_meta(session);
        }
        Ok(json!({}))
    }
}

/// `data.reason` of an MCP reconnect on a chat whose harness is not Claude
/// Code (`_acpmux/mcp/reconnect`).
pub const MCP_UNSUPPORTED: &str = "mcp.unsupported";

/// How long `_acpmux/mcp/reconnect` waits for Claude Code: a server is
/// started (or dialed) again, which a slow one takes a while to do.
const RECONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// The prefix of an off row that names a Claude Code built-in tool the chat
/// was started without (`NewRequest::disallowed_tools`), not an MCP server.
pub(super) const BUILT_IN: &str = "tool:";

/// `--disallowedTools <tool>` for each built-in tool the chat was started
/// without, then `--disallowedTools mcp__<server>` for each server the chat
/// turned off, in Claude Code's spelling of a server name: other than
/// `[A-Za-z0-9_-]` becomes `_`, and for a `claude.ai ` connector runs of `_`
/// collapse and the ends trim (Claude Code 2.1.299).
pub(super) fn disallowed_args(tools: &ToolInventory) -> Vec<String> {
    let mut args = Vec::new();
    for tool in tools.off.iter().filter_map(|id| id.strip_prefix(BUILT_IN)) {
        args.push("--disallowedTools".to_owned());
        args.push(tool.to_owned());
    }
    for server in tools.off.iter().filter_map(|id| id.strip_prefix("mcp:")) {
        let mut name: String = server
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' })
            .collect();
        if server.starts_with("claude.ai ") {
            let mut collapsed = String::with_capacity(name.len());
            for c in name.chars() {
                if !(c == '_' && collapsed.ends_with('_')) {
                    collapsed.push(c);
                }
            }
            name = collapsed.trim_matches('_').to_owned();
        }
        args.push("--disallowedTools".to_owned());
        args.push(format!("mcp__{name}"));
    }
    args
}

/// The rows of Claude Code's system/init: its MCP servers (`{name, status}`,
/// with that status, off when `disabled`), then its plugins and skills (a
/// name, or `{name}`).
/// None can toggle until `absorb_reported_tools` decides. cmux's own plugin
/// is listed by its skills only. The `tools` names are not rows: an MCP
/// tool belongs to its server, a built-in tool to Claude Code.
fn reported_rows(claude: &Value) -> Vec<ToolRow> {
    let list = |key: &str| claude.get(key).and_then(Value::as_array).into_iter().flatten();
    let name =
        |v: &Value| v.as_str().or_else(|| v.get("name").and_then(Value::as_str)).map(str::to_owned);
    let row = |kind: &str, name: String, enabled: bool| ToolRow {
        id: format!("{kind}:{name}"),
        name,
        kind: kind.to_owned(),
        source: "claude".to_owned(),
        enabled,
        can_toggle: false,
        status: None,
    };
    let mut rows = Vec::new();
    for server in list("mcp_servers") {
        if let Some(n) = name(server) {
            let status = server.get("status").and_then(Value::as_str);
            let on = status != Some("disabled");
            rows.push(ToolRow { status: status.map(str::to_owned), ..row("mcp", n, on) });
        }
    }
    let plugins = list("plugins").filter_map(name).filter(|n| n != crate::agent_tools::PLUGIN_NAME);
    rows.extend(plugins.map(|n| row("plugin", n, true)));
    rows.extend(list("skills").filter_map(name).map(|n| row("skill", n, true)));
    rows
}
