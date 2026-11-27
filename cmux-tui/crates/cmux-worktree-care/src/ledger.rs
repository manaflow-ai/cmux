//! The ledger: one append-only JSON line per thing a pass did, with its
//! size, in the store folder (`care-ledger.jsonl`). Bounded: past
//! [`MAX_BYTES`] the file becomes `care-ledger.jsonl.1` (replacing the older
//! one) and a new one starts, so it never holds more than about twice that.
//! `cmux care why PATH` reads it.

use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

const FILE: &str = "care-ledger.jsonl";
/// The size at which the file rotates.
pub const MAX_BYTES: u64 = 4 * 1024 * 1024;

/// One thing a pass did or refused to do.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub at_ms: u64,
    pub family: String,
    pub path: PathBuf,
    pub bytes: u64,
    /// What the policy decided: keep, trim, reclaim, archive.
    pub verdict: String,
    /// What happened: removed, archived, trimmed, failed, kept.
    pub action: String,
    /// The archive id, when the entry was archived first.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archive: Option<String>,
    #[serde(default)]
    pub reason: String,
}

#[derive(Debug, Clone)]
pub struct Ledger {
    path: PathBuf,
}

impl Ledger {
    pub fn in_dir(dir: &Path) -> Self {
        Self { path: dir.join(FILE) }
    }

    fn older(&self) -> PathBuf {
        let mut name = self.path.clone().into_os_string();
        name.push(".1");
        PathBuf::from(name)
    }

    /// Appends `rows`, rotating first when the file is full.
    pub fn append(&self, rows: &[Row]) -> Result<(), String> {
        if rows.is_empty() {
            return Ok(());
        }
        if std::fs::metadata(&self.path).is_ok_and(|m| m.len() >= MAX_BYTES) {
            std::fs::rename(&self.path, self.older())
                .map_err(|e| format!("{}: {e}", self.path.display()))?;
        }
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .map_err(|e| format!("{}: {e}", self.path.display()))?;
        let mut text = String::new();
        for row in rows {
            text.push_str(&serde_json::to_string(row).map_err(|e| e.to_string())?);
            text.push('\n');
        }
        file.write_all(text.as_bytes()).map_err(|e| format!("{}: {e}", self.path.display()))
    }

    /// Every row on file, oldest first.
    pub fn rows(&self) -> Vec<Row> {
        let mut rows = Vec::new();
        for path in [self.older(), self.path.clone()] {
            if let Ok(text) = std::fs::read_to_string(&path) {
                rows.extend(text.lines().filter_map(|line| serde_json::from_str::<Row>(line).ok()));
            }
        }
        rows
    }

    /// The rows for `path` itself or anything inside it, newest first, at most `limit`.
    pub fn for_path(&self, path: &Path, limit: usize) -> Vec<Row> {
        let mut rows: Vec<Row> = self
            .rows()
            .into_iter()
            .filter(|row| {
                row.path == path || row.path.starts_with(path) || path.starts_with(&row.path)
            })
            .collect();
        rows.reverse();
        rows.truncate(limit);
        rows
    }

    /// The newest `limit` rows, newest first.
    pub fn recent(&self, limit: usize) -> Vec<Row> {
        let mut rows = self.rows();
        rows.reverse();
        rows.truncate(limit);
        rows
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::care_tests::scratch;

    fn row(at: u64, path: &str) -> Row {
        Row {
            at_ms: at,
            family: "npm-cache".into(),
            path: path.into(),
            bytes: 1024,
            verdict: "reclaim".into(),
            action: "removed".into(),
            archive: None,
            reason: "unused".into(),
        }
    }

    #[test]
    fn rows_come_back_by_path_newest_first() {
        let ledger = Ledger::in_dir(&scratch("ledger"));
        ledger.append(&[row(1, "/h/a"), row(2, "/h/b"), row(3, "/h/a")]).unwrap();
        let rows = ledger.for_path(Path::new("/h/a"), 10);
        assert_eq!(rows.iter().map(|r| r.at_ms).collect::<Vec<_>>(), vec![3, 1]);
        assert_eq!(ledger.recent(2).len(), 2);
        assert!(ledger.for_path(Path::new("/h/zzz"), 10).is_empty());
        // A parent's row names everything inside it, and a child's row its parent.
        assert_eq!(ledger.for_path(Path::new("/h/a/sub"), 10).len(), 2);
        assert_eq!(ledger.for_path(Path::new("/h"), 10).len(), 3);
    }

    #[test]
    fn a_full_file_rotates_and_both_halves_are_read() {
        let dir = scratch("ledger-rotate");
        let ledger = Ledger::in_dir(&dir);
        ledger.append(&[row(1, "/h/old")]).unwrap();
        // Fill to the limit with one big line's worth of padding rows.
        let padding = Row { reason: "x".repeat(1 << 20), ..row(2, "/h/pad") };
        for _ in 0..4 {
            ledger.append(std::slice::from_ref(&padding)).unwrap();
        }
        ledger.append(&[row(9, "/h/new")]).unwrap();
        assert!(dir.join("care-ledger.jsonl.1").exists());
        assert_eq!(ledger.for_path(Path::new("/h/old"), 5).len(), 1);
        assert_eq!(ledger.for_path(Path::new("/h/new"), 5).len(), 1);
        let size = std::fs::metadata(dir.join("care-ledger.jsonl")).unwrap().len();
        assert!(size < MAX_BYTES + (1 << 20));
    }

    #[test]
    fn a_torn_line_is_skipped() {
        let dir = scratch("ledger-torn");
        let ledger = Ledger::in_dir(&dir);
        ledger.append(&[row(1, "/h/a")]).unwrap();
        let mut file = std::fs::OpenOptions::new().append(true).open(dir.join(FILE)).unwrap();
        writeln!(file, "{{\"atMs\": 5, \"fam").unwrap();
        ledger.append(&[row(3, "/h/a")]).unwrap();
        assert_eq!(ledger.rows().len(), 2);
    }
}
