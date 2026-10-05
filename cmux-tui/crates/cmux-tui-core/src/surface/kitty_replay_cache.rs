//! The Kitty image replay of one terminal for snapshot viewers
//! (`terminal-snapshot-images-v1`).

#[cfg(test)]
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use ghostty_vt::Terminal;

use super::SnapshotImages;
use crate::SurfaceId;

/// The last Kitty replay of one terminal, keyed by its image generation
/// and the cap: viewers of the terminal and later READYs at the same
/// generation reuse the bytes, so only the first READY after an image change
/// pays the encode under the terminal lock. Used only under the terminal
/// lock; dropped with the terminal.
#[derive(Default)]
pub(crate) struct KittyReplayCache {
    last: Mutex<Option<CachedReplay>>,
    /// Encodes run (tests count them).
    #[cfg(test)]
    encodes: AtomicU64,
}

struct CachedReplay {
    generation: u64,
    max_image_bytes: u64,
    /// `None`: the replay holds no image, placement or skipped image.
    images: Option<Arc<SnapshotImages>>,
}

impl KittyReplayCache {
    /// The Kitty replay of `term` with at most `max_image_bytes` of decoded
    /// pixels, or `None` when the terminal has no images (nothing is encoded
    /// while the image storage never changed). The caller holds the terminal
    /// lock of the READY encode it belongs to. Encodes at most once per
    /// (image generation, cap); a failed encode is not cached.
    pub(crate) fn images_locked(
        &self,
        term: &Terminal,
        max_image_bytes: u64,
        surface: SurfaceId,
    ) -> Option<Arc<SnapshotImages>> {
        let generation = match term.kitty_image_generation() {
            // NoValue: Kitty graphics are not built in.
            Ok(0) | Err(_) => return None,
            Ok(generation) => generation,
        };
        let mut last = self.last.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(cached) = last.as_ref()
            && (cached.generation, cached.max_image_bytes) == (generation, max_image_bytes)
        {
            return cached.images.clone();
        }
        // The generation changed: the old bytes no longer apply.
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
        *last = Some(CachedReplay { generation, max_image_bytes, images: images.clone() });
        images
    }

    /// Kitty replay encodes run so far.
    #[cfg(test)]
    pub(crate) fn encodes(&self) -> u64 {
        self.encodes.load(Ordering::Relaxed)
    }
}
