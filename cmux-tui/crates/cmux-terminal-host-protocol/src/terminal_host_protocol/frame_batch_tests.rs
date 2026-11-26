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
    assert!(matches!(error, ProtocolError::Io(ref io) if io.kind() == io::ErrorKind::WriteZero));
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
