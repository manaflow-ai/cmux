//! Part of `Hub`; see `hub/mod.rs`. Ends the subagents that stopped running without their harness
//! saying so, by writing their ends into the chat's log (the rules: `crate::subagents::expiry`).

use super::*;
use crate::subagents::expiry::Ended;

impl Hub {
    /// Writes each of `ended`'s end into `session`'s log, as the harness would have: a
    /// `subagent_state_update` the tree annotates (its name, task, agent id, background mark),
    /// with `reason` naming the rule. Then the count and the work below the turn follow.
    pub(super) fn end_subagents(&self, session: &Session, ended: Vec<Ended>) {
        if ended.is_empty() {
            return;
        }
        let (records, before, after) = {
            let mut tree = session.subagents.lock().unwrap_or_else(|e| e.into_inner());
            let before = tree.running_count();
            let records: Vec<Value> = ended
                .into_iter()
                .map(|end| {
                    let mut params = json!({"sessionId": session.id,
                        "update": {"sessionUpdate": "subagent_state_update",
                            "subagentSessionId": end.id, "state": end.state, "reason": end.reason}});
                    tree.annotate_live(&mut params, true);
                    json!({"jsonrpc": "2.0", "method": method::SESSION_UPDATE, "params": params})
                })
                .collect();
            (records, before, tree.running_count())
        };
        for record in records {
            self.append(session, "in", "subagent_state_update", record);
        }
        if after != before {
            self.subagents_running(session, after);
        }
        self.refresh_work_below(session);
    }

    /// Claude Code's whole list of its live background tasks (`system/background_tasks_changed`):
    /// the background subagents no longer in it end (`task_gone`).
    pub(super) fn subagent_tasks_changed(&self, session: &Session, line: &Value) {
        let Some(tasks) = line.get("tasks").and_then(Value::as_array) else { return };
        let live: HashSet<&str> =
            tasks.iter().filter_map(|t| t.get("task_id").and_then(Value::as_str)).collect();
        let ended = session
            .subagents
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .reconcile_tasks(&live, crate::store::now_ms());
        self.end_subagents(session, ended);
    }

    /// Claude Code's `system/task_notification`: the status it gives a running subagent's task is
    /// kept for its end (`SubagentTree::note_task_ended`).
    pub(super) fn subagent_task_notified(&self, session: &Session, line: &Value) {
        let text = |k: &str| line.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
        let Some(task) = text("task_id") else { return };
        let status = text("status").unwrap_or("completed");
        session.subagents.lock().unwrap_or_else(|e| e.into_inner()).note_task_ended(task, status);
    }

    /// The running subagents quiet past the bound end (`aged_out`), checked at most once a minute
    /// per chat, or now when `force`.
    pub(super) fn sweep_aged_subagents(&self, session: &Session, force: bool) {
        let ended = session
            .subagents
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .sweep_aged(crate::store::now_ms(), force);
        self.end_subagents(session, ended);
    }
}
