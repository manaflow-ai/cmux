//! On first open after a setting is retired, move it to its current name or
//! remove it from the person's settings file. The ledger records which table
//! entries this owner has processed. A later paste of an obsolete name is
//! still read through the compatibility table.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::fsio::write_atomic;
use crate::schema::{replaced_by_row, retired_entries};
use crate::store::{Edit, EditKind, Target};
use crate::value::value_at;

/// Format version of the ledger file.
pub const LEDGER_VERSION: u64 = 1;

/// The ledger under the daemon's state directory.
pub fn ledger_path(state_dir: &Path) -> PathBuf {
    state_dir.join("settings").join("migrations.json")
}

/// One recorded migration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Recorded {
    /// Unix seconds when this owner ran it.
    pub at: u64,
    /// Whether the owner changed the file for this entry (a move or removal).
    pub moved: bool,
}

/// The migrations an owner has run.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Ledger {
    #[serde(default)]
    pub version: u64,
    #[serde(default)]
    pub applied: BTreeMap<String, Recorded>,
}

impl Ledger {
    /// The saved ledger; an empty one when there is none or it cannot be read
    /// (every migration then runs again, which only re-moves a key that is
    /// still in the old spelling).
    pub fn read(state_dir: &Path) -> Ledger {
        std::fs::read_to_string(ledger_path(state_dir))
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    pub fn write(&self, state_dir: &Path) -> std::io::Result<()> {
        let mut text = crate::render::pretty(&serde_json::to_value(self)?, "");
        text.push('\n');
        write_atomic(&ledger_path(state_dir), text.as_bytes())
    }

    pub fn has(&self, id: &str) -> bool {
        self.applied.contains_key(id)
    }

    pub fn record(&mut self, id: String, moved: bool, at: u64) {
        self.version = LEDGER_VERSION;
        self.applied.insert(id, Recorded { at, moved });
    }
}

/// An unrecorded table entry and the JSONC edits it needs.
#[derive(Debug, Clone, PartialEq)]
pub struct Pending {
    pub id: String,
    pub edits: Vec<Edit>,
}

/// The member paths that spell an old key in this file, most nested first.
/// A settings file can contain both `{"a": {"b": 1}}` and `{"a.b": 2}`.
fn spellings(
    file: &Value,
    parts: &[String],
    prefix: &mut Vec<String>,
    found: &mut Vec<Vec<String>>,
) {
    for (head, rest) in super::splits(parts) {
        let Some(value) = file.get(&head) else { continue };
        prefix.push(head);
        if rest.is_empty() {
            found.push(prefix.clone());
        } else if value.is_object() {
            spellings(value, rest, prefix, found);
        }
        prefix.pop();
    }
}

fn edits_for(file: &Value, entry: &crate::schema::Retired) -> Vec<Edit> {
    let mut old_paths = Vec::new();
    spellings(file, &super::path(&entry.key), &mut Vec::new(), &mut old_paths);
    let Some(old) = old_paths.first().and_then(|path| value_at(file, path)) else {
        return Vec::new();
    };
    let mut edits = Vec::new();
    if let Some(new) = &entry.replaced_by {
        let new_path = super::path(new);
        if value_at(file, &new_path).is_none() {
            // An explicit current spelling wins, including one written as a dotted key.
            let value = file
                .as_object()
                .and_then(|root| super::find(root, &new_path))
                .or_else(|| replaced_by_row(&new_path)?.read(old));
            if let Some(value) = value {
                // JSONC set would replace a non-object ancestor. Leave the old setting
                // and the conflicting user value intact.
                if (1..new_path.len())
                    .any(|n| value_at(file, &new_path[..n]).is_some_and(|value| !value.is_object()))
                {
                    return Vec::new();
                }
                edits.push(Edit {
                    target: Target::Path(new_path),
                    kind: EditKind::SetExact(value.clone()),
                });
            }
        }
    }
    edits.extend(
        old_paths
            .into_iter()
            .map(|path| Edit { target: Target::Path(path), kind: EditKind::Reset }),
    );
    edits
}

/// Every table entry this owner has yet to process. Retain existing rename
/// IDs so an upgrade respects what earlier versions recorded.
pub fn pending(file: &Value, ledger: &Ledger) -> Vec<Pending> {
    retired_entries()
        .iter()
        .filter_map(|entry| {
            let kind = if entry.replaced_by.is_some() { "rename" } else { "remove" };
            let id = format!("{kind}:{}", entry.key);
            (!ledger.has(&id)).then(|| Pending { id, edits: edits_for(file, entry) })
        })
        .collect()
}
