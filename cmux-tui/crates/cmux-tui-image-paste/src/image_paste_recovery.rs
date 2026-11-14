//! Bounded recurring recovery; a busy namespace cannot permanently hide an upload.

use std::collections::HashSet;
use std::fs::ReadDir;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use crate::image_paste_file::{ImagePasteFile, WallClock};
use crate::image_paste_storage::ImagePasteStorage;

#[derive(Default)]
pub(crate) struct ImagePasteRecovery {
    storage: Option<ImagePasteStorage>,
    entries: Option<ReadDir>,
    scanning_count: usize,
    clock: WallClock,
    pub retained_count: usize,
    pub ready: bool,
}

impl ImagePasteRecovery {
    /// A sweeper over `storage`, as another daemon sharing it would run one.
    #[cfg(test)]
    pub(crate) fn with_storage(storage: ImagePasteStorage, clock: WallClock) -> Self {
        Self { storage: Some(storage), clock, ..Default::default() }
    }

    pub(crate) fn scan(&mut self, active: &HashSet<PathBuf>) -> Duration {
        if self.entries.is_none() {
            self.scanning_count = 0;
            if self.storage.is_none() {
                self.storage = ImagePasteStorage::open().ok();
            }
            self.entries = self.storage.as_ref().and_then(|storage| storage.entries().ok());
            if self.entries.is_none() {
                return Duration::from_secs(30);
            }
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
                    if let Some((deadline, file)) =
                        ImagePasteFile::recover_one(entry.path(), self.clock.now())
                        && (deadline > Instant::now()
                            || !file.claim_for_removal()
                            || !file.remove_owned())
                    {
                        self.scanning_count = self.scanning_count.saturating_add(1);
                    }
                }
                Some(Err(_)) => continue,
                None => {
                    self.entries = None;
                    self.retained_count = self.scanning_count;
                    self.ready = true;
                    return Duration::from_secs(30);
                }
            }
        }
        // Keep the iterator across batches. Never restart at the same first
        // entries and starve receipts beyond a fixed enumeration cap.
        Duration::from_millis(50)
    }
}

#[cfg(test)]
mod tests;
