//! Workflow configuration: labels, statuses, projects, team settings.

use serde_json::json;

use super::{OpResult, Reject, Tx, conflict, invalid, not_found};
use crate::event::{Entity, EventKind};
use crate::ids::{is_valid_id, prefix};
use crate::model::{Category, Label, Project, ProjectState, Status};
use crate::op::{
    LabelCreate, LabelUpdate, ProjectCreate, ProjectUpdate, SettingsUpdate, StatusCreate,
    StatusDelete, StatusUpdate,
};

fn validate_name(name: &str, what: &str) -> Result<String, Reject> {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed.chars().count() > 80 {
        return Err(invalid(format!("{what} name must be 1..=80 characters")));
    }
    Ok(trimmed.to_owned())
}

fn validate_color(color: Option<u8>) -> Result<u8, Reject> {
    match color {
        Some(c) if c > 15 => Err(invalid("color is a Ghostty palette index 0..=15")),
        Some(c) => Ok(c),
        None => Ok(8),
    }
}

fn validate_prefix(prefix: &str) -> Result<(), Reject> {
    let ok = (1..=8).contains(&prefix.len()) && prefix.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
        && prefix.as_bytes()[0].is_ascii_uppercase();
    if ok { Ok(()) } else { Err(invalid("key prefix must be 1..=8 of A-Z0-9, starting with a letter")) }
}

impl Tx<'_> {
    fn label_name_taken(&self, name: &str, except: &str) -> bool {
        self.state
            .labels
            .values()
            .any(|l| !l.archived && l.id != except && l.name.eq_ignore_ascii_case(name))
    }

    pub(super) fn label_create(&mut self, p: &LabelCreate) -> Result<OpResult, Reject> {
        if !is_valid_id(&p.id, prefix::LABEL) {
            return Err(invalid(format!("label id must be lbl_…: {}", p.id)));
        }
        if self.state.labels.contains_key(&p.id) {
            return Err(conflict(format!("label id already used: {}", p.id)));
        }
        let name = validate_name(&p.name, "label")?;
        if self.label_name_taken(&name, &p.id) {
            return Err(conflict(format!("label name already used: {name}")));
        }
        let label = Label { id: p.id.clone(), name, color: validate_color(p.color)?, archived: false };
        self.state.labels.insert(label.id.clone(), label.clone());
        self.events.push(EventKind::upsert("task.label.created", Entity::Label(label), serde_json::Value::Null));
        Ok(OpResult { id: p.id.clone(), key: None })
    }

    pub(super) fn label_update(&mut self, p: &LabelUpdate) -> Result<OpResult, Reject> {
        let id = self.state.resolve_label(&p.label).ok_or_else(|| not_found("label", &p.label))?;
        let name = p.name.as_deref().map(|n| validate_name(n, "label")).transpose()?;
        if let Some(name) = &name
            && self.label_name_taken(name, &id)
        {
            return Err(conflict(format!("label name already used: {name}")));
        }
        let color = p.color.map(|c| validate_color(Some(c))).transpose()?;
        let label = self.state.labels.get_mut(&id).expect("validated label");
        if let Some(name) = name {
            label.name = name;
        }
        if let Some(color) = color {
            label.color = color;
        }
        let snapshot = label.clone();
        self.events.push(EventKind::upsert("task.label.updated", Entity::Label(snapshot), serde_json::Value::Null));
        Ok(OpResult { id, key: None })
    }

    /// Archive the label and remove it from every task in the same commit.
    pub(super) fn label_delete(&mut self, reference: &str) -> Result<OpResult, Reject> {
        let id = self.state.resolve_label(reference).ok_or_else(|| not_found("label", reference))?;
        let holders: Vec<String> = self
            .state
            .tasks
            .values()
            .filter(|t| t.labels.contains(&id))
            .map(|t| t.id.clone())
            .collect();
        for task_id in holders {
            let task = self.state.tasks.get_mut(&task_id).expect("task exists");
            task.labels.remove(&id);
            task.updated_at = self.now;
            let snapshot = task.clone();
            self.events.push(EventKind::upsert("task.labeled", Entity::Task(Box::new(snapshot)), json!({"added": [], "removed": [id], "cascade": true})));
        }
        let label = self.state.labels.get_mut(&id).expect("validated label");
        label.archived = true;
        let snapshot = label.clone();
        self.events.push(EventKind::upsert("task.label.deleted", Entity::Label(snapshot), serde_json::Value::Null));
        Ok(OpResult { id, key: None })
    }

    pub(super) fn status_create(&mut self, p: &StatusCreate) -> Result<OpResult, Reject> {
        if !is_valid_id(&p.id, prefix::STATUS) {
            return Err(invalid(format!("status id must be st_…: {}", p.id)));
        }
        if self.state.statuses.contains_key(&p.id) {
            return Err(conflict(format!("status id already used: {}", p.id)));
        }
        let name = validate_name(&p.name, "status")?;
        if self.state.statuses.values().any(|s| s.name.eq_ignore_ascii_case(&name)) {
            return Err(conflict(format!("status name already used: {name}")));
        }
        let position = p.position.unwrap_or_else(|| self.state.statuses.values().map(|s| s.position).max().unwrap_or(0) + 1);
        let status = Status { id: p.id.clone(), name, category: p.category, position, color: validate_color(p.color)? };
        self.state.statuses.insert(status.id.clone(), status.clone());
        self.events.push(EventKind::upsert("task.status.created", Entity::Status(status), serde_json::Value::Null));
        Ok(OpResult { id: p.id.clone(), key: None })
    }

    pub(super) fn status_update(&mut self, p: &StatusUpdate) -> Result<OpResult, Reject> {
        let id = self.state.resolve_status(&p.status).ok_or_else(|| not_found("status", &p.status))?;
        let name = p.name.as_deref().map(|n| validate_name(n, "status")).transpose()?;
        if let Some(name) = &name
            && self.state.statuses.values().any(|s| s.id != id && s.name.eq_ignore_ascii_case(name))
        {
            return Err(conflict(format!("status name already used: {name}")));
        }
        let color = p.color.map(|c| validate_color(Some(c))).transpose()?;
        let status = self.state.statuses.get_mut(&id).expect("validated status");
        if let Some(name) = name {
            status.name = name;
        }
        if let Some(color) = color {
            status.color = color;
        }
        if let Some(position) = p.position {
            status.position = position;
        }
        let snapshot = status.clone();
        self.events.push(EventKind::upsert("task.status.updated", Entity::Status(snapshot), serde_json::Value::Null));
        Ok(OpResult { id, key: None })
    }

    /// Delete a status: its tasks move to `replacement` in the same commit;
    /// every required category keeps a status; settings never point at it.
    pub(super) fn status_delete(&mut self, p: &StatusDelete) -> Result<OpResult, Reject> {
        let id = self.state.resolve_status(&p.status).ok_or_else(|| not_found("status", &p.status))?;
        let replacement = self.state.resolve_status(&p.replacement).ok_or_else(|| not_found("status", &p.replacement))?;
        if id == replacement {
            return Err(invalid("replacement must be another status"));
        }
        let category = self.state.statuses[&id].category;
        let remaining = self.state.statuses.values().filter(|s| s.id != id && s.category == category).count();
        if Category::REQUIRED.contains(&category) && remaining == 0 {
            return Err(invalid(format!("the team needs at least one {} status", category.as_str())));
        }
        let settings = &self.state.settings;
        if settings.default_status == id || settings.started_status == id || settings.review_status.as_deref() == Some(id.as_str()) {
            return Err(invalid("status is used by team settings; change them first"));
        }
        let movers: Vec<String> = self.state.tasks.values().filter(|t| t.status == id).map(|t| t.id.clone()).collect();
        for task in movers {
            self.set_status(&task, &replacement, false);
        }
        self.state.statuses.remove(&id);
        self.events.push(EventKind::remove("task.status.deleted", "status", &id, json!({"replacement": replacement})));
        Ok(OpResult { id, key: None })
    }

    pub(super) fn project_create(&mut self, p: &ProjectCreate) -> Result<OpResult, Reject> {
        if !is_valid_id(&p.id, prefix::PROJECT) {
            return Err(invalid(format!("project id must be prj_…: {}", p.id)));
        }
        if self.state.projects.contains_key(&p.id) {
            return Err(conflict(format!("project id already used: {}", p.id)));
        }
        let name = validate_name(&p.name, "project")?;
        let project = Project {
            id: p.id.clone(),
            name,
            state: p.state.unwrap_or(ProjectState::Active),
            lead: Some(crate::ids::Principal::user(self.actor.human())),
            archived: false,
        };
        self.state.projects.insert(project.id.clone(), project.clone());
        self.events.push(EventKind::upsert("task.project.created", Entity::Project(project), serde_json::Value::Null));
        Ok(OpResult { id: p.id.clone(), key: None })
    }

    pub(super) fn project_update(&mut self, p: &ProjectUpdate) -> Result<OpResult, Reject> {
        let id = self.state.resolve_project(&p.project).ok_or_else(|| not_found("project", &p.project))?;
        let name = p.name.as_deref().map(|n| validate_name(n, "project")).transpose()?;
        let project = self.state.projects.get_mut(&id).expect("validated project");
        if let Some(name) = name {
            project.name = name;
        }
        if let Some(state) = p.state {
            project.state = state;
        }
        let snapshot = project.clone();
        self.events.push(EventKind::upsert("task.project.updated", Entity::Project(snapshot), serde_json::Value::Null));
        Ok(OpResult { id, key: None })
    }

    /// Archive the project and detach its tasks in the same commit.
    pub(super) fn project_archive(&mut self, reference: &str) -> Result<OpResult, Reject> {
        let id = self.state.resolve_project(reference).ok_or_else(|| not_found("project", reference))?;
        let members: Vec<String> = self.state.tasks.values().filter(|t| t.project.as_deref() == Some(id.as_str())).map(|t| t.id.clone()).collect();
        for task_id in members {
            let task = self.state.tasks.get_mut(&task_id).expect("task exists");
            task.project = None;
            task.updated_at = self.now;
            let snapshot = task.clone();
            self.events.push(EventKind::upsert("task.updated", Entity::Task(Box::new(snapshot)), json!({"fields": ["project"], "cascade": true})));
        }
        let project = self.state.projects.get_mut(&id).expect("validated project");
        project.archived = true;
        let snapshot = project.clone();
        self.events.push(EventKind::upsert("task.project.archived", Entity::Project(snapshot), serde_json::Value::Null));
        Ok(OpResult { id, key: None })
    }

    pub(super) fn settings_update(&mut self, p: &SettingsUpdate) -> Result<OpResult, Reject> {
        let mut next = self.state.settings.clone();
        if let Some(prefix) = &p.key_prefix {
            validate_prefix(prefix)?;
            next.key_prefix = prefix.clone();
        }
        let status_in = |tx: &Self, r: &str, categories: &[Category]| -> Result<String, Reject> {
            let id = tx.state.resolve_status(r).ok_or_else(|| not_found("status", r))?;
            if categories.contains(&tx.state.statuses[&id].category) {
                Ok(id)
            } else {
                Err(invalid(format!("status {r} has the wrong category for this setting")))
            }
        };
        if let Some(r) = &p.default_status {
            next.default_status = status_in(self, r, &[Category::Triage, Category::Backlog, Category::Unstarted])?;
        }
        if let Some(r) = &p.started_status {
            next.started_status = status_in(self, r, &[Category::Started])?;
        }
        if p.clear_review_status && p.review_status.is_some() {
            return Err(invalid("review_status and clear_review_status are exclusive"));
        }
        if let Some(r) = &p.review_status {
            next.review_status = Some(status_in(self, r, &[Category::Started])?);
        } else if p.clear_review_status {
            next.review_status = None;
        }
        if let Some(flow) = p.agent_flow {
            next.agent_flow = flow;
        }
        self.state.settings = next.clone();
        self.events.push(EventKind::upsert("task.settings.updated", Entity::Settings(next), serde_json::Value::Null));
        Ok(OpResult { id: self.state.settings.team.clone(), key: None })
    }
}
