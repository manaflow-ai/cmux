//! The VS Code family (Code, Insiders, Cursor, Windsurf, VSCodium): the
//! "Open Recent" list in `User/globalStorage/state.vscdb`
//! (`history.recentlyOpenedPathsList`, newest first, no times), else the
//! workspace folders `User/globalStorage/storage.json` associates with a
//! profile. Local folders only: remote URIs, files and `.code-workspace`
//! files are not projects.

use std::path::Path;

use serde_json::Value;

use super::{Layout, SourceScan, modified_ms, open_read_only};
use crate::state::projects::Observation;

/// (product folder, source id).
const PRODUCTS: [(&str, &str); 5] = [
    ("Code", "vscode"),
    ("Code - Insiders", "vscode-insiders"),
    ("Cursor", "cursor"),
    ("Windsurf", "windsurf"),
    ("VSCodium", "vscodium"),
];

pub(crate) fn scan_vscode_family(layout: &Layout) -> Vec<SourceScan> {
    PRODUCTS
        .iter()
        .filter_map(|(product, source)| {
            let storage = layout.vscode_user_dir(product).join("globalStorage");
            // `state.vscdb` holds the full list: when it is there but cannot
            // be read (busy, mid-migration), report nothing rather than the
            // smaller `storage.json` list as complete.
            let db = storage.join("state.vscdb");
            let entries = if db.exists() {
                recent_list(&db)?
            } else {
                profile_workspaces(&storage.join("storage.json"))?
            };
            Some(SourceScan { source, entries })
        })
        .collect()
}

/// The list carries no times: the file's mtime is the first entry's use.
/// Each later entry gets the epoch plus its rank, so a write to the file
/// never makes the whole list look just used, and the order still survives
/// the merge (the reducer keeps each source's newest time).
fn ordered(paths: Vec<String>, file: &Path) -> Vec<Observation> {
    let newest = modified_ms(file).unwrap_or(0);
    let mut seen = std::collections::BTreeSet::new();
    let paths: Vec<String> = paths.into_iter().filter(|path| seen.insert(path.clone())).collect();
    let paths_len = paths.len();
    paths
        .into_iter()
        .enumerate()
        .map(|(index, path)| {
            let last_used_ms = if index == 0 { newest } else { (paths_len - index) as i64 };
            Observation { path, last_used_ms }
        })
        .collect()
}

fn recent_list(db: &Path) -> Option<Vec<Observation>> {
    let connection = open_read_only(db)?;
    let raw: String = connection
        .query_row(
            "SELECT CAST(value AS TEXT) FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'",
            [],
            |row| row.get(0),
        )
        .ok()?;
    let list: Value = serde_json::from_str(&raw).ok()?;
    let paths = list
        .get("entries")?
        .as_array()?
        .iter()
        .filter_map(|entry| entry.get("folderUri")?.as_str().and_then(local_folder))
        .collect();
    Some(ordered(paths, db))
}

fn profile_workspaces(file: &Path) -> Option<Vec<Observation>> {
    let storage: Value = serde_json::from_str(&std::fs::read_to_string(file).ok()?).ok()?;
    let paths = storage
        .pointer("/profileAssociations/workspaces")?
        .as_object()?
        .keys()
        .filter_map(|uri| local_folder(uri))
        .collect();
    Some(ordered(paths, file))
}

/// A `file://` folder URI as a path; anything else (a remote) is none.
fn local_folder(uri: &str) -> Option<String> {
    let url = url::Url::parse(uri).ok()?;
    if url.scheme() != "file" || url.host_str().is_some_and(|host| !host.is_empty()) {
        return None;
    }
    let path = url.to_file_path().ok()?.to_string_lossy().into_owned();
    (!path.ends_with(".code-workspace")).then_some(path)
}
