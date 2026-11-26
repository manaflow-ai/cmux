//! The chat's copy: events, chunks and the snapshot.

use std::ops::RangeInclusive;

use serde_json::json;

use super::*;
use crate::chunks::{Pack, assemble, split};
use crate::consts::{CHUNK_MAX_BYTES, EVENTS_MAX_PER_APPEND, LEASE_MS};

/// The laptop appends the events numbered `seqs` at epoch 1.
fn append(cloud: &FakeAutoCloud, seqs: RangeInclusive<u64>) -> CloudResult<u64> {
    append_as(cloud, &mac(), 1, seqs)
}

/// A folder's manifest at epoch 1, as the laptop posts it.
fn post(tar: &[String], last_seq: u64) -> SnapshotPost {
    SnapshotPost { holder: mac(), epoch: 1, manifest: manifest(tar, last_seq) }
}

/// `len` bytes that differ from chunk to chunk.
fn folder(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i / 251 + i % 251) as u8).collect()
}

fn seqs(events: &[SeqRecord]) -> Vec<u64> {
    events.iter().map(|event| event.seq).collect()
}

#[test]
fn events_append_in_order_and_a_gap_is_refused() {
    let (owner, _machine) = store();
    assert_eq!(append(&owner, 1..=3), Ok(3));
    // A repeat of stored seqs is accepted, alone or before new ones.
    assert_eq!(append(&owner, 2..=3), Ok(3));
    assert_eq!(append(&owner, 3..=5), Ok(5));

    let gap = append(&owner, 7..=8).expect_err("a gap");
    assert_eq!((gap.code(), gap.status()), (Some(ErrorCode::SeqGap), Some(409)));
    assert_eq!((gap.last_seq(), gap.session().map(|session| session.last_seq)), (Some(5), Some(5)));
    assert_eq!(chat(&owner).last_seq, 5);

    // Any of the owner's devices reads them.
    let page = ready(owner.events(CHAT, 2, Some(2))).expect("a page");
    assert_eq!((seqs(&page.events), page.last_seq), (vec![3, 4], 5));
    assert_eq!(page.events.first().map(|event| event.record.clone()), Some(json!({ "n": 3 })));
    let rest = ready(owner.events(CHAT, 4, None)).expect("a page");
    assert_eq!((seqs(&rest.events), rest.last_seq), (vec![5], 5));
    assert!(ready(owner.events(CHAT, 5, None)).expect("a page").events.is_empty());
}

#[test]
fn an_append_takes_at_most_256_events_and_one_mebibyte() {
    let (owner, _machine) = store();
    let many = append(&owner, 1..=EVENTS_MAX_PER_APPEND as u64 + 1).expect_err("too many");
    assert_eq!((many.status(), many.code()), (Some(400), None));
    assert_eq!(append(&owner, 1..=EVENTS_MAX_PER_APPEND as u64), Ok(256));

    let big = SeqRecord { seq: 257, record: json!({ "text": "x".repeat(1 << 20) }) };
    let events = EventsAppend { holder: mac(), epoch: 1, events: vec![big] };
    let heavy = ready(owner.append_events(CHAT, &events)).expect_err("too heavy");
    assert_eq!((heavy.status(), heavy.code()), (Some(413), Some(ErrorCode::TooLarge)));
    assert_eq!(chat(&owner).last_seq, 256);

    // A page of events is cut at a mebibyte of records.
    let text = "x".repeat(400_000);
    for seq in 257..=259 {
        let record = SeqRecord { seq, record: json!({ "text": text }) };
        let events = EventsAppend { holder: mac(), epoch: 1, events: vec![record] };
        assert_eq!(ready(owner.append_events(CHAT, &events)), Ok(seq));
    }
    let page = ready(owner.events(CHAT, 256, None)).expect("a page");
    assert_eq!((seqs(&page.events), page.last_seq), (vec![257, 258], 259));
}

#[test]
fn a_snapshot_is_whole_or_absent() {
    let (owner, _machine) = store();
    let held = Fence::new(mac(), 1);
    assert_eq!(code(ready(owner.snapshot(CHAT))), ErrorCode::NoSnapshot);

    let bytes = folder(CHUNK_MAX_BYTES + 10);
    let tar = Pack::new().add(&bytes).expect("under the cap");
    let parts: Vec<&[u8]> = split(&bytes).collect();
    let (first, second) = (parts[0], parts[1]);

    // No chunk is stored yet: the manifest is refused, naming both.
    let refused = ready(owner.post_snapshot(CHAT, &post(&tar, 0))).expect_err("incomplete");
    assert_eq!(
        (refused.code(), refused.status()),
        (Some(ErrorCode::SnapshotIncomplete), Some(409))
    );
    assert_eq!(refused.missing(), tar.as_slice());

    // A chunk under another chunk's name is refused.
    let wrong = ready(owner.put_chunk(CHAT, &tar[0], second, &held)).expect_err("mismatch");
    assert_eq!((wrong.code(), wrong.status()), (Some(ErrorCode::ChunkMismatch), Some(400)));
    // A name that is no SHA-256 is no chunk.
    assert_eq!(status(ready(owner.put_chunk(CHAT, "abc", second, &held))), Some(404));

    assert_eq!(ready(owner.put_chunk(CHAT, &tar[0], first, &held)), Ok(()));
    let refused = ready(owner.post_snapshot(CHAT, &post(&tar, 0))).expect_err("incomplete");
    assert_eq!(refused.missing(), &tar[1..]);
    assert_eq!(chat(&owner).snapshot, 0);

    assert_eq!(ready(owner.put_chunk(CHAT, &tar[1], second, &held)), Ok(()));
    // The same chunk again is fine.
    assert_eq!(ready(owner.put_chunk(CHAT, &tar[1], second, &held)), Ok(()));
    assert_eq!(ready(owner.post_snapshot(CHAT, &post(&tar, 0))), Ok(1));
    assert_eq!(chat(&owner).snapshot, 1);

    // A reader gets the manifest and puts the folder back together.
    let answer = ready(owner.snapshot(CHAT)).expect("a snapshot");
    assert_eq!((answer.snapshot, &answer.manifest), (1, &post(&tar, 0).manifest));
    let back = assemble(&tar, |name| ready(owner.chunk(CHAT, name)).ok());
    assert_eq!(back, Ok(bytes.clone()));

    // The next snapshot has the next number, and the chunks only the old one named are gone.
    assert_eq!(snapshot_as(&owner, &mac(), 1, b"smaller now", 0), Ok(2));
    assert_eq!(ready(owner.snapshot(CHAT)).expect("a snapshot").snapshot, 2);
    assert_eq!(status(ready(owner.chunk(CHAT, &tar[0]))), Some(404));
}

#[test]
fn a_chat_past_its_size_limit_is_too_large() {
    let (owner, _machine) = store();
    let held = Fence::new(mac(), 1);
    owner.set_snapshot_max(10);

    // The chunks waiting for their snapshot stay under the limit.
    let big = ready(owner.put_chunk(CHAT, &name_of(b"eleven byte"), b"eleven byte", &held));
    let refused = big.expect_err("too large");
    assert_eq!((refused.code(), refused.status()), (Some(ErrorCode::TooLarge), Some(413)));
    assert_eq!(snapshot_as(&owner, &mac(), 1, b"eight by", 0), Ok(1));

    // So does what one snapshot names: the kept chunk and a new one are past it together.
    let more = b"8 more b";
    assert_eq!(ready(owner.put_chunk(CHAT, &name_of(more), more, &held)), Ok(()));
    let both = [name_of(b"eight by"), name_of(more)];
    assert_eq!(code(ready(owner.post_snapshot(CHAT, &post(&both, 0)))), ErrorCode::TooLarge);
    assert_eq!(chat(&owner).snapshot, 1);

    // So do the chat's events.
    assert_eq!(append(&owner, 1..=1), Ok(1));
    assert_eq!(code(append(&owner, 2..=2)), ErrorCode::TooLarge);
    assert_eq!(chat(&owner).last_seq, 1);

    // One chunk over a mebibyte is refused whatever the limit.
    let huge = vec![7u8; CHUNK_MAX_BYTES + 1];
    let chunk = ready(owner.put_chunk(CHAT, &name_of(&huge), &huge, &held));
    assert_eq!(code(chunk), ErrorCode::TooLarge);
}

#[test]
fn an_upload_that_was_given_up_makes_room_after_a_day() {
    let (owner, _machine) = store();
    owner.set_snapshot_max(10);
    let old = b"given up";
    assert_eq!(ready(owner.put_chunk(CHAT, &name_of(old), old, &Fence::new(mac(), 1))), Ok(()));

    // A day later the laptop is back (its idle chat was parked) and uploads again.
    owner.advance(24 * 3_600_000 + LEASE_MS);
    assert_eq!(renew(&owner, &mac(), 1, false).session.epoch, 3);
    assert_eq!(snapshot_as(&owner, &mac(), 3, b"new bytes", 0), Ok(1));
    assert_eq!(status(ready(owner.chunk(CHAT, &name_of(old)))), Some(404));
}
