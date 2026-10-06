//! Part of `Hub`; see `hub/mod.rs`. Cross-harness handoff: a record that
//! pairs a source session with a new, never-prompted target session on
//! another harness, the editable first message for the target (the
//! capsule), and its one delivery. `ops` holds the `_acpmux/handoff_*`
//! methods, `capsule` builds the first message from the source transcript.
//!
//! Records live in `handoffs/<handoffId>.json` next to the session store
//! (in memory with the memory store) and are loaded on daemon start, so
//! get, draft and a start retry work across a restart.

use super::*;
use serde::{Deserialize, Serialize};

mod capsule;
mod ops;

/// The UTF-8 byte budget of `capsule.text`, shared by prepare, draft and start.
pub const MAX_CAPSULE_BYTES: usize = 65_536;

/// Advertised in `initialize` as `_meta.acpmux.operations`.
pub const HANDOFF_OPERATIONS: [&str; 5] = [
    method::MUX_HANDOFF_PREPARE,
    method::MUX_HANDOFF_GET,
    method::MUX_HANDOFF_DRAFT,
    method::MUX_HANDOFF_START,
    method::MUX_HANDOFF_DISCARD,
];

/// Set to `1` in tests and dogfood only: a first start delivers the
/// capsule, then answers with an `uncertain_delivery` error instead of the
/// receipt and leaves the record `starting`, so a retry with the same
/// promptId exercises reconciliation.
const DROP_START_REPLY_ENV: &str = "ACPMUX_TEST_DROP_HANDOFF_START_REPLY";

/// Error codes: refused input, a state conflict, an unknown handoff.
const INVALID: i64 = -32602;
const CONFLICT: i64 = -32000;
const NOT_FOUND: i64 = -32002;

/// The session tag a prepare puts on the target it creates, so a repeat
/// prepare whose record was never saved adopts that target.
const TARGET_TAG: &str = "handoffKey";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum State {
    Draft,
    Starting,
    Started,
    Discarded,
}

/// A checkpoint the user attested; the daemon stamps who and when.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Checkpoint {
    #[serde(rename = "ref")]
    reference: String,
    attested_by: String,
    attested_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Context {
    from_seq: u64,
    to_seq: u64,
    truncated: bool,
    bytes: usize,
    total_bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Coverage {
    item: String,
    status: String,
    detail: Option<String>,
}

impl Coverage {
    fn new(item: &str, status: &str, detail: Option<String>) -> Self {
        Self { item: item.into(), status: status.into(), detail }
    }
}

/// One session of a handoff, as recorded at prepare. `enforcement` is
/// refreshed from the live session whenever the record is shown.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Side {
    session_id: String,
    name: String,
    harness: String,
    cwd: String,
    enforcement: Value,
}

impl Side {
    fn of(m: &SessionMeta, enforcement: Value) -> Self {
        Self {
            session_id: m.id.clone(),
            name: m.name.clone(),
            harness: m.harness.clone(),
            cwd: m.cwd.to_string_lossy().into_owned(),
            enforcement,
        }
    }
}

/// The result of one accepted draft write, answered again when its
/// `draftKey` repeats so a lost acknowledgement never reads back a newer
/// write.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DraftWrite {
    draft_key: String,
    revision: u64,
    text: String,
    memory_refs: Vec<String>,
    checkpoint: Option<Checkpoint>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    handoff_id: String,
    handoff_key: String,
    state: State,
    revision: u64,
    source: Side,
    source_seq: u64,
    target: Side,
    text: String,
    context: Context,
    checkpoint: Option<Checkpoint>,
    memory_refs: Vec<String>,
    /// Transcript, tool output, plan, files and model, fixed at prepare;
    /// memory and checkpoint follow the draft.
    coverage: Vec<Coverage>,
    prompt_id: Option<String>,
    turn_id: Option<String>,
    created_at: String,
    updated_at: String,
    /// The last `DRAFT_HISTORY` draft writes, newest last.
    #[serde(default)]
    drafts: Vec<DraftWrite>,
}

/// Draft writes remembered per handoff for `draftKey` replays.
const DRAFT_HISTORY: usize = 8;

impl Record {
    fn coverage(&self) -> Vec<Coverage> {
        let mut all = self.coverage.clone();
        all.push(if self.memory_refs.is_empty() {
            Coverage::new("memory", "omitted", None)
        } else {
            Coverage::new(
                "memory",
                "included",
                Some(format!("{} references the user approved", self.memory_refs.len())),
            )
        });
        all.push(match &self.checkpoint {
            Some(c) => Coverage::new("checkpoint", "included", Some(c.reference.clone())),
            None => Coverage::new(
                "checkpoint",
                "omitted",
                Some("no checkpoint yet; start requires one".into()),
            ),
        });
        all
    }

    /// Remember the record's current draft as the result of `key`.
    fn remember_draft(&mut self, key: &str) {
        self.drafts.push(DraftWrite {
            draft_key: key.to_owned(),
            revision: self.revision,
            text: self.text.clone(),
            memory_refs: self.memory_refs.clone(),
            checkpoint: self.checkpoint.clone(),
        });
        if self.drafts.len() > DRAFT_HISTORY {
            self.drafts.remove(0);
        }
    }

    /// The record as the write under `key` left it; state and timestamps
    /// stay current.
    fn draft_replay(&self, key: &str) -> Option<Record> {
        let w = self.drafts.iter().find(|w| w.draft_key == key)?;
        let mut r = self.clone();
        r.revision = w.revision;
        r.text = w.text.clone();
        r.memory_refs = w.memory_refs.clone();
        r.checkpoint = w.checkpoint.clone();
        Some(r)
    }
}

type KeyLocks = StdMutex<HashMap<String, Arc<Mutex<()>>>>;

/// One handoff key held for a mutation. Dropping it releases the key and
/// removes its entry when nobody else waits for it.
struct KeyGuard<'a> {
    locks: &'a KeyLocks,
    key: String,
    lock: Arc<Mutex<()>>,
    guard: Option<tokio::sync::OwnedMutexGuard<()>>,
}

impl Drop for KeyGuard<'_> {
    fn drop(&mut self) {
        let mut locks = self.locks.lock().unwrap();
        self.guard.take();
        // Only the map and this guard hold it, and new holders clone it
        // under the map lock: nobody waits.
        if Arc::strong_count(&self.lock) == 2 {
            locks.remove(&self.key);
        }
    }
}

/// Every handoff record, with its file when the store is on disk.
pub(crate) struct Handoffs {
    dir: Option<PathBuf>,
    records: StdMutex<HashMap<String, Record>>,
    /// Async locks per `key:<handoffKey>` (prepare) and `id:<handoffId>`
    /// (draft, start, discard), so retries of one handoff never create two
    /// targets or send twice while a slow harness holds up no other handoff.
    locks: KeyLocks,
}

impl Handoffs {
    /// Load every record under `dir`; `None` keeps them in memory only.
    pub(crate) fn open(dir: Option<PathBuf>) -> Self {
        let mut records = HashMap::new();
        if let Some(rd) = dir.as_ref().and_then(|d| std::fs::read_dir(d).ok()) {
            for entry in rd.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("json") {
                    continue;
                }
                match std::fs::read_to_string(&path)
                    .map_err(anyhow::Error::from)
                    .and_then(|t| serde_json::from_str::<Record>(&t).map_err(Into::into))
                {
                    Ok(r) => {
                        records.insert(r.handoff_id.clone(), r);
                    }
                    Err(e) => tracing::warn!("skip handoff {}: {e}", path.display()),
                }
            }
        }
        Self { dir, records: StdMutex::new(records), locks: StdMutex::new(HashMap::new()) }
    }

    async fn lock(&self, key: String) -> KeyGuard<'_> {
        let lock = self
            .locks
            .lock()
            .unwrap()
            .entry(key.clone())
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone();
        let guard = lock.clone().lock_owned().await;
        KeyGuard { locks: &self.locks, key, lock, guard: Some(guard) }
    }

    fn get(&self, id: &str) -> Option<Record> {
        self.records.lock().unwrap().get(id).cloned()
    }

    fn by_key(&self, key: &str) -> Option<Record> {
        self.records.lock().unwrap().values().find(|r| r.handoff_key == key).cloned()
    }

    /// The handoff whose target is `session_id`, else the newest one not
    /// discarded whose source it is.
    fn for_session(&self, session_id: &str) -> Option<Record> {
        let records = self.records.lock().unwrap();
        if let Some(r) = records.values().find(|r| r.target.session_id == session_id) {
            return Some(r.clone());
        }
        records
            .values()
            .filter(|r| r.source.session_id == session_id && r.state != State::Discarded)
            .max_by(|a, b| a.handoff_id.cmp(&b.handoff_id))
            .cloned()
    }

    /// Write the record (to disk first, when the store is on disk).
    fn put(&self, record: &Record) -> Result<(), RpcError> {
        if let Some(dir) = &self.dir {
            let write = || -> Result<()> {
                use std::os::unix::fs::DirBuilderExt;
                std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
                let bytes = serde_json::to_vec_pretty(record)?;
                crate::config::write_atomic(
                    &dir.join(format!("{}.json", record.handoff_id)),
                    &bytes,
                )
            };
            write().map_err(|e| RpcError::internal(format!("save handoff: {e}")))?;
        }
        self.records.lock().unwrap().insert(record.handoff_id.clone(), record.clone());
        Ok(())
    }
}

/// An error with `data: {reason, handoff?}` and the reason as the message
/// prefix.
fn refuse(
    code: i64,
    reason: &str,
    message: impl std::fmt::Display,
    handoff: Option<Value>,
) -> RpcError {
    let mut data = json!({"reason": reason});
    if let Some(h) = handoff {
        data["handoff"] = h;
    }
    RpcError::new(code, format!("{reason}: {message}")).with_data(data)
}

fn not_found(id: &str) -> RpcError {
    refuse(NOT_FOUND, "not_found", format!("no handoff {id:?}"), None)
}

fn too_large(bytes: usize) -> RpcError {
    RpcError::new(
        INVALID,
        format!(
            "capsule_too_large: the capsule is {bytes} bytes; the limit is {MAX_CAPSULE_BYTES}"
        ),
    )
    .with_data(json!({"reason": "capsule_too_large", "limit": MAX_CAPSULE_BYTES, "bytes": bytes}))
}

impl Hub {
    /// The wire `Handoff` for a record.
    fn handoff_view(&self, r: &Record) -> Value {
        let coverage = r.coverage();
        let side = |s: &Side| {
            let live = self.sessions.lock().unwrap().get(&s.session_id).cloned();
            let enforcement = live
                .map(|l| self.session_enforcement(&l.meta()))
                .unwrap_or_else(|| s.enforcement.clone());
            json!({"sessionId": s.session_id, "harness": s.harness, "cwd": s.cwd, "coverage": coverage, "enforcement": enforcement})
        };
        let mut source = side(&r.source);
        source["seq"] = json!(r.source_seq);
        json!({
            "handoffId": r.handoff_id,
            "handoffKey": r.handoff_key,
            "state": r.state,
            "revision": r.revision,
            "source": source,
            "target": side(&r.target),
            "capsule": {
                "text": r.text,
                "context": r.context,
                "checkpoint": r.checkpoint,
                "memoryRefs": r.memory_refs,
                "maxBytes": MAX_CAPSULE_BYTES,
            },
            "promptId": r.prompt_id,
            "turnId": r.turn_id,
            "createdAt": r.created_at,
            "updatedAt": r.updated_at,
        })
    }
}
