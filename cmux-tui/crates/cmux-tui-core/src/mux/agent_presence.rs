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

pub use cmux_presence::AgentActivity;

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

impl AgentPresence {
    /// Local record for the sidebar's agent. The caller supplies its workspace, display name,
    /// fallback surface id and owner epoch (the hook's timestamp is not an ordering key).
    pub fn record(
        &self,
        workspace: &str,
        name: &str,
        surface: &str,
        epoch: u64,
    ) -> cmux_presence::Presence {
        use cmux_presence::{FileTarget, Kind, Presence, PresenceId};

        let id = self.session.as_deref().unwrap_or(surface);
        let mut record = Presence::new(PresenceId(id.into()), Kind::Agent, name, epoch);
        record.color = Some(id.into());
        record.doing = self.activity.into();
        record.location.workspace = Some(workspace.into());
        record.location.file =
            self.path.as_deref().map(|path| FileTarget { path: path.into(), line: self.line });
        record
    }
}

/// One terminal's presence and the journal sequence of the newest hook
/// event that touched it. Hooks can finish committing out of order, so an
/// event older than the watermark never changes presence; a cleared slot
/// keeps its watermark until the terminal closes.
#[derive(Debug, Default)]
pub(super) struct PresenceSlot {
    sequence: u64,
    presence: Option<AgentPresence>,
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
    let agent: Option<Arc<str>> = payload
        .get("adapter")
        .and_then(|adapter| adapter.get("id"))
        .and_then(Value::as_str)
        .map(Arc::from);
    let base = AgentPresence {
        activity: AgentActivity::Thinking,
        session: field("agent_session_id")
            .and_then(Value::as_str)
            .and_then(|session| published_agent_session_id(terminal_id, session))
            .map(Arc::from)
            // Events without a session id (tool hooks of some harnesses)
            // keep the session only when the same adapter reports them.
            .or_else(|| {
                previous
                    .filter(|previous| previous.agent == agent)
                    .and_then(|previous| previous.session.clone())
            }),
        agent,
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
    pub(super) fn apply_agent_presence(&self, ingress: &crate::JournalIngress, sequence: u64) {
        self.apply_agent_presence_at(ingress, Some(sequence));
    }

    /// Apply a hook report that got no journal row (`agent_hooks_at_rest.rs`).
    /// It has no sequence of its own: it comes after every row of its
    /// terminal, because a report is appended while one of those is still on
    /// its way to the journal. The watermark stays where the last row put it.
    pub(super) fn apply_live_agent_presence(&self, ingress: &crate::JournalIngress) {
        self.apply_agent_presence_at(ingress, None);
    }

    fn apply_agent_presence_at(&self, ingress: &crate::JournalIngress, sequence: Option<u64>) {
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
        let Some(surface) = self.agent_view_surface_for_terminal(&terminal_id) else { return };
        // Emit while holding the table so two events of one terminal reach
        // subscribers in the order they changed it. `emit` takes only the
        // subscriber lock and never this one.
        let mut table = self.agent_presence.lock().unwrap();
        let slot = table.entry(terminal_id.clone()).or_default();
        if let Some(sequence) = sequence {
            if slot.sequence >= sequence && slot.sequence != 0 {
                return;
            }
            slot.sequence = sequence;
        }
        let presence = match next_presence(slot.presence.as_ref(), ingress, &terminal_id, now_ms())
        {
            PresenceStep::Unchanged => return,
            PresenceStep::Set(presence) => {
                if slot.presence.as_ref() == Some(&presence) {
                    return;
                }
                slot.presence = Some(presence.clone());
                Some(Arc::new(presence))
            }
            PresenceStep::Clear => {
                slot.presence = None;
                None
            }
        };
        self.emit(MuxEvent::AgentPresenceChanged { surface, presence });
    }

    /// Every terminal's presence as `AgentPresenceChanged` events, a cleared one as `None`
    /// (`agent-presence-replay-v1`). A client that reconnects to this daemon keeps the presence it
    /// showed and takes these on its new subscription, so an agent that is still acting never
    /// blinks off, and one that stopped while the link was down is cleared (hq#19373). A slot
    /// stays until its terminal closes, and a closed terminal's tab leaves in the snapshot.
    pub(crate) fn agent_presence_replay(&self) -> Vec<MuxEvent> {
        let slots: Vec<(TerminalPublicId, Option<Arc<AgentPresence>>)> = self
            .agent_presence
            .lock()
            .unwrap()
            .iter()
            .map(|(terminal, slot)| (terminal.clone(), slot.presence.clone().map(Arc::new)))
            .collect();
        // The surface lookup takes the state lock: never while holding the table.
        slots
            .into_iter()
            .filter_map(|(terminal, presence)| {
                let surface = self.agent_view_surface_for_terminal(&terminal)?;
                Some(MuxEvent::AgentPresenceChanged { surface, presence })
            })
            .collect()
    }

    /// Clear a terminal's presence when its agent record goes idle or done
    /// by any path, including a screen-detected exit or a socket report that
    /// sends no hook event (a Ctrl-C'd or crashed agent).
    pub(super) fn clear_agent_presence(&self, terminal_id: &TerminalPublicId, surface: SurfaceId) {
        let mut table = self.agent_presence.lock().unwrap();
        let Some(slot) = table.get_mut(terminal_id) else { return };
        if slot.presence.take().is_some() {
            self.emit(MuxEvent::AgentPresenceChanged { surface, presence: None });
        }
    }
}
