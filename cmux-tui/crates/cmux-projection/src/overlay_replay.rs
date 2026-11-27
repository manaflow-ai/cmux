//! Replay prefetch (RFD 0065 piece 8): the overlay records the order in which a session first
//! reads each lower file, and the next start fetches that list ahead, in batches, before the
//! agent asks. Folder read-ahead guessed 5 to 1,000 times more than `git status` or a build
//! reads; a recorded list of the last session was 99 to 100% right in RFD 0065's measures (as
//! eStargz and Nydus replay a start's access list).
//!
//! - The list is per state folder (one repo or folder) and per key (the command or kind of
//!   start, [`Overlay::with_replay`]): `replay/<key>`, paths in first-touch order, one per NUL.
//! - A session records into `replay/<key>.next` and it replaces the list when the overlay goes
//!   (or, after a crash, at the next open), once it touched at least [`MIN_FILES`]: a start that
//!   read almost nothing keeps the list of the last real one.
//! - [`Overlay::replay_prefetch`] fetches the listed small files the cache lacks, in batches of up
//!   to [`wire::MAX_BATCH`] files and [`BATCH_BYTES`], up to [`MAX_BYTES`] (or half the cache cap),
//!   and stops at the first batch the Mac is away for.
//! - With a list, folder read-ahead is off until a scan is detected: [`SCAN_MISSES`] faults of
//!   unlisted files within [`SCAN_WINDOW`] turn it on until [`SCAN_HOLD`] after the last. With no
//!   list yet (a first start) read-ahead is as it was.

use std::collections::VecDeque;
use std::time::Instant;

use super::*;
use crate::wire;

/// The state folder's folder of access lists.
pub const REPLAY_DIR: &str = "replay";
/// The most paths a list holds.
pub const MAX_FILES: usize = 16_384;
/// A session that touched fewer files leaves the last list in place.
pub const MIN_FILES: usize = 16;
/// The most bytes one prefetch asks for (less when half the cache cap is less).
pub const MAX_BYTES: u64 = 256 * 1024 * 1024;
/// The most bytes in one prefetch batch.
pub const BATCH_BYTES: u64 = 16 * 1024 * 1024;
/// Faults of unlisted files that make a scan.
pub const SCAN_MISSES: usize = 16;
/// The window those faults fall in.
pub const SCAN_WINDOW: Duration = Duration::from_secs(2);
/// How long read-ahead stays on after the last fault of a scan.
pub const SCAN_HOLD: Duration = Duration::from_secs(10);

/// What a replay prefetch did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReplayReport {
    /// Paths in the list.
    pub listed: u64,
    /// Files asked of the Mac.
    pub asked: u64,
    /// Files that landed in the cache, and their bytes.
    pub fetched: u64,
    pub bytes: u64,
    /// Batches sent.
    pub batches: u64,
    /// Whether it stopped because the Mac was away.
    pub away: bool,
}

/// The session's recording.
struct Recorder {
    file: Option<fs::File>,
    seen: HashSet<u32>,
}

/// Recent faults of files the list does not hold.
#[derive(Default)]
struct Scan {
    misses: VecDeque<Instant>,
    until: Option<Instant>,
}

/// An overlay's access list: the last session's, and this one's recording.
pub(super) struct Replay {
    list: PathBuf,
    next: PathBuf,
    /// The last session's paths, in first-touch order.
    last: Vec<String>,
    /// Their ids in this manifest.
    listed: HashSet<u32>,
    recorder: Mutex<Recorder>,
    scan: Mutex<Scan>,
}

/// The paths of a list file, at most [`MAX_FILES`].
fn read_list(path: &Path) -> Vec<String> {
    let Ok(bytes) = fs::read(path) else { return Vec::new() };
    bytes
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
        .filter_map(|path| String::from_utf8(path.to_vec()).ok())
        .take(MAX_FILES)
        .collect()
}

/// Makes the recording `next` the list when it holds at least [`MIN_FILES`] paths.
fn promote(next: &Path, list: &Path) {
    if read_list(next).len() >= MIN_FILES {
        let _ = fs::rename(next, list);
    }
}

impl Replay {
    fn open(state: &Path, key: &str, manifest: &Lower) -> Option<Self> {
        let key: String = key
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
            .collect();
        let dir = state.join(REPLAY_DIR);
        fs::create_dir_all(&dir).ok()?;
        let list = dir.join(&key);
        let next = dir.join(format!("{key}.next"));
        // A session that ended without its overlay going (a crash) left its recording.
        promote(&next, &list);
        let last = read_list(&list);
        let listed = last.iter().filter_map(|path| manifest.resolve(path)).collect();
        let file = fs::File::create(&next).ok();
        Some(Self {
            list,
            next,
            last,
            listed,
            recorder: Mutex::new(Recorder { file, seen: HashSet::new() }),
            scan: Mutex::new(Scan::default()),
        })
    }

    /// Records the first read of file `index` (at `path`).
    fn touch(&self, index: u32, path: impl FnOnce() -> String) {
        let mut recorder = self.recorder.lock().unwrap_or_else(PoisonError::into_inner);
        if recorder.seen.len() >= MAX_FILES || !recorder.seen.insert(index) {
            return;
        }
        let mut line = path().into_bytes();
        line.push(0);
        if let Some(file) = recorder.file.as_mut()
            && file.write_all(&line).is_err()
        {
            recorder.file = None;
        }
    }

    /// Whether a fault on uncached file `index` reads its folder ahead.
    fn read_ahead(&self, index: u32) -> bool {
        if self.last.is_empty() {
            return true;
        }
        let now = Instant::now();
        let mut scan = self.scan.lock().unwrap_or_else(PoisonError::into_inner);
        if !self.listed.contains(&index) {
            scan.misses.push_back(now);
            while scan.misses.front().is_some_and(|at| now.duration_since(*at) > SCAN_WINDOW) {
                scan.misses.pop_front();
            }
            if scan.misses.len() >= SCAN_MISSES {
                scan.until = Some(now + SCAN_HOLD);
            }
        }
        scan.until.is_some_and(|until| now < until)
    }
}

impl Drop for Replay {
    fn drop(&mut self) {
        let recorder = self.recorder.get_mut().unwrap_or_else(PoisonError::into_inner);
        if let Some(file) = recorder.file.take() {
            let _ = file.sync_all();
        }
        promote(&self.next, &self.list);
    }
}

impl Overlay {
    /// The overlay recording its access list under `key` (the kind of start: one list per repo,
    /// which is the state folder, and per key), and replaying the last one: see the module docs.
    /// A source that is not cached (a git object store) records nothing.
    #[must_use]
    pub fn with_replay(mut self, key: &str) -> Self {
        if !self.fetch.cache() {
            return self;
        }
        let Some(state) = self.cache.parent() else { return self };
        self.replay = Replay::open(state, key, &self.manifest);
        self
    }

    /// Records a read of lower file `index`.
    pub(super) fn replay_touch(&self, index: u32) {
        if let Some(replay) = &self.replay {
            replay.touch(index, || self.manifest.path_of(index));
        }
    }

    /// Whether a fault on uncached file `index` reads its folder ahead: always with no list; with
    /// one, only during a scan.
    pub(super) fn replay_read_ahead(&self, index: u32) -> bool {
        self.replay.as_ref().is_none_or(|replay| replay.read_ahead(index))
    }

    /// The last session's paths (empty with no list or no replay).
    #[must_use]
    pub fn replay_list(&self) -> Vec<String> {
        self.replay.as_ref().map(|replay| replay.last.clone()).unwrap_or_default()
    }

    /// Fetches the files of the last session's list the cache lacks, in first-touch order, in
    /// batches (each in id order, which is path order within a folder). Run it in the background
    /// after the mount: a fault on a file in a batch in flight waits for that batch.
    pub fn replay_prefetch(&self) -> ReplayReport {
        let Some(replay) = &self.replay else { return ReplayReport::default() };
        let mut report =
            ReplayReport { listed: replay.last.len() as u64, ..ReplayReport::default() };
        let budget = MAX_BYTES.min(self.cache_max / 2);
        let (mut total, mut batch, mut batch_bytes) = (0u64, Vec::new(), 0u64);
        for path in &replay.last {
            let Some(index) = self.manifest.resolve(path) else { continue };
            let Some(entry) = self.manifest.entry(index) else { continue };
            if entry.kind != Kind::File
                || entry.size > CHUNK
                || self.manifest.kept(index).is_some()
                || Self::hidden(&self.lock(), path)
                || self.upper.stat(path).is_ok()
                || self.cache_path((index, WHOLE)).exists()
                || self.in_content((index, WHOLE))
            {
                continue;
            }
            if total + entry.size > budget {
                break;
            }
            if batch.len() >= wire::MAX_BATCH as usize || batch_bytes + entry.size > BATCH_BYTES {
                if !self.replay_batch(std::mem::take(&mut batch), &mut report) {
                    return report;
                }
                batch_bytes = 0;
            }
            total += entry.size;
            batch_bytes += entry.size;
            batch.push(index);
        }
        if !batch.is_empty() {
            self.replay_batch(batch, &mut report);
        }
        report
    }

    /// Fetches `batch` (the files no other thread fetches now) and caches what lands; false when
    /// the Mac was away.
    fn replay_batch(&self, mut batch: Vec<u32>, report: &mut ReplayReport) -> bool {
        let mut claim = Claim { overlay: self, keys: Vec::new() };
        {
            let mut inflight = self.inflight.lock().unwrap_or_else(PoisonError::into_inner);
            batch.retain(|index| inflight.insert((*index, WHOLE)));
        }
        claim.keys = batch.iter().map(|index| (*index, WHOLE)).collect();
        // Claimed now: a cached check again, as a fault may have landed one in between.
        batch.retain(|index| !self.cache_path((*index, WHOLE)).exists());
        if batch.is_empty() {
            return true;
        }
        batch.sort_unstable();
        report.batches += 1;
        report.asked += batch.len() as u64;
        let answers = self.fetch.batch(&batch);
        let mut away = !answers.is_empty();
        for (index, answer) in batch.iter().zip(answers) {
            let expected = self.manifest.entry(*index).map_or(0, |entry| entry.size);
            match answer {
                Ok(bytes) if bytes.len() as u64 == expected => {
                    away = false;
                    self.count(expected);
                    self.store((*index, WHOLE), &bytes);
                    report.fetched += 1;
                    report.bytes += expected;
                }
                Err(FetchError::Away) => {}
                _ => away = false,
            }
        }
        drop(claim);
        report.away = away;
        !away
    }
}
