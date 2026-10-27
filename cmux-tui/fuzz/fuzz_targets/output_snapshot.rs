//! An output store snapshot file (`snapshot::decode`, output_store/snapshot.rs):
//! the screen a respawn after a lost host or a reboot starts with, read back
//! from disk, where it may be cut or corrupt. A bad file must read as
//! nothing, never a panic.
//!
//! The first byte's low bit picks the shape: the rest as a raw file, or as
//! `arbitrary` values the writer encodes (`snapshot::encode`), optionally cut
//! or with bytes appended. What the decoder accepts holds a non-empty replay
//! of at most 4 MiB, and the writer's file of it reads back the same.

#![no_main]

use arbitrary::{Arbitrary, Unstructured};
use cmux_tui_core::fuzz_entry::{OutputSnapshot, encode_output_snapshot, output_snapshot};
use libfuzzer_sys::fuzz_target;

/// `MAX_SNAPSHOT_REPLAY_BYTES` in output_store/snapshot.rs.
const MAX_REPLAY_BYTES: usize = 4 * 1024 * 1024;

#[derive(Arbitrary, Debug)]
struct Written {
    generation: String,
    cols: u16,
    rows: u16,
    replay: Vec<u8>,
    stream_end: u64,
    written_at_ms: u64,
    cut: Option<u16>,
    appended: Vec<u8>,
}

fn check_accepted(snapshot: &OutputSnapshot) {
    assert!(!snapshot.replay.is_empty(), "an accepted snapshot has an empty replay");
    assert!(snapshot.replay.len() <= MAX_REPLAY_BYTES, "an accepted snapshot is over its cap");
    let file = match encode_output_snapshot(snapshot, 0, 0) {
        Ok(file) => file,
        Err(error) => panic!("an accepted snapshot does not encode: {error:#}"),
    };
    assert!(output_snapshot(&file).as_ref() == Some(snapshot), "a snapshot does not round-trip");
}

fuzz_target!(|data: &[u8]| {
    let Some((&shape, rest)) = data.split_first() else {
        return;
    };
    if shape & 1 == 0 {
        if let Some(snapshot) = output_snapshot(rest) {
            check_accepted(&snapshot);
        }
        return;
    }
    let Ok(written) = Written::arbitrary_take_rest(Unstructured::new(rest)) else {
        return;
    };
    let snapshot = OutputSnapshot {
        generation: written.generation,
        cols: written.cols,
        rows: written.rows,
        replay: written.replay,
    };
    let Ok(mut file) = encode_output_snapshot(&snapshot, written.stream_end, written.written_at_ms)
    else {
        return;
    };
    let whole = written.cut.is_none() && written.appended.is_empty();
    if let Some(cut) = written.cut {
        file.truncate(usize::from(cut));
    }
    file.extend_from_slice(&written.appended);
    let read = output_snapshot(&file);
    if let Some(read) = &read {
        check_accepted(read);
    }
    if whole && !snapshot.replay.is_empty() {
        assert!(read == Some(snapshot), "the writer's snapshot file does not read back");
    }
});
