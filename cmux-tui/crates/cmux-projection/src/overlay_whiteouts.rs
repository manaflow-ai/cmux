//! The overlay's writes to its whiteouts log ([`crate::whiteouts`]): one append per change, and the
//! whole file written again when the log is due a compaction or an append did not land.

use std::fs;
use std::io::Write as _;
use std::sync::atomic::Ordering;

use super::{Inner, Overlay, io_errno};
use crate::whiteouts::{append_entry, whiteouts_due};

impl Overlay {
    pub(super) fn write_whiteouts(&self, inner: &Inner) -> Result<(), i32> {
        let mut text = String::new();
        for path in &inner.whiteouts {
            text.push_str(path);
            text.push('\0');
        }
        let temp = self.scratch_path();
        let written = fs::write(&temp, text).and_then(|()| fs::rename(&temp, &self.whiteouts_file));
        if written.is_err() {
            let _ = fs::remove_file(&temp);
        }
        self.whiteouts_stale.store(written.is_err(), Ordering::Relaxed);
        if written.is_ok() {
            self.whiteouts_logged.store(inner.whiteouts.len(), Ordering::Relaxed);
        }
        written.map_err(|error| io_errno(&error))
    }

    /// Appends `entries` (`count` whole NUL-ended entries) to the whiteouts log in one write, then
    /// compacts the log when it has grown past its live paths. False when the append did not land
    /// (the caller writes the whole set instead); the log was never torn by it.
    pub(super) fn append_whiteouts(&self, inner: &Inner, entries: &[u8], count: usize) -> bool {
        if self.whiteouts_stale.load(Ordering::Relaxed) {
            return false;
        }
        let appended =
            fs::OpenOptions::new().append(true).create(true).open(&self.whiteouts_file).and_then(
                |mut file| append_entry(&mut file, entries, |file, bytes| file.write_all(bytes)),
            );
        if appended.is_err() {
            return false;
        }
        let logged = self.whiteouts_logged.fetch_add(count, Ordering::Relaxed) + count;
        if whiteouts_due(logged, inner.whiteouts.len()) {
            // The log already says it all; a compaction that fails leaves it as it was.
            let _ = self.write_whiteouts(inner);
        }
        true
    }
}
