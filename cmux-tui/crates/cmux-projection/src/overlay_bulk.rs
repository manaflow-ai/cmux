//! Background bulk copy (RFD 0065 piece 11): once a projected start is serving, the rest of the
//! tree comes down behind it, at low priority, so the folder ends up local and reads stop
//! costing a round trip. It rides the seams the other pieces built: the batched, packed answers
//! of the wire (a path-ordered run of files per request, [`wire::MAX_BATCH`] and
//! [`BATCH_BYTES`] at most), the disk cache and its content store, and [`Overlay::replay_batch`]'s
//! claim of in-flight files, so a fault on a file in a batch waits for it and never fetches it twice.
//!
//! - It walks the listing in id order (path order within a folder) and skips what is already
//!   local: cached, in the content store, copied up, kept, or deleted. A file over one chunk is
//!   fetched chunk by chunk.
//! - It never evicts. The copy stops (not [`BulkReport::complete`]) at the first file that would
//!   take the cache past [`BulkOptions::fill`] of its cap: a tree that does not fit stays a
//!   projection with the cache, replay prefetch and sparse materialisation (RFD 0065, "Where a
//!   projection stops").
//! - It stays out of the way: a pause after every batch, ten times longer when the mount faulted
//!   remote reads since the last one; it stops when the Mac is away, and when `stop` is set.

use std::sync::atomic::AtomicBool;

use super::*;
use crate::wire;

/// The most bytes in one bulk batch.
pub const BATCH_BYTES: u64 = 16 * 1024 * 1024;

/// How a bulk copy behaves.
#[derive(Clone, Copy, Debug)]
pub struct BulkOptions {
    /// The share of the cache's cap the copy may fill, out of 100.
    pub fill: u64,
    /// The wait after each batch.
    pub pause: Duration,
}

impl Default for BulkOptions {
    fn default() -> Self {
        Self { fill: 75, pause: Duration::from_millis(50) }
    }
}

/// What a bulk copy did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BulkReport {
    /// Files fetched (a chunk of a big file counts once, with its file).
    pub files: u64,
    /// Bytes fetched.
    pub bytes: u64,
    /// Batches and chunks asked.
    pub requests: u64,
    /// Every file in the tree is local.
    pub complete: bool,
    /// It stopped because the Mac was away.
    pub away: bool,
    /// It stopped because the rest does not fit [`BulkOptions::fill`] of the cache.
    pub full: bool,
}

impl Overlay {
    /// Copies the tree's files the cache lacks, in path order, until it is all local, the cache
    /// is [`BulkOptions::fill`] full, the Mac goes away, or `stop` is set. Run it on its own
    /// thread after the mount ([`bulk::lower_priority`] first).
    pub fn bulk_copy(&self, options: &BulkOptions, stop: &AtomicBool) -> BulkReport {
        let mut report = BulkReport::default();
        if !self.fetch.cache() {
            return report;
        }
        let limit = self.cache_max / 100 * options.fill.min(100);
        let (mut batch, mut batch_bytes) = (Vec::new(), 0u64);
        let mut seen = self.remote_reads.load(Ordering::Relaxed);
        let mut projected = self.cache_bytes();
        let mut pause = || {
            // Remote reads this copy did not make are the agent's: back off.
            let now = self.remote_reads.load(Ordering::Relaxed);
            let busy = now.saturating_sub(seen) > 0;
            seen = now;
            std::thread::sleep(if busy { options.pause * 10 } else { options.pause });
        };
        for index in 0..self.manifest.len() as u32 {
            if stop.load(Ordering::Relaxed) {
                return report;
            }
            let Some(entry) = self.manifest.entry(index) else { continue };
            if entry.kind != Kind::File || self.manifest.kept(index).is_some() {
                continue;
            }
            let path = self.manifest.path_of(index);
            if Self::hidden(&self.lock(), &path) || self.upper.stat(&path).is_ok() {
                continue;
            }
            if entry.size > CHUNK {
                // Flush the small files first, so the order stays the path order.
                if !self.bulk_flush(&mut batch, &mut batch_bytes, &mut report) {
                    return report;
                }
                if !self.bulk_big(index, entry.size, limit, &mut projected, &mut report, stop) {
                    return report;
                }
                pause();
                continue;
            }
            if self.cache_path((index, WHOLE)).exists() || self.in_content((index, WHOLE)) {
                continue;
            }
            if projected + entry.size > limit {
                report.full = true;
                self.bulk_flush(&mut batch, &mut batch_bytes, &mut report);
                return report;
            }
            if batch.len() >= wire::MAX_BATCH as usize || batch_bytes + entry.size > BATCH_BYTES {
                if !self.bulk_flush(&mut batch, &mut batch_bytes, &mut report) {
                    return report;
                }
                pause();
            }
            projected += entry.size;
            batch_bytes += entry.size;
            batch.push(index);
        }
        report.complete =
            self.bulk_flush(&mut batch, &mut batch_bytes, &mut report) && !report.full;
        report
    }

    /// Fetches `batch`; false when the Mac was away.
    fn bulk_flush(&self, batch: &mut Vec<u32>, bytes: &mut u64, report: &mut BulkReport) -> bool {
        *bytes = 0;
        if batch.is_empty() {
            return true;
        }
        let mut sent = replay::ReplayReport::default();
        let live = self.replay_batch(std::mem::take(batch), &mut sent);
        report.files += sent.fetched;
        report.bytes += sent.bytes;
        report.requests += sent.batches;
        report.away |= sent.away;
        live
    }

    /// Fetches the chunks of big file `index` the cache lacks; false when it must stop.
    fn bulk_big(
        &self,
        index: u32,
        size: u64,
        limit: u64,
        projected: &mut u64,
        report: &mut BulkReport,
        stop: &AtomicBool,
    ) -> bool {
        let mut fetched = false;
        for chunk in 0..size.div_ceil(CHUNK) {
            let Ok(chunk) = u32::try_from(chunk) else { return true };
            let key = (index, chunk);
            if self.cache_path(key).exists() || self.in_content(key) {
                continue;
            }
            let len = CHUNK.min(size - u64::from(chunk) * CHUNK);
            if *projected + len > limit {
                report.full = true;
                return false;
            }
            if stop.load(Ordering::Relaxed) {
                return false;
            }
            // Not `chunk`: a failure here must not mark the path away for the agent.
            let _claim = self.claim(key);
            if self.cache_path(key).exists() {
                continue;
            }
            let at = u64::from(chunk) * CHUNK;
            let generation = self.generation_of(index);
            match self.fetch.read(index, at, u32::try_from(len).unwrap_or(0)) {
                Ok(bytes) if bytes.len() as u64 == len => {
                    self.count(len);
                    self.store(key, &bytes, generation);
                    *projected += len;
                    report.bytes += len;
                    report.requests += 1;
                    fetched = true;
                }
                Err(FetchError::Away) => {
                    report.away = true;
                    return false;
                }
                // The file changed under the listing: leave it to the read that finds out.
                _ => return true,
            }
        }
        report.files += u64::from(fetched);
        true
    }
}

/// Lowers the calling thread's CPU priority (best effort, Linux): the copy yields to the agent.
pub fn lower_priority() {
    #[cfg(target_os = "linux")]
    // SAFETY: gettid and setpriority take and return plain integers.
    unsafe {
        let tid = libc::syscall(libc::SYS_gettid);
        if let Ok(tid) = libc::id_t::try_from(tid) {
            libc::setpriority(libc::PRIO_PROCESS, tid, 19);
        }
    }
}
