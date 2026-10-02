//! Pure reads: `task.list`, `task.get` and the view shape clients render.

use serde::{Deserialize, Serialize};

use crate::ids::Principal;
use crate::model::{AgentSession, Category, Comment, Priority, Relation, State, Task};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Order {
    /// Manual order (sort keys).
    #[default]
    Manual,
    Priority,
    Updated,
    Created,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ListFilter {
    /// Tasks assigned to the caller's person or delegated to the caller.
    #[serde(default)]
    pub mine: bool,
    /// Status ids, names or category names.
    #[serde(default)]
    pub status: Vec<String>,
    /// Only open categories (triage..started).
    #[serde(default)]
    pub open: bool,
    /// `me`, `usr_…` or `agt_…` (matches the delegate).
    #[serde(default)]
    pub assignee: Option<String>,
    #[serde(default)]
    pub label: Vec<String>,
    #[serde(default)]
    pub project: Option<String>,
    /// Case-insensitive substring of key, title or description.
    #[serde(default)]
    pub search: Option<String>,
    /// Only tasks that need attention (the inbox).
    #[serde(default)]
    pub attention: bool,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub order: Order,
    #[serde(default)]
    pub limit: Option<usize>,
}

/// A task as clients see it: the entity plus derived fields.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskView {
    pub key: String,
    pub category: Category,
    pub status_name: String,
    #[serde(flatten)]
    pub task: Task,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskDetail {
    #[serde(flatten)]
    pub view: TaskView,
    pub comments: Vec<Comment>,
    pub relations: Vec<Relation>,
    pub sessions: Vec<AgentSession>,
    pub children: Vec<String>,
}

pub fn view(state: &State, task: &Task) -> TaskView {
    let status = state.statuses.get(&task.status);
    TaskView {
        key: state.task_key(task),
        category: status.map_or(Category::Backlog, |s| s.category),
        status_name: status.map_or_else(String::new, |s| s.name.clone()),
        task: task.clone(),
    }
}

fn priority_rank(priority: Priority) -> u8 {
    match priority {
        Priority::Urgent => 0,
        Priority::High => 1,
        Priority::Medium => 2,
        Priority::Low => 3,
        Priority::None => 4,
    }
}

fn is_mine(task: &Task, caller: &Principal) -> bool {
    task.assignee.as_ref().is_some_and(|a| a.id() == caller.human())
        || task.delegate.as_ref().is_some_and(|d| d.principal == caller.id())
}

pub fn list(state: &State, caller: &Principal, filter: &ListFilter) -> Vec<TaskView> {
    let statuses: Vec<(Option<String>, Option<Category>)> =
        filter.status.iter().map(|s| (state.resolve_status(s), Category::parse(s))).collect();
    let labels: Vec<Option<String>> = filter.label.iter().map(|l| state.resolve_label(l)).collect();
    let project = filter.project.as_deref().map(|p| state.resolve_project(p));
    let search = filter.search.as_deref().map(str::to_lowercase);
    let mut out: Vec<TaskView> = state
        .live_tasks()
        .filter(|t| t.archived == filter.archived)
        .filter(|t| !filter.mine || is_mine(t, caller))
        .filter(|t| !filter.attention || t.attention.is_some())
        .filter(|t| {
            let category = state.category_of(t);
            (!filter.open || category.is_some_and(Category::is_open))
                && (statuses.is_empty()
                    || statuses.iter().any(|(id, cat)| {
                        id.as_deref() == Some(t.status.as_str())
                            || (cat.is_some() && *cat == category)
                    }))
        })
        .filter(|t| match filter.assignee.as_deref() {
            None => true,
            Some("me") => is_mine(t, caller),
            Some(id) => {
                t.assignee.as_ref().is_some_and(|a| a.id() == id)
                    || t.delegate.as_ref().is_some_and(|d| d.principal == id)
            }
        })
        .filter(|t| labels.iter().all(|l| l.as_ref().is_some_and(|l| t.labels.contains(l))))
        .filter(|t| match &project {
            None => true,
            Some(p) => p.is_some() && t.project == *p,
        })
        .filter(|t| match &search {
            None => true,
            Some(q) => {
                state.task_key(t).to_lowercase().contains(q)
                    || t.title.to_lowercase().contains(q)
                    || t.description.text.to_lowercase().contains(q)
            }
        })
        .map(|t| view(state, t))
        .collect();
    match filter.order {
        Order::Manual => out.sort_by(|a, b| a.task.sort_key.cmp(&b.task.sort_key)),
        Order::Priority => out.sort_by(|a, b| {
            priority_rank(a.task.priority)
                .cmp(&priority_rank(b.task.priority))
                .then(a.task.sort_key.cmp(&b.task.sort_key))
        }),
        Order::Updated => out.sort_by(|a, b| {
            b.task.updated_at.cmp(&a.task.updated_at).then(a.task.number.cmp(&b.task.number))
        }),
        Order::Created => out.sort_by_key(|v| std::cmp::Reverse(v.task.number)),
    }
    if let Some(limit) = filter.limit {
        out.truncate(limit);
    }
    out
}

pub fn detail(state: &State, reference: &str) -> Option<TaskDetail> {
    let id = state.resolve_task(reference)?;
    let task = &state.tasks[&id];
    let mut comments: Vec<Comment> =
        state.comments.values().filter(|c| c.task == id && !c.deleted).cloned().collect();
    comments.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));
    Some(TaskDetail {
        view: view(state, task),
        comments,
        relations: state
            .relations
            .values()
            .filter(|r| r.from == id || r.to == id)
            .cloned()
            .collect(),
        sessions: state.sessions.values().filter(|s| s.task == id).cloned().collect(),
        children: state
            .live_tasks()
            .filter(|t| t.parent.as_deref() == Some(id.as_str()))
            .map(|t| state.task_key(t))
            .collect(),
    })
}
