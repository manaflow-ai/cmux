//! Every Claude workflow on this daemon, across its chats (`_acpmux/workflows`). A workflow is
//! seen only inside the chat that started it, so several running at once, or the same one
//! started twice, go unnoticed; this index answers for all of them. It is fed from the subagent
//! model the hub's tap already writes into each live update (`subagents.rs`): a spawn of
//! `kind: "workflow"`, its progress (`runId`, `args`, `agents`, usage, current step) and its end.
//! Nothing is read for it. It holds what this daemon saw since it started; a run another
//! daemon serves is that daemon's.
//!
//! A running workflow is listed while it runs, and an ended one stays among the last
//! `ENDED_KEPT`. Two running workflows of one name and the same args, in any chat, are
//! duplicates: each lists the other (`duplicateOf`).

use super::Hub;
use crate::rpc::RpcError;
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::sync::Mutex as StdMutex;

/// Ended workflows listed after the running ones.
const ENDED_KEPT: usize = 50;

/// One workflow: its chat, its subagent id and the latest of what its updates said.
#[derive(Debug, Clone)]
struct Row {
    session_id: String,
    fields: Map<String, Value>,
    started_at: u64,
    updated_at: u64,
    ended_at: Option<u64>,
}

/// The workflows of this daemon's chats (`Hub::workflow_index`).
#[derive(Debug, Default)]
pub struct WorkflowIndex {
    rows: StdMutex<HashMap<String, Row>>,
}

/// The fields of a workflow's progress the index keeps, as the subagent model names them.
const KEPT: [&str; 10] = [
    "name",
    "task",
    "runId",
    "args",
    "agents",
    "tokens",
    "toolUses",
    "elapsedMs",
    "action",
    "reason",
];

impl WorkflowIndex {
    /// Folds one live update's subagent events (`_meta.acpmux.subagents`) of chat `session_id`.
    pub fn observe(&self, session_id: &str, events: &[Value], now: u64) {
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        for event in events {
            let Some(id) = event.get("id").and_then(Value::as_str) else { continue };
            let workflow = event.get("kind").and_then(Value::as_str) == Some("workflow")
                || event.get("runId").and_then(Value::as_str).is_some();
            if !rows.contains_key(id) {
                if !workflow {
                    continue;
                }
                let row = Row {
                    session_id: session_id.to_owned(),
                    fields: Map::new(),
                    started_at: now,
                    updated_at: now,
                    ended_at: None,
                };
                rows.insert(id.to_owned(), row);
            }
            let Some(row) = rows.get_mut(id) else { continue };
            for key in KEPT {
                if let Some(value) = event.get(key).filter(|v| !v.is_null()) {
                    row.fields.insert(key.into(), value.clone());
                }
            }
            if let Some(state) = event.get("state").and_then(Value::as_str) {
                row.fields.insert("state".into(), json!(state));
                row.ended_at = (state != "running").then(|| row.ended_at.unwrap_or(now));
            }
            row.updated_at = now;
        }
        let ended: Vec<(u64, String)> =
            rows.iter().filter_map(|(id, row)| row.ended_at.map(|at| (at, id.clone()))).collect();
        if ended.len() > ENDED_KEPT {
            let mut ended = ended;
            ended.sort();
            for (_, id) in ended.iter().take(ended.len() - ENDED_KEPT) {
                rows.remove(id);
            }
        }
    }

    /// Forgets the workflows of a chat that is gone.
    pub fn forget(&self, session_id: &str) {
        self.rows
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|_, row| row.session_id != session_id);
    }

    /// Every workflow, running ones first, each newest first: `{sessionId, subagentSessionId,
    /// state, startedAt, updatedAt, endedAt?, duplicateOf?, ...}` with the kept fields.
    pub fn list(&self, include_ended: bool) -> Vec<Value> {
        let rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        let mut out: Vec<(&String, &Row)> =
            rows.iter().filter(|(_, row)| include_ended || row.ended_at.is_none()).collect();
        out.sort_by_key(|(id, row)| {
            (row.ended_at.is_some(), std::cmp::Reverse(row.started_at), *id)
        });
        let same = |a: &Row, b: &Row| {
            let field = |row: &Row, key: &str| row.fields.get(key).cloned();
            a.ended_at.is_none()
                && b.ended_at.is_none()
                && field(a, "name").is_some()
                && field(a, "name") == field(b, "name")
                && field(a, "args") == field(b, "args")
        };
        out.iter()
            .map(|(id, row)| {
                let mut value = Value::Object(row.fields.clone());
                if let Some(object) = value.as_object_mut() {
                    object.insert("sessionId".into(), json!(row.session_id));
                    object.insert("subagentSessionId".into(), json!(id));
                    object.entry("state").or_insert(json!("running"));
                    object.insert("startedAt".into(), json!(row.started_at));
                    object.insert("updatedAt".into(), json!(row.updated_at));
                    if let Some(at) = row.ended_at {
                        object.insert("endedAt".into(), json!(at));
                    }
                    let twins: Vec<&String> = rows
                        .iter()
                        .filter(|(other, twin)| other != id && same(row, twin))
                        .map(|(other, _)| other)
                        .collect();
                    if !twins.is_empty() {
                        object.insert("duplicateOf".into(), json!(twins));
                    }
                }
                value
            })
            .collect()
    }
}

/// `_acpmux/workflows {includeEnded?}`: `{workflows}`, each with its chat's name. A chat that is
/// gone takes its workflows with it.
pub(crate) fn handle(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    let include_ended = params.get("includeEnded").and_then(Value::as_bool) == Some(true);
    let mut rows = hub.workflow_index.list(include_ended);
    rows.retain_mut(|row| {
        let session = row.get("sessionId").and_then(Value::as_str).unwrap_or_default().to_owned();
        match hub.resolve(&session) {
            Ok(chat) if !chat.purged.load(std::sync::atomic::Ordering::SeqCst) => {
                if let Some(object) = row.as_object_mut() {
                    object.insert("chatName".into(), json!(chat.meta().name));
                }
                true
            }
            _ => {
                hub.workflow_index.forget(&session);
                false
            }
        }
    });
    Ok(json!({"workflows": rows}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spawn(id: &str) -> Value {
        json!({"id": id, "parent": null, "name": "Workflow", "kind": "workflow", "state": "running"})
    }

    #[test]
    fn a_workflow_is_listed_from_its_spawn_to_its_end() {
        let index = WorkflowIndex::default();
        index.observe("chat-1", &[spawn("acp-1/toolu_w")], 10);
        // A plain subagent is not a workflow.
        index.observe(
            "chat-1",
            &[json!({"id": "acp-1/toolu_a", "parent": null, "kind": "Explore"})],
            11,
        );
        index.observe(
            "chat-1",
            &[json!({"id": "acp-1/toolu_w", "state": "running", "name": "deep-review", "runId": "wf_4fe",
                "args": {"pr": 1}, "agents": {"done": 3, "started": 5}, "tokens": 120000, "action": "Review: r1"})],
            20,
        );
        let listed = index.list(false);
        assert_eq!(listed.len(), 1, "{listed:?}");
        let row = &listed[0];
        assert_eq!(
            (row["sessionId"].clone(), row["subagentSessionId"].clone()),
            (json!("chat-1"), json!("acp-1/toolu_w"))
        );
        assert_eq!(
            (row["name"].clone(), row["runId"].clone(), row["state"].clone()),
            (json!("deep-review"), json!("wf_4fe"), json!("running"))
        );
        assert_eq!(row["agents"], json!({"done": 3, "started": 5}));
        assert_eq!((row["startedAt"].clone(), row["updatedAt"].clone()), (json!(10), json!(20)));

        index.observe(
            "chat-1",
            &[json!({"id": "acp-1/toolu_w", "state": "cancelled", "reason": "paused"})],
            30,
        );
        assert!(index.list(false).is_empty());
        let ended = index.list(true);
        assert_eq!(
            (ended[0]["state"].clone(), ended[0]["reason"].clone(), ended[0]["endedAt"].clone()),
            (json!("cancelled"), json!("paused"), json!(30))
        );
        index.forget("chat-1");
        assert!(index.list(true).is_empty());
    }

    /// Two running workflows of one name and the same args, in any chat, list each other.
    #[test]
    fn the_same_workflow_running_twice_is_a_duplicate() {
        let index = WorkflowIndex::default();
        let progress =
            |id: &str, args: Value| json!({"id": id, "name": "session-review", "args": args});
        index.observe("chat-1", &[spawn("a/w1"), progress("a/w1", json!({"pr": 7}))], 1);
        index.observe("chat-2", &[spawn("b/w2"), progress("b/w2", json!({"pr": 7}))], 2);
        index.observe("chat-2", &[spawn("b/w3"), progress("b/w3", json!({"pr": 8}))], 3);
        let listed = index.list(false);
        let of = |id: &str| {
            listed.iter().find(|row| row["subagentSessionId"] == id).unwrap()["duplicateOf"].clone()
        };
        assert_eq!(
            (of("a/w1"), of("b/w2"), of("b/w3")),
            (json!(["b/w2"]), json!(["a/w1"]), Value::Null)
        );
        // Once one ends, the other is no longer a duplicate.
        index.observe("chat-2", &[json!({"id": "b/w2", "state": "completed"})], 4);
        assert_eq!(
            index.list(false).iter().find(|row| row["subagentSessionId"] == "a/w1").unwrap()["duplicateOf"],
            Value::Null
        );
    }

    #[test]
    fn only_the_latest_ended_workflows_are_kept() {
        let index = WorkflowIndex::default();
        for n in 0..(ENDED_KEPT as u64 + 5) {
            let id = format!("s/w{n}");
            index.observe("chat", &[spawn(&id), json!({"id": id, "state": "completed"})], n);
        }
        index.observe("chat", &[spawn("s/live")], 1000);
        let listed = index.list(true);
        assert_eq!(listed.len(), ENDED_KEPT + 1);
        assert_eq!(listed[0]["subagentSessionId"], "s/live", "running first");
        assert!(listed.iter().all(|row| row["subagentSessionId"] != "s/w0"), "the oldest went");
    }
}
