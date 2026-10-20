//! Zed: its workspace table (`db/0-stable/db.sqlite`). `paths` holds the
//! workspace's roots one per line; `remote_connection_id` is null for a local
//! workspace; `timestamp` is UTC `YYYY-MM-DD HH:MM:SS`. Zed also keeps a file
//! opened on its own as a root; the store reads no disk (projects.md rule 4),
//! so a root named like a source file is left out by its name.

use super::{Layout, SourceScan, open_read_only, utc_ms};
use crate::state::projects::Observation;

/// Extensions of the files people open on their own in an editor.
/// Not `js` or `io`: folders like `three.js` and `socket.io` are projects.
const FILE_EXTENSIONS: [&str; 27] = [
    "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "jsx", "kt", "lock", "log", "lua",
    "md", "py", "rb", "rs", "sh", "sql", "swift", "toml", "tsx", "txt", "xml", "yaml", "yml",
];

pub(crate) fn scan_zed(layout: &Layout) -> Option<SourceScan> {
    let connection = open_read_only(&layout.zed_db())?;
    let mut statement = connection
        .prepare(
            "SELECT paths, timestamp FROM workspaces
             WHERE remote_connection_id IS NULL AND paths IS NOT NULL
             ORDER BY timestamp DESC",
        )
        .ok()?;
    let rows = statement
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
        .ok()?;
    let mut newest = std::collections::BTreeMap::<String, i64>::new();
    let mut order = Vec::new();
    // A row that fails (busy mid-step) would make the list partial, and a
    // partial list sent as complete drops projects: report nothing instead.
    let rows = rows.collect::<Result<Vec<_>, _>>().ok()?;
    for (paths, timestamp) in rows {
        let Some(used) = utc_ms(&timestamp) else { continue };
        for root in
            paths.lines().map(str::trim).filter(|root| !root.is_empty() && !is_file_name(root))
        {
            let slot = newest.entry(root.to_string()).or_insert_with(|| {
                order.push(root.to_string());
                used
            });
            *slot = (*slot).max(used);
        }
    }
    let entries =
        order.into_iter().map(|path| Observation { last_used_ms: newest[&path], path }).collect();
    Some(SourceScan { source: "zed", entries })
}

fn is_file_name(root: &str) -> bool {
    let name = root.rsplit(['/', '\\']).next().unwrap_or(root);
    name.rsplit_once('.').is_some_and(|(stem, extension)| {
        !stem.is_empty() && FILE_EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str())
    })
}
