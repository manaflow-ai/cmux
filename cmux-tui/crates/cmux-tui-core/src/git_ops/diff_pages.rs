//! Active immutable patch captures, shared only by identical repository reads.
//! No timer: every page request prunes idle entries; eviction/drop closes the
//! anonymous file. The cache retains at most eight captures and 256 MiB, except
//! one larger active capture, so a large file is not itself refused by a cap.

use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use cmux_git::run::GitWindow;
use serde_json::Value;

const MAX_CAPTURES: usize = 8;
const TARGET_BYTES: u64 = 256 * 1024 * 1024;
const IDLE: Duration = Duration::from_secs(120);

/// A captured patch and its page revision (`diff::page_revision`): the
/// patch bytes and the page-zero listing together.
pub(super) struct Capture {
    pub(super) revision: String,
    pub(super) window: GitWindow,
}

struct Entry {
    key: String,
    revision: String,
    window: GitWindow,
    metadata: Value,
    used: Instant,
}

#[derive(Default)]
struct Captures(Vec<Entry>);

impl Captures {
    fn prune(&mut self, now: Instant) {
        self.0.retain(|entry| now.duration_since(entry.used) < IDLE);
    }

    fn get(&mut self, key: &str, revision: &str, now: Instant) -> Option<(GitWindow, Value)> {
        self.prune(now);
        let entry =
            self.0.iter_mut().find(|entry| entry.key == key && entry.revision == revision)?;
        entry.used = now;
        Some((entry.window.clone(), entry.metadata.clone()))
    }

    fn put(&mut self, key: String, capture: Capture, metadata: Value, now: Instant) {
        self.prune(now);
        // A request key describes the comparison inputs, but not the bytes that
        // were captured at a particular revision. Keep older revisions alive so
        // a continuation for an in-flight page cannot be evicted by a newer
        // offset-zero capture for the same request. A revision covers the
        // listing too, so an equal key/revision already holds this metadata.
        let Capture { revision, window } = capture;
        if self.0.iter().any(|entry| entry.key == key && entry.revision == revision) {
            return;
        }
        self.0.sort_by_key(|entry| entry.used);
        while !self.0.is_empty()
            && (self.0.len() >= MAX_CAPTURES
                || self
                    .0
                    .iter()
                    .map(|entry| entry.window.total_bytes)
                    .sum::<u64>()
                    .saturating_add(window.total_bytes)
                    > TARGET_BYTES)
        {
            self.0.remove(0);
        }
        self.0.push(Entry { key, revision, window, metadata, used: now });
    }
}

fn captures() -> &'static Mutex<Captures> {
    static CAPTURES: OnceLock<Mutex<Captures>> = OnceLock::new();
    CAPTURES.get_or_init(|| Mutex::new(Captures::default()))
}

pub(super) fn get(key: &str, revision: &str) -> Option<(GitWindow, Value)> {
    captures().lock().ok()?.get(key, revision, Instant::now())
}

pub(super) fn put(key: String, capture: Capture, metadata: Value) {
    if let Ok(mut captures) = captures().lock() {
        captures.put(key, capture, metadata, Instant::now());
    }
}

#[cfg(test)]
mod tests;
