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
mod tests {
    use super::*;
    use crate::terminal_host_protocol::{MessageKind, PROTOCOL_VERSION};

    /// The writer before vectored writes: header, then payload, then flush.
    fn write_frame_reference(writer: &mut impl Write, frame: &Frame) -> Result<(), ProtocolError> {
        let header = encode_header(frame, MAX_FRAME_PAYLOAD)?;
        writer.write_all(&header)?;
        writer.write_all(&frame.payload)?;
        writer.flush()?;
        Ok(())
    }

    /// A writer that takes at most `step` bytes per call, uses only part of
    /// the slices it is given, and reports `Interrupted` every third call.
    struct ChoppyWriter {
        bytes: Vec<u8>,
        step: usize,
        calls: usize,
        flushes: usize,
    }

    impl ChoppyWriter {
        fn new(step: usize) -> Self {
            Self { bytes: Vec::new(), step, calls: 0, flushes: 0 }
        }

        fn take(&mut self, slices: &[IoSlice<'_>]) -> io::Result<usize> {
            self.calls += 1;
            if self.calls.is_multiple_of(3) {
                return Err(io::ErrorKind::Interrupted.into());
            }
            let mut room = self.step;
            let mut taken = 0;
            for slice in slices {
                let part = slice.len().min(room);
                self.bytes.extend_from_slice(slice.get(..part).unwrap_or_default());
                taken += part;
                room -= part;
                if room == 0 {
                    break;
                }
            }
            Ok(taken)
        }
    }

    impl Write for ChoppyWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.take(&[IoSlice::new(buf)])
        }

        fn write_vectored(&mut self, bufs: &[IoSlice<'_>]) -> io::Result<usize> {
            self.take(bufs)
        }

        fn flush(&mut self) -> io::Result<()> {
            self.flushes += 1;
            Ok(())
        }
    }

    fn frame(kind: MessageKind, payload: Vec<u8>, sequence: u64) -> Frame {
        let mut frame = Frame::new(kind, payload);
        frame.sequence = sequence;
        frame.flags = (sequence % 2) as u32;
        frame.request_id = sequence.wrapping_mul(7);
        frame
    }

    fn adversarial_frames() -> Vec<Vec<Frame>> {
        let non_utf8: Vec<u8> = (0..=255u8).rev().collect();
        let huge = vec![0x1b; 300 * 1024];
        vec![
            Vec::new(),
            vec![frame(MessageKind::Bell, Vec::new(), 1)],
            vec![frame(MessageKind::Output, b"x".to_vec(), 2)],
            vec![
                frame(MessageKind::Output, non_utf8.clone(), 3),
                frame(MessageKind::Colors, Vec::new(), 4),
                frame(MessageKind::Output, vec![b'a'; 65536], 5),
                frame(MessageKind::Title, "t\u{e9}".as_bytes().to_vec(), 6),
            ],
            vec![frame(MessageKind::Output, huge, 7), frame(MessageKind::Exit, non_utf8, 8)],
            (0..MAX_BATCH_FRAMES as u64)
                .map(|n| frame(MessageKind::Output, vec![n as u8; n as usize], n))
                .collect(),
        ]
    }

    #[test]
    fn a_batch_writes_the_bytes_of_one_write_frame_per_frame_through_every_short_write() {
        for frames in adversarial_frames() {
            let mut expected = Vec::new();
            for frame in &frames {
                write_frame_reference(&mut expected, frame).expect("reference write");
            }
            for step in [1, 2, 7, 31, 32, 33, 1000, 4096, 65536, usize::MAX] {
                let mut writer = ChoppyWriter::new(step);
                write_frames(&mut writer, &frames).expect("batch write");
                assert_eq!(writer.bytes, expected, "step {step}, {} frames", frames.len());
                assert_eq!(writer.flushes, 1);
            }
        }
    }

    #[test]
    fn a_whole_batch_goes_out_in_one_vectored_write_when_the_writer_takes_it() {
        let frames = adversarial_frames().swap_remove(3);
        let mut writer = ChoppyWriter::new(usize::MAX);
        write_frames(&mut writer, &frames).expect("batch write");
        assert_eq!(writer.calls, 1);
    }

    #[test]
    fn a_frame_that_cannot_be_encoded_ends_the_batch_after_the_frames_before_it() {
        let mut bad = frame(MessageKind::Output, b"bad".to_vec(), 2);
        bad.version = 0;
        let good = frame(MessageKind::Output, b"good".to_vec(), 1);
        let after = frame(MessageKind::Output, b"after".to_vec(), 3);
        let mut expected = Vec::new();
        write_frame_reference(&mut expected, &good).expect("reference write");
        let reference_error = write_frame_reference(&mut Vec::new(), &bad).unwrap_err();

        let mut writer = ChoppyWriter::new(5);
        let error = write_frames(&mut writer, &[good, bad, after]).unwrap_err();
        assert_eq!(writer.bytes, expected);
        assert_eq!(error.to_string(), reference_error.to_string());
    }

    #[test]
    fn a_writer_that_takes_nothing_fails_the_batch() {
        struct Full;
        impl Write for Full {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                Ok(0)
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let frames = [frame(MessageKind::Output, b"x".to_vec(), 1)];
        let error = write_frames(&mut Full, &frames).unwrap_err();
        assert!(
            matches!(error, ProtocolError::Io(ref io) if io.kind() == io::ErrorKind::WriteZero)
        );
    }

    #[test]
    fn frames_behind_an_arc_write_the_same_bytes() {
        let frames = adversarial_frames().swap_remove(3);
        let shared: Vec<std::sync::Arc<Frame>> =
            frames.iter().cloned().map(std::sync::Arc::new).collect();
        let mut plain = Vec::new();
        write_frames(&mut plain, &frames).expect("plain");
        let mut behind_arc = Vec::new();
        write_frames(&mut behind_arc, &shared).expect("arc");
        assert_eq!(plain, behind_arc);
        assert_eq!(frames.first().map(|frame| frame.version), Some(PROTOCOL_VERSION));
    }
}
