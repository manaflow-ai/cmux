//! Apps that keep an explicit project list (verified from the installed apps
//! on 2026-10-10): a project made there shows up before it has any chat.
//!
//! - Codex desktop app (also the ChatGPT app's Codex): `local-projects`
//!   (`{id: {rootPaths, updatedAt}}`, ms) and `electron-saved-workspace-roots`
//!   in `$CODEX_HOME/.codex-global-state.json`.
//! - t3code: `projection_projects` (`workspace_root`, ISO `updated_at`,
//!   `deleted_at`) in `~/.t3/userdata/statev2.sqlite`, else `state.sqlite`.
//! - Conductor: `repos` (`root_path`, `updated_at`, `hidden`) in
//!   `com.conductor.app/conductor.db`.

use serde_json::Value;

use super::{Layout, SourceScan, modified_ms, open_read_only, utc_ms};
use crate::state::projects::Observation;

pub(crate) fn scan_codex_app(layout: &Layout) -> Option<SourceScan> {
    let file = layout.codex_global_state();
    let state: Value = serde_json::from_str(&std::fs::read_to_string(&file).ok()?).ok()?;
    let saved_at = modified_ms(&file).unwrap_or(0);
    let mut entries = Vec::new();
    for project in state
        .get("local-projects")
        .and_then(Value::as_object)
        .into_iter()
        .flat_map(|map| map.values())
    {
        let used = project.get("updatedAt").and_then(Value::as_i64).unwrap_or(saved_at);
        for root in project.get("rootPaths").and_then(Value::as_array).into_iter().flatten() {
            if let Some(path) = root.as_str() {
                entries.push(Observation { path: path.to_string(), last_used_ms: used });
            }
        }
    }
    // Folders opened without a project: no time of their own beyond the file's.
    let saved = state.get("electron-saved-workspace-roots").and_then(Value::as_array);
    for root in saved.into_iter().flatten().filter_map(Value::as_str) {
        if !entries.iter().any(|entry| entry.path == root) {
            entries.push(Observation { path: root.to_string(), last_used_ms: 1 });
        }
    }
    entries.retain(|entry| entry.path.starts_with('/'));
    Some(SourceScan { source: "codex-app", entries })
}

pub(crate) fn scan_t3code(layout: &Layout) -> Option<SourceScan> {
    let db = layout.t3code_dbs().into_iter().find(|db| db.is_file())?;
    let rows = query(
        &db,
        "SELECT workspace_root, updated_at FROM projection_projects WHERE deleted_at IS NULL",
    )?;
    Some(SourceScan { source: "t3code", entries: rows })
}

pub(crate) fn scan_conductor(layout: &Layout) -> Option<SourceScan> {
    let rows = query(
        &layout.conductor_db(),
        "SELECT root_path, updated_at FROM repos WHERE root_path IS NOT NULL AND coalesce(hidden, 0) = 0",
    )?;
    Some(SourceScan { source: "conductor", entries: rows })
}

/// `(path, UTC time)` rows; any failed row reports nothing (a partial list
/// sent as complete would drop projects).
fn query(db: &std::path::Path, sql: &str) -> Option<Vec<Observation>> {
    let connection = open_read_only(db)?;
    let mut statement = connection.prepare(sql).ok()?;
    let rows = statement
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
        .ok()?
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    Some(
        rows.into_iter()
            .filter(|(path, _)| path.starts_with('/'))
            .map(|(path, time)| Observation { last_used_ms: utc_ms(&time).unwrap_or(1), path })
            .collect(),
    )
}
