//! The fault interface: how the machine asks for bytes it does not have.
//!
//! This module does no I/O. The product implements [`Source`] over the existing authenticated
//! link between the Mac and the machine; tests implement it in memory.

use crate::manifest::{Stat, Version};

/// One range of one file the machine wants.
///
/// It names the path and the version the machine believes, never a manifest index, so the Mac
/// can check both against the file as it is now before it answers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Want {
    /// The path relative to the projected folder's root, components joined with `/`.
    pub path: String,
    /// The size and times the machine's manifest has for the file.
    pub version: Version,
    /// The first byte wanted.
    pub offset: u64,
    /// How many bytes are wanted. The answer has exactly this many unless the file changed.
    pub len: u32,
}

/// The answer to one [`Want`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Got {
    /// The bytes of the range, for the version asked for.
    Bytes(Vec<u8>),
    /// The file no longer matches the version asked for; this is its stat now.
    Changed(Stat),
    /// The path no longer exists on the Mac.
    Gone,
    /// The path exists, but its bytes stay on the Mac.
    Withheld,
    /// The Mac cannot be reached right now.
    Away,
    /// Anything else went wrong for this one request.
    Failed(String),
}

/// Answers faults. Implementations must answer every want, in order, in one `Vec`.
///
/// `fetch` may block for a round trip; it is called from many threads at once.
pub trait Source: Send + Sync {
    fn fetch(&self, wants: &[Want]) -> Vec<Got>;
}
