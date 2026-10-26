//! The block a PTY's attach output is cut from: one shared buffer per run of
//! reads, so a chunk every viewer holds costs no allocation of its own.

use bytes::{Bytes, BytesMut};

/// Capacity of a fresh block; a longer read gets a block of its own length.
pub(in crate::surface) const OUTPUT_ARENA_BLOCK_BYTES: usize = 16 * 1024;

/// Output chunks for one PTY's viewers, cut from a reference-counted block.
///
/// A chunk is a slice of the block, so cloning it for each viewer only bumps
/// the block's count. When every chunk of a full block is gone, the block is
/// reused in place; only a block a viewer still holds is replaced. Chromium's
/// network service reads into the data pipe's buffer the same way
/// (`BeginWriteData` in services/network/url_loader.cc) instead of
/// allocating a buffer per read. A viewer's backlog counts a chunk's length,
/// so a stuck viewer can keep up to one uncounted block per queued frame
/// (`ATTACH_STREAM_CAPACITY` x this block size) alive.
#[derive(Default)]
pub(in crate::surface) struct OutputArena {
    block: BytesMut,
}

impl OutputArena {
    /// `bytes` as a chunk every viewer can share.
    pub(in crate::surface) fn chunk(&mut self, bytes: &[u8]) -> Bytes {
        if bytes.is_empty() {
            return Bytes::new();
        }
        if self.block.capacity() < bytes.len() && !self.block.try_reclaim(bytes.len()) {
            self.block = BytesMut::with_capacity(bytes.len().max(OUTPUT_ARENA_BLOCK_BYTES));
        }
        self.block.extend_from_slice(bytes);
        self.block.split().freeze()
    }

    /// Drop the block once no viewer is left to cut chunks for.
    pub(in crate::surface) fn release(&mut self) {
        self.block = BytesMut::new();
    }
}
