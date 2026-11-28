//! The writer the TUI draws its frames into: the host terminal's output
//! (stdout), as the ratatui backend's writer.

use std::io::{BufWriter, Write};

/// Room for a whole frame: a full 300x100 screen of styled cells is about
/// 200 KiB of escapes and text. A larger frame still goes out whole, in
/// writes of this size.
const FRAME_BUFFER_BYTES: usize = 256 * 1024;

/// The host terminal's output as the TUI's frames go to it: buffered so a
/// frame leaves in one write when ratatui flushes at the end of the draw,
/// not in 1 KiB pieces as std's line-buffered stdout sends it. Every other
/// writer to stdout writes under the stdout lock after the draw has
/// flushed, so nothing it writes can pass a frame still held here.
pub(super) fn host_frame_writer<W: Write>(out: W) -> BufWriter<W> {
    BufWriter::with_capacity(FRAME_BUFFER_BYTES, out)
}

#[cfg(test)]
#[path = "host_frame_writer_tests.rs"]
mod tests;
