//! `idempotency_key` for acpmux's MCP tools that act (`send_message` today): a retry with
//! the same key from the same session within [`TTL`] returns the first result instead of
//! acting twice (plans/mcp-everything/ergonomics.md section 5).
//!
//! The cache lives in the tools-mcp process of the chat, keyed by (session, key), and is
//! bounded in size ([`MAX_ENTRIES`]) and age ([`TTL`]). A call that ends in an error is
//! forgotten, so a retry after a refusal acts again. Concurrent calls with one key share
//! the first one's run. The same key with other arguments is refused, not replayed.

use serde_json::{Map, Value};
use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::hash::{DefaultHasher, Hash as _, Hasher as _};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::OnceCell;

/// The argument every acting tool takes; removed before the call reaches the daemon.
pub const KEY_ARG: &str = "idempotency_key";
/// How long a key is remembered.
pub const TTL: Duration = Duration::from_secs(600);
/// How many keys one process remembers; past it the oldest goes first.
pub const MAX_ENTRIES: usize = 1024;
const MAX_KEY_LEN: usize = 128;

/// The schema line for [`KEY_ARG`] in a tool's `inputSchema`.
pub fn schema() -> Value {
    serde_json::json!({
        "type": "string",
        "description": "Optional. A retry with the same key within 10 minutes returns the first result (structuredContent.replayed: true) instead of acting twice. Echoed in structuredContent.idempotency_key."
    })
}

struct Entry {
    at: Instant,
    fingerprint: u64,
    result: Arc<OnceCell<Value>>,
}

type Id = (String, String);

/// The keys and, oldest first, when each was claimed: eviction pops the front, so a
/// claim costs O(1) amortized at any size. A front item whose entry was replaced or
/// forgotten since is skipped.
#[derive(Default)]
struct Entries {
    map: HashMap<Id, Entry>,
    order: VecDeque<(Id, Instant)>,
}

impl Entries {
    fn is_current(&self, id: &Id, at: Instant) -> bool {
        self.map.get(id).is_some_and(|e| e.at == at)
    }
}

/// Remembered keys and their first results, bounded by `max` and `ttl`.
pub struct Cache {
    entries: Mutex<Entries>,
    ttl: Duration,
    max: usize,
}

impl Cache {
    pub fn new(ttl: Duration, max: usize) -> Self {
        Self { entries: Mutex::new(Entries::default()), ttl, max: max.max(1) }
    }

    pub fn len(&self) -> usize {
        self.entries.lock().map(|e| e.map.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The cell holding `key`'s result, new unless a live entry exists; `None` when
    /// a live entry has other arguments.
    fn claim(
        &self,
        scope: &str,
        key: &str,
        fingerprint: u64,
        now: Instant,
    ) -> Option<Arc<OnceCell<Value>>> {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        let id = (scope.to_owned(), key.to_owned());
        if let Some(e) = entries.map.get(&id)
            && now.saturating_duration_since(e.at) < self.ttl
        {
            return (e.fingerprint == fingerprint).then(|| e.result.clone());
        }
        // Oldest first: drop what expired, then the oldest while full.
        while let Some((front, at)) = entries.order.pop_front() {
            let current = entries.is_current(&front, at);
            let expired = now.saturating_duration_since(at) >= self.ttl;
            if current && !expired && entries.map.len() < self.max {
                entries.order.push_front((front, at));
                break;
            }
            if current {
                entries.map.remove(&front);
            }
        }
        // Skipped items (replaced or forgotten keys) never outnumber live ones for long.
        if entries.order.len() > 2 * self.max {
            let Entries { map, order } = &mut *entries;
            order.retain(|(id, at)| map.get(id).is_some_and(|e| e.at == *at));
        }
        let result = Arc::new(OnceCell::new());
        entries.map.insert(id.clone(), Entry { at: now, fingerprint, result: result.clone() });
        entries.order.push_back((id, now));
        Some(result)
    }

    fn forget(&self, scope: &str, key: &str, cell: &Arc<OnceCell<Value>>) {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        let id = (scope.to_owned(), key.to_owned());
        if entries.map.get(&id).is_some_and(|e| Arc::ptr_eq(&e.result, cell)) {
            entries.map.remove(&id);
        }
    }
}

fn fingerprint(args: &Value) -> u64 {
    let mut h = DefaultHasher::new();
    serde_json::to_string(args).unwrap_or_default().hash(&mut h);
    h.finish()
}

fn with_key(mut result: Value, key: &str, replayed: bool) -> Value {
    if let Some(obj) = result.as_object_mut() {
        let structured =
            obj.entry("structuredContent").or_insert_with(|| Value::Object(Map::new()));
        if let Some(s) = structured.as_object_mut() {
            s.insert(KEY_ARG.to_owned(), Value::String(key.to_owned()));
            if replayed {
                s.insert("replayed".to_owned(), Value::Bool(true));
            }
        }
    }
    result
}

/// Runs `run(args)` (with [`KEY_ARG`] taken out) at most once per (`scope`, key) while
/// the key is remembered, and returns the first result with the key echoed. Without a
/// key it is `run(args)`.
pub async fn once<F, Fut>(cache: &Cache, scope: &str, mut args: Value, run: F) -> Value
where
    F: FnOnce(Value) -> Fut,
    Fut: Future<Output = Value>,
{
    let key = match args.as_object_mut().and_then(|o| o.remove(KEY_ARG)) {
        None | Some(Value::Null) => return run(args).await,
        Some(Value::String(k)) if !k.is_empty() && k.len() <= MAX_KEY_LEN => k,
        Some(_) => {
            return crate::secret_mcp::error_result(format!(
                "{KEY_ARG} must be a string of 1 to {MAX_KEY_LEN} bytes"
            ));
        }
    };
    let Some(cell) = cache.claim(scope, &key, fingerprint(&args), Instant::now()) else {
        return crate::secret_mcp::error_result(format!(
            "idempotency.conflict: {KEY_ARG} {key:?} was already used with other arguments; use a new key for a new message"
        ));
    };
    let mut ran = false;
    let out = cell
        .get_or_init(|| {
            ran = true;
            run(args)
        })
        .await
        .clone();
    if ran && out.get("isError").and_then(Value::as_bool).unwrap_or(false) {
        cache.forget(scope, &key, &cell);
    }
    with_key(out, &key, !ran)
}

#[cfg(test)]
#[path = "idempotency_tests.rs"]
mod tests;
