use super::*;
use std::collections::BTreeMap;
use std::sync::Mutex as StdMutex;

use cmux_important_file::{Mode, Options, write_important_with};

use super::config_writer::ConfigWriter;

#[derive(Default)]
pub(crate) struct Briefs {
    rows: StdMutex<BTreeMap<String, Value>>,
    persist: Option<Persist>,
    load_failed: bool,
}

/// Where the ledger is saved, and the thread that saves it: a change takes a snapshot under the
/// rows lock and queues it, so the newest snapshot wins and no request waits on the disk
/// (`config_writer.rs`, Chrome's ImportantFileWriter on its background sequence).
struct Persist {
    path: std::path::PathBuf,
    writer: ConfigWriter,
}

impl Briefs {
    /// The ledger saved at `path` (`Store::briefs_path`), or one in memory only.
    pub(crate) fn open(path: Option<std::path::PathBuf>) -> Self {
        let Some(path) = path else { return Self::default() };
        let (rows, load_failed) = match std::fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice(&bytes) {
                Ok(rows) => (rows, false),
                Err(error) => {
                    eprintln!("acpmux: brief ledger unreadable; starting empty: {error}");
                    (BTreeMap::new(), true)
                }
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (BTreeMap::new(), false),
            Err(error) => {
                eprintln!("acpmux: brief ledger could not be read; starting empty: {error}");
                (BTreeMap::new(), true)
            }
        };
        let writer = ConfigWriter::start("acpmux-briefs-writer", write_ledger);
        Self { rows: StdMutex::new(rows), persist: Some(Persist { path, writer }), load_failed }
    }

    /// Waits until every change made so far is on disk (shutdown).
    pub(crate) fn flush(&self) {
        if let Some(persist) = &self.persist {
            persist.writer.flush();
        }
    }

    pub(crate) fn load_failed(&self) -> bool {
        self.load_failed
    }

    pub(crate) fn claim(&self, id: &str, key: Option<&str>) -> Option<Value> {
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(row) = rows.get(id).cloned() {
            return Some(row);
        }
        if let Some(key) = key
            && let Some(row) = rows
                .values()
                .find(|row| row.get("idempotencyKey").and_then(Value::as_str) == Some(key))
                .cloned()
        {
            return Some(row);
        }
        let mut row = json!({"briefId": id, "status": "starting"});
        if let Some(key) = key {
            row["idempotencyKey"] = json!(key);
        }
        rows.insert(id.to_owned(), row);
        self.save(&rows);
        None
    }

    /// Queues a snapshot of `rows`; called under the rows lock, so snapshots queue in order.
    fn save(&self, rows: &BTreeMap<String, Value>) {
        let Some(persist) = &self.persist else { return };
        match serde_json::to_vec(rows) {
            Ok(bytes) => persist.writer.queue(persist.path.clone(), bytes),
            Err(error) => eprintln!("acpmux: brief persistence warning: {error}"),
        }
    }

    pub(crate) fn put(&self, mut row: Value) -> Value {
        let id = row
            .get("briefId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| format!("brief-{}", uuid::Uuid::now_v7()));
        row["briefId"] = json!(id);
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        rows.insert(id, row.clone());
        self.save(&rows);
        row
    }

    pub(crate) fn get(&self, id: &str) -> Option<Value> {
        self.rows.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
    }

    pub(crate) fn update(&self, id: &str, patch: impl FnOnce(&mut Value)) -> Option<Value> {
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        let row = rows.get_mut(id)?;
        patch(row);
        let updated = row.clone();
        self.save(&rows);
        Some(updated)
    }

    pub(crate) fn release(&self, id: &str) {
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        if rows.get(id).and_then(|row| row.get("status")).and_then(Value::as_str)
            == Some("starting")
        {
            rows.remove(id);
            self.save(&rows);
        }
    }

    /// Every row `keep` keeps, unpaged: for the daemon's own sweeps, not for a client.
    pub(crate) fn matching(&self, keep: impl Fn(&Value) -> bool) -> Vec<Value> {
        let rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        rows.values().filter(|row| keep(row)).cloned().collect()
    }

    pub(crate) fn list(&self, status: Option<&str>, limit: usize) -> Vec<Value> {
        let rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        rows.values()
            .filter(|v| {
                status.is_none_or(|want| v.get("status").and_then(Value::as_str) == Some(want))
            })
            .rev()
            .take(limit.clamp(1, 500))
            .cloned()
            .collect()
    }
}

/// The ledger's write, on its writer thread.
fn write_ledger(path: &std::path::Path, bytes: &[u8]) {
    let options = Options::new(Mode::Default).create_parent();
    if let Err(error) = write_important_with(path, bytes, &options) {
        eprintln!("acpmux: brief persistence warning: {error}");
    }
}

pub(crate) fn event(kind: &str, row: &Value) -> Value {
    json!({
        "kind": kind,
        "briefId": row.get("briefId"),
        "title": row.get("title"),
        "from": row.get("from"),
        "to": row.get("to"),
        "target": row.get("target"),
        "host": row.get("host"),
        "sessionId": row.get("sessionId"),
        "status": row.get("status"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn brief_identity_keeps_non_claude_harness_pair() {
        let briefs = Briefs::default();
        let row = briefs.put(json!({
            "title": "opencode to pi",
            "harness": "pi",
            "fromHarness": "opencode",
            "status": "running"
        }));
        let id = row["briefId"].as_str().expect("brief id");
        let listed = briefs.list(Some("running"), 10);
        assert_eq!(listed[0]["briefId"], id);
        assert_eq!(listed[0]["fromHarness"], "opencode");
        assert_eq!(listed[0]["harness"], "pi");
    }

    /// A claim queues the ledger and returns; the newest snapshot is what reaches the disk.
    #[test]
    fn changes_reach_the_disk_on_the_writer_and_the_newest_wins() {
        let dir = std::env::temp_dir().join(format!("acpmux-briefs-{}", uuid::Uuid::now_v7()));
        let path = dir.join("briefs.json");
        let briefs = Briefs::open(Some(path.clone()));
        assert!(briefs.claim("b1", Some("k1")).is_none());
        for n in 0..20 {
            briefs.update("b1", |row| row["n"] = json!(n));
        }
        briefs.put(json!({"briefId": "b2", "status": "running"}));
        assert!(briefs.claim("b3", None).is_none());
        briefs.release("b3");
        briefs.flush();
        let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(saved["b1"]["n"], 19, "{saved}");
        assert_eq!(saved["b2"]["status"], "running", "{saved}");
        assert!(saved.get("b3").is_none(), "a released claim is gone: {saved}");
        let reopened = Briefs::open(Some(path));
        assert_eq!(reopened.get("b1").unwrap()["idempotencyKey"], "k1");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
