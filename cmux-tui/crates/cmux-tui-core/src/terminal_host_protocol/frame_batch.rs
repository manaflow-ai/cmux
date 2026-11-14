//! Frames written with one vectored write: each frame's header and payload,
//! and a run of queued frames, go to the socket in one `writev` instead of two
//! `write` calls per frame. The bytes on the wire are exactly those of
//! [`super::write_frame`] called once per frame, so a peer of any build reads
//! them the same way.

use std::borrow::Borrow;
use std::io::{self, IoSlice, Write};

use super::{Frame, HEADER_LEN, MAX_FRAME_PAYLOAD, ProtocolError, encode_header};

/// The most frames one [`write_frames`] call is given by a queue drain. Two
/// slices per frame stays far below every platform's `IOV_MAX` (1024).
pub(crate) const MAX_BATCH_FRAMES: usize = 64;

/// The most frame bytes (headers and payloads) a queue drain gathers before
/// it writes. One PTY read is at most 64 KiB, so a batch never holds back a
/// single large frame, and a drain that stops here writes at once.
pub(crate) const MAX_BATCH_BYTES: usize = 256 * 1024;

/// Writes `frames` in order, byte for byte as [`super::write_frame`] writes
/// each one, in as few vectored writes as the writer takes. A frame that
/// cannot be encoded ends the batch: the frames before it are written and
/// flushed, then its error returns, as a run of single writes would do.
pub(crate) fn write_frames<F: Borrow<Frame>>(
    writer: &mut impl Write,
    frames: &[F],
) -> Result<(), ProtocolError> {
    let mut headers: Vec<[u8; HEADER_LEN]> = Vec::with_capacity(frames.len());
    let mut failure = None;
    for frame in frames {
        match encode_header(frame.borrow(), MAX_FRAME_PAYLOAD) {
            Ok(header) => headers.push(header),
            Err(error) => {
                failure = Some(error);
                break;
            }
        }
    }
    let mut slices = Vec::with_capacity(headers.len().saturating_mul(2));
    for (header, frame) in headers.iter().zip(frames) {
        slices.push(IoSlice::new(header));
        let payload = &frame.borrow().payload;
        if !payload.is_empty() {
            slices.push(IoSlice::new(payload));
        }
    }
    write_all_vectored(writer, &mut slices)?;
    writer.flush()?;
    match failure {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

/// `write_all` over several buffers: retries `Interrupted`, resumes after a
/// short write, and fails with `WriteZero` when the writer takes nothing.
fn write_all_vectored(writer: &mut impl Write, slices: &mut [IoSlice<'_>]) -> io::Result<()> {
    let mut slices = slices;
    while !slices.is_empty() {
        match writer.write_vectored(slices) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "failed to write a whole terminal-host frame",
                ));
            }
            Ok(written) => {
                let remaining: usize = slices.iter().map(|slice| slice.len()).sum();
                if written > remaining {
                    return Err(io::Error::other("a writer reported more bytes than it was given"));
                }
                IoSlice::advance_slices(&mut slices, written);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
