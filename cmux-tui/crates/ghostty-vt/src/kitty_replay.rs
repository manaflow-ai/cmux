//! Kitty image replay after a GHOSTSNP snapshot (snapshot format version 1
//! carries no images): libghostty-vt `ghostty_terminal_kitty_replay_encode`,
//! `ghostty_terminal_kitty_replay_apply` and
//! `ghostty_terminal_kitty_image_generation`.
//!
//! The stream is applied ONLY with [`Terminal::apply_kitty_replay`] (the
//! trusted path), never as PTY output. Its images are already zlib (Kitty
//! `o=z`), so callers do not compress it again.

use crate::terminal::Terminal;
use crate::Result;

/// What [`Terminal::encode_kitty_replay`] wrote.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct KittyReplayStats {
    /// Images transmitted with their pixels.
    pub images: u64,
    /// Placements written.
    pub placements: u64,
    /// Images that a showing placement uses but the byte cap skipped.
    pub skipped_images: u64,
    /// Decoded pixel bytes of the transmitted images (what the cap limits).
    pub image_bytes: u64,
    /// All bytes written.
    pub bytes: u64,
}

impl KittyReplayStats {
    /// Whether the stream recreates anything a viewer could show or must
    /// know it did not get.
    pub fn is_empty(&self) -> bool {
        self.images == 0 && self.placements == 0 && self.skipped_images == 0
    }
}

impl Terminal {
    /// The Kitty image generation: it strictly increases at every change of
    /// the stored images or placements of either screen. Zero means the
    /// image storage never changed. Process-local value.
    pub fn kitty_image_generation(&self) -> Result<u64> {
        // RED: not wired to libghostty-vt yet.
        Ok(0)
    }

    /// Encode the Kitty image replay stream of this terminal: a per-screen
    /// reset, every stored image (pixels for the selected ones, metadata for
    /// the rest), and the placements that show. `max_image_bytes` caps the
    /// decoded pixel bytes of the selected images (newest first). Serialize
    /// it with every other access to the terminal, like
    /// [`Terminal::encode_snapshot`], and call it at the same cut.
    pub fn encode_kitty_replay(&self, max_image_bytes: u64) -> Result<(Vec<u8>, KittyReplayStats)> {
        // RED: not wired to libghostty-vt yet.
        let _ = max_image_bytes;
        Ok((Vec::new(), KittyReplayStats::default()))
    }

    /// Apply a complete stream of [`Terminal::encode_kitty_replay`] through
    /// the trusted path (the viewer side, after the snapshot restore). Fails
    /// with `InvalidValue` when parts were skipped; the valid commands still
    /// ran.
    pub fn apply_kitty_replay(&mut self, stream: &[u8]) -> Result<()> {
        // RED: not wired to libghostty-vt yet.
        let _ = stream;
        Err(crate::Error::NoValue)
    }
}

#[cfg(test)]
#[path = "kitty_replay_tests.rs"]
mod tests;
