use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSummary {
    pub id: String,
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub parent_thread_id: Option<String>,
    #[serde(default)]
    pub preview: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub agent_nickname: Option<String>,
    #[serde(default)]
    pub agent_role: Option<String>,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub created_at: i64,
    #[serde(default)]
    pub updated_at: i64,
    #[serde(default)]
    pub recency_at: Option<i64>,
    #[serde(default)]
    pub status: Value,
}

impl ThreadSummary {
    pub fn activity_at(&self) -> i64 {
        let user_activity = self.recency_at.unwrap_or(self.created_at);
        if self.is_active() { user_activity } else { self.updated_at.max(user_activity) }
    }

    pub fn status_type(&self) -> &str {
        self.status.get("type").and_then(Value::as_str).unwrap_or("notLoaded")
    }

    pub fn active_flags(&self) -> Vec<String> {
        self.status
            .get("activeFlags")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect()
    }

    pub fn is_active(&self) -> bool {
        self.status_type() == "active"
    }

    pub fn title(&self) -> Option<&str> {
        self.name
            .as_deref()
            .filter(|name| !name.trim().is_empty())
            .or_else(|| (!self.preview.trim().is_empty()).then_some(self.preview.as_str()))
    }

    pub fn subagent_title(&self) -> Option<String> {
        match (self.agent_nickname.as_deref(), self.agent_role.as_deref()) {
            (Some(nickname), Some(role)) => Some(format!("{nickname} · {role}")),
            (Some(nickname), None) => Some(nickname.to_string()),
            (None, Some(role)) => Some(role.to_string()),
            (None, None) => self.title().map(str::to_owned),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreadTreeRow {
    pub thread: ThreadSummary,
    pub ancestor_has_next: Vec<bool>,
    pub is_last: bool,
}

impl ThreadTreeRow {
    pub fn depth(&self) -> usize {
        self.ancestor_has_next.len()
    }

    pub fn prefix(&self) -> String {
        if self.ancestor_has_next.is_empty() {
            return String::new();
        }
        let mut prefix = String::new();
        for has_next in self.ancestor_has_next.iter().skip(1) {
            prefix.push_str(if *has_next { "│ " } else { "  " });
        }
        prefix.push_str(if self.is_last { "└─" } else { "├─" });
        prefix
    }
}

pub fn flatten_thread_tree(mut threads: Vec<ThreadSummary>) -> Vec<ThreadTreeRow> {
    threads.sort_by(|left, right| {
        right.activity_at().cmp(&left.activity_at()).then_with(|| right.id.cmp(&left.id))
    });

    let known = threads.iter().map(|thread| thread.id.clone()).collect::<HashSet<_>>();
    let mut children: HashMap<Option<String>, Vec<ThreadSummary>> = HashMap::new();
    for thread in threads {
        let parent = thread
            .parent_thread_id
            .as_ref()
            .filter(|parent| known.contains(parent.as_str()))
            .cloned();
        children.entry(parent).or_default().push(thread);
    }
    for values in children.values_mut() {
        values.sort_by(|left, right| {
            right.activity_at().cmp(&left.activity_at()).then_with(|| right.id.cmp(&left.id))
        });
    }

    let mut rows = Vec::new();
    let mut visited = HashSet::new();
    append_children(None, &children, &mut visited, &mut Vec::new(), &mut rows);

    let mut unvisited = children
        .values()
        .flatten()
        .filter(|thread| !visited.contains(&thread.id))
        .cloned()
        .collect::<Vec<_>>();
    unvisited.sort_by_key(|thread| Reverse(thread.activity_at()));
    for thread in unvisited {
        if visited.insert(thread.id.clone()) {
            rows.push(ThreadTreeRow { thread, ancestor_has_next: Vec::new(), is_last: true });
        }
    }
    rows
}

fn append_children(
    parent: Option<&str>,
    children: &HashMap<Option<String>, Vec<ThreadSummary>>,
    visited: &mut HashSet<String>,
    ancestors: &mut Vec<bool>,
    rows: &mut Vec<ThreadTreeRow>,
) {
    let key = parent.map(str::to_owned);
    let Some(entries) = children.get(&key) else { return };
    for (index, thread) in entries.iter().enumerate() {
        if !visited.insert(thread.id.clone()) {
            continue;
        }
        let is_last = index + 1 == entries.len();
        rows.push(ThreadTreeRow {
            thread: thread.clone(),
            ancestor_has_next: ancestors.clone(),
            is_last,
        });
        ancestors.push(if ancestors.is_empty() { false } else { !is_last });
        append_children(Some(&thread.id), children, visited, ancestors, rows);
        ancestors.pop();
    }
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub id: String,
    #[serde(default)]
    pub status: Value,
    #[serde(default)]
    pub turns: Vec<Turn>,
}

impl Conversation {
    pub fn is_stopped(&self) -> bool {
        self.status.get("type").and_then(Value::as_str) != Some("active")
            && self.turns.iter().all(|turn| turn.status != "inProgress")
    }
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Turn {
    pub id: String,
    #[serde(default)]
    pub items: Vec<Value>,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub started_at: Option<i64>,
    #[serde(default)]
    pub completed_at: Option<i64>,
    #[serde(default)]
    pub duration_ms: Option<i64>,
    #[serde(default)]
    pub error: Option<Value>,
}

impl Turn {
    pub fn internal_items(&self) -> impl Iterator<Item = &Value> {
        self.items.iter().filter(|item| is_internal_item(item_type(item)))
    }
}

pub fn item_type(item: &Value) -> &str {
    item.get("type").and_then(Value::as_str).unwrap_or("unknown")
}

pub fn item_id(item: &Value) -> &str {
    item.get("id").and_then(Value::as_str).unwrap_or("unknown")
}

pub fn is_internal_item(item_type: &str) -> bool {
    !matches!(item_type, "userMessage" | "agentMessage")
}

pub fn item_status(item: &Value) -> Option<&str> {
    item.get("status").and_then(Value::as_str)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn thread(id: &str, parent: Option<&str>, activity: i64) -> ThreadSummary {
        ThreadSummary {
            id: id.into(),
            parent_thread_id: parent.map(str::to_owned),
            updated_at: activity,
            ..ThreadSummary::default()
        }
    }

    #[test]
    fn thread_tree_orders_roots_by_activity_and_nests_subagents() {
        let rows = flatten_thread_tree(vec![
            thread("older-root", None, 10),
            thread("child", Some("newer-root"), 40),
            thread("grandchild", Some("child"), 30),
            thread("newer-root", None, 50),
        ]);

        assert_eq!(
            rows.iter().map(|row| (row.thread.id.as_str(), row.depth())).collect::<Vec<_>>(),
            vec![("newer-root", 0), ("child", 1), ("grandchild", 2), ("older-root", 0)]
        );
        assert_eq!(rows[1].prefix(), "└─");
        assert_eq!(rows[2].prefix(), "  └─");
    }

    #[test]
    fn activity_uses_the_latest_stop_or_user_timestamp() {
        let stopped = ThreadSummary {
            created_at: 10,
            updated_at: 50,
            recency_at: Some(40),
            ..ThreadSummary::default()
        };
        let active = ThreadSummary {
            updated_at: 90,
            status: json!({"type": "active", "activeFlags": []}),
            ..stopped.clone()
        };

        assert_eq!(stopped.activity_at(), 50);
        assert_eq!(active.activity_at(), 40);
    }

    #[test]
    fn tree_prefix_keeps_sibling_branch_visible_for_grandchildren() {
        let rows = flatten_thread_tree(vec![
            thread("root", None, 50),
            thread("first", Some("root"), 40),
            thread("grandchild", Some("first"), 30),
            thread("second", Some("root"), 20),
        ]);

        assert_eq!(rows[1].prefix(), "├─");
        assert_eq!(rows[2].prefix(), "│ └─");
        assert_eq!(rows[3].prefix(), "└─");
    }

    #[test]
    fn stopped_requires_no_active_status_or_turn() {
        let stopped = Conversation {
            status: json!({"type": "idle"}),
            turns: vec![Turn { status: "completed".into(), ..Turn::default() }],
            ..Conversation::default()
        };
        let active_turn = Conversation {
            turns: vec![Turn { status: "inProgress".into(), ..Turn::default() }],
            ..stopped.clone()
        };

        assert!(stopped.is_stopped());
        assert!(!active_turn.is_stopped());
    }
}
