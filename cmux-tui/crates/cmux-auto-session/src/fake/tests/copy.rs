//! The chat's copy: events, chunks and the snapshot.

use std::ops::RangeInclusive;

use serde_json::json;

use super::*;
use crate::chunks::{Pack, assemble, name_of, split};
use crate::consts::{CHUNK_MAX_BYTES, EVENTS_MAX_PER_APPEND, MANIFEST_VERSION};
use crate::wire::{Cwd, EventsAppend, Manifest, SeqRecord, SnapshotPost};

fn record(seq: u64) -> SeqRecord {
    SeqRecord { seq, record: json!({ "n": seq }) }
}

/// The laptop appends the events numbered `seqs` at epoch 1.
fn append(cloud: &FakeAutoCloud, seqs: RangeInclusive<u64>) -> CloudResult<u64> {
    let events = EventsAppend { holder: mac(), epoch: 1, events: seqs.map(record).collect() };
    ready(cloud.append_events(CHAT, &events))
}

/// A folder's manifest at epoch 1, as the laptop posts it.
fn post(tar: &[String], last_seq: u64) -> SnapshotPost {
    let manifest = Manifest {
        v: MANIFEST_VERSION,
        at: 0,
        last_seq,
        harness: "claude".into(),
        harness_session_id: "h".into(),
        cwd: Cwd::Folder { tar: tar.to_vec() },
        queue: Vec::new(),
        draft: String::new(),
        open_turn: None,
    };
    SnapshotPost { holder: mac(), epoch: 1, manifest }
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
    let (owner, machine) = store();
    assert_eq!(append(&owner, 1..=3), Ok(3));
    // A repeat of stored seqs is accepted, alone or before new ones.
    assert_eq!(append(&owner, 2..=3), Ok(3));
    assert_eq!(append(&owner, 3..=5), Ok(5));

    let gap = append(&owner, 7..=8).expect_err("a gap");
    assert_eq!((gap.code(), gap.status()), (Some(ErrorCode::SeqGap), Some(409)));
    assert_eq!(gap.last_seq(), Some(5));
    assert_eq!(chat(&owner).last_seq, 5);

    // Any device and the machine read them.
    let page = ready(machine.events(CHAT, 2, Some(2))).expect("a page");
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
    assert_eq!((many.status(), many.code()), (Some(413), None));
    assert_eq!(append(&owner, 1..=EVENTS_MAX_PER_APPEND as u64), Ok(256));

    let big = SeqRecord { seq: 257, record: json!({ "text": "x".repeat(1 << 20) }) };
    let events = EventsAppend { holder: mac(), epoch: 1, events: vec![big] };
    let heavy = ready(owner.append_events(CHAT, &events)).expect_err("too heavy");
    assert_eq!(heavy.status(), Some(413));
    assert_eq!(chat(&owner).last_seq, 256);
}

#[test]
fn a_snapshot_is_whole_or_absent() {
    let (owner, machine) = store();
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

    assert_eq!(ready(owner.put_chunk(CHAT, &tar[0], first, &held)), Ok(()));
    let refused = ready(owner.post_snapshot(CHAT, &post(&tar, 0))).expect_err("incomplete");
    assert_eq!(refused.missing(), &tar[1..]);
    assert_eq!(chat(&owner).snapshot, 0);

    assert_eq!(ready(owner.put_chunk(CHAT, &tar[1], second, &held)), Ok(()));
    // The same chunk again is fine.
    assert_eq!(ready(owner.put_chunk(CHAT, &tar[1], second, &held)), Ok(()));
    assert_eq!(ready(owner.post_snapshot(CHAT, &post(&tar, 0))), Ok(1));
    assert_eq!(chat(&owner).snapshot, 1);

    // The machine reads the manifest and puts the folder back together.
    let answer = ready(machine.snapshot(CHAT)).expect("a snapshot");
    assert_eq!((answer.snapshot, &answer.manifest), (1, &post(&tar, 0).manifest));
    let back = assemble(&tar, |name| ready(machine.chunk(CHAT, name)).ok());
    assert_eq!(back, Ok(bytes.clone()));

    // The next snapshot has the next number, and the chunks only the old one named are gone.
    let small = b"smaller now".to_vec();
    let next = Pack::new().add(&small).expect("under the cap");
    assert_eq!(ready(owner.put_chunk(CHAT, &next[0], &small, &held)), Ok(()));
    assert_eq!(ready(owner.post_snapshot(CHAT, &post(&next, 0))), Ok(2));
    assert_eq!(ready(owner.snapshot(CHAT)).expect("a snapshot").snapshot, 2);
    assert_eq!(ready(owner.chunk(CHAT, &tar[0])).expect_err("dropped").status(), Some(404));
}

#[test]
fn a_snapshot_past_the_cap_is_too_large() {
    let (owner, _machine) = store();
    let held = Fence::new(mac(), 1);
    owner.set_snapshot_max(10);
    let bytes = b"eleven byte".to_vec();
    let tar = vec![name_of(&bytes)];
    assert_eq!(ready(owner.put_chunk(CHAT, &tar[0], &bytes, &held)), Ok(()));
    let refused = ready(owner.post_snapshot(CHAT, &post(&tar, 0))).expect_err("too large");
    assert_eq!((refused.code(), refused.status()), (Some(ErrorCode::TooLarge), Some(413)));
    assert_eq!(chat(&owner).snapshot, 0);

    // One chunk over a mebibyte is refused whatever the cap.
    let big = vec![7u8; CHUNK_MAX_BYTES + 1];
    let chunk = ready(owner.put_chunk(CHAT, &name_of(&big), &big, &held));
    assert_eq!(code(chunk), ErrorCode::TooLarge);
}

#[test]
fn a_snapshot_cannot_include_events_the_store_lacks() {
    let (owner, _machine) = store();
    let bytes = b"folder".to_vec();
    let tar = vec![name_of(&bytes)];
    assert_eq!(ready(owner.put_chunk(CHAT, &tar[0], &bytes, &Fence::new(mac(), 1))), Ok(()));
    let ahead = ready(owner.post_snapshot(CHAT, &post(&tar, 3))).expect_err("ahead");
    assert_eq!((ahead.code(), ahead.last_seq()), (Some(ErrorCode::SeqGap), Some(0)));

    assert_eq!(append(&owner, 1..=3), Ok(3));
    assert_eq!(ready(owner.post_snapshot(CHAT, &post(&tar, 3))), Ok(1));
}
