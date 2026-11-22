//! A chat's task list: what is done and what is next, kept on the chat across its turns (David
//! Beyer's Nov 20 ask for long agent chats). A running turn's plan step (`hub/activity.rs`) ends
//! with the turn; this list stays until a newer one replaces it.
//!
//! Who keeps it, in this order of trust in its accuracy:
//! - the harness: its own plan events (Claude Code's TodoWrite and Codex's update_plan, both an
//!   ACP `plan` update through acpmux). Each new plan replaces the list; an empty one clears it.
//! - the chat's agent or its Chief, through `_acpmux/task_list/set` (`server/task_list.rs`), for a
//!   harness that writes no plan. A harness's empty plan never clears such a list (that harness
//!   had nothing to say about it); a harness's real plan replaces it, as the harness then keeps
//!   its own.
//!
//! The list is saved with the session's meta (`SessionMeta::task_list`) and every summary carries
//! it as `taskList` ([`TaskListSummary`]), so the sidebar row and the chat read one source.
//! Each step is masked (`secret_scan`) and cut before it is kept: every view shows it.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The most steps a list keeps; a longer plan keeps its first ones.
pub const MAX_ITEMS: usize = 100;
/// The longest step kept, in characters.
pub const ITEM_CHARS: usize = 300;

/// Who keeps a chat's task list.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskListSource {
    /// The harness's own plan events (TodoWrite, update_plan, ACP `plan`).
    Harness,
    /// The chat's own agent, through `_acpmux/task_list/set`.
    Agent,
    /// The person's side: the Chief or the app, through `_acpmux/task_list/set`.
    Chief,
}

/// Where one step stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Pending,
    InProgress,
    Completed,
}

impl TaskStatus {
    /// ACP's `plan` entry status (`pending`, `in_progress`, `completed`), else None.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "pending" => Some(Self::Pending),
            "in_progress" => Some(Self::InProgress),
            "completed" => Some(Self::Completed),
            _ => None,
        }
    }
}

/// One step of the list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = crate::protocol::require_all)]
pub struct TaskItem {
    /// The step's words, masked and cut to [`ITEM_CHARS`].
    pub content: String,
    pub status: TaskStatus,
}

/// A chat's task list as its meta keeps it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskList {
    pub source: TaskListSource,
    pub items: Vec<TaskItem>,
    /// When it last changed, Unix ms.
    pub updated_at: u64,
}

/// What a summary carries of a chat's task list (`SessionSummary::task_list`): the steps, and the
/// counts and lines a sidebar row or a chat strip draws without counting again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = crate::protocol::require_all)]
pub struct TaskListSummary {
    /// Who keeps it: `harness` (its own plan events), `agent` or `chief` (`_acpmux/task_list/set`).
    pub source: TaskListSource,
    /// The steps completed.
    pub done: u32,
    /// Every step.
    pub total: u32,
    /// The first step in progress; null when none is.
    pub current: Option<String>,
    /// The first step still pending after the current one (or the first pending one when none is
    /// in progress); null when none is left.
    pub next: Option<String>,
    pub items: Vec<TaskItem>,
    /// When it last changed, Unix ms.
    pub updated_at: u64,
}

impl TaskList {
    /// The summary's view of it.
    pub fn summary(&self) -> TaskListSummary {
        let done = self.items.iter().filter(|i| i.status == TaskStatus::Completed).count();
        let at = self.items.iter().position(|i| i.status == TaskStatus::InProgress);
        let after = at.map_or(0, |at| at + 1);
        let next = self.items[after..].iter().find(|i| i.status == TaskStatus::Pending);
        TaskListSummary {
            source: self.source,
            done: u32::try_from(done).unwrap_or(u32::MAX),
            total: u32::try_from(self.items.len()).unwrap_or(u32::MAX),
            current: at.map(|at| self.items[at].content.clone()),
            next: next.map(|i| i.content.clone()),
            items: self.items.clone(),
            updated_at: self.updated_at,
        }
    }
}

/// One step's words as kept: masked, then cut; None when nothing is left.
fn step_text(s: &str) -> Option<String> {
    let text = crate::hub::masked_step(s, ITEM_CHARS);
    (!text.trim().is_empty()).then_some(text)
}

/// The steps of an ACP `plan` update (`entries`), leniently: an entry with no words is left out,
/// an unknown status reads as pending. None when the update has no `entries` list.
pub fn plan_items(update: &Value) -> Option<Vec<TaskItem>> {
    let entries = update.get("entries")?.as_array()?;
    Some(
        entries
            .iter()
            .filter_map(|e| {
                let content = step_text(e.get("content")?.as_str()?)?;
                let status = e
                    .get("status")
                    .and_then(Value::as_str)
                    .and_then(TaskStatus::parse)
                    .unwrap_or(TaskStatus::Pending);
                Some(TaskItem { content, status })
            })
            .take(MAX_ITEMS)
            .collect(),
    )
}

/// The steps `_acpmux/task_list/set` was given, strictly: each needs words and a known status.
pub fn set_items(items: &Value) -> Result<Vec<TaskItem>, String> {
    let list = items.as_array().ok_or("items must be a list")?;
    if list.len() > MAX_ITEMS {
        return Err(format!("items holds over {MAX_ITEMS} steps"));
    }
    list.iter()
        .enumerate()
        .map(|(n, item)| {
            let content = item
                .get("content")
                .and_then(Value::as_str)
                .and_then(step_text)
                .ok_or_else(|| format!("items[{n}].content is required"))?;
            let status =
                item.get("status").and_then(Value::as_str).and_then(TaskStatus::parse).ok_or_else(
                    || format!("items[{n}].status must be pending, in_progress or completed"),
                )?;
            Ok(TaskItem { content, status })
        })
        .collect()
}

/// `current` after a harness's plan of `items` at `now`, or None when it stays as it was. A
/// harness's plan replaces any list; an empty one clears only a list a harness keeps.
pub fn after_plan(
    current: Option<&TaskList>,
    items: Vec<TaskItem>,
    now: u64,
) -> Option<Option<TaskList>> {
    if items.is_empty() {
        return match current {
            Some(list) if list.source == TaskListSource::Harness => Some(None),
            _ => None,
        };
    }
    after_set(current, TaskListSource::Harness, items, now)
}

/// `current` after `source` set `items` at `now`, or None when nothing changed (the same steps
/// from the same keeper). An empty list clears it.
pub fn after_set(
    current: Option<&TaskList>,
    source: TaskListSource,
    items: Vec<TaskItem>,
    now: u64,
) -> Option<Option<TaskList>> {
    if items.is_empty() {
        return current.map(|_| None);
    }
    if current.is_some_and(|list| list.source == source && list.items == items) {
        return None;
    }
    Some(Some(TaskList { source, items, updated_at: now }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn item(content: &str, status: TaskStatus) -> TaskItem {
        TaskItem { content: content.into(), status }
    }

    #[test]
    fn the_summary_names_the_step_at_work_and_the_one_after_it() {
        let list = TaskList {
            source: TaskListSource::Harness,
            items: vec![
                item("a", TaskStatus::Pending),
                item("b", TaskStatus::Completed),
                item("c", TaskStatus::InProgress),
                item("d", TaskStatus::Completed),
                item("e", TaskStatus::Pending),
            ],
            updated_at: 7,
        };
        let s = list.summary();
        assert_eq!((s.done, s.total), (2, 5));
        assert_eq!(s.current.as_deref(), Some("c"));
        assert_eq!(s.next.as_deref(), Some("e"));
        let none_running = TaskList { items: list.items[..2].to_vec(), ..list };
        assert_eq!(none_running.summary().current, None);
        assert_eq!(none_running.summary().next.as_deref(), Some("a"));
    }

    #[test]
    fn a_plan_is_read_leniently_and_a_set_strictly() {
        let plan = json!({"entries": [
            {"content": "  one  ", "status": "completed"},
            {"content": "", "status": "pending"},
            {"content": "two", "status": "weird"},
            {"status": "pending"},
        ]});
        assert_eq!(
            plan_items(&plan),
            Some(vec![item("one", TaskStatus::Completed), item("two", TaskStatus::Pending)])
        );
        assert_eq!(plan_items(&json!({"sessionUpdate": "plan"})), None);
        assert!(
            set_items(&json!([{"content": "x", "status": "weird"}]))
                .unwrap_err()
                .contains("status")
        );
        assert!(
            set_items(&json!([{"content": " ", "status": "pending"}]))
                .unwrap_err()
                .contains("content")
        );
        let many: Vec<Value> = (0..=MAX_ITEMS)
            .map(|n| json!({"content": n.to_string(), "status": "pending"}))
            .collect();
        assert!(set_items(&Value::Array(many)).is_err());
    }

    #[test]
    fn an_empty_plan_clears_only_a_harness_list() {
        let kept = TaskList {
            source: TaskListSource::Chief,
            items: vec![item("x", TaskStatus::Pending)],
            updated_at: 1,
        };
        assert_eq!(after_plan(Some(&kept), vec![], 2), None);
        let harness = TaskList { source: TaskListSource::Harness, ..kept.clone() };
        assert_eq!(after_plan(Some(&harness), vec![], 2), Some(None));
        let replaced =
            after_plan(Some(&kept), vec![item("y", TaskStatus::InProgress)], 3).unwrap().unwrap();
        assert_eq!(replaced.source, TaskListSource::Harness);
        // The same steps again change nothing, not even the time.
        assert_eq!(after_plan(Some(&harness), harness.items.clone(), 9), None);
    }
}
