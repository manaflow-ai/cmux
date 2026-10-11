//! Live agent presence (`agent-presence-v1`): what the agent in each terminal
//! is touching right now (its tool and the file and line it targets), reduced
//! from committed agent hook events and broadcast as
//! `agent-presence-changed`. Presence is ephemeral: it is never persisted,
//! replayed commits do not produce it, and turn end, session end and terminal
//! close clear it. Clients fade a record that stops updating.

use std::sync::Arc;

use serde_json::Value;

use super::*;
use crate::agent_hooks::semantic_key;

const MAX_PRESENCE_TOOL_BYTES: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentActivity {
    /// Between tool calls, or a tool presence cannot classify.
    Thinking,
    Editing,
    Reading,
    Running,
    Browsing,
    ComputerUse,
    /// Blocked on the user: an approval, a question or a plan review.
    Waiting,
}

impl AgentActivity {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentActivity::Thinking => "thinking",
            AgentActivity::Editing => "editing",
            AgentActivity::Reading => "reading",
            AgentActivity::Running => "running",
            AgentActivity::Browsing => "browsing",
            AgentActivity::ComputerUse => "computer_use",
            AgentActivity::Waiting => "waiting",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentPresence {
    pub activity: AgentActivity,
    /// The reporting adapter id (`claude`, `codex`, ...).
    pub agent: Option<Arc<str>>,
    /// The agent's own session id when it is portable (see
    /// `published_agent_session_id`); the stable identity for colour.
    pub session: Option<Arc<str>>,
    pub tool: Option<Arc<str>>,
    pub path: Option<Arc<str>>,
    pub line: Option<u64>,
    pub updated_at_ms: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum PresenceStep {
    Unchanged,
    Set(AgentPresence),
    Clear,
}

/// The presence `ingress` (a committed `cmux_agent` hook event for
/// `terminal_id`) leaves behind, given the terminal's current presence.
pub(super) fn next_presence(
    previous: Option<&AgentPresence>,
    ingress: &crate::JournalIngress,
    terminal_id: &TerminalPublicId,
    now_ms: u64,
) -> PresenceStep {
    let payload = &ingress.payload;
    let normalized = payload.get("normalized");
    let field = |name: &str| normalized.and_then(|fields| fields.get(name));
    let event = semantic_key(payload.get("native_event").and_then(Value::as_str).unwrap_or(""));
    let tool = field("tool_name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|tool| !tool.is_empty() && tool.len() <= MAX_PRESENCE_TOOL_BYTES)
        .map(Arc::<str>::from);
    let base = AgentPresence {
        activity: AgentActivity::Thinking,
        agent: payload
            .get("adapter")
            .and_then(|adapter| adapter.get("id"))
            .and_then(Value::as_str)
            .map(Arc::from),
        session: field("agent_session_id")
            .and_then(Value::as_str)
            .and_then(|session| published_agent_session_id(terminal_id, session))
            .map(Arc::from)
            .or_else(|| previous.and_then(|previous| previous.session.clone())),
        tool: None,
        path: None,
        line: None,
        updated_at_ms: field("observed_at_ms")
            .and_then(Value::as_str)
            .and_then(|observed| observed.parse().ok())
            .unwrap_or(now_ms),
    };
    let keep_target = |activity: AgentActivity| AgentPresence {
        activity,
        tool: previous.and_then(|previous| previous.tool.clone()),
        path: previous.and_then(|previous| previous.path.clone()),
        line: previous.and_then(|previous| previous.line),
        ..base.clone()
    };
    match ingress.kind.as_str() {
        "agent.session.started" | "agent.turn.completed" | "agent.session.ended" => {
            if previous.is_some() { PresenceStep::Clear } else { PresenceStep::Unchanged }
        }
        "agent.turn.started" => PresenceStep::Set(base),
        "agent.approval.requested" | "agent.question.requested" | "agent.plan_review.requested" => {
            PresenceStep::Set(keep_target(AgentActivity::Waiting))
        }
        // A failed tool call (PostToolUseFailure) ends the call like any
        // other post-tool event; other errors leave presence as it was.
        "agent.error.reported" if is_post_tool_event(&event) => {
            PresenceStep::Set(keep_target(AgentActivity::Thinking))
        }
        "agent.state.changed" if is_pre_tool_event(&event) => PresenceStep::Set(AgentPresence {
            activity: activity_for_tool(tool.as_deref(), &event),
            tool,
            path: field("tool_target_path").and_then(Value::as_str).map(Arc::from),
            line: field("tool_target_line").and_then(Value::as_u64),
            ..base
        }),
        "agent.state.changed" if is_post_tool_event(&event) => {
            // Cursor reports edits only after the fact (`afterFileEdit`);
            // show that edit instead of an empty "thinking".
            if event == "afterfileedit" {
                PresenceStep::Set(AgentPresence {
                    activity: AgentActivity::Editing,
                    path: field("tool_target_path").and_then(Value::as_str).map(Arc::from),
                    ..base
                })
            } else {
                PresenceStep::Set(keep_target(AgentActivity::Thinking))
            }
        }
        _ => PresenceStep::Unchanged,
    }
}

fn is_pre_tool_event(event: &str) -> bool {
    matches!(
        event,
        "pretooluse"
            | "beforetool"
            | "beforeshellexecution"
            | "beforemcpexecution"
            | "beforereadfile"
            | "toolexecutebefore"
            | "pretoolcall"
            | "toolexecutionstart"
            | "toolcall"
    )
}

fn is_post_tool_event(event: &str) -> bool {
    matches!(
        event,
        "posttooluse"
            | "posttoolusefailure"
            | "posttoolbatch"
            | "aftertool"
            | "aftershellexecution"
            | "aftermcpexecution"
            | "afterfileedit"
            | "toolexecuteafter"
            | "posttoolcall"
            | "toolexecutionend"
            | "toolresult"
    )
}

/// What a tool call is doing, from the tool's name across harnesses (Claude,
/// Codex, Gemini, OpenCode, Cursor, Amp, ...), or from the native event when
/// the harness names no tool (Cursor's shell and file hooks).
pub(super) fn activity_for_tool(tool: Option<&str>, event: &str) -> AgentActivity {
    let Some(tool) = tool else {
        return match event {
            "beforeshellexecution" => AgentActivity::Running,
            "beforereadfile" => AgentActivity::Reading,
            _ => AgentActivity::Thinking,
        };
    };
    let key = semantic_key(tool);
    // MCP tools are `mcp__<server>__<tool>`: the server names the surface.
    if key.contains("computer") || key.contains("cua") {
        return AgentActivity::ComputerUse;
    }
    if key.contains("browser") || key.contains("playwright") || key.contains("chrome") {
        return AgentActivity::Browsing;
    }
    match key.as_str() {
        "edit" | "multiedit" | "write" | "notebookedit" | "applypatch" | "replace"
        | "writefile" | "strreplace" | "strreplaceeditor" | "create" | "patch" | "editfile" => {
            AgentActivity::Editing
        }
        "read" | "readfile" | "readmanyfiles" | "view" | "grep" | "glob" | "ls" | "list"
        | "listdirectory" | "search" | "searchfiles" | "find" | "codebasesearch" => {
            AgentActivity::Reading
        }
        "bash" | "shell" | "exec" | "execcommand" | "localshell" | "runshellcommand"
        | "terminal" | "command" | "runterminalcmd" | "writestdin" => AgentActivity::Running,
        _ => AgentActivity::Thinking,
    }
}

impl Mux {
    /// Apply one freshly committed (not replayed) journal event to the live
    /// presence table and broadcast the change. Hook events for a terminal
    /// with no live placement are dropped: presence has nothing to point at.
    pub(super) fn apply_agent_presence(&self, ingress: &crate::JournalIngress) {
        if ingress.producer_id != crate::agent_hooks::AGENT_HOOK_PRODUCER_ID
            || ingress.payload.get("native_event").and_then(Value::as_str)
                == Some(crate::journal_reducers::LEGACY_SCREEN_DETECT_NATIVE_EVENT)
        {
            return;
        }
        let Some(terminal_id) = ingress
            .subjects
            .iter()
            .find(|subject| subject.kind == "terminal")
            .and_then(|subject| TerminalPublicId::parse(&subject.id).ok())
        else {
            return;
        };
        let Some(surface) = self.resource_surface_for_terminal(&terminal_id) else { return };
        let mut table = self.agent_presence.lock().unwrap();
        let presence = match next_presence(
            table.get(&terminal_id),
            ingress,
            &terminal_id,
            super::time::now_ms(),
        ) {
            PresenceStep::Unchanged => return,
            PresenceStep::Set(presence) => {
                if table.get(&terminal_id) == Some(&presence) {
                    return;
                }
                table.insert(terminal_id, presence.clone());
                Some(Arc::new(presence))
            }
            PresenceStep::Clear => {
                table.remove(&terminal_id);
                None
            }
        };
        drop(table);
        self.emit(MuxEvent::AgentPresenceChanged { surface, presence });
    }
}
