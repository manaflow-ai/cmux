//! The project list's operations on the state commit path
//! (plans/cmux-next/projects.md section 6): each one loads the list, applies
//! the reducer, writes the rows it changed and emits one `session.events`
//! batch (`state_upsert` / `state_delete` of resource `project`, id = path).

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;

use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::projects::{Observation, OverlayEdit, ProjectReject, Projects};
use crate::state::projects_store::{self as store, RESOURCE};
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};

/// The most paths one `project.observe` batch may carry: a source with
/// `complete` sends everything it knows in one batch.
pub(crate) const MAX_OBSERVATIONS: usize = 10_000;

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64)
}

/// `entries` of `project.observe`: `{path, last_used_ms}` with the time a
/// decimal string (spec `decimal`); a JSON number is accepted too.
fn observations(entries: &Value) -> anyhow::Result<Vec<Observation>> {
    let items = entries
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("bad request: entries must be an array"))?;
    items
        .iter()
        .map(|item| {
            let path = item.get("path").and_then(Value::as_str);
            let time = item.get("last_used_ms");
            let last_used_ms = time
                .and_then(Value::as_str)
                .and_then(|text| text.parse::<i64>().ok())
                .or_else(|| time.and_then(Value::as_i64));
            match (path, last_used_ms) {
                (Some(path), Some(last_used_ms)) => {
                    Ok(Observation { path: path.to_string(), last_used_ms })
                }
                _ => Err(anyhow::anyhow!(
                    "bad request: entries: each needs path and a decimal last_used_ms"
                )),
            }
        })
        .collect()
}

fn rejected(reject: ProjectReject) -> anyhow::Error {
    let detail = match &reject {
        ProjectReject::InvalidPath(detail)
        | ProjectReject::RefusedPath(detail)
        | ProjectReject::UnknownProject(detail)
        | ProjectReject::InvalidName(detail) => detail.clone(),
    };
    anyhow::anyhow!("bad request: {}: {detail}", reject.code())
}

/// The commit's events and result for the `changed` paths of `projects`.
fn changes(projects: &Projects, changed: &[String]) -> StateChanges {
    let events = changed
        .iter()
        .map(|path| match projects.get(path) {
            Some(project) => state_upsert(RESOURCE, path, store::project_value(project)),
            None => state_delete(RESOURCE, path),
        })
        .collect();
    StateChanges::new(json!({"changed": changed}), events)
}

impl Mux {
    fn commit_projects(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        apply: impl FnOnce(&mut Projects) -> anyhow::Result<Vec<String>>,
    ) -> anyhow::Result<StateCommit> {
        self.commit_state(
            mutation,
            operation,
            fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let mut projects = store::load(transaction)?;
                let changed = apply(&mut projects)?;
                store::write(transaction, &projects, &changed)?;
                Ok(changes(&projects, &changed))
            },
        )
    }

    /// `project.observe`: `source` reports paths (acpmux's chat index, an
    /// editor adapter). Paths are normalized lexically, never read from disk;
    /// refused ones are skipped.
    pub(crate) fn state_project_observe(
        &self,
        mutation: &WorkspaceMutation,
        source: &str,
        entries: &Value,
        complete: bool,
    ) -> anyhow::Result<StateCommit> {
        let parsed = observations(entries)?;
        anyhow::ensure!(
            parsed.len() <= MAX_OBSERVATIONS,
            "bad request: at most {MAX_OBSERVATIONS} entries per batch"
        );
        let fingerprint = json!({"operation": "project.observe", "source": source, "entries": entries, "complete": complete});
        let refusals = store::refusals();
        let now = now_ms();
        self.commit_projects(mutation, "project.observe", &fingerprint, |projects| {
            projects.observe(source, &parsed, complete, now, &refusals).map_err(rejected)
        })
    }

    /// `project.add`: the user adds a folder they picked (source `user`). It
    /// must be absolute and exist; its symlinks are resolved (the user chose
    /// this folder, so reading it is the user's act).
    pub(crate) fn state_project_add(
        &self,
        mutation: &WorkspaceMutation,
        path: &str,
    ) -> anyhow::Result<StateCommit> {
        anyhow::ensure!(path.starts_with('/'), "bad request: invalid_path: {path} is not absolute");
        let canonical = std::fs::canonicalize(path).map_err(|_| {
            anyhow::anyhow!("bad request: invalid_path: {path} is not an existing folder")
        })?;
        anyhow::ensure!(canonical.is_dir(), "bad request: invalid_path: {path} is not a folder");
        let canonical = canonical.to_string_lossy().into_owned();
        let fingerprint = json!({"operation": "project.add", "path": path});
        let refusals = store::refusals();
        let now = now_ms();
        self.commit_projects(mutation, "project.add", &fingerprint, |projects| {
            projects.add(&canonical, now, &refusals).map_err(rejected)
        })
    }

    /// `project.update`: the user's rename, pin, hide or order.
    pub(crate) fn state_project_update(
        &self,
        mutation: &WorkspaceMutation,
        path: &str,
        edit: &Value,
    ) -> anyhow::Result<StateCommit> {
        let parsed: OverlayEdit = serde_json::from_value(edit.clone())
            .map_err(|error| anyhow::anyhow!("bad request: {error}"))?;
        let fingerprint = json!({"operation": "project.update", "path": path, "edit": edit});
        self.commit_projects(mutation, "project.update", &fingerprint, |projects| {
            let changed = projects.update(path, &parsed).map_err(rejected)?;
            Ok(if changed { vec![path.to_string()] } else { Vec::new() })
        })
    }

    /// `project.remove`: hidden if a source still reports it, else deleted.
    pub(crate) fn state_project_remove(
        &self,
        mutation: &WorkspaceMutation,
        path: &str,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = json!({"operation": "project.remove", "path": path});
        self.commit_projects(mutation, "project.remove", &fingerprint, |projects| {
            projects.remove(path).map_err(rejected)?;
            Ok(vec![path.to_string()])
        })
    }

    /// `project.sync` (app activation): the disk facts the app checked with its
    /// privacy rules (rule 4); the store reads no disk itself.
    pub(crate) fn state_project_sync(
        &self,
        mutation: &WorkspaceMutation,
        existing: &[String],
        gone: &[String],
    ) -> anyhow::Result<StateCommit> {
        anyhow::ensure!(
            existing.len() + gone.len() <= MAX_OBSERVATIONS,
            "bad request: at most {MAX_OBSERVATIONS} paths per sync"
        );
        let fingerprint = json!({"operation": "project.sync", "existing": existing, "gone": gone});
        self.commit_projects(mutation, "project.sync", &fingerprint, |projects| {
            Ok(projects.apply_disk(existing, gone))
        })
    }
}
