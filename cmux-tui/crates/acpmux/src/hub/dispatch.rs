use super::*;
use std::collections::BTreeMap;
use std::sync::Mutex as StdMutex;

#[derive(Default)]
pub(crate) struct Briefs {
    rows: StdMutex<BTreeMap<String, Value>>,
    path: Option<std::path::PathBuf>,
    load_failed: bool,
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
        Self { rows: StdMutex::new(rows), path: Some(path), load_failed }
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

    fn save(&self, rows: &BTreeMap<String, Value>) {
        let Some(path) = &self.path else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(bytes) = serde_json::to_vec(rows) {
            let tmp = path.with_extension("json.tmp");
            if let Err(error) = std::fs::write(&tmp, bytes).and_then(|_| std::fs::rename(tmp, path))
            {
                eprintln!("acpmux: brief persistence warning: {error}");
            }
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

impl Hub {
    /// Whether a brief row is one this daemon ran: still being claimed (no session and no host
    /// yet), or its session is one of this host's, open or closed. A row a peer ran (this host's
    /// copy of a brief it dispatched there, `server/requests.rs`) names a session it never had.
    pub(crate) fn brief_ran_here(&self, row: &Value) -> bool {
        let Some(id) = row.get("sessionId").and_then(Value::as_str) else {
            return row.get("host").is_none();
        };
        self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner).contains_key(id)
            || matches!(self.store.load(id), Ok(Some(_)))
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
        let briefs =
            Briefs { rows: StdMutex::new(BTreeMap::new()), path: None, load_failed: false };
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
}
