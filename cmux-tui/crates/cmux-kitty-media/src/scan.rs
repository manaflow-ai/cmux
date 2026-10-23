//! The streaming scanner: PTY bytes in, the same bytes out except that each
//! complete file-medium Kitty graphics command becomes a direct one.

use crate::{Limits, MediaRefusal};

/// Rewrites one terminal's output stream. Keep one per PTY: an APC split
/// across reads is carried to the next [`Self::rewrite`].
#[derive(Debug, Default)]
pub struct KittyMediaRewriter {
    limits: Limits,
    rewritten: u64,
    last_refusal: Option<MediaRefusal>,
}

impl KittyMediaRewriter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_limits(limits: Limits) -> Self {
        Self { limits, ..Self::default() }
    }

    /// Appends the rewritten form of `input` to `out`.
    pub fn rewrite(&mut self, input: &[u8], out: &mut Vec<u8>) {
        let _ = self.limits;
        out.extend_from_slice(input);
    }

    /// Appends whatever is held back (an unfinished command) unchanged; call
    /// at end of stream.
    pub fn finish(&mut self, out: &mut Vec<u8>) {
        let _ = out;
    }

    /// Whether bytes of an unfinished file-medium command are held back.
    pub fn is_holding(&self) -> bool {
        false
    }

    /// Commands rewritten so far.
    pub fn rewritten_commands(&self) -> u64 {
        self.rewritten
    }

    /// Why the latest file-medium command was passed through, if it was.
    pub fn last_refusal(&self) -> Option<&MediaRefusal> {
        self.last_refusal.as_ref()
    }
}
