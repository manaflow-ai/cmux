//! Comments and relations.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::json;

use super::{OpResult, Reject, Tx, conflict, forbidden, invalid, not_found};
use crate::event::{Entity, EventKind};
use crate::ids::{is_valid_id, prefix};
use crate::model::{Comment, Relation, RelationKind, State};
use crate::op::{CommentAdd, CommentUpdate, RelationAdd};

/// Whether adding `from blocks to` would close a cycle in the blocks graph.
pub(crate) fn blocks_path_exists(state: &State, start: &str, goal: &str) -> bool {
    let mut edges: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for r in state.relations.values().filter(|r| r.kind == RelationKind::Blocks) {
        edges.entry(r.from.as_str()).or_default().push(r.to.as_str());
    }
    let mut seen = BTreeSet::new();
    let mut stack = vec![start];
    while let Some(node) = stack.pop() {
        if node == goal {
            return true;
        }
        if seen.insert(node) {
            stack.extend(edges.get(node).into_iter().flatten().copied());
        }
    }
    false
}

impl Tx<'_> {
    pub(super) fn comment_add(&mut self, p: &CommentAdd) -> Result<OpResult, Reject> {
        if !is_valid_id(&p.id, prefix::COMMENT) {
            return Err(invalid(format!("comment id must be cmt_…: {}", p.id)));
        }
        if self.state.comments.contains_key(&p.id) {
            return Err(conflict(format!("comment id already used: {}", p.id)));
        }
        let task = self.task_id(&p.task)?;
        if p.body.trim().is_empty() {
            return Err(invalid("comment body must not be empty"));
        }
        super::tasks::validate_text(&p.body, "comment")?;
        if let Some(parent) = &p.reply_to {
            let parent =
                self.state.comments.get(parent).ok_or_else(|| not_found("comment", parent))?;
            if parent.task != task {
                return Err(invalid("reply_to belongs to another task"));
            }
            if parent.reply_to.is_some() {
                return Err(invalid(
                    "threads are one level deep; reply to the thread's first comment",
                ));
            }
        }
        let comment = Comment {
            id: p.id.clone(),
            task: task.clone(),
            reply_to: p.reply_to.clone(),
            author: self.actor.clone(),
            body: p.body.clone(),
            version: 1,
            created_at: self.now,
            edited_at: None,
            deleted: false,
        };
        self.state.comments.insert(comment.id.clone(), comment.clone());
        self.events.push(EventKind::upsert(
            "task.comment.created",
            Entity::Comment(comment),
            json!({"task": task}),
        ));
        Ok(OpResult { id: p.id.clone(), key: self.result_for_task(&task).key })
    }

    fn own_comment(&self, id: &str) -> Result<Comment, Reject> {
        let comment =
            self.state.comments.get(id).cloned().ok_or_else(|| not_found("comment", id))?;
        if comment.deleted {
            return Err(not_found("comment", id));
        }
        if comment.author.id() != self.actor.id() && !self.actor.is_mux() {
            return Err(forbidden("only the author (or a mux) may change a comment"));
        }
        Ok(comment)
    }

    pub(super) fn comment_update(&mut self, p: &CommentUpdate) -> Result<OpResult, Reject> {
        let comment = self.own_comment(&p.comment)?;
        if p.body.trim().is_empty() {
            return Err(invalid("comment body must not be empty"));
        }
        super::tasks::validate_text(&p.body, "comment")?;
        if comment.version != p.if_version {
            return Err(conflict(format!(
                "comment changed: version {} is current",
                comment.version
            )));
        }
        let c = self
            .state
            .comments
            .get_mut(&p.comment)
            .ok_or_else(|| not_found("comment", &p.comment))?;
        c.body = p.body.clone();
        c.version += 1;
        c.edited_at = Some(self.now);
        let snapshot = c.clone();
        let task = snapshot.task.clone();
        self.events.push(EventKind::upsert(
            "task.comment.updated",
            Entity::Comment(snapshot),
            json!({"task": task}),
        ));
        Ok(OpResult { id: p.comment.clone(), key: self.result_for_task(&task).key })
    }

    pub(super) fn comment_delete(&mut self, id: &str) -> Result<OpResult, Reject> {
        self.own_comment(id)?;
        let c = self.state.comments.get_mut(id).ok_or_else(|| not_found("comment", id))?;
        c.deleted = true;
        c.body.clear();
        c.edited_at = Some(self.now);
        let snapshot = c.clone();
        let task = snapshot.task.clone();
        self.events.push(EventKind::upsert(
            "task.comment.deleted",
            Entity::Comment(snapshot),
            json!({"task": task}),
        ));
        Ok(OpResult { id: id.to_owned(), key: self.result_for_task(&task).key })
    }

    pub(super) fn relation_add(&mut self, p: &RelationAdd) -> Result<OpResult, Reject> {
        if !is_valid_id(&p.id, prefix::RELATION) {
            return Err(invalid(format!("relation id must be rel_…: {}", p.id)));
        }
        if self.state.relations.contains_key(&p.id) {
            return Err(conflict(format!("relation id already used: {}", p.id)));
        }
        let from = self.task_id(&p.from)?;
        let to = self.task_id(&p.to)?;
        if from == to {
            return Err(invalid("a task cannot relate to itself"));
        }
        let duplicate = self.state.relations.values().any(|r| {
            r.kind == p.kind
                && ((r.from == from && r.to == to)
                    || (p.kind == RelationKind::Related && r.from == to && r.to == from))
        });
        if duplicate {
            return Err(conflict("relation already exists"));
        }
        if p.kind == RelationKind::Blocks && blocks_path_exists(self.state, &to, &from) {
            return Err(invalid("blocks relation would create a cycle"));
        }
        let relation = Relation { id: p.id.clone(), kind: p.kind, from: from.clone(), to };
        self.state.relations.insert(relation.id.clone(), relation.clone());
        self.events.push(EventKind::upsert(
            "task.relation.added",
            Entity::Relation(relation),
            serde_json::Value::Null,
        ));
        Ok(OpResult { id: p.id.clone(), key: self.result_for_task(&from).key })
    }

    pub(super) fn relation_remove(&mut self, id: &str) -> Result<OpResult, Reject> {
        if self.state.relations.remove(id).is_none() {
            return Err(not_found("relation", id));
        }
        self.events.push(EventKind::remove(
            "task.relation.removed",
            "relation",
            id,
            serde_json::Value::Null,
        ));
        Ok(OpResult { id: id.to_owned(), key: None })
    }
}
