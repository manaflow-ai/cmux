//! The Kitty image replay of one terminal for snapshot viewers
//! (`terminal-snapshot-images-v1`).

#[cfg(test)]
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use ghostty_vt::Terminal;

use super::SnapshotImages;
use crate::SurfaceId;

/// The last Kitty replay of one terminal, keyed by the cut (the snapshot
/// stream's grid generation and byte offset), the Kitty image generation and
/// the cap: every viewer that gets a READY at the same cut reuses the bytes,
/// so the encode runs under the terminal lock once per cut, not once per
/// viewer. The image generation alone is not a valid key: output that
/// scrolls moves the placements' rows in the stream without changing it.
/// Used only under the terminal lock; dropped with the terminal.
#[derive(Default)]
pub(crate) struct KittyReplayCache {
    last: Mutex<Option<CachedReplay>>,
    /// Encodes run (tests count them).
    #[cfg(test)]
    encodes: AtomicU64,
}

#[derive(PartialEq, Eq)]
struct ReplayKey {
    /// `(grid generation, offset)` of the snapshot stream.
    cut: (u64, u64),
    image_generation: u64,
    max_image_bytes: u64,
}

struct CachedReplay {
    key: ReplayKey,
    /// `None`: the replay holds no image, placement or skipped image.
    images: Option<Arc<SnapshotImages>>,
}

impl KittyReplayCache {
    /// The Kitty replay of `term` with at most `max_image_bytes` of decoded
    /// pixels, or `None` when the terminal has no images (nothing is encoded
    /// while the image storage never changed). The caller holds the terminal
    /// lock of the READY encode it belongs to, and `cut` is that READY's
    /// stream position. Encodes at most once per key; a failed encode is not
    /// cached.
    pub(crate) fn images_locked(
        &self,
        term: &Terminal,
        cut: (u64, u64),
        max_image_bytes: u64,
        surface: SurfaceId,
    ) -> Option<Arc<SnapshotImages>> {
        let image_generation = match term.kitty_image_generation() {
            // NoValue: Kitty graphics are not built in.
            Ok(0) | Err(_) => return None,
            Ok(generation) => generation,
        };
        let key = ReplayKey { cut, image_generation, max_image_bytes };
        let mut last = self.last.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(cached) = last.as_ref().filter(|cached| cached.key == key) {
            return cached.images.clone();
        }
        // Another cut or image change: the old bytes no longer apply.
        *last = None;
        #[cfg(test)]
        self.encodes.fetch_add(1, Ordering::Relaxed);
        let images = match term.encode_kitty_replay(max_image_bytes) {
            Ok((data, stats)) if !stats.is_empty() => {
                Some(Arc::new(SnapshotImages { data, stats }))
            }
            Ok(_) => None,
            Err(error) => {
                eprintln!("cmux-tui: surface {surface} snapshot images not encoded: {error}");
                return None;
            }
        };
        *last = Some(CachedReplay { key, images: images.clone() });
        images
    }

    /// Kitty replay encodes run so far.
    #[cfg(test)]
    pub(crate) fn encodes(&self) -> u64 {
        self.encodes.load(Ordering::Relaxed)
    }
}
