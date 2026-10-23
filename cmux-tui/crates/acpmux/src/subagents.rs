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
//!   Claude workflow (`kind: "workflow"`), `agents: {done, started}`.
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
    /// Codex's native id for this session, learned from a collab call. Legacy
    /// activity metadata can echo this id while a child is running; it is the
    /// root, never a subagent of the child that reported it.
    root_thread: Option<String>,
}

impl SubagentTree {
    /// Seed the native harness session id before the first update. The hub's
    /// ACP wrapper id is different from Codex's native thread id.
    pub fn set_root(&mut self, id: &str) {
        self.remember_root(id);
    }

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
                let mut event = self.spawn(&id, owner);
                event.insert("state".into(), json!(state));
                vec![Value::Object(event)]
            }
            // A running subagent's or workflow's live numbers (claude_stdio/workflows.rs).
            Some("subagent_progress") => {
                let Some(id) = s(update, "subagentSessionId") else { return vec![] };
                let mut event = self.spawn(&id, owner);
                event.insert("state".into(), json!("running"));
                for key in [
                    "name",
                    "task",
                    "tokens",
                    "toolUses",
                    "elapsedMs",
                    "action",
                    "agents",
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
            let sender = collab.get("senderThreadId").and_then(Value::as_str);
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
                    let (parent, authoritative) = match sender {
                        Some(sender) => (self.authoritative_parent(sender), true),
                        None => (owner.map(str::to_owned), false),
                    };
                    let mut event = if authoritative {
                        self.spawn_authoritative(id, parent.as_deref())
                    } else {
                        self.spawn_with_parent(id, parent.as_deref())
                    };
                    if let Some(task) = task {
                        event.insert("task".into(), json!(task));
                    }
                    event.insert("state".into(), json!(codex_state(status)));
                    event.insert("background".into(), json!(true));
                    if let Some(call) = update.get("toolCallId") {
                        event.insert("toolCallId".into(), call.clone());
                    }
                    Value::Object(event)
                })
                .collect();
        }
        let Some(activity) = codex.and_then(|c| c.get("subagent")) else { return vec![] };
        let Some(id) = activity.get("threadId").and_then(Value::as_str) else { return vec![] };
        // The root's own id is occasionally echoed as a legacy activity item
        // while a direct child is active. Do not manufacture a root child.
        if self.root_thread.as_deref() == Some(id) {
            return vec![];
        }
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
        event.insert("background".into(), json!(true));
        vec![Value::Object(event)]
    }

    /// Records `id` under `owner` the first time it appears and starts its
    /// event with its id and parent.
    fn spawn(&mut self, id: &str, owner: Option<&str>) -> Map<String, Value> {
        self.spawn_with_parent(id, owner)
    }

    fn spawn_authoritative(&mut self, id: &str, parent: Option<&str>) -> Map<String, Value> {
        let parent = parent.map(str::to_owned);
        let stored = self.parents.entry(id.to_owned()).or_insert_with(|| parent.clone());
        if *stored != parent {
            *stored = parent;
        }
        let current = stored.clone();
        let mut event = Map::new();
        event.insert("id".into(), json!(id));
        event.insert("parent".into(), json!(current));
        event
    }

    fn spawn_with_parent(&mut self, id: &str, parent: Option<&str>) -> Map<String, Value> {
        let parent =
            self.parents.entry(id.to_owned()).or_insert_with(|| parent.map(str::to_owned)).clone();
        let mut event = Map::new();
        event.insert("id".into(), json!(id));
        event.insert("parent".into(), json!(parent));
        event
    }

    /// Codex's sender id is authoritative when it names a known child or the
    /// native root. An unseen sender is deliberately left parentless: it may
    /// be a child whose spawn record has not arrived yet, so treating it as the
    /// root would create the hierarchy shown by the reported bug.
    fn authoritative_parent(&self, sender: &str) -> Option<String> {
        if self.root_thread.as_deref() == Some(sender) {
            None
        } else if self.parents.contains_key(sender) {
            Some(sender.to_owned())
        } else {
            None
        }
    }

    /// Record the native root id once, and repair an out-of-order echo that
    /// arrived before the root's first collab call identified it.
    fn remember_root(&mut self, id: &str) {
        if self.root_thread.as_deref() == Some(id) {
            return;
        }
        if self.root_thread.is_some() {
            return;
        }
        self.root_thread = Some(id.to_owned());
        self.parents.remove(id);
        for parent in self.parents.values_mut() {
            if parent.as_deref() == Some(id) {
                *parent = None;
            }
        }
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
        subagents_for(tree, "s1", update)
    }

    fn subagents_for(tree: &mut SubagentTree, session_id: &str, update: Value) -> Vec<Value> {
        let mut params = json!({"sessionId": session_id, "update": update});
        tree.annotate(&mut params);
        params
            .pointer("/_meta/acpmux/subagents")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
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

    /// A Codex root's native thread id may be echoed by a direct child as a legacy
    /// activity item. It is the root that issued the call, never a child of that
    /// direct child; later root spawns must remain siblings in the model.
    #[test]
    fn codex_root_thread_is_never_inserted_as_a_nested_subagent() {
        let mut tree = SubagentTree::default();
        let root = "root-native-thread";
        let review = "review-thread";
        let prior_art = "prior-art-thread";
        tree.set_root(root);

        let first = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [review]}}}}),
        );
        assert_eq!(first[0]["id"], review);
        assert_eq!(first[0]["parent"], Value::Null);

        // The child reports an activity item carrying the root's own native id.
        let echoed = subagents_for(
            &mut tree,
            review,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-root",
                   "_meta": {"codex": {"subagent": {"threadId": root,
                     "path": "/root", "activity": "working"}}}}),
        );
        assert!(echoed.is_empty(), "root echo became a child: {echoed:?}");

        let second = subagents_for(
            &mut tree,
            root,
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-prior-art",
                   "rawInput": {"prompt": "Prior art", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [prior_art]}}}}),
        );
        assert_eq!(second[0]["id"], prior_art);
        assert_eq!(second[0]["parent"], Value::Null);
    }

    #[test]
    fn codex_child_sender_remains_the_parent_of_a_grandchild() {
        let mut tree = SubagentTree::default();
        let child = "review-thread";
        let grandchild = "review-helper-thread";
        let first = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": "root-native-thread", "receiverThreadIds": [child]}}}}),
        );
        assert_eq!(first[0]["parent"], Value::Null);
        let nested = subagents_for(
            &mut tree,
            child,
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-helper",
                   "rawInput": {"prompt": "Helper", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": child, "receiverThreadIds": [grandchild]}}}}),
        );
        assert_eq!(nested[0]["id"], grandchild);
        assert_eq!(nested[0]["parent"], child);
    }

    #[test]
    fn a_known_child_sender_wins_over_the_wrapper_session_id() {
        let mut tree = SubagentTree::default();
        let child = "review-thread";
        let helper = "review-helper-thread";
        let first = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": "root-native-thread", "receiverThreadIds": [child]}}}}),
        );
        assert_eq!(first[0]["parent"], Value::Null);
        let nested = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-helper",
                   "rawInput": {"prompt": "Helper", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": child, "receiverThreadIds": [helper]}}}}),
        );
        assert_eq!(nested[0]["id"], helper);
        assert_eq!(nested[0]["parent"], child);
    }

    #[test]
    fn a_known_root_sender_clears_a_wrong_parent_even_on_a_child_session_update() {
        let mut tree = SubagentTree::default();
        let root = "root-native-thread";
        let child = "review-thread";
        let prior_art = "prior-art-thread";
        tree.set_root(root);
        let _ = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [child]}}}}),
        );
        // Simulate a malformed persisted first record; the next authoritative
        // root call must normalize it to a direct child.
        let malformed = subagents_for(
            &mut tree,
            child,
            json!({"sessionUpdate": "tool_call", "toolCallId": "old-spawn",
                   "rawInput": {"prompt": "Prior art", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "receiverThreadIds": [prior_art]}}}}),
        );
        assert_eq!(malformed[0]["parent"], child);
        let repaired = subagents_for(
            &mut tree,
            child,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "root-replay",
                   "rawInput": {"prompt": "Prior art", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [prior_art]}}}}),
        );
        assert_eq!(repaired[0]["parent"], Value::Null);
    }

    #[test]
    fn an_unseen_sender_does_not_fall_back_to_the_update_owner() {
        let mut tree = SubagentTree::default();
        let owner = "known-child";
        let _ = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": owner}),
        );
        let child = subagents_for(
            &mut tree,
            owner,
            json!({"sessionUpdate": "tool_call", "toolCallId": "unknown-sender",
                   "rawInput": {"prompt": "Unknown", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": "unseen-child", "receiverThreadIds": ["grandchild"]}}}}),
        );
        assert_eq!(child[0]["parent"], Value::Null);
    }
}
