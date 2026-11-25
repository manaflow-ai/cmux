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
//! A list belongs to the turn that last wrote it (design/chat-plan-lifecycle.md; Leo, 2026-11-22:
//! "we need to figure out how to do better plans and have them expired"). It stays the chat's
//! plan through that turn, the gap after it and the next turn, which may finish it; once a turn
//! that never touched it has ended, it has expired ([`TaskList::current`]): no summary carries it,
//! so neither the composer's hat nor the sidebar row shows it again. Claude Code keeps its tasks a
//! whole session and Codex plans per turn: both end the same way. Only a list the Chief (the
//! person's side) set never expires by turns.
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
    /// The chat's turn (`SessionMeta::turn_count`) that last changed it; 0 for a list kept before
    /// turns were noted, which has expired in any chat past its second turn.
    #[serde(default)]
    pub turn: u64,
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
    /// The first step in progress, by its title (`step_title`); null when none is.
    pub current: Option<String>,
    /// The first step still pending after the current one (or the first pending one when none is
    /// in progress), by its title; null when none is left.
    pub next: Option<String>,
    pub items: Vec<TaskItem>,
    /// When it last changed, Unix ms.
    pub updated_at: u64,
}

impl TaskList {
    /// Whether it is still the chat's plan, with `turn_count` turns started and the latest one
    /// `running` or not: written in the running turn or the one before it, or in the latest turn
    /// once it ended. A list the Chief keeps always is.
    pub fn current(&self, turn_count: u64, running: bool) -> bool {
        self.source == TaskListSource::Chief
            || turn_count <= self.turn
            || (running && turn_count == self.turn + 1)
    }

    /// The summary's view of it.
    pub fn summary(&self) -> TaskListSummary {
        let done = self.items.iter().filter(|i| i.status == TaskStatus::Completed).count();
        let at = self.items.iter().position(|i| i.status == TaskStatus::InProgress);
        let after = at.map_or(0, |at| at + 1);
        let next = self.items.iter().skip(after).find(|i| i.status == TaskStatus::Pending);
        TaskListSummary {
            source: self.source,
            done: u32::try_from(done).unwrap_or(u32::MAX),
            total: u32::try_from(self.items.len()).unwrap_or(u32::MAX),
            current: at.and_then(|at| self.items.get(at)).map(|i| step_title(&i.content)),
            next: next.map(|i| step_title(&i.content)),
            items: self.items.clone(),
            updated_at: self.updated_at,
        }
    }
}

/// A step's title: its first line with words, trimmed. A step written as several lines (an ops
/// note: a title, then its detail) names itself by that line wherever one line names it: the
/// summary's `current` and `next`, which the sidebar's hover card and the TUI draw. The chat's list
/// draws the rest as muted detail from `items`. Leo, 2026-11-22, on a two-line note drawn as a
/// plan's step: "these shouldn't have been shown like that."
pub fn step_title(content: &str) -> String {
    content.lines().map(str::trim).find(|line| !line.is_empty()).unwrap_or("").to_owned()
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
    turn: u64,
) -> Option<Option<TaskList>> {
    if items.is_empty() {
        return match current {
            Some(list) if list.source == TaskListSource::Harness => Some(None),
            _ => None,
        };
    }
    after_set(current, TaskListSource::Harness, items, now, turn)
}

/// `current` after `source` set `items` at `now` in the chat's turn `turn`, or None when nothing
/// changed (the same steps from the same keeper in the same turn). An empty list clears it. The
/// same steps again in a later turn keep the list current: the agent went back to it.
pub fn after_set(
    current: Option<&TaskList>,
    source: TaskListSource,
    items: Vec<TaskItem>,
    now: u64,
    turn: u64,
) -> Option<Option<TaskList>> {
    if items.is_empty() {
        return current.map(|_| None);
    }
    if current.is_some_and(|list| list.source == source && list.items == items && list.turn == turn)
    {
        return None;
    }
    Some(Some(TaskList { source, items, updated_at: now, turn }))
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
            turn: 1,
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
    fn summary_names_a_multi_line_step_by_its_first_line() {
        let list = TaskList {
            items: vec![
                item(
                    "\n  Restart the relay  \nthen read its log for the 403s",
                    TaskStatus::InProgress,
                ),
                item("Rerun the lane\nfrom its last green head", TaskStatus::Pending),
            ],
            source: TaskListSource::Harness,
            updated_at: 7,
            turn: 1,
        };
        let s = list.summary();
        assert_eq!(s.current.as_deref(), Some("Restart the relay"));
        assert_eq!(s.next.as_deref(), Some("Rerun the lane"));
        assert!(s.items[0].content.contains("403s"), "the whole step stays in items");
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
            turn: 4,
        };
        assert_eq!(after_plan(Some(&kept), vec![], 2, 4), None);
        let harness = TaskList { source: TaskListSource::Harness, ..kept.clone() };
        assert_eq!(after_plan(Some(&harness), vec![], 2, 4), Some(None));
        let replaced = after_plan(Some(&kept), vec![item("y", TaskStatus::InProgress)], 3, 4)
            .unwrap()
            .unwrap();
        assert_eq!(replaced.source, TaskListSource::Harness);
        // The same steps again in the same turn change nothing, not even the time.
        assert_eq!(after_plan(Some(&harness), harness.items.clone(), 9, 4), None);
        // In a later turn they note that the agent went back to the list.
        let again = after_plan(Some(&harness), harness.items.clone(), 9, 6).unwrap().unwrap();
        assert_eq!((again.turn, again.updated_at), (6, 9));
    }

    /// Leo, 2026-11-22, on an "Earlier plan · 0 of 1" over a coordinator's hours-old ops note and a
    /// sidebar row's "0/1": "we need to figure out how to do better plans and have them expired".
    #[test]
    fn a_list_expires_once_a_turn_that_never_touched_it_ends() {
        let list = TaskList {
            source: TaskListSource::Harness,
            items: vec![item(
                "08:41Z merge cmux#45744 pinned; then close #45720",
                TaskStatus::Pending,
            )],
            updated_at: 1,
            turn: 5,
        };
        // The turn that wrote it, running and ended.
        assert!(list.current(5, true));
        assert!(list.current(5, false));
        // The next turn may finish it while it runs ...
        assert!(list.current(6, true));
        // ... but once it ended without touching the list, the list has expired.
        assert!(!list.current(6, false));
        assert!(!list.current(7, true));
        assert!(!list.current(140, false));
        // The agent's own list (`_acpmux/task_list/set`) expires the same way.
        let agent = TaskList { source: TaskListSource::Agent, ..list.clone() };
        assert!(!agent.current(7, true));
        // The person's side keeps its list until it changes it.
        let chief = TaskList { source: TaskListSource::Chief, ..list.clone() };
        assert!(chief.current(140, false));
        // A list saved before turns were noted reads as turn 0: expired past a chat's second turn.
        let old: TaskList = serde_json::from_value(json!({
            "source": "harness", "items": [{"content": "x", "status": "pending"}], "updatedAt": 1,
        }))
        .unwrap();
        assert_eq!(old.turn, 0);
        assert!(old.current(1, true));
        assert!(!old.current(2, true));
    }
}
