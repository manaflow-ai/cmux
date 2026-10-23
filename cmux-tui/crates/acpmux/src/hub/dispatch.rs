//! First-class agent dispatch records.  The brief is the durable identity of a
//! task; the harness that executes it is only one field of the record.

use super::*;
use std::collections::BTreeMap;
use std::sync::Mutex as StdMutex;

#[derive(Default)]
pub(crate) struct Briefs {
    rows: StdMutex<BTreeMap<String, Value>>,
    path: Option<std::path::PathBuf>,
}

impl Briefs {
    pub(crate) fn open() -> Self {
        let path = crate::config::home().join("briefs.json");
        let rows = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self { rows: StdMutex::new(rows), path: Some(path) }
    }

    fn save(&self, rows: &BTreeMap<String, Value>) {
        let Some(path) = &self.path else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(bytes) = serde_json::to_vec(rows) {
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(tmp, path);
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

    pub(crate) fn by_idempotency(&self, key: &str) -> Option<Value> {
        self.rows
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .find(|row| row.get("idempotencyKey").and_then(Value::as_str) == Some(key))
            .cloned()
    }

    pub(crate) fn update(&self, id: &str, patch: impl FnOnce(&mut Value)) -> Option<Value> {
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        let row = rows.get_mut(id)?;
        patch(row);
        self.save(&rows);
        Some(row.clone())
    }

    pub(crate) fn list(&self, status: Option<&str>, limit: usize) -> Vec<Value> {
        let rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        rows.values()
            .filter(|v| {
                status.is_none_or(|want| v.get("status").and_then(Value::as_str) == Some(want))
            })
            .rev()
            .take(limit.max(1).min(500))
            .cloned()
            .collect()
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
        let briefs = Briefs { rows: StdMutex::new(BTreeMap::new()), path: None };
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
