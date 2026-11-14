//! Every Claude workflow on this daemon, across its chats (`_acpmux/workflows`). A workflow is
//! seen only inside the chat that started it, so several running at once, or the same one
//! started twice, go unnoticed; this index answers for all of them. It is fed from the subagent
//! model the hub's tap already writes into each live update (`subagents.rs`): a spawn of
//! `kind: "workflow"`, its progress (`runId`, `argsDigest`, `agents`, usage, current step) and its end.
//! Nothing is read for it. It holds what this daemon saw since it started; a run another
//! daemon serves is that daemon's.
//!
//! A running workflow is listed while it runs, and an ended one stays among the last
//! `ENDED_KEPT`. A chat whose agent exits ends its running workflows as `disconnected` (their
//! Claude process is gone; `end_session`), and no more than `RUNNING_MAX` are listed as running.
//! Two running workflows of one name and the same args (by `argsDigest`), in any chat, are
//! duplicates (a run with no digest never is): each lists
//! the other (`duplicateOf`).
//!
//! The index lock is held only to fold one update's events or to copy the rows: what a list
//! answers is built from the copy.

use super::Hub;
use crate::rpc::RpcError;
use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::Mutex as StdMutex;

/// Ended workflows listed after the running ones.
const ENDED_KEPT: usize = 50;
/// Running workflows kept; past it the longest quiet ones are dropped.
const RUNNING_MAX: usize = 256;

/// One workflow: its chat, its subagent id and the latest of what its updates said.
#[derive(Debug, Clone)]
struct Row {
    session_id: String,
    fields: Map<String, Value>,
    started_at: u64,
    updated_at: u64,
    ended_at: Option<u64>,
}

#[derive(Debug, Default)]
struct Rows {
    by_id: HashMap<String, Row>,
    /// How many of `by_id` ended.
    ended: usize,
}

/// The workflows of this daemon's chats (`Hub::workflow_index`).
#[derive(Debug, Default)]
pub struct WorkflowIndex {
    rows: StdMutex<Rows>,
}

/// The fields of a workflow's progress the index keeps, as the subagent model names them.
const KEPT: [&str; 10] = [
    "name",
    "task",
    "runId",
    "argsDigest",
    "agents",
    "tokens",
    "toolUses",
    "elapsedMs",
    "action",
    "reason",
];

impl Rows {
    /// Keeps the ended rows at about `ENDED_KEPT` and the running ones at `RUNNING_MAX`: a sort
    /// once every `ENDED_KEPT` ends, not a scan on every update.
    fn bound(&mut self) {
        if self.ended > 2 * ENDED_KEPT {
            let mut ended: Vec<(u64, String)> = self
                .by_id
                .iter()
                .filter_map(|(id, row)| row.ended_at.map(|at| (at, id.clone())))
                .collect();
            ended.sort();
            let extra = ended.len().saturating_sub(ENDED_KEPT);
            for (_, id) in ended.iter().take(extra) {
                self.by_id.remove(id);
            }
            self.ended -= extra;
        }
        let running = self.by_id.len() - self.ended;
        if running > RUNNING_MAX {
            let mut quiet: Vec<(u64, String)> = self
                .by_id
                .iter()
                .filter(|(_, row)| row.ended_at.is_none())
                .map(|(id, row)| (row.updated_at, id.clone()))
                .collect();
            quiet.sort();
            for (_, id) in quiet.iter().take(running - RUNNING_MAX) {
                self.by_id.remove(id);
            }
        }
    }
}

impl WorkflowIndex {
    /// Folds one live update's subagent events (`_meta.acpmux.subagents`) of chat `session_id`.
    pub fn observe(&self, session_id: &str, events: &[Value], now: u64) {
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        let rows = &mut *rows;
        for event in events {
            let Some(id) = event.get("id").and_then(Value::as_str) else { continue };
            if !rows.by_id.contains_key(id) {
                let workflow = event.get("kind").and_then(Value::as_str) == Some("workflow")
                    || event.get("runId").and_then(Value::as_str).is_some();
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
                rows.by_id.insert(id.to_owned(), row);
            }
            let Some(row) = rows.by_id.get_mut(id) else { continue };
            for key in KEPT {
                if let Some(value) = event.get(key).filter(|v| !v.is_null()) {
                    row.fields.insert(key.into(), value.clone());
                }
            }
            if let Some(state) = event.get("state").and_then(Value::as_str) {
                row.fields.insert("state".into(), json!(state));
                match (state != "running", row.ended_at.is_some()) {
                    (true, false) => {
                        row.ended_at = Some(now);
                        rows.ended += 1;
                    }
                    (false, true) => {
                        row.ended_at = None;
                        rows.ended -= 1;
                    }
                    _ => {}
                }
            }
            row.updated_at = now;
        }
        rows.bound();
    }

    /// Ends chat `session_id`'s running workflows as `disconnected`: its agent exited, and a
    /// workflow runs in its agent's process.
    pub fn end_session(&self, session_id: &str, now: u64) {
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        let rows = &mut *rows;
        for row in rows.by_id.values_mut() {
            if row.session_id == session_id && row.ended_at.is_none() {
                row.fields.insert("state".into(), json!("disconnected"));
                row.ended_at = Some(now);
                row.updated_at = now;
                rows.ended += 1;
            }
        }
        rows.bound();
    }

    /// Forgets the workflows of chats that are gone.
    pub fn forget(&self, sessions: &HashSet<String>) {
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        rows.by_id.retain(|_, row| !sessions.contains(&row.session_id));
        rows.ended = rows.by_id.values().filter(|row| row.ended_at.is_some()).count();
    }

    /// Every workflow, running ones first, each newest first: `{sessionId, subagentSessionId,
    /// state, startedAt, updatedAt, endedAt?, duplicateOf?, ...}` with the kept fields.
    pub fn list(&self, include_ended: bool) -> Vec<Value> {
        let mut rows: Vec<(String, Row)> = {
            let rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
            rows.by_id
                .iter()
                .filter(|(_, row)| include_ended || row.ended_at.is_none())
                .map(|(id, row)| (id.clone(), row.clone()))
                .collect()
        };
        rows.sort_by(|(a_id, a), (b_id, b)| {
            (a.ended_at.is_some(), std::cmp::Reverse(a.started_at), a_id).cmp(&(
                b.ended_at.is_some(),
                std::cmp::Reverse(b.started_at),
                b_id,
            ))
        });
        // The index trims ended rows only now and then: list the newest `ENDED_KEPT`.
        let running = rows.iter().filter(|(_, row)| row.ended_at.is_none()).count();
        rows.truncate(running + ENDED_KEPT);
        // Running workflows by name and args digest: each group of more than one is duplicates. A run
        // with no digest is never one: the same script run with unknown args is not a duplicate.
        let key = |row: &Row| -> Option<(String, String)> {
            let name = row.fields.get("name").and_then(Value::as_str)?;
            let digest = row.fields.get("argsDigest").and_then(Value::as_str)?;
            (row.ended_at.is_none()).then(|| (name.to_owned(), digest.to_owned()))
        };
        let mut twins: HashMap<(String, String), Vec<String>> = HashMap::new();
        for (id, row) in &rows {
            if let Some(key) = key(row) {
                twins.entry(key).or_default().push(id.clone());
            }
        }
        let twins_of = |id: &str, row: &Row| -> Vec<String> {
            key(row)
                .and_then(|key| twins.get(&key))
                .map(|group| group.iter().filter(|other| *other != id).cloned().collect())
                .unwrap_or_default()
        };
        rows.iter()
            .map(|(id, row)| {
                let mut object = row.fields.clone();
                object.insert("sessionId".into(), json!(row.session_id));
                object.insert("subagentSessionId".into(), json!(id));
                object.entry("state").or_insert(json!("running"));
                object.insert("startedAt".into(), json!(row.started_at));
                object.insert("updatedAt".into(), json!(row.updated_at));
                if let Some(at) = row.ended_at {
                    object.insert("endedAt".into(), json!(at));
                }
                let twins = twins_of(id, row);
                if !twins.is_empty() {
                    object.insert("duplicateOf".into(), json!(twins));
                }
                Value::Object(object)
            })
            .collect()
    }
}

/// `_acpmux/workflows {includeEnded?}`: `{workflows}`, each with its chat's name. Chats that are
/// gone take their workflows with them.
pub(crate) fn handle(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    let include_ended = params.get("includeEnded").and_then(Value::as_bool) == Some(true);
    let mut rows = hub.workflow_index.list(include_ended);
    let mut names: HashMap<String, Option<String>> = HashMap::new();
    for row in &rows {
        let session = row.get("sessionId").and_then(Value::as_str).unwrap_or_default();
        if !names.contains_key(session) {
            let name = hub
                .resolve(session)
                .ok()
                .filter(|chat| !chat.purged.load(std::sync::atomic::Ordering::SeqCst))
                .map(|chat| chat.meta().name);
            names.insert(session.to_owned(), name);
        }
    }
    let gone: HashSet<String> =
        names.iter().filter(|(_, name)| name.is_none()).map(|(id, _)| id.clone()).collect();
    if !gone.is_empty() {
        hub.workflow_index.forget(&gone);
    }
    rows.retain_mut(|row| {
        let session = row.get("sessionId").and_then(Value::as_str).unwrap_or_default();
        match names.get(session) {
            Some(Some(name)) => {
                if let Some(object) = row.as_object_mut() {
                    object.insert("chatName".into(), json!(name));
                }
                true
            }
            _ => false,
        }
    });
    Ok(json!({"workflows": rows}))
}

#[cfg(test)]
mod tests;
