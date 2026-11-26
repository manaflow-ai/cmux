use super::*;

#[test]
fn asks_and_answers_round_trip() {
    let asks = [
        Ask::Read { ask: 1, entry: 9, offset: 1 << 33, len: 4096 },
        Ask::Batch { ask: 2, entries: vec![3, 4, 5] },
        Ask::Ping { ask: 3 },
        Ask::Stored { ask: 4, since: 1025 },
        Ask::Listing { ask: 5, since: 1 << 40 },
    ];
    let mut bytes = Vec::new();
    for ask in &asks {
        ask.write(&mut bytes).unwrap();
    }
    let mut input = bytes.as_slice();
    for ask in &asks {
        assert_eq!(Ask::read(&mut input).unwrap().as_ref(), Some(ask));
    }
    assert_eq!(Ask::read(&mut input).unwrap(), None);

    let parts = vec![Part::ok(b"abc".to_vec()), Part::status(CHANGED)];
    let mut bytes = Vec::new();
    write_answer(&mut bytes, 7, &parts).unwrap();
    let mut input = bytes.as_slice();
    assert_eq!(read_answer(&mut input).unwrap(), Some((7, parts)));
    assert_eq!(read_answer(&mut input).unwrap(), None);
}

#[test]
fn a_packed_answer_is_smaller_and_reads_back_as_the_same_parts() {
    let text = b"fn main() { println!(\"hello\"); }\n".repeat(200);
    // Bytes that do not compress (xorshift), as an image or an archive.
    let mut state = 0x9e37_79b9_7f4a_7c15u64;
    let noise: Vec<u8> = (0..4096)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state >> 32) as u8
        })
        .collect();
    let parts = vec![
        Part::ok(text.clone()),
        Part::ok(noise.clone()),
        Part::ok(b"short".to_vec()),
        Part::status(CHANGED),
        Part::ok(Vec::new()),
    ];
    let mut plain = Vec::new();
    write_answer(&mut plain, 9, &parts).unwrap();
    let mut packed = Vec::new();
    write_packed_answer(&mut packed, 9, &parts).unwrap();
    assert!(packed.len() < plain.len() - text.len() / 2, "{} vs {}", packed.len(), plain.len());
    // Text went as zstd; noise and the short file went as they are.
    assert_eq!(packed[8], OK_ZSTD);
    assert!(packed.windows(noise.len()).any(|window| window == noise.as_slice()));
    assert_eq!(read_answer(&mut packed.as_slice()).unwrap(), Some((9, parts.clone())));
    assert_eq!(read_answer(&mut plain.as_slice()).unwrap(), Some((9, parts)));
}

#[test]
fn a_packed_part_past_the_read_limit_is_refused() {
    let huge = vec![0u8; MAX_READ as usize + 1];
    let mut packed = Vec::new();
    write_packed_answer(&mut packed, 1, &[Part::ok(huge)]).unwrap();
    assert!(packed.len() < 4096);
    assert!(read_answer(&mut packed.as_slice()).is_err());
    let mut junk = Vec::new();
    write_answer(&mut junk, 1, &[Part { status: OK_ZSTD, bytes: b"not zstd".to_vec() }]).unwrap();
    assert!(read_answer(&mut junk.as_slice()).is_err());
}

#[test]
fn an_oversized_ask_is_refused() {
    let mut bytes = Vec::new();
    Ask::Read { ask: 1, entry: 0, offset: 0, len: MAX_READ + 1 }.write(&mut bytes).unwrap();
    assert!(Ask::read(&mut bytes.as_slice()).is_err());
}
