//! Subagent attribution for session updates.
//!
//! Harnesses report subagents three ways: native ACP subagent sessions
//! (draft agentclientprotocol/agent-client-protocol#1992: `subagent_spawned`,
//! `subagent_state_update`, and the child's updates under its own session
//! id), Codex's legacy `spawnAgent` collaboration calls, and Codex's legacy
//! subagent activity items. The hub forwards every update under its own
//! session id, so the child's id would be lost; this module writes one model
//! into each update's `_meta.acpmux` instead:
//!
//! - `subagent`: the subagent whose session the update belongs to.
//! - `subagents`: subagents this update starts or changes, each
//!   `{id, parent, name?, task?, prompt?, state, toolCallId?}`, with `parent`
//!   null for the session's own subagents and `state` one of `running`,
//!   `completed`, `failed`, `cancelled` or `disconnected`.

use crate::hub::merge_mux_meta;
use serde_json::{Map, Value, json};
use std::collections::HashMap;

/// The subagents seen in one session, each mapped to its parent subagent
/// (`None` for the session's own).
#[derive(Debug, Default)]
pub struct SubagentTree {
    parents: HashMap<String, Option<String>>,
}

impl SubagentTree {
    /// Whether `session_id` is one of this session's subagents.
    pub fn owns(&self, session_id: &str) -> bool {
        self.parents.contains_key(session_id)
    }

    /// Writes the subagent model into one `session/update`'s params. Returns
    /// the subagent the update belongs to, or `None` for the session's own.
    pub fn annotate(&mut self, params: &mut Value) -> Option<String> {
        let owner = params
            .get("sessionId")
            .and_then(Value::as_str)
            .filter(|sid| self.parents.contains_key(*sid))
            .map(str::to_owned);
        let events =
            params.get("update").map(|u| self.events(u, owner.as_deref())).unwrap_or_default();
        let mut fields = Map::new();
        if let Some(owner) = &owner {
            fields.insert("subagent".into(), json!(owner));
        }
        if !events.is_empty() {
            fields.insert("subagents".into(), Value::Array(events));
        }
        if !fields.is_empty() {
            merge_mux_meta(params, Value::Object(fields));
        }
        owner
    }

    fn events(&mut self, update: &Value, owner: Option<&str>) -> Vec<Value> {
        let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("subagent_spawned") => {
                let Some(id) = s(update, "subagentSessionId") else { return vec![] };
                let mut event = self.spawn(&id, owner);
                for key in ["name", "task", "prompt"] {
                    if let Some(v) = s(update, key) {
                        event.insert(key.into(), json!(v));
                    }
                }
                // The tool call that started it (Claude's Agent call), which a
                // client drawing the subagent can leave out.
                if let Some(call) = update.pointer("/_meta/claude/toolUseId") {
                    event.insert("toolCallId".into(), call.clone());
                }
                event.insert("state".into(), json!("running"));
                vec![Value::Object(event)]
            }
            Some("subagent_state_update") => {
                let Some(id) = s(update, "subagentSessionId") else { return vec![] };
                let state = s(update, "state").unwrap_or_else(|| "completed".into());
                let mut event = self.spawn(&id, owner);
                event.insert("state".into(), json!(state));
                vec![Value::Object(event)]
            }
            Some("tool_call" | "tool_call_update") => self.codex_legacy(update, owner),
            _ => vec![],
        }
    }

    /// Codex without native subagent sessions: `spawnAgent` collaboration
    /// calls list their children and states; activity items name one child.
    fn codex_legacy(&mut self, update: &Value, owner: Option<&str>) -> Vec<Value> {
        let codex = update.pointer("/_meta/codex");
        if let Some(collab) = codex.and_then(|c| c.get("collaboration"))
            && collab.get("tool").and_then(Value::as_str) == Some("spawnAgent")
        {
            let input = update.get("rawInput");
            let states = input.and_then(|i| i.get("agentsStates"));
            let task = input.and_then(|i| i.get("prompt")).and_then(Value::as_str);
            let ids = collab
                .get("receiverThreadIds")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            return ids
                .iter()
                .filter_map(Value::as_str)
                .map(|id| {
                    let status = states
                        .and_then(|s| s.get(id))
                        .and_then(|s| s.get("status"))
                        .and_then(Value::as_str);
                    let mut event = self.spawn(id, owner);
                    if let Some(task) = task {
                        event.insert("task".into(), json!(task));
                    }
                    event.insert("state".into(), json!(codex_state(status)));
                    if let Some(call) = update.get("toolCallId") {
                        event.insert("toolCallId".into(), call.clone());
                    }
                    Value::Object(event)
                })
                .collect();
        }
        let Some(activity) = codex.and_then(|c| c.get("subagent")) else { return vec![] };
        let Some(id) = activity.get("threadId").and_then(Value::as_str) else { return vec![] };
        let name = activity
            .get("path")
            .and_then(Value::as_str)
            .and_then(|p| p.split('/').rfind(|part| !part.is_empty()))
            .map(str::to_owned);
        let state = match activity.get("activity").and_then(Value::as_str) {
            Some("completed") => "completed",
            Some("interrupted") => "cancelled",
            _ => "running",
        };
        let mut event = self.spawn(id, owner);
        if let Some(name) = name {
            event.insert("name".into(), json!(name));
        }
        event.insert("state".into(), json!(state));
        vec![Value::Object(event)]
    }

    /// Records `id` under `owner` the first time it appears and starts its
    /// event with its id and parent.
    fn spawn(&mut self, id: &str, owner: Option<&str>) -> Map<String, Value> {
        let parent =
            self.parents.entry(id.to_owned()).or_insert_with(|| owner.map(str::to_owned)).clone();
        let mut event = Map::new();
        event.insert("id".into(), json!(id));
        event.insert("parent".into(), json!(parent));
        event
    }
}

/// A Codex agent status as a subagent state (codex-acp's `terminalStateOf`).
fn codex_state(status: Option<&str>) -> &'static str {
    match status {
        Some("completed") => "completed",
        Some("interrupted") => "cancelled",
        Some("errored" | "shutdown" | "notFound") => "failed",
        _ => "running",
    }
}
