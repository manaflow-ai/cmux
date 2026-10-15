//! The project list's operations on the state commit path
//! (plans/cmux-next/projects.md section 6): each one loads the list, applies
//! the reducer, writes the rows it changed and emits one `session.events`
//! batch (`state_upsert` / `state_delete` of resource `project`, id = path).

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;

use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::project_sources::{self, SourceScan};
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

/// This machine's editor sources, under `HOME` (and the XDG folders on
/// Linux). `CMUX_PROJECT_SOURCES=off` turns them off for a daemon that must
/// not read them.
pub(crate) fn editor_scans() -> Vec<SourceScan> {
    if !project_sources::enabled() {
        return Vec::new();
    }
    project_sources::Layout::current()
        .map(|layout| project_sources::scan_all(&layout))
        .unwrap_or_default()
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
                store::write_disabled(transaction, &projects)?;
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

    /// `project.source.update`: the user turns a source on or off. Turning
    /// an editor or app source on reads it again at once.
    pub(crate) fn state_project_source_update(
        &self,
        mutation: &WorkspaceMutation,
        source: &str,
        enabled: bool,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint =
            json!({"operation": "project.source.update", "source": source, "enabled": enabled});
        let scans: Vec<SourceScan> = if enabled {
            editor_scans().into_iter().filter(|scan| scan.source == source).collect()
        } else {
            Vec::new()
        };
        let refusals = store::refusals();
        let now = now_ms();
        self.commit_projects(mutation, "project.source.update", &fingerprint, |projects| {
            let mut changed: std::collections::BTreeSet<String> = projects
                .set_source_enabled(source, enabled)
                .map_err(rejected)?
                .into_iter()
                .collect();
            for scan in &scans {
                let observed = projects.observe(scan.source, &scan.entries, true, now, &refusals);
                changed.extend(observed.map_err(rejected)?);
            }
            Ok(changed.into_iter().collect())
        })
    }

    /// The daemon's own import of `scans` (startup, a source file changed):
    /// each list is complete, under the same rules as `project.observe`.
    pub(crate) fn state_project_import(&self, scans: &[SourceScan]) -> anyhow::Result<StateCommit> {
        let mutation = WorkspaceMutation::daemon_local("project-sources");
        let sources: Vec<&str> = scans.iter().map(|scan| scan.source).collect();
        let fingerprint =
            json!({"operation": "project.import", "sources": sources, "id": mutation.id});
        let refusals = store::refusals();
        let now = now_ms();
        self.commit_projects(&mutation, "project.import", &fingerprint, |projects| {
            let mut changed = std::collections::BTreeSet::new();
            for scan in scans {
                let observed = projects.observe(scan.source, &scan.entries, true, now, &refusals);
                changed.extend(observed.map_err(rejected)?);
            }
            Ok(changed.into_iter().collect())
        })
    }

    /// `project.sync` (app launch and activation): the disk facts the app
    /// checked with its privacy rules (rule 4), and a fresh read of the editor
    /// sources (section 3), each one's list `complete`. The store never checks
    /// whether a project folder exists itself.
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
        let scans = editor_scans();
        let refusals = store::refusals();
        let now = now_ms();
        self.commit_projects(mutation, "project.sync", &fingerprint, |projects| {
            let mut changed = std::collections::BTreeSet::new();
            for scan in &scans {
                let observed = projects.observe(scan.source, &scan.entries, true, now, &refusals);
                changed.extend(observed.map_err(rejected)?);
            }
            changed.extend(projects.apply_disk(existing, gone));
            Ok(changed.into_iter().collect())
        })
    }
}
