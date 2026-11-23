//! The renames the settings owner applies to a person's own file, once each.
//!
//! [`migrate`](super::migrate) reads an old key as its new name and leaves
//! the file alone. This module is the other half: the first time an owner
//! opens a file after a cmux release that renamed a key, the key moves to its
//! new name in the file itself, and the migration is recorded in a ledger
//! (`<state dir>/settings/migrations.json`), so it never runs again. A key a
//! person writes in the old spelling afterwards (a pasted snippet) is still
//! read through the table, but nothing rewrites it a second time.
//!
//! A migration's id is `rename:<old key>`. Only an entry with `replaced_by` is
//! one: a removed key has nothing to move. The ledger lists every id this
//! owner has run, whether or not the file held the old key, so a rename that
//! shipped before the file named it is not run late either.

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
    /// Whether the file held the old key and the owner moved it.
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

/// One rename not in the ledger yet.
#[derive(Debug, Clone, PartialEq)]
pub struct Pending {
    pub id: String,
    /// The edit that moves the old key's value to the new one; `None` when the
    /// file does not hold the old key, the new key is set already (the old
    /// one is then ignored, as the table reads it), or the old value has no
    /// equivalent under the new name.
    pub edit: Option<Edit>,
}

/// The renames in the table that `ledger` has not recorded, with the edit
/// each needs on `file` (the person's file as parsed).
pub fn pending(file: &Value, ledger: &Ledger) -> Vec<Pending> {
    retired_entries()
        .iter()
        .filter_map(|entry| {
            let new = entry.replaced_by.as_ref()?;
            let id = format!("rename:{}", entry.key);
            if ledger.has(&id) {
                return None;
            }
            let old_path: Vec<String> = entry.key.split('.').map(str::to_string).collect();
            let new_path: Vec<String> = new.split('.').map(str::to_string).collect();
            let edit = value_at(file, &old_path)
                .filter(|_| value_at(file, &new_path).is_none())
                .and_then(|old| replaced_by_row(&new_path)?.read(old).cloned())
                .map(|value| Edit { target: Target::Path(new_path), kind: EditKind::Set(value) });
            Some(Pending { id, edit })
        })
        .collect()
}
