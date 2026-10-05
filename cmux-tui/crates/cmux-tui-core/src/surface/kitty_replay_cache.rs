//! The Kitty image replay of one terminal for snapshot viewers
//! (`terminal-snapshot-images-v1`).

use std::sync::Arc;
#[cfg(test)]
use std::sync::atomic::{AtomicU64, Ordering};

use ghostty_vt::Terminal;

use super::SnapshotImages;
use crate::SurfaceId;

/// Per-terminal state of the Kitty replay encode. Used only under the
/// terminal lock.
#[derive(Default)]
pub(crate) struct KittyReplayCache {
    /// Encodes run (tests count them).
    #[cfg(test)]
    encodes: AtomicU64,
}

impl KittyReplayCache {
    /// The Kitty replay of `term` with at most `max_image_bytes` of decoded
    /// pixels, or `None` when the terminal has no images (nothing is encoded
    /// while the image storage never changed). The caller holds the terminal
    /// lock of the READY encode it belongs to.
    pub(crate) fn images_locked(
        &self,
        term: &Terminal,
        max_image_bytes: u64,
        surface: SurfaceId,
    ) -> Option<Arc<SnapshotImages>> {
        match term.kitty_image_generation() {
            // NoValue: Kitty graphics are not built in.
            Ok(0) | Err(_) => return None,
            Ok(_) => {}
        }
        #[cfg(test)]
        self.encodes.fetch_add(1, Ordering::Relaxed);
        match term.encode_kitty_replay(max_image_bytes) {
            Ok((data, stats)) if !stats.is_empty() => Some(Arc::new(SnapshotImages { data, stats })),
            Ok(_) => None,
            Err(error) => {
                eprintln!("cmux-tui: surface {surface} snapshot images not encoded: {error}");
                None
            }
        }
    }

    /// Kitty replay encodes run so far.
    #[cfg(test)]
    pub(crate) fn encodes(&self) -> u64 {
        self.encodes.load(Ordering::Relaxed)
    }
}
