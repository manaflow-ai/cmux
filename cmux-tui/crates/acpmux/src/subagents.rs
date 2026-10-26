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
//!   `{id, parent, name?, task?, prompt?, kind?, state, toolCallId?}`, with `parent`
//!   null for the session's own subagents and `state` one of `running`,
//!   `completed`, `failed`, `cancelled` or `disconnected`. A running one's
//!   progress adds `tokens`, `toolUses`, `elapsedMs`, `action` and, for a
//!   Claude workflow (`kind: "workflow"`), `agents: {done, started, failed?,
//!   queued?}`, its `runId` and `scriptPath` (what a resume names again)
//!   and `argsDigest` (a digest of its args, never the args) and, from Claude's progress snapshots, its
//!   `phases` (`{index, title}`, whole, when they change) and
//!   `workflowAgents`: each agent that changed, as its `index` and only the
//!   fields that changed (a removed one null), which a client merges by the
//!   subagent's id and `index`; at the run's end, every agent whole with
//!   `workflowAgentsFull: true`, which replaces them. An agent's fields are `label`, `state` (`queued`, `running`,
//!   `completed`, `failed`, `skipped` or `blocked`), `phase`, `phaseIndex`,
//!   `agentId`, `kind`, `model`, `fallbackModel`, `tokens`, `toolUses`,
//!   `elapsedMs`, `queuedAt`, `startedAt`, `lastProgressAt`, `attempt`,
//!   `retryReason`, `cached`, `isolation`, `remoteSessionId`, `action`,
//!   `prompt`, `result` and `error` (`claude_stdio/workflows.rs`). A
//!   subagent's end may say why (`reason`: `paused` for a Claude workflow a
//!   resume can pick up by its `runId`). A failed one may say its `error`, and a Claude
//!   agent its `agentId` (what SendMessage resumes it by; a resume reports it `running`
//!   again).
//!   `background: true` marks one that outlives its parent's turn (every
//!   Codex child, which runs in its own thread).

use crate::hub::merge_mux_meta;
use serde_json::{Map, Value, json};
use std::collections::HashMap;

/// Whether a `session/update` params object is a subagent's (the hub tags it
/// `_meta.acpmux.subagent`, ``SubagentTree::annotate``). A subagent's text and
/// thinking reach its own view; a reader of the chat's own words (a reply, a
/// transcript, a handoff) skips them, or a subagent's report would join the
/// chat's answer.
pub fn is_subagents(params: &Value) -> bool {
    params.pointer("/_meta/acpmux/subagent").is_some()
}

/// The subagents seen in one session, each mapped to its parent subagent
/// (`None` for the session's own).
#[derive(Debug, Default)]
pub struct SubagentTree {
    parents: HashMap<String, Option<String>>,
    /// The session's own agent session id (its harness thread), once known:
    /// never one of its subagents.
    own: Option<String>,
}

impl SubagentTree {
    /// Whether `session_id` is one of this session's subagents.
    pub fn owns(&self, session_id: &str) -> bool {
        self.own.as_deref() != Some(session_id) && self.parents.contains_key(session_id)
    }

    /// Names the session's own agent session id. A subagent may report its
    /// parent thread's state (Codex's app server sends a child's
    /// `subagent_state_update` for the root thread when the child talks to
    /// it); that is not a spawn, and recording it made the chat its own
    /// subagent: every later update of the chat read as that subagent's, and
    /// every later spawn nested under it.
    pub fn set_own(&mut self, own: Option<&str>) {
        if self.own.as_deref() != own {
            self.own = own.map(str::to_owned);
        }
    }

    /// Writes the subagent model into one `session/update`'s params. Returns
    /// the subagent the update belongs to, or `None` for the session's own.
    pub fn annotate(&mut self, params: &mut Value) -> Option<String> {
        let owner = params
            .get("sessionId")
            .and_then(Value::as_str)
            .filter(|sid| self.owns(sid))
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
                let Some(mut event) = self.spawn(&id, owner) else { return vec![] };
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
                // The kind of agent it is (Claude's subagent_type: Explore,
                // general-purpose, a user agent), drawn beside its name.
                if let Some(kind) =
                    update.pointer("/_meta/claude/subagentType").and_then(Value::as_str)
                {
                    event.insert("kind".into(), json!(kind));
                }
                if update.get("background") == Some(&Value::Bool(true)) {
                    event.insert("background".into(), json!(true));
                }
                event.insert("state".into(), json!("running"));
                vec![Value::Object(event)]
            }
            Some("subagent_state_update") => {
                let Some(id) = s(update, "subagentSessionId") else { return vec![] };
                let state = s(update, "state").unwrap_or_else(|| "completed".into());
                let Some(mut event) = self.spawn(&id, owner) else { return vec![] };
                event.insert("state".into(), json!(state));
                // Why it ended, when the harness says (`paused`: a Claude workflow
                // whose run a resume can pick up again by its `runId`).
                if let Some(reason) = s(update, "reason") {
                    event.insert("reason".into(), json!(reason));
                }
                // A failed Claude agent's error, and the agent id SendMessage resumes it by.
                for key in ["agentId", "error"] {
                    if let Some(v) = s(update, key) {
                        event.insert(key.into(), json!(v));
                    }
                }
                vec![Value::Object(event)]
            }
            // A running subagent's or workflow's live numbers (claude_stdio/workflows.rs).
            Some("subagent_progress") => {
                let Some(id) = s(update, "subagentSessionId") else { return vec![] };
                let Some(mut event) = self.spawn(&id, owner) else { return vec![] };
                event.insert("state".into(), json!("running"));
                for key in [
                    "name",
                    "task",
                    "tokens",
                    "toolUses",
                    "elapsedMs",
                    "action",
                    "agents",
                    "runId",
                    "scriptPath",
                    "argsDigest",
                    "phases",
                    "workflowAgents",
                    "workflowAgentsFull",
                    "background",
                ] {
                    if let Some(v) = update.get(key).filter(|v| !v.is_null()) {
                        event.insert(key.into(), v.clone());
                    }
                }
                vec![Value::Object(event)]
            }
            Some("tool_call" | "tool_call_update") => self.codex_legacy(update, owner),
            _ => vec![],
        }
    }

    /// Codex without native subagent sessions: `spawnAgent` collaboration
    /// calls list their children and states; activity items name one child.
    /// Each child runs in its own thread and outlives the turn that spawned it
    /// (the model may end its turn without a `wait`), so every one is
    /// `background`: a client never ends it at its turn's end.
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
                .filter_map(|id| {
                    let status = states
                        .and_then(|s| s.get(id))
                        .and_then(|s| s.get("status"))
                        .and_then(Value::as_str);
                    let mut event = self.spawn(id, owner)?;
                    if let Some(task) = task {
                        event.insert("task".into(), json!(task));
                    }
                    event.insert("state".into(), json!(codex_state(status)));
                    event.insert("background".into(), json!(true));
                    if let Some(call) = update.get("toolCallId") {
                        event.insert("toolCallId".into(), call.clone());
                    }
                    Some(Value::Object(event))
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
        let Some(mut event) = self.spawn(id, owner) else { return vec![] };
        if let Some(name) = name {
            event.insert("name".into(), json!(name));
        }
        event.insert("state".into(), json!(state));
        event.insert("background".into(), json!(true));
        vec![Value::Object(event)]
    }

    /// Records `id` under `owner` the first time it appears and starts its
    /// event with its id and parent. None when `id` is not a subagent of
    /// `owner`'s: the session itself, or `owner` or one of its ancestors (a
    /// child reporting on the thread above it), which would make a loop.
    fn spawn(&mut self, id: &str, owner: Option<&str>) -> Option<Map<String, Value>> {
        if self.own.as_deref() == Some(id) || self.is_ancestor(id, owner) {
            return None;
        }
        let parent =
            self.parents.entry(id.to_owned()).or_insert_with(|| owner.map(str::to_owned)).clone();
        let mut event = Map::new();
        event.insert("id".into(), json!(id));
        event.insert("parent".into(), json!(parent));
        Some(event)
    }

    /// Whether `id` is `of` or above it in the tree.
    fn is_ancestor(&self, id: &str, of: Option<&str>) -> bool {
        let mut at = of;
        // The tree has no loops (``spawn``), but a bound costs nothing.
        for _ in 0..=self.parents.len() {
            match at {
                Some(node) if node == id => return true,
                Some(node) => at = self.parents.get(node).and_then(Option::as_deref),
                None => return false,
            }
        }
        false
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

#[cfg(test)]
mod codex_tests {
    use super::*;

    fn subagents(tree: &mut SubagentTree, update: Value) -> Vec<Value> {
        let mut params = json!({"sessionId": "s1", "update": update});
        tree.annotate(&mut params);
        params
            .pointer("/_meta/acpmux/subagents")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    }

    /// Leo's Codex chat (2026-10-22): its child `needs_you_review` reported
    /// the chat's own thread as running, under the child's session. That is
    /// not a spawn: the chat stays the root, its own updates stay its own, and
    /// its next child sits beside the first rather than under the chat.
    #[test]
    fn a_child_reporting_its_parent_thread_never_makes_the_chat_a_subagent() {
        let chat = "01a1658b-c32f-72b1-ab04-d5444235a91c";
        let review = "01a16655-c696-7982-9c38-9ededd986f9b";
        let prior_art = "01a16656-bb2d-7513-b459-4a893451d37a";
        let mut tree = SubagentTree::default();
        tree.set_own(Some(chat));
        let mut annotate = |sid: &str, update: Value| {
            let mut params = json!({"sessionId": sid, "update": update});
            let owner = tree.annotate(&mut params);
            (owner, params.pointer("/_meta/acpmux").cloned())
        };
        annotate(
            chat,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": review,
                   "name": "needs_you_review", "task": "needs_you_review"}),
        );
        // The child names its parent thread.
        let (owner, mux) = annotate(
            review,
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": chat, "state": "running"}),
        );
        assert_eq!(owner.as_deref(), Some(review));
        assert_eq!(mux, Some(json!({"subagent": review})), "the chat is not one of its subagents");
        // The chat's own words stay the chat's.
        let (owner, mux) = annotate(
            chat,
            json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hi"}}),
        );
        assert_eq!((owner, mux), (None, None));
        // Its next child is a top-level subagent, not a grandchild under the chat.
        let (_, mux) = annotate(
            chat,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": prior_art,
                   "name": "needs_you_prior_art"}),
        );
        assert_eq!(mux.unwrap()["subagents"][0]["parent"], Value::Null);
        // A grandchild reporting on the subagent above it makes no loop either.
        let grandchild = "01a16657-46e1-79a0-a61e-d1a99a36d095";
        annotate(
            prior_art,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": grandchild, "name": "g"}),
        );
        let (_, mux) = annotate(
            grandchild,
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": prior_art, "state": "running"}),
        );
        assert_eq!(mux, Some(json!({"subagent": grandchild})));
        assert!(!tree.owns(chat));
    }

    /// A failed Claude agent's entry says why and which agent a resume names.
    #[test]
    fn a_failed_subagent_carries_its_error_and_agent_id() {
        let mut tree = SubagentTree::default();
        subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "s1/t1", "name": "Push relay"}),
        );
        let end = subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "s1/t1", "state": "failed",
                   "agentId": "a8e1", "error": "API Error: 503"}),
        );
        assert_eq!(
            end,
            [
                json!({"id": "s1/t1", "parent": null, "state": "failed", "agentId": "a8e1", "error": "API Error: 503"})
            ]
        );
    }

    /// Codex runs a `spawnAgent` child in its own thread: it outlives the turn
    /// that spawned it (the model may end its turn without a `wait`), so it is
    /// background work, and a client never ends it at the turn's end.
    #[test]
    fn codex_spawned_agents_are_background() {
        let mut tree = SubagentTree::default();
        let spawn = subagents(
            &mut tree,
            json!({"sessionUpdate": "tool_call", "toolCallId": "c1",
                   "rawInput": {"prompt": "Audit", "agentsStates": {"t1": {"status": "running"}}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent", "receiverThreadIds": ["t1"]}}}}),
        );
        assert_eq!(spawn.len(), 1);
        assert_eq!(spawn[0]["background"], json!(true));
        let activity = subagents(
            &mut tree,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "c2",
                   "_meta": {"codex": {"subagent": {"threadId": "t1", "path": "/root/auditor", "activity": "working"}}}}),
        );
        assert_eq!(activity[0]["state"], json!("running"));
        assert_eq!(activity[0]["background"], json!(true));
    }
}
