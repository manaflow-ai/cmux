//! The state invariants of plans/cmux-next/tasks.md section 2. `check`
//! returns every violation; debug builds of the service run it after each
//! commit and the property tests run it after every op.

use std::collections::{BTreeMap, BTreeSet};

use crate::model::{Category, RelationKind, State};
use crate::sort_key;

pub fn check(state: &State) -> Vec<String> {
    let mut out = Vec::new();
    numbers(state, &mut out);
    references(state, &mut out);
    acyclic(state, &mut out);
    workflow(state, &mut out);
    labels_and_keys(state, &mut out);
    sessions(state, &mut out);
    ledger(state, &mut out);
    out
}

fn numbers(state: &State, out: &mut Vec<String>) {
    let mut seen = BTreeSet::new();
    for task in state.tasks.values() {
        if task.number == 0 || task.number >= state.settings.next_number {
            out.push(format!(
                "{}: number {} outside 1..{}",
                task.id, task.number, state.settings.next_number
            ));
        }
        if !seen.insert(task.number) {
            out.push(format!("{}: number {} reused", task.id, task.number));
        }
    }
}

fn references(state: &State, out: &mut Vec<String>) {
    let live = |id: &str| state.tasks.get(id).is_some_and(|t| !t.deleted);
    for task in state.live_tasks() {
        if !state.statuses.contains_key(&task.status) {
            out.push(format!("{}: unknown status {}", task.id, task.status));
        }
        for label in &task.labels {
            if state.labels.get(label).is_none_or(|l| l.archived) {
                out.push(format!("{}: label {label} is not live", task.id));
            }
        }
        if let Some(project) = &task.project
            && state.projects.get(project).is_none_or(|p| p.archived)
        {
            out.push(format!("{}: project {project} is not live", task.id));
        }
        if let Some(parent) = &task.parent
            && (!live(parent) || parent == &task.id)
        {
            out.push(format!("{}: bad parent {parent}", task.id));
        }
        if task.title.trim().is_empty() {
            out.push(format!("{}: empty title", task.id));
        }
    }
    for relation in state.relations.values() {
        if !live(&relation.from) || !live(&relation.to) || relation.from == relation.to {
            out.push(format!("{}: relation endpoints invalid", relation.id));
        }
    }
    for comment in state.comments.values() {
        if !state.tasks.contains_key(&comment.task) {
            out.push(format!("{}: comment on unknown task", comment.id));
        }
    }
    for session in state.sessions.values() {
        if !state.tasks.contains_key(&session.task) {
            out.push(format!("{}: session on unknown task", session.id));
        }
    }
}

fn acyclic(state: &State, out: &mut Vec<String>) {
    for task in state.live_tasks() {
        let mut cursor = task.parent.clone();
        let mut steps = 0;
        while let Some(id) = cursor {
            steps += 1;
            if id == task.id || steps > state.tasks.len() {
                out.push(format!("{}: parent cycle", task.id));
                break;
            }
            cursor = state.tasks.get(&id).and_then(|t| t.parent.clone());
        }
    }
    let mut edges: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    let mut pairs = BTreeSet::new();
    for r in state.relations.values() {
        let pair = if r.kind == RelationKind::Related && r.to < r.from {
            (r.kind, r.to.as_str(), r.from.as_str())
        } else {
            (r.kind, r.from.as_str(), r.to.as_str())
        };
        if !pairs.insert(pair) {
            out.push(format!("{}: duplicate relation", r.id));
        }
        if r.kind == RelationKind::Blocks {
            edges.entry(r.from.as_str()).or_default().push(r.to.as_str());
        }
    }
    // Kahn's algorithm: a cycle leaves nodes with remaining in-degree.
    let mut indegree: BTreeMap<&str, usize> = BTreeMap::new();
    for (from, tos) in &edges {
        indegree.entry(from).or_insert(0);
        for to in tos {
            *indegree.entry(to).or_insert(0) += 1;
        }
    }
    let mut ready: Vec<&str> = indegree.iter().filter(|(_, d)| **d == 0).map(|(n, _)| *n).collect();
    let mut visited = 0;
    while let Some(node) = ready.pop() {
        visited += 1;
        for to in edges.get(node).into_iter().flatten() {
            let d = indegree.get_mut(to).expect("counted");
            *d -= 1;
            if *d == 0 {
                ready.push(to);
            }
        }
    }
    if visited != indegree.len() {
        out.push("blocks graph has a cycle".to_owned());
    }
}

fn workflow(state: &State, out: &mut Vec<String>) {
    for category in Category::REQUIRED {
        if !state.statuses.values().any(|s| s.category == category) {
            out.push(format!("no {} status", category.as_str()));
        }
    }
    let settings = &state.settings;
    for (name, id) in [
        ("default_status", Some(&settings.default_status)),
        ("started_status", Some(&settings.started_status)),
        ("review_status", settings.review_status.as_ref()),
    ] {
        if let Some(id) = id
            && !state.statuses.contains_key(id)
        {
            out.push(format!("settings.{name} points at unknown status {id}"));
        }
    }
    for task in state.live_tasks() {
        let Some(category) = state.category_of(task) else { continue };
        if task.completed_at.is_some() != (category == Category::Completed) {
            out.push(format!("{}: completed_at disagrees with {}", task.id, category.as_str()));
        }
        if task.canceled_at.is_some() != (category == Category::Canceled) {
            out.push(format!("{}: canceled_at disagrees with {}", task.id, category.as_str()));
        }
        if category.rank() >= Category::Started.rank() && task.started_at.is_none() {
            out.push(format!("{}: started without started_at", task.id));
        }
    }
}

fn labels_and_keys(state: &State, out: &mut Vec<String>) {
    let mut names = BTreeSet::new();
    for label in state.labels.values().filter(|l| !l.archived) {
        if !names.insert(label.name.to_lowercase()) {
            out.push(format!("label name {} used twice", label.name));
        }
    }
    let mut keys = BTreeSet::new();
    for task in state.live_tasks() {
        if !sort_key::is_valid(&task.sort_key) {
            out.push(format!("{}: invalid sort key {}", task.id, task.sort_key));
        }
        if !keys.insert(task.sort_key.as_str()) {
            out.push(format!("{}: sort key {} used twice", task.id, task.sort_key));
        }
    }
}

fn sessions(state: &State, out: &mut Vec<String>) {
    let mut active = BTreeSet::new();
    for session in state.sessions.values().filter(|s| !s.status.is_terminal()) {
        if !active.insert((session.task.as_str(), session.agent.principal.as_str())) {
            out.push(format!("{}: second active session for one agent on one task", session.id));
        }
        if state.tasks.get(&session.task).is_some_and(|t| t.deleted) {
            out.push(format!("{}: active session on a deleted task", session.id));
        }
    }
}

fn ledger(state: &State, out: &mut Vec<String>) {
    if state.ledger.len() != state.ledger_order.len() {
        out.push("ledger order and ledger disagree".to_owned());
    }
    if state.ledger.values().any(|e| e.seq > state.seq) {
        out.push("ledger entry after the last commit".to_owned());
    }
}
