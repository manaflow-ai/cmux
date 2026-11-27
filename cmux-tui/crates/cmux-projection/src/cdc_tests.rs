use super::*;

use std::collections::HashSet;

/// Bytes that do not repeat (xorshift), so every cut comes from the content.
fn noise(len: usize, seed: u64) -> Vec<u8> {
    let mut state = seed | 1;
    (0..len)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state.to_le_bytes()[0]
        })
        .collect()
}

fn chunks<'a>(params: &Params, data: &'a [u8]) -> Vec<&'a [u8]> {
    spans(params, data).into_iter().map(|(at, len)| &data[at..at + len]).collect()
}

/// The share of `after`'s bytes in chunks `before` also has.
fn reused(params: &Params, before: &[u8], after: &[u8]) -> f64 {
    let old: HashSet<&[u8]> = chunks(params, before).into_iter().collect();
    let same: usize =
        chunks(params, after).into_iter().filter(|c| old.contains(c)).map(<[u8]>::len).sum();
    same as f64 / after.len() as f64
}

#[test]
fn spans_cover_the_bytes_within_bounds() {
    let data = noise(5 * 1024 * 1024 + 17, 7);
    let spans = spans(&PROJECTION, &data);
    let mut at = 0;
    for (index, (offset, len)) in spans.iter().enumerate() {
        assert_eq!(*offset, at);
        assert!(*len <= PROJECTION.max);
        if index + 1 < spans.len() {
            assert!(*len > PROJECTION.min, "chunk {index} is {len} bytes");
        }
        at += len;
    }
    assert_eq!(at, data.len());
    // Near the 64 KiB average: normalized chunking keeps it within a factor of 2.
    let average = data.len() / spans.len();
    assert!((32 * 1024..128 * 1024).contains(&average), "average {average}");
}

#[test]
fn small_and_empty_inputs_are_one_chunk_or_none() {
    assert!(spans(&PROJECTION, &[]).is_empty());
    let small = noise(PROJECTION.min, 3);
    assert_eq!(spans(&PROJECTION, &small), vec![(0, small.len())]);
}

#[test]
fn the_same_bytes_cut_the_same_way() {
    let data = noise(2 * 1024 * 1024, 11);
    assert_eq!(spans(&PROJECTION, &data), spans(&PROJECTION, &data.clone()));
}

#[test]
fn an_insert_moves_only_the_cuts_near_it() {
    let before = noise(4 * 1024 * 1024, 21);
    for (at, inserted) in [(0usize, 1usize), (1_234_567, 100), (3 * 1024 * 1024, 7_000)] {
        let mut after = before.clone();
        after.splice(at..at, noise(inserted, at as u64 + 5));
        // Every cut past the insert's chunk is the old cut shifted by the insert.
        let old: HashSet<usize> = spans(&PROJECTION, &before)
            .iter()
            .map(|(o, l)| o + l)
            .filter(|end| *end > at)
            .collect();
        let new: HashSet<usize> = spans(&PROJECTION, &after)
            .iter()
            .map(|(o, l)| o + l)
            .filter(|end| *end > at + inserted + PROJECTION.max)
            .collect();
        assert!(new.iter().all(|end| old.contains(&(end - inserted))), "insert at {at}");
        let share = reused(&PROJECTION, &before, &after);
        assert!(share > 0.9, "insert of {inserted} at {at}: {share:.3} reused");
    }
}

#[test]
fn a_delete_and_an_overwrite_keep_the_rest() {
    let before = noise(3 * 1024 * 1024, 31);
    let mut deleted = before.clone();
    deleted.drain(500_000..500_300);
    assert!(reused(&PROJECTION, &before, &deleted) > 0.9);
    let mut overwritten = before.clone();
    overwritten[2_000_000..2_000_010].copy_from_slice(&[0xAA; 10]);
    assert!(reused(&PROJECTION, &before, &overwritten) > 0.9);
}

#[test]
fn fixed_offsets_lose_what_content_cuts_keep() {
    // The RFD's comparison: after a one-byte insert at the front, fixed 64 KiB blocks share
    // nothing and content-defined chunks share nearly everything.
    let before = noise(2 * 1024 * 1024, 41);
    let mut after = before.clone();
    after.insert(0, 0x42);
    let fixed: HashSet<&[u8]> = before.chunks(64 * 1024).collect();
    assert!(after.chunks(64 * 1024).all(|block| !fixed.contains(block)));
    assert!(reused(&PROJECTION, &before, &after) > 0.9);
}

#[test]
fn sync_cuts_are_unchanged() {
    // `link sync push` names its stored chunks by these cuts: moving the chunker here must not
    // move them. The expected ends were cut by the chunker as it was in sync_cli/store.rs.
    let data = noise(20 * 1024 * 1024, 51);
    let ends: Vec<usize> = spans(&SYNC, &data).iter().map(|(o, l)| o + l).collect();
    assert_eq!(
        ends,
        [
            2_380_846, 3_463_906, 4_364_113, 6_474_338, 8_907_310, 9_578_919, 13_899_855,
            16_026_842, 18_129_274, 20_971_520
        ]
    );
    assert_eq!(
        SYNC,
        Params { min: 524_288, avg: 2_097_152, max: 8_388_608, hard_bits: 23, easy_bits: 19 }
    );
}
