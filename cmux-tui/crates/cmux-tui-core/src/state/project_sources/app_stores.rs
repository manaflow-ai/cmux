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

use super::{
    Layout, MAX_SOURCE_ENTRIES, MAX_SOURCE_PATH_BYTES, MAX_SOURCE_TIMESTAMP_BYTES,
    MAX_SOURCE_TOTAL_BYTES, SourceScan, modified_ms, open_read_only, read_text_bounded, utc_ms,
};
use crate::state::projects::Observation;

pub(crate) fn scan_codex_app(layout: &Layout) -> Option<SourceScan> {
    let file = layout.codex_global_state();
    let state: Value = serde_json::from_str(&read_text_bounded(&file)?).ok()?;
    let saved_at = modified_ms(&file).unwrap_or(0);
    let mut entries = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for project in state
        .get("local-projects")
        .and_then(Value::as_object)
        .into_iter()
        .flat_map(|map| map.values())
    {
        let used = project.get("updatedAt").and_then(Value::as_i64).unwrap_or(saved_at);
        for root in project.get("rootPaths").and_then(Value::as_array).into_iter().flatten() {
            if let Some(path) = root.as_str()
                && path.starts_with('/')
                && path.len() <= MAX_SOURCE_PATH_BYTES
                && seen.insert(path.to_owned())
            {
                entries.push(Observation { path: path.to_string(), last_used_ms: used });
                if entries.len() > MAX_SOURCE_ENTRIES {
                    return None;
                }
            }
        }
    }
    // Folders opened without a project: no time of their own beyond the file's.
    let saved = state.get("electron-saved-workspace-roots").and_then(Value::as_array);
    for root in saved.into_iter().flatten().filter_map(Value::as_str) {
        if root.starts_with('/')
            && root.len() <= MAX_SOURCE_PATH_BYTES
            && seen.insert(root.to_owned())
        {
            entries.push(Observation { path: root.to_string(), last_used_ms: 1 });
            if entries.len() > MAX_SOURCE_ENTRIES {
                return None;
            }
        }
    }
    Some(SourceScan { source: "codex-app", entries })
}

pub(crate) fn scan_t3code(layout: &Layout) -> Option<SourceScan> {
    let db = layout.t3code_dbs().into_iter().find(|db| db.is_file())?;
    let rows = query(
        &db,
        "SELECT CAST(substr(CAST(workspace_root AS BLOB), 1, ?1) AS TEXT),
                CAST(substr(CAST(updated_at AS BLOB), 1, ?2) AS TEXT)
         FROM projection_projects WHERE deleted_at IS NULL LIMIT ?3",
    )?;
    Some(SourceScan { source: "t3code", entries: rows })
}

pub(crate) fn scan_conductor(layout: &Layout) -> Option<SourceScan> {
    let rows = query(
        &layout.conductor_db(),
        "SELECT CAST(substr(CAST(root_path AS BLOB), 1, ?1) AS TEXT),
                CAST(substr(CAST(updated_at AS BLOB), 1, ?2) AS TEXT)
         FROM repos WHERE root_path IS NOT NULL AND coalesce(hidden, 0) = 0 LIMIT ?3",
    )?;
    Some(SourceScan { source: "conductor", entries: rows })
}

/// `(path, UTC time)` rows; a read that fails reports nothing (a partial list
/// sent as complete would drop projects). A cell that is NULL or not text
/// (another app's schema drift) is no path or no time, not a failure.
fn query(db: &std::path::Path, sql: &str) -> Option<Vec<Observation>> {
    let connection = open_read_only(db)?;
    let mut statement = connection.prepare(sql).ok()?;
    let mut rows = statement
        .query(rusqlite::params![
            i64::try_from(MAX_SOURCE_PATH_BYTES + 1).ok()?,
            i64::try_from(MAX_SOURCE_TIMESTAMP_BYTES + 1).ok()?,
            i64::try_from(MAX_SOURCE_ENTRIES + 1).ok()?
        ])
        .ok()?;
    let mut entries = Vec::new();
    let mut row_count = 0_usize;
    let mut retained_bytes = 0_usize;
    while let Some(row) = rows.next().ok()? {
        row_count += 1;
        if row_count > MAX_SOURCE_ENTRIES {
            return None;
        }
        let path = text(row.get_ref(0).ok()?);
        let time = text(row.get_ref(1).ok()?);
        let Some(path) = path else { continue };
        if path.len() > MAX_SOURCE_PATH_BYTES
            || time.as_ref().is_some_and(|time| time.len() > MAX_SOURCE_TIMESTAMP_BYTES)
        {
            return None;
        }
        retained_bytes = retained_bytes.saturating_add(path.len());
        retained_bytes = retained_bytes.saturating_add(time.as_ref().map_or(0, |time| time.len()));
        if retained_bytes > MAX_SOURCE_TOTAL_BYTES {
            return None;
        }
        if path.starts_with('/') {
            entries.push(Observation {
                last_used_ms: time.as_deref().and_then(utc_ms).unwrap_or(1),
                path,
            });
        }
    }
    Some(entries)
}

fn text(value: rusqlite::types::ValueRef<'_>) -> Option<String> {
    match value {
        rusqlite::types::ValueRef::Text(bytes) => {
            std::str::from_utf8(bytes).ok().map(str::to_string)
        }
        _ => None,
    }
}
