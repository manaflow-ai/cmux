//! Kitty graphics file media for terminals whose viewer runs elsewhere.
//!
//! A program can send a Kitty graphics image as a path instead of its bytes:
//! `t=f` (a file), `t=t` (a temporary file the terminal deletes after
//! reading) or `t=s` (a POSIX shared-memory object). The path names a file on
//! the machine where the program runs, which a viewer on another machine
//! cannot open. [`KittyMediaRewriter`] runs where the PTY is read (the
//! terminal host, next to the program): it reads the file there and rewrites
//! the command into a direct transmission (`t=d`) chunked into 4096-byte
//! base64 pieces, so every consumer of the stream (the host's own terminal,
//! the journal, every viewer) sees in-band image data.
//!
//! Everything else passes through untouched. The scanner only looks for
//! `ESC _ G`, holds back nothing but the control data and path of a
//! file-medium command, and never holds a direct upload's payload.
//! A command it cannot serve (a missing or unsafe file, a cancelled APC, an
//! oversized path) passes through unchanged, so the terminal answers it
//! exactly as before and programs such as `kitten icat` fall back to direct
//! transmission.

mod command;
mod media;
mod scan;

pub use media::MediaRefusal;
pub use scan::KittyMediaRewriter;

/// Base64 characters of image data in one chunk, the Kitty protocol maximum.
pub const CHUNK_BASE64_BYTES: usize = 4096;

/// Bounds of the rewriter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// Largest file payload read for one command; a larger one passes through.
    pub max_file_bytes: u64,
    /// Largest control data plus path a file-medium command may hold back
    /// before it is passed through unchanged.
    pub max_held_bytes: usize,
}

/// Matches the terminal's own per-image byte cap (ghostty-vt
/// `MAX_KITTY_IMAGE_BYTES`).
pub const DEFAULT_MAX_FILE_BYTES: u64 = 10_000_000;

impl Default for Limits {
    fn default() -> Self {
        Self { max_file_bytes: DEFAULT_MAX_FILE_BYTES, max_held_bytes: 8 * 1024 }
    }
}
