//! An output store segment file (`segments::decode_frames`,
//! output_store/segments.rs): every byte a terminal printed in full
//! persistence mode, read back by a respawn's rebuild and by output reads. A
//! frame cut by a crash or corrupt on disk ends the read, never a panic.
//!
//! The first byte's low bit picks the shape: the rest as a raw file, or as
//! `arbitrary` frames the writer encodes (`segments::encode_frame`), then cut
//! or followed by any bytes. Raw: the frames read re-encode to a file that
//! reads back the same. Written: a file cut at any byte reads exactly the
//! frames that end before the cut; a file with bytes appended reads its
//! frames first.

#![no_main]

use arbitrary::{Arbitrary, Unstructured};
use cmux_tui_core::fuzz_entry::{encode_output_segment_frame, output_segment_frames};
use libfuzzer_sys::fuzz_target;

#[derive(Arbitrary, Debug)]
struct Written {
    frames: Vec<(u64, Vec<u8>)>,
    end: End,
}

#[derive(Arbitrary, Debug)]
enum End {
    Whole,
    Cut(u32),
    Appended(Vec<u8>),
}

/// The file of `frames` and the offset where each frame ends.
fn encode(frames: &[(u64, Vec<u8>)]) -> (Vec<u8>, Vec<usize>) {
    let mut file = Vec::new();
    let mut ends = Vec::with_capacity(frames.len());
    for (start, bytes) in frames {
        match encode_output_segment_frame(*start, bytes) {
            Ok(frame) => file.extend_from_slice(&frame),
            Err(error) => panic!("the writer refuses a frame: {error:#}"),
        }
        ends.push(file.len());
    }
    (file, ends)
}

fuzz_target!(|data: &[u8]| {
    let Some((&shape, rest)) = data.split_first() else {
        return;
    };
    if shape & 1 == 0 {
        let frames = output_segment_frames(rest);
        let (file, _) = encode(&frames);
        assert!(output_segment_frames(&file) == frames, "read frames do not round-trip");
        return;
    }
    let Ok(written) = Written::arbitrary_take_rest(Unstructured::new(rest)) else {
        return;
    };
    let (mut file, ends) = encode(&written.frames);
    match written.end {
        End::Whole => {
            assert!(output_segment_frames(&file) == written.frames, "frames do not read back");
        }
        End::Cut(cut) => {
            let cut = usize::try_from(cut).unwrap_or(usize::MAX) % (file.len() + 1);
            file.truncate(cut);
            let intact = ends.iter().take_while(|end| **end <= cut).count();
            let expected = written.frames.get(..intact).unwrap_or_default();
            assert!(output_segment_frames(&file) == expected, "a cut file reads other frames");
        }
        End::Appended(tail) => {
            file.extend_from_slice(&tail);
            assert!(
                output_segment_frames(&file).starts_with(&written.frames),
                "bytes after the frames change them"
            );
        }
    }
});
