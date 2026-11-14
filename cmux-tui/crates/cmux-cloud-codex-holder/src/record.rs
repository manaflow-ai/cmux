//! Which Cloud machines a holder home delivered Codex access to, kept beside the holder so the
//! next run of cmux knows them: it picks renewal back up on each (cmux#33878), and a sign-out,
//! an account or team switch or the Cloud off switch erases them, including what an earlier run
//! left (cmux#33877). It holds machine IDs and one flag each, never a token. `erase` marks a
//! machine whose access was asked to be erased but could not be yet (a paused machine): the next
//! run erases it instead of renewing it.
//!
//! The files are the ones the Swift holder wrote (`delivered-machines.json`, `holder-id`), so an
//! update keeps every earlier run's record.

use std::collections::{BTreeMap, HashMap};
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{Value, json};

/// One update at a time in this process (a read, a change and a write).
static UPDATES: Mutex<()> = Mutex::new(());

#[derive(Clone, Debug)]
pub struct Record {
    pub file: PathBuf,
    holder_file: PathBuf,
}

impl Record {
    pub fn new(home: &Path) -> Self {
        Self { file: home.join("delivered-machines.json"), holder_file: home.join("holder-id") }
    }

    /// This holder's opaque ID, made on first use. Each delivered access file carries it, so a run
    /// takes back only what this holder delivered, never another Mac's or account's delivery.
    pub fn holder_id(&self) -> String {
        if let Ok(text) = std::fs::read_to_string(&self.holder_file) {
            let id = text.trim();
            if !id.is_empty() {
                return id.to_owned();
            }
        }
        let id = uuid::Uuid::new_v4().to_string().to_lowercase();
        write(&self.holder_file, format!("{id}\n").as_bytes());
        id
    }

    /// Machine ID to whether it waits to be erased.
    pub fn entries(&self) -> HashMap<String, bool> {
        let Some(object) = std::fs::read(&self.file)
            .ok()
            .and_then(|data| serde_json::from_slice::<Value>(&data).ok())
        else {
            return HashMap::new();
        };
        if object.get("schema").and_then(Value::as_i64) != Some(1) {
            return HashMap::new();
        }
        let Some(machines) = object.get("machines").and_then(Value::as_object) else {
            return HashMap::new();
        };
        machines
            .iter()
            .filter(|(id, _)| !id.is_empty())
            .map(|(id, value)| {
                (id.clone(), value.get("erase").and_then(Value::as_bool).unwrap_or(false))
            })
            .collect()
    }

    /// A delivery to `machine`: it renews from now on, even if an earlier ask to erase it failed.
    pub fn delivered(&self, machine: &str) {
        self.update(|entries| {
            entries.insert(machine.to_owned(), false);
        });
    }

    /// `machine` holds no access of this holder any more.
    pub fn forget(&self, machine: &str) {
        self.update(|entries| {
            entries.remove(machine);
        });
    }

    /// A sign-out, a switch or the off switch: whatever is still recorded is erased, not renewed.
    pub fn mark_all_for_erasure(&self) {
        self.update(|entries| entries.values_mut().for_each(|erase| *erase = true));
    }

    fn update(&self, change: impl FnOnce(&mut HashMap<String, bool>)) {
        let _one = UPDATES.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut entries = self.entries();
        let before = entries.clone();
        change(&mut entries);
        if entries == before {
            return;
        }
        if entries.is_empty() {
            let _ = std::fs::remove_file(&self.file);
            return;
        }
        let machines: BTreeMap<&String, Value> =
            entries.iter().map(|(id, erase)| (id, json!({ "erase": erase }))).collect();
        let object = json!({ "machines": machines, "schema": 1 });
        write(&self.file, object.to_string().as_bytes());
    }
}

/// An atomic 0600 write in a 0700 folder; a failure leaves the old file.
fn write(path: &Path, data: &[u8]) {
    let Some(folder) = path.parent() else { return };
    if std::fs::DirBuilder::new().recursive(true).mode(0o700).create(folder).is_err() {
        return;
    }
    let temporary = folder.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
        .and_then(|mut file| file.write_all(data).and_then(|()| file.sync_all()));
    if written.is_err() || std::fs::rename(&temporary, path).is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_deliveries_erasure_and_forgetting_with_one_holder_id() {
        let home = tempfile::tempdir().unwrap();
        let record = Record::new(home.path());
        let id = record.holder_id();
        assert_eq!(id.len(), 36);
        assert_eq!(record.holder_id(), id, "the id is kept");
        assert!(record.entries().is_empty());
        record.delivered("one");
        record.delivered("two");
        assert_eq!(record.entries(), HashMap::from([("one".into(), false), ("two".into(), false)]));
        record.mark_all_for_erasure();
        assert_eq!(record.entries(), HashMap::from([("one".into(), true), ("two".into(), true)]));
        record.delivered("one");
        assert!(!record.entries()["one"]);
        record.forget("one");
        record.forget("two");
        assert!(!record.file.exists(), "an empty record is no file");
    }

    #[test]
    fn reads_the_swift_holders_record() {
        let home = tempfile::tempdir().unwrap();
        let record = Record::new(home.path());
        std::fs::write(
            &record.file,
            r#"{"machines":{"a":{"erase":true},"b":{"erase":false},"":{}},"schema":1}"#,
        )
        .unwrap();
        std::fs::write(home.path().join("holder-id"), "abc\n").unwrap();
        assert_eq!(record.entries(), HashMap::from([("a".into(), true), ("b".into(), false)]));
        assert_eq!(record.holder_id(), "abc");
        std::fs::write(&record.file, r#"{"machines":{"a":{}},"schema":2}"#).unwrap();
        assert!(record.entries().is_empty(), "another schema is none");
    }
}
