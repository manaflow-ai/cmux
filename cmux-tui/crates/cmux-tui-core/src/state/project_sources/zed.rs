//! Zed: its workspace table (`db/0-stable/db.sqlite`). `paths` holds the
//! workspace's roots one per line; `remote_connection_id` is null for a local
//! workspace; `timestamp` is UTC `YYYY-MM-DD HH:MM:SS`. Zed also keeps a file
//! opened on its own as a root; the store reads no disk (projects.md rule 4),
//! so a root named like a source file is left out by its name.

use super::{Layout, SourceScan, open_read_only};
use crate::state::projects::Observation;

/// Extensions of the files people open on their own in an editor.
const FILE_EXTENSIONS: [&str; 30] = [
    "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "json", "jsx", "kt", "lock",
    "log", "lua", "md", "py", "rb", "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml",
    "yaml", "yml",
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
    for (paths, timestamp) in rows.flatten() {
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

/// `YYYY-MM-DD HH:MM:SS` (UTC) as ms since the epoch.
fn utc_ms(text: &str) -> Option<i64> {
    let (date, time) = text.trim().split_once([' ', 'T'])?;
    let mut date = date.split('-').map(str::parse::<i64>);
    let (year, month, day) = (date.next()?.ok()?, date.next()?.ok()?, date.next()?.ok()?);
    let mut time = time.trim_end_matches('Z').split(':');
    let hour: i64 = time.next()?.parse().ok()?;
    let minute: i64 = time.next()?.parse().ok()?;
    let second: f64 = time.next().unwrap_or("0").parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    let shifted = if month <= 2 { year - 1 } else { year };
    let era = shifted.div_euclid(400);
    let year_of_era = shifted - era * 400;
    let day_of_year = (153 * ((month + 9) % 12) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    Some(((days * 24 + hour) * 60 + minute) * 60_000 + (second * 1000.0) as i64)
}
