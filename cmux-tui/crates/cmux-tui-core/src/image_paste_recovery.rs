//! Bounded recurring recovery; a busy namespace cannot permanently hide an upload.

use std::collections::HashSet;
use std::fs::ReadDir;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use crate::image_paste_file::ImagePasteFile;
use crate::image_paste_storage::ImagePasteStorage;

#[derive(Default)]
pub(crate) struct ImagePasteRecovery {
    storage: Option<ImagePasteStorage>,
    entries: Option<ReadDir>,
    scanning_bytes: usize,
    scanning_count: usize,
    pub retained_bytes: usize,
    pub retained_count: usize,
    pub ready: bool,
}

impl ImagePasteRecovery {
    pub(crate) fn scan(&mut self, active: &HashSet<PathBuf>) -> Duration {
        if self.entries.is_none() {
            self.scanning_bytes = 0;
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
                    if let Some((deadline, file)) = ImagePasteFile::recover_one(entry.path())
                        && (deadline > Instant::now() || !file.remove_owned())
                    {
                        self.scanning_bytes = self.scanning_bytes.saturating_add(file.size());
                        self.scanning_count = self.scanning_count.saturating_add(1);
                    }
                }
                Some(Err(_)) => continue,
                None => {
                    self.entries = None;
                    self.retained_bytes = self.scanning_bytes;
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
        assert_eq!(recovery.scan(&HashSet::new()), Duration::from_millis(50));
        assert!(!recovery.ready);
        assert_eq!(fs::read_dir(&namespace).unwrap().count(), 16);
        assert_eq!(recovery.scan(&HashSet::new()), Duration::from_secs(30));
        assert!(recovery.ready);
        assert_eq!(fs::read_dir(&namespace).unwrap().count(), 0);
        create_expired(recovery.storage.as_ref().unwrap());
        assert_eq!(recovery.scan(&HashSet::new()), Duration::from_secs(30));
        assert_eq!(fs::read_dir(&namespace).unwrap().count(), 0);
        drop(recovery);
        fs::remove_dir(namespace).unwrap();
        fs::remove_dir(temporary).unwrap();
    }
}
