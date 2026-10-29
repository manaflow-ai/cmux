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

/// Where a file-medium command's bytes are.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileMedium {
    /// `t=f`: a regular file.
    File,
    /// `t=t`: a temporary file, deleted once read.
    TempFile,
    /// `t=s`: a POSIX shared-memory object, unlinked once read.
    SharedMemory,
}

impl FileMedium {
    fn of(medium: command::Medium) -> Option<Self> {
        match medium {
            command::Medium::File => Some(Self::File),
            command::Medium::TempFile => Some(Self::TempFile),
            command::Medium::SharedMemory => Some(Self::SharedMemory),
            command::Medium::Direct | command::Medium::Unknown => None,
        }
    }

    fn medium(self) -> command::Medium {
        match self {
            Self::File => command::Medium::File,
            Self::TempFile => command::Medium::TempFile,
            Self::SharedMemory => command::Medium::SharedMemory,
        }
    }
}

/// The read one file-medium command asks for: what a deferring rewriter
/// ([`KittyMediaRewriter::deferring`]) hands to the process that may open
/// files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaRequest {
    pub medium: FileMedium,
    /// The command's payload as sent: the base64 path or object name.
    pub name: Vec<u8>,
    /// The `O` key: where the bytes start.
    pub offset: u64,
    /// The `S` key: how many bytes, 0 for the rest.
    pub size: u64,
}

impl MediaRequest {
    /// The bytes, at most `max_bytes`, with every check the rewriter
    /// applies when it reads them itself.
    pub fn read(&self, max_bytes: u64) -> Result<Vec<u8>, MediaRefusal> {
        media::read(self.medium.medium(), &self.name, self.offset, self.size, max_bytes)
    }
}

impl Default for Limits {
    fn default() -> Self {
        Self { max_file_bytes: DEFAULT_MAX_FILE_BYTES, max_held_bytes: 8 * 1024 }
    }
}
