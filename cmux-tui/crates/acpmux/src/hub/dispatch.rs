use super::*;
use cmux_json::JsonSet as _;
use std::collections::BTreeMap;
use std::sync::Mutex as StdMutex;

#[derive(Default)]
pub(crate) struct Briefs {
    rows: StdMutex<BTreeMap<String, Value>>,
    path: Option<std::path::PathBuf>,
    load_failed: bool,
}

impl Briefs {
    /// A workflow's dispatch identity must be on stable storage before the
    /// session or prompt can be admitted. Unlike the legacy advisory ledger,
    /// a failed write refuses the effect and never publishes the new row.
    pub(crate) fn put_durable(&self, row: Value) -> anyhow::Result<Value> {
        let id = row
            .get("briefId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .ok_or_else(|| anyhow::anyhow!("durable brief needs an id"))?;
        let mut rows = self.rows.lock().unwrap_or_else(|error| error.into_inner());
        let mut next = rows.clone();
        next.insert(id.to_owned(), row.clone());
        if let Some(path) = &self.path {
            if let Some(parent) = path.parent() {
                crate::config::private_state_dir(parent)?;
            }
            crate::config::write_atomic(path, &serde_json::to_vec(&next)?)?;
            #[cfg(unix)]
            if let Some(parent) = path.parent() {
                std::fs::File::open(parent)?.sync_all()?;
            }
        }
        *rows = next;
        Ok(row)
    }
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
        if let Some(row) = Self::taken(&rows, id, key) {
            return Some(row);
        }
        let mut row = json!({"briefId": id, "status": "starting"});
        if let Some(key) = key {
            row.set("idempotencyKey", json!(key));
        }
        rows.insert(id.to_owned(), row);
        self.save(&rows);
        None
    }

    /// The brief already taken under `id` or `key`, claiming nothing: what a retry of it
    /// answers before any check on where a new lane may start.
    pub(crate) fn existing(&self, id: &str, key: Option<&str>) -> Option<Value> {
        Self::taken(&self.rows.lock().unwrap_or_else(|e| e.into_inner()), id, key)
    }

    fn taken(rows: &BTreeMap<String, Value>, id: &str, key: Option<&str>) -> Option<Value> {
        rows.get(id).cloned().or_else(|| {
            let key = key?;
            rows.values()
                .find(|row| row.get("idempotencyKey").and_then(Value::as_str) == Some(key))
                .cloned()
        })
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
        row.set("briefId", json!(id));
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        // Advisory imports (including another peer's colliding brief ID) may
        // never downgrade or replace a scoped durable dispatch reservation.
        if let Some(previous) = rows.get(&id)
            && previous.get("durable").and_then(Value::as_bool) == Some(true)
        {
            return previous.clone();
        }
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
    fn durable_brief_cannot_be_downgraded_by_an_advisory_peer_import() {
        let briefs = Briefs::default();
        let reserved = briefs
            .put_durable(json!({"briefId":"stable","durable":true,
            "fromSession":"owner","dispatchFingerprint":"private-capability-hash"}))
            .unwrap();
        let imported = briefs.put(json!({"briefId":"stable","fromSession":"other",
            "outcome":{"Ok":{"finalReply":"forged"}}}));
        assert_eq!(imported, reserved);
        assert_eq!(briefs.get("stable"), Some(reserved));
    }

    #[test]
    fn durable_brief_reservation_survives_reopen_before_any_effect() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("briefs.json");
        let row = json!({"briefId":"stable","sessionId":"wfd-stable","promptId":"wfp-stable",
            "dispatchFingerprint":"source-and-options","status":"starting"});
        Briefs::open(Some(path.clone())).put_durable(row.clone()).unwrap();
        assert_eq!(Briefs::open(Some(path)).get("stable"), Some(row));
    }

    #[test]
    fn durable_brief_failed_persistence_does_not_publish_the_effect_identity() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("not-a-directory");
        std::fs::write(&path, b"blocking-file").unwrap();
        let briefs = Briefs::open(Some(path.join("briefs.json")));
        let row = json!({"briefId":"stable","status":"starting"});
        assert!(briefs.put_durable(row).is_err());
        assert!(briefs.get("stable").is_none());
    }

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
