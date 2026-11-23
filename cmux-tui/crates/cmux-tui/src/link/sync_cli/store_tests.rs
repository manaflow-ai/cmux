use serde_json::json;

use super::{CHUNK_MAX, CHUNK_MIN, chunks, serves_fetch};

#[test]
fn an_identify_answer_without_capabilities_says_nothing_about_fetch() {
    // Unknown, so the push takes the fence of a machine it cannot read.
    assert_eq!(serves_fetch(&json!({"build_id": "b"})), None);
    assert_eq!(serves_fetch(&json!({"capabilities": "blob-fetch-v2"})), None);
    assert_eq!(serves_fetch(&json!({"capabilities": ["fs-v1"]})), Some(false));
    assert_eq!(serves_fetch(&json!({"capabilities": ["fs-v1", "blob-fetch-v2"]})), Some(true));
}

fn noise(len: usize, seed: u64) -> Vec<u8> {
    let mut state = seed;
    (0..len)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state as u8
        })
        .collect()
}

#[test]
fn chunks_cover_the_file_within_bounds() {
    let data = noise(40 * 1024 * 1024 + 123, 7);
    let pieces = chunks(&mut data.as_slice()).unwrap();
    assert_eq!(pieces.iter().map(|p| p.size).sum::<u64>(), data.len() as u64);
    let mut offset = 0;
    for (index, piece) in pieces.iter().enumerate() {
        assert_eq!(piece.offset, offset);
        assert!(piece.size as usize <= CHUNK_MAX);
        if index + 1 < pieces.len() {
            assert!(piece.size as usize > CHUNK_MIN);
        }
        offset += piece.size;
    }
    assert!(pieces.len() >= 5, "{} pieces", pieces.len());
}

#[test]
fn an_edit_in_the_middle_changes_only_the_pieces_around_it() {
    let data = noise(48 * 1024 * 1024, 11);
    let mut edited = data.clone();
    edited.splice(20 * 1024 * 1024..20 * 1024 * 1024, b"inserted line\n".iter().copied());
    let before: std::collections::BTreeSet<String> =
        chunks(&mut data.as_slice()).unwrap().into_iter().map(|p| p.sha256).collect();
    let after = chunks(&mut edited.as_slice()).unwrap();
    let new = after.iter().filter(|p| !before.contains(&p.sha256)).count();
    assert!(new <= 2, "{new} of {} pieces changed", after.len());
}

#[test]
fn the_same_bytes_always_cut_the_same_way() {
    let data = noise(20 * 1024 * 1024, 3);
    assert_eq!(chunks(&mut data.as_slice()).unwrap(), chunks(&mut data.as_slice()).unwrap());
}
