//! What started a background turn, and whether it is worth a response (Leo, 2026-11-03:
//! "there's like... background tasks worth responding to and not worth responding to"). Part of
//! `Hub`'s background-turn bracketing (`background_turn.rs`): Claude Code's raw task lines say which
//! task ended and how, and the `started` record carries that as its `cause`, so the transcript
//! decides from the event itself, never from what the agent's reply looks like.
//!
//! - `silent`: not worth a response. An interim stop (the notification says the agent is waiting
//!   on its own background work, or that its result may be interim), a step a subagent ran, a
//!   stopped or killed task, a monitor tick. The task's own row updates in place; the turn draws
//!   no row of its own, and whatever the agent wrote goes inside the task's row.
//! - `result`: a final result (a subagent's final report, a command that exited). The task's row
//!   is marked new; the agent's reply shows when it has something to say.
//! - `failure`: a task that failed. Always worth a response: it always shows.
//!
//! The one table is [`WEIGHTS`], keyed by the task's kind and the notification's status.

use serde_json::{Value, json};
use std::collections::VecDeque;

/// How much a background task's end is worth, from least to most.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Weight {
    Silent,
    Result,
    Failure,
}

impl Weight {
    fn name(self) -> &'static str {
        match self {
            Weight::Silent => "silent",
            Weight::Result => "result",
            Weight::Failure => "failure",
        }
    }
}

/// `(kind, status, weight)`; `"*"` matches any status. The first match wins, so a kind's exact
/// rows come before its `*`. Kinds: `subagent` (an Agent/Task call of the chat's own),
/// `subagent_step` (a call a subagent made), `monitor` (a Monitor tool's watch), `shell` (any
/// other background call: a Bash run in the background), `unknown` (no `task_started` heard,
/// as after a daemon restart). Statuses are the notification's, plus `interim`.
pub const WEIGHTS: &[(&str, &str, Weight)] = &[
    ("subagent", "completed", Weight::Result),
    ("subagent", "interim", Weight::Silent),
    ("subagent", "failed", Weight::Failure),
    ("subagent", "*", Weight::Silent),
    ("subagent_step", "failed", Weight::Failure),
    ("subagent_step", "*", Weight::Silent),
    ("monitor", "failed", Weight::Failure),
    ("monitor", "*", Weight::Silent),
    ("shell", "completed", Weight::Result),
    ("shell", "interim", Weight::Silent),
    ("shell", "failed", Weight::Failure),
    ("shell", "*", Weight::Silent),
    ("unknown", "failed", Weight::Failure),
    ("unknown", "interim", Weight::Silent),
    ("unknown", "*", Weight::Result),
];

/// The weight of a task of `kind` that ended with `status`.
pub fn weight(kind: &str, status: &str) -> Weight {
    WEIGHTS
        .iter()
        .find(|(k, s, _)| *k == kind && (*s == status || *s == "*"))
        .map_or(Weight::Result, |(_, _, w)| *w)
}

/// Words Claude Code puts in a notification whose result is not final: the agent stopped while
/// it waits on its own background work.
const INTERIM: [&str; 2] = ["waiting on its own background work", "may be interim"];

/// The tasks kept to name a notification's kind; older ones are forgotten.
const TASKS_KEPT: usize = 512;

#[derive(Debug, Clone)]
struct Task {
    id: String,
    kind: &'static str,
}

/// The tasks a session started, and the causes heard since its last background turn started.
#[derive(Debug, Default)]
pub(super) struct Causes {
    tasks: VecDeque<Task>,
    /// The notifications heard since the last `started` record: the heaviest one names the cause.
    pending: Option<Value>,
    pending_weight: Option<Weight>,
}

impl Causes {
    /// A raw `claude.system.task_started` or `claude.system.task_notification` line.
    pub(super) fn on_line(&mut self, method: &str, line: &Value) {
        let text = |k: &str| line.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
        match method {
            "claude.system.task_started" => {
                let Some(id) = text("task_id") else { return };
                let kind = if line.get("owned_by_subagent").and_then(Value::as_bool) == Some(true) {
                    "subagent_step"
                } else if text("subagent_type").is_some() {
                    "subagent"
                } else if matches!(text("task_type"), Some("monitor" | "local_monitor"))
                    || text("tool_name") == Some("Monitor")
                {
                    "monitor"
                } else {
                    "shell"
                };
                self.tasks.retain(|t| t.id != id);
                self.tasks.push_back(Task { id: id.to_owned(), kind });
                while self.tasks.len() > TASKS_KEPT {
                    self.tasks.pop_front();
                }
            }
            "claude.system.task_notification" => {
                let kind = text("task_id")
                    .and_then(|id| self.tasks.iter().rev().find(|t| t.id == id))
                    .map_or("unknown", |t| t.kind);
                let summary = text("summary").unwrap_or("");
                // A failure is a failure, whatever else it says: it always shows.
                let interim = text("status") != Some("failed")
                    && (INTERIM.iter().any(|w| summary.contains(w))
                        || line.get("interim").and_then(Value::as_bool) == Some(true));
                let status =
                    if interim { "interim" } else { text("status").unwrap_or("completed") };
                let w = weight(kind, status);
                if self.pending_weight.is_some_and(|p| p > w) {
                    return;
                }
                let mut cause = serde_json::Map::new();
                cause.insert("kind".into(), json!(kind));
                cause.insert("status".into(), json!(status));
                cause.insert("weight".into(), json!(w.name()));
                if let Some(origin) = text("tool_use_id") {
                    cause.insert("origin".into(), json!(origin));
                }
                if !summary.is_empty() {
                    cause.insert(
                        "summary".into(),
                        json!(summary.chars().take(240).collect::<String>()),
                    );
                }
                self.pending = Some(Value::Object(cause));
                self.pending_weight = Some(w);
            }
            _ => {}
        }
    }

    /// The cause of a background turn that starts now; the next one starts from nothing.
    pub(super) fn take(&mut self) -> Option<Value> {
        self.pending_weight = None;
        self.pending.take()
    }

    /// A turn acpmux runs consumed what was heard: it is no background turn's cause.
    pub(super) fn clear(&mut self) {
        self.pending = None;
        self.pending_weight = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn started(id: &str, extra: Value) -> Value {
        let mut line = json!({"subtype": "task_started", "task_id": id, "description": "x"});
        for (k, v) in extra.as_object().unwrap() {
            line[k] = v.clone();
        }
        line
    }

    fn cause_of(start: Option<Value>, status: &str, summary: &str) -> Value {
        let mut c = Causes::default();
        if let Some(line) = start {
            c.on_line("claude.system.task_started", &line);
        }
        c.on_line(
            "claude.system.task_notification",
            &json!({"task_id": "t1", "tool_use_id": "toolu_1", "status": status, "summary": summary}),
        );
        c.take().unwrap()
    }

    #[test]
    fn a_subagents_final_report_is_a_result_and_its_interim_stop_is_silent() {
        let agent = || Some(started("t1", json!({"subagent_type": "general-purpose"})));
        let c = cause_of(agent(), "completed", "Merged #12.");
        assert_eq!(c["kind"], "subagent");
        assert_eq!(c["weight"], "result");
        assert_eq!(c["origin"], "toolu_1");
        let c = cause_of(agent(), "completed", "The agent is waiting on its own background work.");
        assert_eq!((c["status"].as_str(), c["weight"].as_str()), (Some("interim"), Some("silent")));
        assert_eq!(
            cause_of(agent(), "completed", "Its result may be interim.")["weight"],
            "silent"
        );
        assert_eq!(cause_of(agent(), "failed", "")["weight"], "failure");
        assert_eq!(cause_of(agent(), "stopped", "")["weight"], "silent");
    }

    #[test]
    fn a_step_a_subagent_ran_is_silent_unless_it_failed() {
        let step = || Some(started("t1", json!({"owned_by_subagent": true})));
        let c = cause_of(step(), "completed", "Commit and push");
        assert_eq!(
            (c["kind"].as_str(), c["weight"].as_str()),
            (Some("subagent_step"), Some("silent"))
        );
        assert_eq!(cause_of(step(), "failed", "")["weight"], "failure");
    }

    #[test]
    fn a_background_command_that_exited_is_a_result_a_stop_is_silent_a_failure_shows() {
        let shell = || Some(started("t1", json!({"is_backgrounded": true})));
        let c = cause_of(shell(), "completed", "Background command \"x\" completed (exit code 0)");
        assert_eq!((c["kind"].as_str(), c["weight"].as_str()), (Some("shell"), Some("result")));
        assert_eq!(cause_of(shell(), "stopped", "")["weight"], "silent");
        assert_eq!(cause_of(shell(), "killed", "")["weight"], "silent");
        assert_eq!(cause_of(shell(), "failed", "exit code 1")["weight"], "failure");
    }

    #[test]
    fn a_monitor_tick_is_silent_unless_it_failed() {
        let monitor = || Some(started("t1", json!({"task_type": "monitor"})));
        let c = cause_of(monitor(), "completed", "");
        assert_eq!((c["kind"].as_str(), c["weight"].as_str()), (Some("monitor"), Some("silent")));
        assert_eq!(cause_of(monitor(), "failed", "")["weight"], "failure");
    }

    #[test]
    fn a_failure_that_also_says_interim_still_shows_and_a_local_monitor_is_a_monitor() {
        let agent = || Some(started("t1", json!({"subagent_type": "general-purpose"})));
        assert_eq!(cause_of(agent(), "failed", "Its result may be interim.")["weight"], "failure");
        let local = || Some(started("t1", json!({"task_type": "local_monitor"})));
        let c = cause_of(local(), "completed", "");
        assert_eq!((c["kind"].as_str(), c["weight"].as_str()), (Some("monitor"), Some("silent")));
    }

    #[test]
    fn a_task_never_heard_starting_is_a_result_and_its_failure_shows() {
        let c = cause_of(None, "completed", "");
        assert_eq!((c["kind"].as_str(), c["weight"].as_str()), (Some("unknown"), Some("result")));
        assert_eq!(cause_of(None, "failed", "")["weight"], "failure");
        assert_eq!(cause_of(None, "completed", "may be interim")["weight"], "silent");
    }

    #[test]
    fn the_heaviest_notification_before_a_turn_names_its_cause() {
        let mut c = Causes::default();
        c.on_line("claude.system.task_started", &started("a", json!({"owned_by_subagent": true})));
        c.on_line("claude.system.task_started", &started("b", json!({"is_backgrounded": true})));
        let note =
            |id: &str, status: &str| json!({"task_id": id, "status": status, "tool_use_id": id});
        c.on_line("claude.system.task_notification", &note("b", "failed"));
        c.on_line("claude.system.task_notification", &note("a", "completed"));
        let cause = c.take().unwrap();
        assert_eq!(
            (cause["weight"].as_str(), cause["origin"].as_str()),
            (Some("failure"), Some("b"))
        );
        // Taken: the next turn starts from nothing.
        assert_eq!(c.take(), None);
    }

    #[test]
    fn every_kind_has_a_row_for_every_status_it_can_end_with() {
        for kind in ["subagent", "subagent_step", "monitor", "shell", "unknown"] {
            for status in ["completed", "failed", "stopped", "killed", "interim"] {
                let w = weight(kind, status);
                assert_eq!(w == Weight::Failure, status == "failed", "{kind} {status}");
            }
        }
    }
}
