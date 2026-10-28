//! `cmux.rd/1` stream carrier (`StreamDeframer`). The input after its first
//! byte is fed in chunks of the size that byte picks; the frames read must
//! not depend on where the chunks end, each frame re-encodes to the bytes it
//! came from, and after an error the deframer stays failed and empty.
#![no_main]

use cmux_rd_proto::{MAX_STREAM_FRAME, StreamDeframer, encode_stream_frame};
use libfuzzer_sys::fuzz_target;

/// The frames read, and whether the deframer failed.
type Read = (Vec<(u8, Vec<u8>)>, bool);

fn read_all<'a>(chunks: impl IntoIterator<Item = &'a [u8]>) -> Read {
    let mut deframer = StreamDeframer::default();
    let mut frames = Vec::new();
    for chunk in chunks {
        deframer.extend(chunk);
        loop {
            match deframer.next_frame() {
                Ok(Some(frame)) => frames.push(frame),
                Ok(None) => break,
                Err(_) => {
                    assert!(deframer.next_frame().is_err());
                    assert_eq!(deframer.buffered(), 0);
                    return (frames, true);
                }
            }
        }
    }
    (frames, false)
}

fuzz_target!(|data: &[u8]| {
    let Some((&step, stream)) = data.split_first() else { return };
    let (frames, failed) = read_all(stream.chunks(usize::from(step).max(1)));
    assert_eq!(read_all([stream]), (frames.clone(), failed));
    let mut encoded = Vec::new();
    for (kind, payload) in &frames {
        assert!(payload.len() <= MAX_STREAM_FRAME);
        encode_stream_frame(*kind, payload, &mut encoded).expect("a frame read back encodes");
    }
    assert_eq!(encoded.as_slice(), &stream[..encoded.len()]);
});
