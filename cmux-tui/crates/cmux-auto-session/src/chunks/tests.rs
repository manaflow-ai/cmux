use std::collections::BTreeMap;

use super::*;
use crate::wire::Cwd;

const MIB: usize = 1 << 20;

/// `len` bytes that do not repeat within a chunk, different for each `seed`.
fn bytes(len: usize, seed: u32) -> Vec<u8> {
    let mut state = seed.wrapping_mul(2_654_435_761).wrapping_add(1);
    (0..len)
        .map(|_| {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            state.to_be_bytes()[0]
        })
        .collect()
}

fn manifest(cwd: Cwd) -> Manifest {
    Manifest {
        v: MANIFEST_VERSION,
        at: 1,
        last_seq: 2,
        harness: "claude".into(),
        harness_session_id: "h".into(),
        cwd,
        queue: Vec::new(),
        draft: String::new(),
        open_turn: None,
    }
}

#[test]
fn a_name_is_the_lowercase_hex_sha256_of_the_bytes() {
    assert_eq!(name_of(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert_eq!(name_of(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    assert!(is_name(&name_of(b"abc")));
    let upper = name_of(b"abc").to_uppercase();
    let long = format!("{}0", name_of(b"abc"));
    for bad in ["", "abc", upper.as_str(), long.as_str()] {
        assert!(!is_name(bad), "{bad:?}");
    }
}

#[test]
fn bytes_split_into_chunks_of_at_most_one_mebibyte() {
    let part = bytes(2 * MIB + MIB / 2, 1);
    let sizes: Vec<usize> = split(&part).map(<[u8]>::len).collect();
    assert_eq!(sizes, [MIB, MIB, MIB / 2]);
    assert_eq!(split(&bytes(MIB, 2)).count(), 1);
    assert_eq!(split(&bytes(MIB + 1, 2)).count(), 2);
    assert_eq!(split(&[]).count(), 0);
}

#[test]
fn a_part_comes_back_whole_from_its_chunk_list() {
    let bundle = bytes(2 * MIB + 17, 3);
    let patch = bytes(4_096, 4);
    let mut pack = Pack::new();
    let bundle_list = pack.add(&bundle).expect("under the cap");
    let patch_list = pack.add(&patch).expect("under the cap");
    assert_eq!((bundle_list.len(), patch_list.len()), (3, 1));
    assert_eq!(pack.bytes(), (bundle.len() + patch.len()) as u64);

    let stored: BTreeMap<String, Vec<u8>> =
        pack.chunks().map(|chunk| (chunk.name.to_owned(), chunk.bytes.to_vec())).collect();
    for chunk in pack.chunks() {
        assert_eq!(check(chunk.name, chunk.bytes), Ok(()));
    }
    let fetch = |name: &str| stored.get(name);
    assert_eq!(assemble(&bundle_list, fetch), Ok(bundle.clone()));
    assert_eq!(assemble(&patch_list, fetch), Ok(patch.clone()));
    assert_eq!(assemble(&[], fetch), Ok(Vec::new()));
}

#[test]
fn equal_chunks_are_uploaded_once() {
    let block = bytes(MIB, 5);
    let twice = [block.as_slice(), block.as_slice()].concat();
    let mut pack = Pack::new();
    let list = pack.add(&twice).expect("under the cap");
    assert_eq!(list.len(), 2);
    assert_eq!(list[0], list[1]);
    assert_eq!(pack.chunks().count(), 1);
    assert_eq!(assemble(&list, |_| Some(block.as_slice())), Ok(twice.clone()));
}

#[test]
fn a_snapshot_past_the_cap_is_too_large() {
    let part = bytes(2 * MIB, 6);
    let mut pack = Pack::with_max(3 * MIB as u64);
    pack.add(&part).expect("under the cap");
    let refused = pack.add(&part).expect_err("past the cap");
    assert_eq!(refused, ChunkError::TooLarge { bytes: 4 * MIB as u64, max: 3 * MIB as u64 });
    assert_eq!(refused.code(), Some(ErrorCode::TooLarge));
    // The pack is as it was.
    assert_eq!(pack.bytes(), 2 * MIB as u64);
    assert_eq!(pack.chunks().count(), 2);

    // The same cap on the way back.
    let list = Pack::new().add(&part).expect("under the cap");
    let mut assembler = Assembler::with_max(&list, MIB as u64).expect("names");
    assert_eq!(assembler.accept(&part[..MIB]), Ok(()));
    assert!(matches!(assembler.accept(&part[MIB..]), Err(ChunkError::TooLarge { .. })));
}

#[test]
fn a_chunk_that_is_not_what_its_name_says_is_refused() {
    let part = bytes(MIB + 9, 7);
    let list = Pack::new().add(&part).expect("under the cap");
    let mut chunks: Vec<Vec<u8>> = split(&part).map(<[u8]>::to_vec).collect();

    let mut assembler = Assembler::new(&list).expect("names");
    assert_eq!(assembler.wanted(), Some(list[0].as_str()));
    // The second chunk in the first one's place.
    let wrong = assembler.accept(&chunks[1]).expect_err("the wrong chunk");
    assert!(matches!(wrong, ChunkError::Mismatch { .. }));
    assert_eq!(wrong.code(), Some(ErrorCode::ChunkMismatch));
    // A refused chunk leaves the assembler where it was.
    assert_eq!((assembler.wanted(), assembler.bytes()), (Some(list[0].as_str()), 0));
    assert_eq!(assembler.accept(&chunks[0]), Ok(()));
    assert_eq!(assembler.accept(&chunks[1]), Ok(()));
    assert!(assembler.whole());
    assert_eq!(assembler.bytes(), part.len() as u64);
    assert_eq!(assembler.accept(&chunks[1]), Err(ChunkError::Unexpected));

    // One flipped bit.
    chunks[0][100] ^= 1;
    let flipped = assemble(&list, |name| (name == list[0]).then(|| chunks[0].clone()));
    assert!(matches!(flipped, Err(ChunkError::Mismatch { .. })));
    // A chunk over the size limit, whatever its name.
    let big = bytes(MIB + 1, 8);
    assert!(matches!(check(&name_of(&big), &big), Err(ChunkError::ChunkTooLarge { .. })));
}

#[test]
fn a_missing_chunk_is_named() {
    let part = bytes(MIB + 9, 9);
    let list = Pack::new().add(&part).expect("under the cap");
    let first = &part[..MIB];
    let missing = assemble(&list, |name| (name == list[0]).then_some(first));
    assert_eq!(missing, Err(ChunkError::Missing { name: list[1].clone() }));
    assert_eq!(
        ChunkError::Missing { name: list[1].clone() }.code(),
        Some(ErrorCode::SnapshotIncomplete)
    );
}

#[test]
fn a_manifest_is_checked_before_anything_is_fetched() {
    let (a, b, c) = (name_of(b"a"), name_of(b"b"), name_of(b"c"));
    let git = manifest(Cwd::Git {
        remote: "https://example.com/r.git".into(),
        branch: "main".into(),
        base: "0123abc".into(),
        bundle: vec![a.clone(), b.clone()],
        patch: vec![c.clone(), a.clone()],
    });
    assert_eq!(validate(&git), Ok(()));
    // Each missing chunk once, in the manifest's order.
    assert_eq!(missing(&git, |name| name == b), [a.clone(), c]);
    assert!(missing(&git, |_| true).is_empty());

    let bad = manifest(Cwd::Folder { tar: vec![a.clone(), "not-a-hash".into()] });
    assert_eq!(validate(&bad), Err(ChunkError::BadName { name: "not-a-hash".into() }));
    assert!(matches!(Assembler::new(&["XYZ".to_owned()]), Err(ChunkError::BadName { .. })));

    let newer = Manifest { v: MANIFEST_VERSION + 1, ..manifest(Cwd::Folder { tar: vec![a] }) };
    assert_eq!(validate(&newer), Err(ChunkError::Version { v: MANIFEST_VERSION + 1 }));
}
