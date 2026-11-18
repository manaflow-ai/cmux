//! Fetching chunks: shared fetches, directory batches, read-ahead, and what each answer does.

use std::collections::{HashMap, HashSet};
use std::ops::Range;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Condvar, Mutex};

use super::{Core, Counters, Target, lock};
use crate::cache::{CHUNK, ChunkKey, chunk_count, chunk_len};
use crate::manifest::{Delta, Index, Kind};
use crate::source::{Got, Want};

/// How many times a read re-resolves a chunk that vanished from the cache between being stored
/// and being read (a tiny cache evicting under pressure).
const CHUNK_ATTEMPTS: usize = 3;

/// The result of one fetched chunk, shared by everyone waiting on it.
#[derive(Clone, Debug)]
pub(crate) enum Outcome {
    Bytes(Arc<Vec<u8>>),
    Changed,
    Gone,
    Withheld,
    Away,
    Failed(String),
}

/// Why a chunk could not be read (the read loop decides what to do next).
#[derive(Debug)]
pub(crate) enum Miss {
    Changed,
    Gone,
    Withheld,
    Away,
    Failed(String),
    /// Only for cache-only reads: the chunk is not in the cache.
    NotLocal,
}

impl From<Outcome> for Miss {
    fn from(o: Outcome) -> Miss {
        match o {
            Outcome::Changed => Miss::Changed,
            Outcome::Gone => Miss::Gone,
            Outcome::Withheld => Miss::Withheld,
            Outcome::Away => Miss::Away,
            Outcome::Failed(why) => Miss::Failed(why),
            Outcome::Bytes(_) => Miss::Failed("bytes reported as a miss".into()),
        }
    }
}

/// One fetch in flight; readers of the same chunk block on it instead of fetching again.
#[derive(Default)]
pub(crate) struct Waiter {
    slot: Mutex<Option<Outcome>>,
    ready: Condvar,
}

impl Waiter {
    fn wait(&self) -> Outcome {
        let mut slot = lock(&self.slot);
        loop {
            if let Some(o) = slot.as_ref() {
                return o.clone();
            }
            slot = self.ready.wait(slot).unwrap_or_else(std::sync::PoisonError::into_inner);
        }
    }

    fn set(&self, o: Outcome) {
        *lock(&self.slot) = Some(o);
        self.ready.notify_all();
    }
}

/// The fetches in flight, and the directories whose small files were already batched.
#[derive(Default)]
pub(crate) struct Inflight {
    chunks: Mutex<HashMap<ChunkKey, Arc<Waiter>>>,
    dirs_batched: Mutex<HashSet<Index>>,
}

enum Claim {
    Cached,
    Join(Arc<Waiter>),
    Mine(Arc<Waiter>),
}

/// A chunk this thread has claimed and must finish.
struct Pending {
    want: Want,
    key: ChunkKey,
    waiter: Arc<Waiter>,
}

impl Core {
    fn claim(&self, key: &ChunkKey) -> Claim {
        let mut chunks = lock(&self.inflight.chunks);
        if let Some(w) = chunks.get(key) {
            return Claim::Join(w.clone());
        }
        if self.cache.contains(key) {
            return Claim::Cached;
        }
        let w = Arc::new(Waiter::default());
        chunks.insert(*key, w.clone());
        Claim::Mine(w)
    }

    fn claim_pending(&self, path: &str, target: &Target, size: u64, chunk: u32) -> Option<Pending> {
        let key = ChunkKey::new(path, target.version, chunk);
        match self.claim(&key) {
            Claim::Mine(waiter) => {
                Some(Pending { want: want(path, target, size, chunk), key, waiter })
            }
            Claim::Cached | Claim::Join(_) => None,
        }
    }

    /// Stores the bytes (best effort), then releases the claim and wakes the waiters. The cache
    /// is written before the claim goes, so a reader that finds no claim finds the chunk.
    fn finish(&self, p: &Pending, outcome: Outcome) {
        if let Outcome::Bytes(bytes) = &outcome {
            let _ = self.cache.put(&p.key, bytes);
        }
        {
            let mut chunks = lock(&self.inflight.chunks);
            if chunks.get(&p.key).is_some_and(|w| Arc::ptr_eq(w, &p.waiter)) {
                chunks.remove(&p.key);
            }
        }
        p.waiter.set(outcome);
    }

    /// Bytes `range` of chunk `c`, from the cache or the source.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn chunk_range(
        self: &Arc<Self>,
        target: &Target,
        size: u64,
        c: u32,
        key: ChunkKey,
        clen: u64,
        range: Range<u64>,
        remote: &mut bool,
    ) -> Result<Vec<u8>, Miss> {
        for _ in 0..CHUNK_ATTEMPTS {
            if let Some(bytes) = self.cache.read(&key, clen, range.start, range.end - range.start) {
                return Ok(bytes);
            }
            *remote = true;
            let outcome = match self.claim(&key) {
                Claim::Cached => continue,
                Claim::Join(w) => {
                    Counters::bump(&self.counters.shared_waits, 1);
                    w.wait()
                }
                Claim::Mine(waiter) => {
                    let first = Pending { want: want(&target.path, target, size, c), key, waiter };
                    self.demand(target, size, first)
                }
            };
            return match outcome {
                Outcome::Bytes(b) => Ok(b[range.start as usize..range.end as usize].to_vec()),
                other => Err(other.into()),
            };
        }
        Err(Miss::Failed("the chunk kept leaving the cache".into()))
    }

    /// A demand fault. The faulting chunk is first; a small file's first fault in its directory
    /// brings the directory's other uncached small files along in the same call.
    fn demand(self: &Arc<Self>, target: &Target, size: u64, first: Pending) -> Outcome {
        let mut batch = vec![first];
        if size <= CHUNK && lock(&self.inflight.dirs_batched).insert(target.parent) {
            self.claim_siblings(target, size, &mut batch);
        }
        self.fetch_and_finish(batch)
    }

    fn claim_siblings(&self, target: &Target, size: u64, batch: &mut Vec<Pending>) {
        let mut bytes = size;
        let m = self.manifest();
        let prefix = match target.path.rsplit_once('/') {
            Some((dir, _)) => format!("{dir}/"),
            None => String::new(),
        };
        for i in m.children(target.parent) {
            if batch.len() >= self.config.batch_files {
                break;
            }
            let Some(e) = m.entry(i) else { break };
            let s = &e.stat;
            let small = s.kind == Kind::File && s.size > 0 && s.size <= CHUNK;
            if i == target.idx
                || e.gone
                || s.withheld
                || !small
                || bytes + s.size > self.config.batch_bytes
            {
                continue;
            }
            let sibling = Target {
                idx: i,
                parent: target.parent,
                path: format!("{prefix}{}", e.name),
                version: s.version(),
            };
            if let Some(p) = self.claim_pending(&sibling.path, &sibling, s.size, 0) {
                bytes += s.size;
                batch.push(p);
            }
        }
    }

    /// After a read of a big file, fetches the next chunks in the background.
    pub(super) fn read_ahead(self: &Arc<Self>, target: &Target, size: u64, last_read: u32) {
        if size <= CHUNK || self.config.readahead_chunks == 0 {
            return;
        }
        let last = chunk_count(size) - 1;
        let upto = last_read.saturating_add(self.config.readahead_chunks).min(last);
        let ahead: Vec<Pending> = (last_read.saturating_add(1)..=upto)
            .filter_map(|c| self.claim_pending(&target.path, target, size, c))
            .collect();
        if ahead.is_empty() {
            return;
        }
        // The claims must be finished even if no thread can be started, or a later reader would
        // wait on them forever; then this reader fetches them itself.
        let slot = Arc::new(Mutex::new(Some(ahead)));
        let (core, theirs) = (self.clone(), slot.clone());
        let spawned = std::thread::Builder::new().name("projfs-ahead".into()).spawn(move || {
            if let Some(ahead) = lock(&theirs).take() {
                core.fetch_and_finish(ahead);
            }
        });
        if spawned.is_err() {
            let ahead = lock(&slot).take();
            if let Some(ahead) = ahead {
                self.fetch_and_finish(ahead);
            }
        }
    }

    /// One call to the source for the whole batch; every claim is finished, the outcome of the
    /// first is returned.
    fn fetch_and_finish(&self, batch: Vec<Pending>) -> Outcome {
        let wants: Vec<Want> = batch.iter().map(|p| p.want.clone()).collect();
        Counters::bump(&self.counters.round_trips, 1);
        let answers = catch_unwind(AssertUnwindSafe(|| self.source.fetch(&wants)))
            .unwrap_or_else(|_| vec![Got::Failed("the source panicked".into()); wants.len()]);
        let mut answers = answers.into_iter();
        let mut first = None;
        for p in batch {
            let got = answers.next().unwrap_or_else(|| {
                Got::Failed("the source answered fewer files than asked".into())
            });
            let outcome = self.settle(&p, got);
            self.finish(&p, outcome.clone());
            first.get_or_insert(outcome);
        }
        first.unwrap_or_else(|| Outcome::Failed("empty batch".into()))
    }

    /// Turns one answer into an outcome, updating the manifest for changed, gone and withheld.
    fn settle(&self, p: &Pending, got: Got) -> Outcome {
        let path = p.want.path.as_str();
        match got {
            Got::Bytes(b) if b.len() as u64 == u64::from(p.want.len) => {
                Counters::bump(&self.counters.bytes_fetched, b.len() as u64);
                Outcome::Bytes(Arc::new(b))
            }
            Got::Bytes(b) => self.failed(format!(
                "{path}: the source answered {} bytes, {} were asked for",
                b.len(),
                p.want.len
            )),
            Got::Changed(stat) => {
                Counters::bump(&self.counters.changed, 1);
                match self.apply_delta(path, Delta::Stat(stat)) {
                    Ok(_) => Outcome::Changed,
                    Err(e) => self.failed(e.to_string()),
                }
            }
            Got::Gone => {
                let _ = self.apply_delta(path, Delta::Gone);
                Outcome::Gone
            }
            Got::Withheld => {
                self.mark_withheld(path);
                Outcome::Withheld
            }
            Got::Away => {
                Counters::bump(&self.counters.away, 1);
                Outcome::Away
            }
            Got::Failed(why) => self.failed(format!("{path}: {why}")),
        }
    }

    fn failed(&self, why: String) -> Outcome {
        Counters::bump(&self.counters.failed, 1);
        Outcome::Failed(why)
    }

    fn mark_withheld(&self, path: &str) {
        let stat = {
            let m = self.manifest();
            m.resolve(path).and_then(|i| m.entry(i)).map(|e| e.stat.clone())
        };
        if let Some(mut stat) = stat.filter(|s| s.kind == Kind::File) {
            stat.withheld = true;
            let _ = self.apply_delta(path, Delta::Stat(stat));
        }
    }
}

fn want(path: &str, target: &Target, size: u64, chunk: u32) -> Want {
    Want {
        path: path.to_owned(),
        version: target.version,
        offset: u64::from(chunk) * CHUNK,
        len: chunk_len(size, chunk) as u32,
    }
}
