//! What a fresh mount does for git before the agent's first `git status` (RFD 0007, hard case 2):
//!
//! - [`Overlay::warm_git`] fetches, in a few batches at once, what every `git status` reads first:
//!   each repo's small `.git` files (`HEAD`, `config`, refs, the index, the pack indexes) and every
//!   `.gitignore`. Asked one by one as git walks, each is a round trip to the Mac: about forty
//!   serial ones on a big repo, most of a cold status.
//! - [`Overlay::prime_git`] writes each repo's index again with an `FSMN` extension
//!   ([`crate::fsmonitor::prime`]), so the first status asks the hook instead of `lstat`ing every
//!   tracked file.
//! - [`Overlay::serve_fsmonitor`] answers the hook ([`crate::fsmonitor::hook`]) on a Unix socket
//!   from the overlay's journal of changes.

use super::*;
use crate::fsmonitor::{self, IndexEntry, Journal};

/// The most bytes [`Overlay::warm_git`] fetches.
pub const WARM_MAX_BYTES: u64 = 64 * 1024 * 1024;
/// The most files [`Overlay::warm_git`] takes from one repo's `refs/`.
const WARM_MAX_REFS: usize = 2048;
/// Fetches [`Overlay::warm_git`] keeps in flight.
const WARM_THREADS: usize = 8;
/// The `.git` files a `git status` reads.
const GIT_FILES: [&str; 9] = [
    "HEAD",
    "config",
    "commondir",
    "packed-refs",
    "shallow",
    "index",
    "info/exclude",
    "info/sparse-checkout",
    "objects/info/alternates",
];

/// What [`Overlay::warm_git`] found and fetched.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct WarmReport {
    /// Repos (a `.git` folder) in the projection.
    pub repos: u64,
    /// Files it wanted.
    pub files: u64,
    /// Their bytes.
    pub bytes: u64,
    /// Bytes fetched from the Mac by this call.
    pub fetched_bytes: u64,
}

impl Overlay {
    /// The journal of changes git's fsmonitor hook reads.
    #[must_use]
    pub fn journal(&self) -> &Journal {
        &self.journal
    }

    /// Notes a change of the file numbered `ino`.
    pub(super) fn note_ino(&self, ino: u64) {
        if let Ok(path) = self.path_of(ino) {
            self.journal.note(&path);
        }
    }

    /// The `.git` folders of the manifest (paths), each a repo whose worktree is its parent.
    fn git_dirs(&self) -> Vec<(u32, String)> {
        (0..u32::try_from(self.manifest.len()).unwrap_or(u32::MAX))
            .filter(|index| {
                self.manifest.entry(*index).is_some_and(|e| e.kind == Kind::Dir && e.name == ".git")
            })
            .map(|index| (index, self.manifest.path_of(index)))
            .filter(|(_, path)| self.lower(path).is_some())
            .collect()
    }

    /// The child `name` (a `/`-separated path) of folder `index` in the manifest.
    fn child_entry(&self, index: u32, name: &str) -> Option<u32> {
        name.split('/').try_fold(index, |at, part| {
            let (first, children) = self.manifest.children(at);
            let offset = children.iter().position(|child| child.name == part)?;
            Some(first + u32::try_from(offset).ok()?)
        })
    }

    /// Every file under folder `index`, at most `max`.
    fn files_in(&self, index: u32, max: usize, out: &mut Vec<u32>) {
        let mut stack = vec![index];
        let mut taken = 0;
        while let Some(at) = stack.pop() {
            let (first, children) = self.manifest.children(at);
            for (offset, child) in children.iter().enumerate() {
                let Ok(offset) = u32::try_from(offset) else { break };
                match child.kind {
                    Kind::File if taken < max => {
                        out.push(first + offset);
                        taken += 1;
                    }
                    Kind::Dir => stack.push(first + offset),
                    _ => {}
                }
            }
        }
    }

    /// Fetches what a first `git status` reads in every repo of the projection, in parallel
    /// batches, so git finds it in the cache (nothing for a source with no cache: its bytes are on
    /// the machine's disk already).
    pub fn warm_git(&self) -> WarmReport {
        let dirs = self.git_dirs();
        let mut report = WarmReport { repos: dirs.len() as u64, ..WarmReport::default() };
        if dirs.is_empty() || !self.fetch.cache() {
            return report;
        }
        let mut wanted = Vec::new();
        for (dir, _) in &dirs {
            wanted.extend(GIT_FILES.iter().filter_map(|name| self.child_entry(*dir, name)));
            if let Some(refs) = self.child_entry(*dir, "refs") {
                self.files_in(refs, WARM_MAX_REFS, &mut wanted);
            }
            for folder in ["objects/info", "objects/pack"] {
                let Some(at) = self.child_entry(*dir, folder) else { continue };
                let (first, children) = self.manifest.children(at);
                for (offset, child) in children.iter().enumerate() {
                    let keep = child.kind == Kind::File
                        && (folder == "objects/info" || child.name.ends_with(".idx"));
                    if let (true, Ok(offset)) = (keep, u32::try_from(offset)) {
                        wanted.push(first + offset);
                    }
                }
            }
        }
        // Every `.gitignore` outside the repos' own `.git` folders.
        let ignores = (0..u32::try_from(self.manifest.len()).unwrap_or(u32::MAX)).filter(|index| {
            self.manifest
                .entry(*index)
                .is_some_and(|e| e.kind == Kind::File && e.name == ".gitignore")
        });
        for index in ignores {
            let path = self.manifest.path_of(index);
            if !path.split('/').any(|name| name == ".git") {
                wanted.push(index);
            }
        }
        wanted.sort_unstable();
        wanted.dedup();
        let mut budget = WARM_MAX_BYTES;
        let (mut small, mut big) = (Vec::new(), Vec::new());
        for index in wanted {
            let Some(size) = self.manifest.entry(index).map(|e| e.size) else { continue };
            if size > budget || self.lower(&self.manifest.path_of(index)).is_none() {
                continue;
            }
            budget -= size;
            report.files += 1;
            report.bytes += size;
            if size <= CHUNK {
                small.push(index);
            } else {
                big.extend(
                    (0..size.div_ceil(CHUNK))
                        .filter_map(|c| Some((index, u32::try_from(c).ok()?, size))),
                );
            }
        }
        let mut batches: Vec<Vec<u32>> = Vec::new();
        let mut bytes = 0;
        for index in small {
            let size = self.manifest.entry(index).map_or(0, |e| e.size);
            match batches.last_mut() {
                Some(batch) if batch.len() < BATCH_FILES && bytes + size <= BATCH_BYTES => {
                    batch.push(index)
                }
                _ => {
                    batches.push(vec![index]);
                    bytes = 0;
                }
            }
            bytes += size;
        }
        let before = self.remote_bytes.load(Ordering::Relaxed);
        let jobs: Mutex<Vec<Box<dyn FnOnce() + Send + '_>>> = Mutex::new(Vec::new());
        {
            let mut queue = jobs.lock().unwrap_or_else(PoisonError::into_inner);
            for (index, chunk, size) in big {
                queue.push(Box::new(move || drop(self.chunk(index, chunk, size))));
            }
            for batch in batches {
                queue.push(Box::new(move || self.fetch_wholes(&batch)));
            }
        }
        std::thread::scope(|scope| {
            for _ in 0..WARM_THREADS {
                scope.spawn(|| {
                    loop {
                        let job = jobs.lock().unwrap_or_else(PoisonError::into_inner).pop();
                        let Some(job) = job else { break };
                        job();
                    }
                });
            }
        });
        report.fetched_bytes = self.remote_bytes.load(Ordering::Relaxed) - before;
        report
    }

    /// Fetches the small files `files` the cache lacks (and nobody is fetching now) in one batch.
    fn fetch_wholes(&self, files: &[u32]) {
        let mut claim = Claim { overlay: self, keys: Vec::new() };
        let mut batch = Vec::new();
        {
            let mut inflight = self.inflight.lock().unwrap_or_else(PoisonError::into_inner);
            for file in files {
                let key = (*file, WHOLE);
                if inflight.contains(&key) || self.cache_lock().has(key) {
                    continue;
                }
                inflight.insert(key);
                claim.keys.push(key);
                batch.push(*file);
            }
        }
        if batch.is_empty() {
            return;
        }
        for (file, answer) in batch.iter().zip(self.fetch.batch(&batch)) {
            let expected = self.manifest.entry(*file).map_or(0, |entry| entry.size);
            if let Ok(bytes) = answer
                && bytes.len() as u64 == expected
            {
                self.count(expected);
                self.store((*file, WHOLE), &bytes);
            }
        }
        drop(claim);
    }

    /// The whole of lower file `index`.
    fn lower_bytes(&self, index: u32) -> Result<Vec<u8>, i32> {
        let size = self.manifest.entry(index).ok_or(ENOENT)?.size;
        if size <= CHUNK {
            return self.whole(index);
        }
        let mut out = Vec::with_capacity(usize::try_from(size).map_err(|_| EIO)?);
        for chunk in 0..size.div_ceil(CHUNK) {
            out.extend(self.chunk(index, u32::try_from(chunk).map_err(|_| EIO)?, size)?);
        }
        Ok(out)
    }

    /// Writes every repo's index again with an `FSMN` extension naming a token of this overlay's
    /// journal, each entry the manifest shows unchanged since the index was written marked clean.
    /// Only an index still in the lower layer (one the agent's git already wrote is git's own),
    /// and only paths still in the lower layer are clean. Returns how many indexes it wrote.
    pub fn prime_git(&self) -> usize {
        let mut primed = 0;
        for (_, dir) in self.git_dirs() {
            let index_path = join(&dir, "index");
            let Some(index) = self.lower(&index_path) else { continue };
            if self.upper.stat(&index_path).is_ok() {
                continue;
            }
            let Some(index_mtime) =
                self.manifest.entry(index).map(|e| e.mtime_ns.div_euclid(1_000_000_000))
            else {
                continue;
            };
            // The token first: a change made from here on is after it, whatever is judged below.
            let token = self.journal.token();
            let Ok(bytes) = self.lower_bytes(index) else { continue };
            let tree = Self::parent_of(&dir).to_owned();
            let mut folders: HashMap<String, bool> = HashMap::new();
            let rewritten = fsmonitor::prime(&bytes, &token, |entry| {
                self.clean_since(&tree, entry, index_mtime, &mut folders)
            });
            let Some(rewritten) = rewritten else { continue };
            if self.write_index(&index_path, &rewritten).is_ok() {
                primed += 1;
            }
        }
        primed
    }

    /// Whether index entry `entry` of the repo whose worktree is `tree` still matches its lower
    /// path's `stat` as `git status` compares them (`core.checkStat = minimal`: the mtime's
    /// seconds, the size, the type and the exec bit), and is not racy (changed in the second the
    /// index was written, or after).
    fn clean_since(
        &self,
        tree: &str,
        entry: &IndexEntry<'_>,
        index_mtime: i64,
        folders: &mut HashMap<String, bool>,
    ) -> bool {
        let Ok(name) = std::str::from_utf8(entry.path) else { return false };
        if entry.special || i64::from(entry.mtime_s) >= index_mtime {
            return false;
        }
        let path = if tree.is_empty() { name.to_owned() } else { join(tree, name) };
        let folder = Self::parent_of(&path).to_owned();
        let in_upper =
            *folders.entry(folder).or_insert_with_key(|folder| self.upper.stat(folder).is_ok());
        if in_upper && self.upper.stat(&path).is_ok() {
            return false;
        }
        let Some(lower) = self.lower(&path).and_then(|index| self.manifest.entry(index)) else {
            return false;
        };
        let regular = matches!(entry.mode, 0o100_644 | 0o100_755);
        regular
            && lower.kind == Kind::File
            && (lower.mode & 0o100 != 0) == (entry.mode & 0o100 != 0)
            && lower.size as u32 == entry.size
            && lower.mtime_ns.div_euclid(1_000_000_000) == i64::from(entry.mtime_s)
    }

    /// Writes `bytes` over the file at `path` through the overlay, as a write through the mount
    /// does (the lower file copied up first).
    fn write_index(&self, path: &str, bytes: &[u8]) -> Result<(), i32> {
        let ino = self.lookup_path(path)?.ino;
        let handle = self.open_handle(ino, libc::O_WRONLY | libc::O_TRUNC)?;
        let written = self.write_handle(handle, ino, 0, bytes);
        self.release(handle);
        written.map(drop)
    }

    /// Answers git's fsmonitor hook on the Unix socket `socket` (an old socket file there is
    /// replaced) until this overlay is dropped.
    pub fn serve_fsmonitor(self: &Arc<Self>, socket: &Path) -> std::io::Result<()> {
        use std::os::unix::net::UnixListener;
        match fs::remove_file(socket) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => return Err(error),
            _ => {}
        }
        let listener = UnixListener::bind(socket)?;
        let overlay = Arc::downgrade(self);
        std::thread::Builder::new().name("fsmonitor".into()).spawn(move || {
            for stream in listener.incoming() {
                let Some(overlay) = overlay.upgrade() else { break };
                let Ok(mut stream) = stream else { continue };
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                let _ = fsmonitor::serve_one(&overlay.journal, &mut stream);
            }
        })?;
        Ok(())
    }
}
