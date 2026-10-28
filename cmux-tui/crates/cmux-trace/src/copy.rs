//! Copying a live ring into a private one with the decode protocol: the heap ring into its file
//! ("Heap, then file", steps 2 and 3) and a snapshot for crash and hang reports. Writers may run
//! on the source; nothing but this copy touches the destination until it is published.

use std::sync::atomic::{Ordering, fence};

use crate::layout::{
    ENTRY_PUBLISHED, HEADER_BYTES, HEADER_U32_PAIRS, NAME_ENTRY_BYTES, RECORD_BYTES,
    RECORDS_PER_CHUNK, THREAD_ENTRY_BYTES, THREAD_EXITED, THREAD_LIVE, lap_of, off,
};
use crate::ring::Ring;

/// The source cursors the tables were copied under (step 3).
pub(crate) struct Copied {
    pub chunk_cursor: u64,
}

/// Copies `src` into `dst` (same layout, `dst` private): the header as it reads now, every chunk,
/// then the name and thread entries below the cursors loaded after the chunks, and those cursors.
/// The chunks go first: a thread or a name is published before its first record, so each copied
/// chunk names only entries the table copy finds.
pub(crate) fn copy_ring(src: &Ring, dst: &Ring) -> Copied {
    debug_assert_eq!(src.layout(), dst.layout());
    for at in (0..HEADER_BYTES).step_by(8) {
        if HEADER_U32_PAIRS.contains(&at) {
            for half in [at, at + 4] {
                dst.a32(half).store(src.a32(half).load(Ordering::Relaxed), Ordering::Relaxed);
            }
        } else {
            dst.a64(at).store(src.a64(at).load(Ordering::Relaxed), Ordering::Relaxed);
        }
    }
    for chunk in 0..src.layout().sizes.chunk_count as usize {
        copy_chunk(src, dst, src.layout().chunk(chunk));
    }
    let name_cursor = src.a32(off::NAME_CURSOR).load(Ordering::Acquire);
    let thread_cursor = src.a32(off::THREAD_CURSOR).load(Ordering::Acquire);
    let chunk_cursor = src.a64(off::CHUNK_CURSOR).load(Ordering::Acquire);
    let sizes = src.layout().sizes;
    for index in 1..name_cursor.min(sizes.name_capacity) as usize {
        copy_entry(src, dst, src.layout().name_entry(index), NAME_ENTRY_BYTES, |state| {
            state == ENTRY_PUBLISHED
        });
    }
    for index in 0..thread_cursor.min(sizes.thread_capacity) as usize {
        // Exited entries too: copied chunks of an exited thread still name it.
        copy_entry(src, dst, src.layout().thread_entry(index), THREAD_ENTRY_BYTES, |state| {
            state == THREAD_LIVE || state == THREAD_EXITED
        });
    }
    dst.a32(off::NAME_CURSOR).store(name_cursor, Ordering::Relaxed);
    dst.a32(off::THREAD_CURSOR).store(thread_cursor, Ordering::Relaxed);
    dst.a64(off::CHUNK_CURSOR).store(chunk_cursor, Ordering::Relaxed);
    Copied { chunk_cursor }
}

/// One entry (a name or a thread): kept when its first two u32 words (the state, and a name's
/// id or a thread's generation) read the same before and after the copy and `keep` accepts the
/// state. Each word is read at the width its writer stores it.
fn copy_entry(src: &Ring, dst: &Ring, at: usize, bytes: usize, keep: impl Fn(u32) -> bool) {
    let state = src.a32(at).load(Ordering::Acquire);
    let second = src.a32(at + 4).load(Ordering::Relaxed);
    if !keep(state) {
        return;
    }
    let mut words = [0u64; 8];
    for (index, word) in words.iter_mut().enumerate().take(bytes / 8).skip(1) {
        *word = src.a64(at + 8 * index).load(Ordering::Relaxed);
    }
    fence(Ordering::Acquire);
    if src.a32(at).load(Ordering::Relaxed) != state
        || src.a32(at + 4).load(Ordering::Relaxed) != second
    {
        return;
    }
    for (index, word) in words.iter().enumerate().take(bytes / 8).skip(1) {
        dst.a64(at + 8 * index).store(*word, Ordering::Relaxed);
    }
    dst.a32(at + 4).store(second, Ordering::Relaxed);
    dst.a32(at).store(state, Ordering::Release);
}

/// One chunk with the decode protocol: a slot whose two `seq` reads differ is stored with `seq` 0,
/// a chunk taken over while it was read is stored with `lap_seq` 0, and an odd (owned) `lap_seq`
/// is stored complete: the copy has no owner, and its published slots are whole.
fn copy_chunk(src: &Ring, dst: &Ring, at: usize) {
    let first = src.a64(at + off::C_LAP_SEQ).load(Ordering::Acquire);
    if first == 0 {
        return;
    }
    for slot in 1..=RECORDS_PER_CHUNK as usize {
        let record = at + slot * RECORD_BYTES;
        let seq = src.a32(record + off::R_SEQ).load(Ordering::Acquire);
        let words = [
            src.a64(record + off::R_T_NS).load(Ordering::Relaxed),
            u64::from(src.a32(record + off::R_META).load(Ordering::Relaxed)),
            src.a64(record + off::R_ARG0).load(Ordering::Relaxed),
            src.a64(record + off::R_ARG1).load(Ordering::Relaxed),
        ];
        fence(Ordering::Acquire);
        if src.a32(record + off::R_SEQ).load(Ordering::Relaxed) != seq {
            continue;
        }
        dst.a64(record + off::R_T_NS).store(words[0], Ordering::Relaxed);
        dst.a32(record + off::R_META).store(words[1] as u32, Ordering::Relaxed);
        dst.a64(record + off::R_ARG0).store(words[2], Ordering::Relaxed);
        dst.a64(record + off::R_ARG1).store(words[3], Ordering::Relaxed);
        dst.a32(record + off::R_SEQ).store(seq, Ordering::Relaxed);
    }
    fence(Ordering::Acquire);
    let thread = src.a32(at + off::C_THREAD).load(Ordering::Relaxed);
    let generation = src.a32(at + off::C_GENERATION).load(Ordering::Relaxed);
    let published = src.a32(at + off::C_PUBLISHED).load(Ordering::Relaxed);
    let second = src.a64(at + off::C_LAP_SEQ).load(Ordering::Relaxed);
    if lap_of(second) != lap_of(first) {
        return;
    }
    dst.a32(at + off::C_THREAD).store(thread, Ordering::Relaxed);
    dst.a32(at + off::C_GENERATION).store(generation, Ordering::Relaxed);
    dst.a32(at + off::C_PUBLISHED).store(published, Ordering::Relaxed);
    dst.a64(at + off::C_LAP_SEQ).store(first + (first & 1), Ordering::Release);
}

/// The ring's bytes as a file of it would read: every record whole or absent. Allocates.
pub(crate) fn snapshot(src: &Ring) -> Vec<u8> {
    let copy = Ring::on_heap(*src.layout());
    copy_ring(src, &copy);
    copy.bytes().to_vec()
}
