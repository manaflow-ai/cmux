//! Bounded recovery; a busy namespace cannot permanently hide an upload.
//!
//! Nothing rescans on a period (p14-energy-077m). A complete scan schedules
//! the next one at the earliest receipt it kept (when that entry expires and
//! frees its capacity); a new upload starts a scan at once when the last
//! complete one is older than [`RESCAN_AFTER`] or none completed, so leftovers
//! of a process that died later are found by the next paste and a namespace
//! that opens again is used by the next paste. Without a paste, a namespace
//! that cannot be opened retries on its own, backing off.

use std::collections::HashSet;
use std::fs::ReadDir;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use crate::image_paste_file::ImagePasteFile;
use crate::image_paste_storage::ImagePasteStorage;

/// A new upload rescans when the last complete scan is older than this.
pub(crate) const RESCAN_AFTER: Duration = Duration::from_secs(30);
/// The wait between batches of one scan.
const BATCH_GAP: Duration = Duration::from_millis(50);
/// The first and the longest retry wait while the namespace cannot be opened.
const OPEN_RETRY_FIRST: Duration = Duration::from_secs(30);
const OPEN_RETRY_MAX: Duration = Duration::from_secs(600);

#[derive(Default)]
pub(crate) struct ImagePasteRecovery {
    storage: Option<ImagePasteStorage>,
    entries: Option<ReadDir>,
    scanning_bytes: usize,
    scanning_count: usize,
    /// The earliest expiry of a receipt this scan kept.
    scanning_next_expiry: Option<Instant>,
    /// When the last scan completed.
    completed: Option<Instant>,
    /// The retry wait after the namespace could not be opened.
    open_retry: Option<Duration>,
    pub retained_bytes: usize,
    pub retained_count: usize,
    pub ready: bool,
}

impl ImagePasteRecovery {
    /// Whether a new upload should ask for a rescan: no scan completed yet,
    /// or the last one is older than [`RESCAN_AFTER`].
    pub(crate) fn stale(&self, now: Instant) -> bool {
        self.completed
            .is_none_or(|completed| now.saturating_duration_since(completed) >= RESCAN_AFTER)
    }

    #[cfg(test)]
    pub(crate) fn at(storage: ImagePasteStorage) -> Self {
        Self { storage: Some(storage), ..Default::default() }
    }

    /// Moves the last complete scan `by` into the past.
    #[cfg(test)]
    pub(crate) fn age(&mut self, by: Duration) {
        self.completed = self.completed.and_then(|completed| completed.checked_sub(by));
    }

    /// Whether a new upload should start a scan now: none is in progress, and
    /// none completed yet (the namespace could not be opened) or the last one
    /// is stale.
    pub(crate) fn wants_scan(&self, now: Instant) -> bool {
        self.entries.is_none() && self.stale(now)
    }

    /// Scans one batch. The wait until the next batch is due, or `None` when
    /// nothing is due until a new upload asks ([`Self::stale`]).
    pub(crate) fn scan(&mut self, active: &HashSet<PathBuf>) -> Option<Duration> {
        if self.entries.is_none() {
            self.scanning_bytes = 0;
            self.scanning_count = 0;
            self.scanning_next_expiry = None;
            if self.storage.is_none() {
                self.storage = ImagePasteStorage::open().ok();
            }
            self.entries = self.storage.as_ref().and_then(|storage| storage.entries().ok());
            if self.entries.is_none() {
                let retry =
                    self.open_retry.map_or(OPEN_RETRY_FIRST, |last| (last * 2).min(OPEN_RETRY_MAX));
                self.open_retry = Some(retry);
                return Some(retry);
            }
            self.open_retry = None;
        }
        for _ in 0..64 {
            match self.entries.as_mut().unwrap().next() {
                Some(Ok(entry)) => {
                    let name = entry.file_name();
                    let Some(suffix) =
                        name.to_str().and_then(|name| name.strip_prefix("cmux-image-"))
                    else {
                        continue;
                    };
                    if suffix.len() != 32
                        || !suffix.bytes().all(|b| b.is_ascii_hexdigit())
                        || active.contains(&entry.path())
                    {
                        continue;
                    }
                    if let Some((deadline, file)) = ImagePasteFile::recover_one(entry.path())
                        && (deadline > Instant::now() || !file.remove_owned())
                    {
                        self.scanning_bytes = self.scanning_bytes.saturating_add(file.size());
                        self.scanning_count = self.scanning_count.saturating_add(1);
                        if deadline > Instant::now() {
                            self.scanning_next_expiry = Some(
                                self.scanning_next_expiry
                                    .map_or(deadline, |next| next.min(deadline)),
                            );
                        }
                    }
                }
                Some(Err(_)) => continue,
                None => {
                    self.entries = None;
                    self.retained_bytes = self.scanning_bytes;
                    self.retained_count = self.scanning_count;
                    self.ready = true;
                    let now = Instant::now();
                    self.completed = Some(now);
                    return self
                        .scanning_next_expiry
                        .map(|expiry| expiry.saturating_duration_since(now));
                }
            }
        }
        // Keep the iterator across batches. Never restart at the same first
        // entries and starve receipts beyond a fixed enumeration cap.
        Some(BATCH_GAP)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::DirBuilderExt;

    #[test]
    fn cloud_image_paste_recovery_continues_across_batches_and_rescans() {
        let mut random = [0u8; 16];
        getrandom::fill(&mut random).unwrap();
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let temporary = std::env::temp_dir().join(format!("image-recovery-test-{suffix}"));
        fs::DirBuilder::new().mode(0o700).create(&temporary).unwrap();
        let storage = ImagePasteStorage::at(&temporary).unwrap();
        let namespace = storage.root().to_owned();
        // Explicitly keep the files to model process death; write no user data.
        let create_expired = |storage: &ImagePasteStorage| {
            let file = ImagePasteFile::create_in(storage, "png").unwrap();
            let directory = file.directory().to_owned();
            let receipt_path = directory.join(".receipt");
            let mut receipt: serde_json::Value =
                serde_json::from_slice(&fs::read(&receipt_path).unwrap()).unwrap();
            receipt["expires"] = serde_json::json!(0);
            fs::write(&receipt_path, serde_json::to_vec(&receipt).unwrap()).unwrap();
            // Read-only recovery handles do not remove anything when dropped.
            let (_, recovered) = ImagePasteFile::recover_one(directory).unwrap();
            file.abandon_for_test();
            drop(recovered);
        };
        for _ in 0..80 {
            create_expired(&storage);
        }
        let mut recovery = ImagePasteRecovery { storage: Some(storage), ..Default::default() };
        assert_eq!(recovery.scan(&HashSet::new()), Some(BATCH_GAP));
        assert!(!recovery.ready);
        assert!(recovery.stale(Instant::now()));
        assert_eq!(fs::read_dir(&namespace).unwrap().count(), 16);
        // Nothing kept: no timed rescan; the next upload asks for one.
        assert_eq!(recovery.scan(&HashSet::new()), None);
        assert!(recovery.ready);
        assert!(!recovery.stale(Instant::now()));
        assert!(recovery.stale(Instant::now() + RESCAN_AFTER));
        assert_eq!(fs::read_dir(&namespace).unwrap().count(), 0);
        create_expired(recovery.storage.as_ref().unwrap());
        assert_eq!(recovery.scan(&HashSet::new()), None);
        assert_eq!(fs::read_dir(&namespace).unwrap().count(), 0);
        drop(recovery);
        fs::remove_dir(namespace).unwrap();
        fs::remove_dir(temporary).unwrap();
    }

    /// p14-energy-077m: a kept receipt schedules the next scan at its expiry,
    /// not on a 30 s period.
    #[test]
    fn a_kept_receipt_schedules_the_next_scan_at_its_expiry() {
        let mut random = [0u8; 16];
        getrandom::fill(&mut random).unwrap();
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let temporary = std::env::temp_dir().join(format!("image-recovery-test-{suffix}"));
        fs::DirBuilder::new().mode(0o700).create(&temporary).unwrap();
        let storage = ImagePasteStorage::at(&temporary).unwrap();
        let namespace = storage.root().to_owned();
        // A live upload of a process that died: its receipt has not expired.
        let file = ImagePasteFile::create_in(&storage, "png").unwrap();
        file.abandon_for_test();
        let mut recovery = ImagePasteRecovery { storage: Some(storage), ..Default::default() };
        let next = recovery.scan(&HashSet::new()).expect("a kept receipt schedules a scan");
        assert!(recovery.ready);
        assert_eq!(recovery.retained_count, 1);
        assert!(next > RESCAN_AFTER && next <= Duration::from_secs(720), "{next:?}");
        drop(recovery);
        fs::remove_dir_all(namespace).unwrap();
        fs::remove_dir_all(temporary).unwrap();
    }
}
