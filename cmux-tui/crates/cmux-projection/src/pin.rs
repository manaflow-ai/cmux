//! Pinned folders: a subtree of the projection fetched whole onto the machine's disk and kept
//! there, the "Make available offline" / "Keep Downloaded" / "Always keep on this device" of
//! Dropbox, iCloud Drive and OneDrive (RFD 0007, "Where they beat us today", gap 5).
//!
//! - A pin names a path of the manifest (a file or a folder). Every file under it is fetched, small
//!   ones in folder batches and big ones by chunk, and its blobs are kept apart from the LRU: never
//!   evicted and never counted against the cache's cap, so they read with the Mac asleep.
//! - A pin is sized against the machine's disk before anything is fetched: one whose missing bytes
//!   would leave less than [`DEFAULT_PIN_RESERVE`] free (or [`Overlay::with_pin_reserve`]) is
//!   refused with `ENOSPC`, never half fetched. The vendors evict when the OS decides; this says no
//!   up front.
//! - Pins are paths, kept in the state folder's `pins` file (one per NUL), so they outlive the
//!   daemon and a new manifest: [`Overlay::hydrate_pins`] fetches again what a new manifest's fresh
//!   cache lacks.
//! - Unpinning a folder hands its blobs to the LRU as the most recently used; a file still under
//!   another pin stays kept.

use super::*;

/// The state folder's file of pinned paths.
pub const PINS_FILE: &str = "pins";
/// The free bytes a pin leaves on the cache's disk by default.
pub const DEFAULT_PIN_RESERVE: u64 = 2 * 1024 * 1024 * 1024;

/// What a pin or a hydration found and fetched.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PinReport {
    /// Files under the pins.
    pub files: u64,
    /// Their bytes.
    pub bytes: u64,
    /// Bytes fetched from the Mac by this call (the rest were on disk already).
    pub fetched_bytes: u64,
    /// Files that could not be fetched.
    pub failed: u64,
    /// The first failure's `errno` (`EHOSTDOWN` when the Mac is away: the walk stops there).
    pub first_error: Option<i32>,
}

/// One pin as a status shows it: what it holds and how much of that is on this machine's disk.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct PinState {
    /// The pinned path, relative to the projected folder (`""` is the whole folder).
    pub path: String,
    /// Files under it.
    pub files: u64,
    /// Their bytes.
    pub bytes: u64,
    /// Of those, the bytes on disk now: `bytes` once it is fully available offline.
    pub local_bytes: u64,
    /// Whether this manifest still has the path (a pin outlives a new manifest without it).
    pub present: bool,
}

impl PinState {
    /// Whether every byte under the pin is on disk (it reads with the Mac away).
    #[must_use]
    pub fn complete(&self) -> bool {
        self.present && self.local_bytes >= self.bytes
    }
}

/// The pinned paths an earlier daemon wrote (none when there is no file).
pub(super) fn read_pins(file: &Path) -> anyhow::Result<BTreeSet<String>> {
    match fs::read(file) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(BTreeSet::new()),
        read => {
            let bytes = read.with_context(|| format!("reading {}", file.display()))?;
            Ok(bytes
                .split(|byte| *byte == 0)
                .filter(|path| !path.is_empty())
                .filter_map(|path| std::str::from_utf8(path).ok())
                .filter_map(|path| normalize(path).ok())
                .collect())
        }
    }
}

/// `path` relative and `/`-separated, with no empty or `.` names; `..` is refused.
fn normalize(path: &str) -> Result<String, i32> {
    let names: Vec<&str> =
        path.split('/').filter(|name| !name.is_empty() && *name != ".").collect();
    if names.contains(&"..") {
        return Err(EINVAL);
    }
    Ok(names.join("/"))
}

impl Overlay {
    /// This overlay with pins leaving `bytes` of the cache's disk free.
    #[must_use]
    pub fn with_pin_reserve(mut self, bytes: u64) -> Self {
        self.pin_reserve = bytes;
        self
    }

    /// The pinned paths, in order.
    #[must_use]
    pub fn pins(&self) -> Vec<String> {
        self.pins_lock().iter().cloned().collect()
    }

    /// The bytes kept on disk for pinned files now.
    #[must_use]
    pub fn pinned_bytes(&self) -> u64 {
        self.cache_lock().kept_bytes
    }

    /// Every pin with its files, bytes and the bytes of them on disk now, in path order.
    #[must_use]
    pub fn pin_states(&self) -> Vec<PinState> {
        self.pins()
            .into_iter()
            .map(|path| match self.files_under(&path) {
                Ok((files, bytes)) => {
                    // A source on the machine's disk (a git object store) holds every byte.
                    let local_bytes =
                        if self.fetch.cache() { self.local_bytes(&files) } else { bytes };
                    PinState { files: files.len() as u64, bytes, local_bytes, present: true, path }
                }
                Err(_) => PinState { path, ..PinState::default() },
            })
            .collect()
    }

    fn pins_lock(&self) -> MutexGuard<'_, BTreeSet<String>> {
        self.pins.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Pins `path`: checks the disk has room for what is missing, records the pin, then fetches
    /// every file under it. The pin holds even when a fetch fails (the Mac away); a later
    /// [`Overlay::hydrate_pins`] finishes it.
    pub fn pin(&self, path: &str) -> Result<PinReport, i32> {
        let path = normalize(path)?;
        let (files, bytes) = self.files_under(&path)?;
        if !self.fetch.cache() {
            // A source on the machine's disk (a git object store) is pinned by being there.
            return Ok(PinReport { files: files.len() as u64, bytes, ..PinReport::default() });
        }
        let missing = bytes.saturating_sub(self.local_bytes(&files));
        if missing.saturating_add(self.pin_reserve) > self.disk_free()? {
            return Err(libc::ENOSPC);
        }
        {
            // Pins, then the cache, under the pins lock: an unpin never misses this pin, and the
            // file on disk is written before memory changes (a failed write changes nothing).
            let mut pins = self.pins_lock();
            let mut next = pins.clone();
            next.insert(path);
            self.write_pins(&next)?;
            *pins = next;
            self.cache_lock().pin(&files);
        }
        Ok(self.hydrate(&files, bytes))
    }

    /// Unpins `path`; its files not under another pin go back to the LRU (and down to the cap).
    pub fn unpin(&self, path: &str) -> Result<(), i32> {
        let path = normalize(path)?;
        // The whole change under the pins lock (pins, then the cache), as in `pin`.
        let mut pins = self.pins_lock();
        if !pins.contains(&path) {
            return Err(ENOENT);
        }
        let mut next = pins.clone();
        next.remove(&path);
        self.write_pins(&next)?;
        *pins = next;
        // A path this manifest no longer has held no files.
        let (mut freed, _) = self.files_under(&path).unwrap_or_default();
        for other in pins.iter() {
            if let Ok((kept, _)) = self.files_under(other) {
                freed.retain(|file| !kept.contains(file));
            }
        }
        let mut index = self.cache_lock();
        index.unpin(&freed);
        self.evict_to_fit(&mut index, 0);
        Ok(())
    }

    /// Fetches whatever the pinned files lack on disk (after a restart, a new manifest, or a pin
    /// made while the Mac was away).
    pub fn hydrate_pins(&self) -> PinReport {
        let (files, bytes) = self.pinned_files();
        if !self.fetch.cache() {
            return PinReport { files: files.len() as u64, bytes, ..PinReport::default() };
        }
        self.hydrate(&files, bytes)
    }

    /// Marks the files of `pins` (read from the pins file at open) pinned.
    pub(super) fn restore_pins(&self, pins: BTreeSet<String>) {
        *self.pins_lock() = pins;
        let (files, _) = self.pinned_files();
        self.cache_lock().pin(&files);
    }

    /// Every file under every pin this manifest has, and their bytes.
    fn pinned_files(&self) -> (HashSet<u32>, u64) {
        let mut all = HashSet::new();
        for path in self.pins() {
            if let Ok((files, _)) = self.files_under(&path) {
                all.extend(files);
            }
        }
        let bytes = all.iter().filter_map(|file| self.manifest.entry(*file)).map(|e| e.size).sum();
        (all, bytes)
    }

    /// The lower files at or under `path` (deleted ones left out), and their bytes.
    fn files_under(&self, path: &str) -> Result<(HashSet<u32>, u64), i32> {
        let top = self.manifest.resolve(path).ok_or(ENOENT)?;
        let inner = self.lock();
        let check = !inner.whiteouts.is_empty();
        if check && Self::hidden(&inner, path) {
            return Err(ENOENT);
        }
        let (mut files, mut bytes) = (HashSet::new(), 0);
        let mut stack = vec![(top, path.to_owned())];
        while let Some((index, at)) = stack.pop() {
            let Some(entry) = self.manifest.entry(index) else { continue };
            match entry.kind {
                Kind::File => {
                    files.insert(index);
                    bytes += entry.size;
                }
                Kind::Link => {}
                Kind::Dir => {
                    for (child_id, child) in self.manifest.children(index) {
                        let child_path = if check { join(&at, &child.name) } else { String::new() };
                        if check && Self::hidden(&inner, &child_path) {
                            continue;
                        }
                        stack.push((child_id, child_path));
                    }
                }
            }
        }
        Ok((files, bytes))
    }

    /// The bytes of `files` the cache holds now.
    fn local_bytes(&self, files: &HashSet<u32>) -> u64 {
        let index = self.cache_lock();
        files
            .iter()
            .filter_map(|file| Some((*file, self.manifest.entry(*file)?.size)))
            .filter(|(file, size)| Self::keys_of(*file, *size).all(|key| index.has(key)))
            .map(|(_, size)| size)
            .sum()
    }

    /// The cache keys file `file` of `size` bytes is stored under.
    fn keys_of(file: u32, size: u64) -> impl Iterator<Item = Key> {
        let chunks = if size <= CHUNK { 0 } else { size.div_ceil(CHUNK) };
        let whole = (chunks == 0).then_some((file, WHOLE));
        whole
            .into_iter()
            .chain((0..chunks).filter_map(move |c| Some((file, u32::try_from(c).ok()?))))
    }

    /// Fetches every blob of `files` the cache lacks, in entry order (so a folder's small files go
    /// in batches). Stops at the first `EHOSTDOWN` (every later fetch would wait out the same
    /// absence), and with `ENOSPC` before a file that would leave less than the reserve free (a
    /// hydration after a restart is held to the same disk rule as the pin).
    fn hydrate(&self, files: &HashSet<u32>, bytes: u64) -> PinReport {
        let mut report = PinReport { files: files.len() as u64, bytes, ..PinReport::default() };
        let before = self.remote_bytes.load(Ordering::Relaxed);
        let mut order: Vec<u32> = files.iter().copied().collect();
        order.sort_unstable();
        for file in order {
            let Some(size) = self.manifest.entry(file).map(|entry| entry.size) else { continue };
            let lacking = !Self::keys_of(file, size).all(|key| self.cache_lock().has(key));
            if lacking && size.saturating_add(self.pin_reserve) > self.disk_free().unwrap_or(0) {
                report.failed += 1;
                report.first_error.get_or_insert(libc::ENOSPC);
                break;
            }
            let mut failed = None;
            for key in Self::keys_of(file, size) {
                if self.cache_lock().has(key) {
                    continue;
                }
                let got = if key.1 == WHOLE {
                    self.whole(file).map(drop)
                } else {
                    self.chunk(file, key.1, size).map(drop)
                };
                if let Err(errno) = got {
                    failed = Some(errno);
                    break;
                }
            }
            if let Some(errno) = failed {
                report.failed += 1;
                report.first_error.get_or_insert(errno);
                if errno == FetchError::Away.errno() {
                    break;
                }
            }
        }
        report.fetched_bytes = self.remote_bytes.load(Ordering::Relaxed).saturating_sub(before);
        report
    }

    /// Free bytes on the cache's disk for an unprivileged writer.
    fn disk_free(&self) -> Result<u64, i32> {
        use std::os::unix::ffi::OsStrExt as _;
        let path = std::ffi::CString::new(self.cache.as_os_str().as_bytes()).map_err(|_| EINVAL)?;
        // SAFETY: a zeroed statvfs is a valid out buffer; `path` is NUL-terminated.
        let mut out: libc::statvfs = unsafe { std::mem::zeroed() };
        // SAFETY: both pointers are valid for the call.
        if unsafe { libc::statvfs(path.as_ptr(), &mut out) } != 0 {
            return Err(EIO);
        }
        #[allow(clippy::useless_conversion)] // u64 on 64-bit Linux, narrower elsewhere
        Ok(u64::from(out.f_bavail).saturating_mul(u64::from(out.f_frsize)))
    }

    /// Writes `pins` to the pins file through a scratch file and a rename (never a torn list).
    fn write_pins(&self, pins: &BTreeSet<String>) -> Result<(), i32> {
        let mut bytes = Vec::new();
        for path in pins {
            // The folder itself is `.`: an empty entry would read back as none.
            bytes.extend_from_slice(if path.is_empty() { b"." } else { path.as_bytes() });
            bytes.push(0);
        }
        let temp = self.scratch_path();
        let written = fs::write(&temp, &bytes).and_then(|()| fs::rename(&temp, &self.pins_file));
        written.map_err(|error| {
            let _ = fs::remove_file(&temp);
            error.raw_os_error().unwrap_or(EIO)
        })
    }
}
