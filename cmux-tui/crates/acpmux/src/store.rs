//! Persistence tiers for session metadata and the event log.
//!
//! `Local` writes `sessions/<id>/session.json` and append-only
//! `events/NNNNNN.ndjson` segments. `Memory` keeps the same data in RAM.
//! Both expose the same API so the hub does not care which is active.

use crate::config::{StoreConfig, StoreMode, write_atomic};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// One line in the session event log.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct EventRecord {
    pub seq: u64,
    /// Unix milliseconds.
    pub at: u64,
    /// `in` = agent to acpmux, `out` = acpmux to agent, `mux` = acpmux internal.
    pub dir: String,
    /// JSON-RPC method, `sessionUpdate` value, or an acpmux kind such as `status`.
    pub kind: String,
    /// Raw JSON-RPC message, or the acpmux payload.
    pub msg: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Copy)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    /// No child process. Prompts respawn and load the agent session.
    Idle,
    /// Child alive, no turn running.
    Ready,
    /// A prompt turn is running.
    Running,
    /// Waiting for a permission answer.
    Waiting,
    /// Child process died unexpectedly.
    Disconnected,
    /// Closed by the user. Log kept.
    Closed,
}

impl std::fmt::Display for SessionStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::Idle => "idle",
            Self::Ready => "ready",
            Self::Running => "running",
            Self::Waiting => "waiting",
            Self::Disconnected => "disconnected",
            Self::Closed => "closed",
        };
        f.write_str(s)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionMeta {
    pub schema: String,
    pub id: String,
    pub name: String,
    pub agent: String,
    #[serde(default)]
    pub agent_argv: Vec<String>,
    pub cwd: PathBuf,
    #[serde(default)]
    pub agent_session_id: Option<String>,
    pub status: SessionStatus,
    pub created_at: u64,
    pub updated_at: u64,
    #[serde(default)]
    pub last_seq: u64,
    #[serde(default)]
    pub parent_id: Option<String>,
    #[serde(default)]
    pub fork_seq: Option<u64>,
    #[serde(default)]
    pub agent_info: Option<Value>,
    #[serde(default)]
    pub agent_capabilities: Option<Value>,
    #[serde(default)]
    pub modes: Option<Value>,
    #[serde(default)]
    pub config_options: Option<Value>,
    #[serde(default)]
    pub models: Option<Value>,
    #[serde(default)]
    pub permission_policy: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub last_prompt: Option<String>,
    #[serde(default)]
    pub preview: Option<String>,
    #[serde(default)]
    pub event_count: u64,
    #[serde(default)]
    pub turn_count: u64,
    #[serde(default)]
    pub usage: Option<Value>,
}

pub const META_SCHEMA: &str = "acpmux.session.v1";

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub trait Store: Send + Sync {
    fn list(&self) -> Result<Vec<SessionMeta>>;
    fn load(&self, id: &str) -> Result<Option<SessionMeta>>;
    fn save(&self, meta: &SessionMeta) -> Result<()>;
    fn append(&self, id: &str, record: &EventRecord) -> Result<()>;
    /// Events with `seq > after`, at most `limit`.
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>>;
    fn delete(&self, id: &str) -> Result<()>;
    fn session_dir(&self, _id: &str) -> Option<PathBuf> {
        None
    }
}

pub fn open(config: &StoreConfig, root: &Path) -> Result<Box<dyn Store>> {
    Ok(match config.mode {
        StoreMode::Memory => Box::new(MemoryStore::default()),
        StoreMode::Local => Box::new(LocalStore::new(root.join("sessions"), config.segment_bytes)?),
    })
}

// ---------------------------------------------------------------- memory

#[derive(Default)]
pub struct MemoryStore {
    inner: Mutex<HashMap<String, (SessionMeta, Vec<EventRecord>)>>,
}

impl Store for MemoryStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        Ok(self.inner.lock().unwrap().values().map(|(m, _)| m.clone()).collect())
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        Ok(self.inner.lock().unwrap().get(id).map(|(m, _)| m.clone()))
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        let mut g = self.inner.lock().unwrap();
        g.entry(meta.id.clone())
            .and_modify(|(m, _)| *m = meta.clone())
            .or_insert_with(|| (meta.clone(), Vec::new()));
        Ok(())
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut g = self.inner.lock().unwrap();
        if let Some((_, events)) = g.get_mut(id) {
            events.push(record.clone());
            // Bound memory: keep the newest 20k events.
            if events.len() > 20_000 {
                let drop = events.len() - 20_000;
                events.drain(..drop);
            }
        }
        Ok(())
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        let g = self.inner.lock().unwrap();
        Ok(g.get(id)
            .map(|(_, ev)| ev.iter().filter(|e| e.seq > after).take(limit).cloned().collect())
            .unwrap_or_default())
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.inner.lock().unwrap().remove(id);
        Ok(())
    }
}

// ----------------------------------------------------------------- local

pub struct LocalStore {
    root: PathBuf,
    segment_bytes: u64,
    writers: Mutex<HashMap<String, SegmentWriter>>,
}

struct SegmentWriter {
    index: u32,
    file: File,
    written: u64,
}

impl LocalStore {
    pub fn new(root: PathBuf, segment_bytes: u64) -> Result<Self> {
        std::fs::create_dir_all(&root).with_context(|| format!("create {}", root.display()))?;
        Ok(Self {
            root,
            segment_bytes: segment_bytes.max(64 * 1024),
            writers: Mutex::new(HashMap::new()),
        })
    }

    fn dir(&self, id: &str) -> PathBuf {
        self.root.join(id)
    }

    fn segments(&self, id: &str) -> Result<Vec<(u32, PathBuf)>> {
        let dir = self.dir(id).join("events");
        let mut out = Vec::new();
        let Ok(rd) = std::fs::read_dir(&dir) else {
            return Ok(out);
        };
        for entry in rd.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if let Some(stem) = name.strip_suffix(".ndjson") {
                if let Ok(idx) = stem.parse::<u32>() {
                    out.push((idx, entry.path()));
                }
            }
        }
        out.sort();
        Ok(out)
    }

    fn open_writer(&self, id: &str) -> Result<SegmentWriter> {
        let dir = self.dir(id).join("events");
        std::fs::create_dir_all(&dir)?;
        let segs = self.segments(id)?;
        let (index, path) = match segs.last() {
            Some((i, p)) => (*i, p.clone()),
            None => (1, dir.join("000001.ndjson")),
        };
        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        let written = file.metadata().map(|m| m.len()).unwrap_or(0);
        Ok(SegmentWriter {
            index,
            file,
            written,
        })
    }
}

impl Store for LocalStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        let mut out = Vec::new();
        let Ok(rd) = std::fs::read_dir(&self.root) else {
            return Ok(out);
        };
        for entry in rd.flatten() {
            let path = entry.path().join("session.json");
            if let Ok(text) = std::fs::read_to_string(&path) {
                match serde_json::from_str::<SessionMeta>(&text) {
                    Ok(meta) => out.push(meta),
                    Err(e) => tracing::warn!("skip {}: {e}", path.display()),
                }
            }
        }
        Ok(out)
    }

    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        let path = self.dir(id).join("session.json");
        if !path.exists() {
            return Ok(None);
        }
        let text = std::fs::read_to_string(&path)?;
        Ok(Some(serde_json::from_str(&text)?))
    }

    fn save(&self, meta: &SessionMeta) -> Result<()> {
        let dir = self.dir(&meta.id);
        std::fs::create_dir_all(&dir)?;
        write_atomic(&dir.join("session.json"), serde_json::to_string_pretty(meta)?.as_bytes())
    }

    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut writers = self.writers.lock().unwrap();
        if !writers.contains_key(id) {
            writers.insert(id.to_owned(), self.open_writer(id)?);
        }
        let w = writers.get_mut(id).unwrap();
        if w.written >= self.segment_bytes {
            let index = w.index + 1;
            let path = self.dir(id).join("events").join(format!("{index:06}.ndjson"));
            let file = OpenOptions::new().create(true).append(true).open(&path)?;
            *w = SegmentWriter {
                index,
                file,
                written: 0,
            };
        }
        let mut line = serde_json::to_string(record)?;
        line.push('\n');
        w.file.write_all(line.as_bytes())?;
        w.written += line.len() as u64;
        Ok(())
    }

    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        let mut out = Vec::new();
        for (_, path) in self.segments(id)? {
            let file = File::open(&path)?;
            for line in BufReader::new(file).lines() {
                let line = line?;
                if line.trim().is_empty() {
                    continue;
                }
                let rec: EventRecord = match serde_json::from_str(&line) {
                    Ok(r) => r,
                    Err(_) => continue,
                };
                if rec.seq > after {
                    out.push(rec);
                    if out.len() >= limit {
                        return Ok(out);
                    }
                }
            }
        }
        Ok(out)
    }

    fn delete(&self, id: &str) -> Result<()> {
        self.writers.lock().unwrap().remove(id);
        let dir = self.dir(id);
        // macOS returns ENOTEMPTY when a file lands mid-removal; retry briefly.
        let mut last = None;
        for _ in 0..5 {
            if !dir.exists() {
                return Ok(());
            }
            match std::fs::remove_dir_all(&dir) {
                Ok(()) => return Ok(()),
                Err(e) => {
                    last = Some(e);
                    std::thread::sleep(std::time::Duration::from_millis(40));
                }
            }
        }
        match last {
            Some(e) => Err(e.into()),
            None => Ok(()),
        }
    }

    fn session_dir(&self, id: &str) -> Option<PathBuf> {
        Some(self.dir(id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta(id: &str) -> SessionMeta {
        SessionMeta {
            schema: META_SCHEMA.into(),
            id: id.into(),
            name: id.into(),
            agent: "codex".into(),
            agent_argv: vec![],
            cwd: PathBuf::from("/tmp"),
            agent_session_id: None,
            status: SessionStatus::Idle,
            created_at: 1,
            updated_at: 1,
            last_seq: 0,
            parent_id: None,
            fork_seq: None,
            agent_info: None,
            agent_capabilities: None,
            modes: None,
            config_options: None,
            models: None,
            permission_policy: None,
            title: None,
            last_prompt: None,
            preview: None,
            event_count: 0,
            turn_count: 0,
            usage: None,
        }
    }

    fn rec(seq: u64) -> EventRecord {
        EventRecord {
            seq,
            at: seq,
            dir: "mux".into(),
            kind: "status".into(),
            msg: serde_json::json!({"seq": seq}),
        }
    }

    #[test]
    fn local_store_rolls_segments_and_reads_after_seq() {
        let tmp = std::env::temp_dir().join(format!("acpmux-store-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let store = LocalStore::new(tmp.clone(), 64 * 1024).unwrap();
        store.save(&meta("s1")).unwrap();
        for i in 1..=3000 {
            store.append("s1", &rec(i)).unwrap();
        }
        let segs = store.segments("s1").unwrap();
        assert!(segs.len() >= 2, "expected roll, got {}", segs.len());
        let tail = store.events("s1", 2990, 100).unwrap();
        assert_eq!(tail.len(), 10);
        assert_eq!(tail[0].seq, 2991);
        assert_eq!(store.list().unwrap().len(), 1);
        store.delete("s1").unwrap();
        assert!(store.load("s1").unwrap().is_none());
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn memory_store_round_trip() {
        let store = MemoryStore::default();
        store.save(&meta("m")).unwrap();
        store.append("m", &rec(1)).unwrap();
        store.append("m", &rec(2)).unwrap();
        assert_eq!(store.events("m", 1, 10).unwrap().len(), 1);
    }
}
