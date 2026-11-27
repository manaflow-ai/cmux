use super::*;

#[test]
fn frames_survive_any_chunking() {
    let frames: Vec<Vec<u8>> = vec![vec![1], vec![0x13; 70_000], vec![], vec![2, 3]];
    let stream: Vec<u8> = frames.iter().flat_map(|f| length_prefixed(f).unwrap()).collect();
    for chunk in [1, 3, 4, 5, 16 * 1024, stream.len()] {
        let mut d = Deframer::new(1 << 20);
        let mut out = Vec::new();
        for piece in stream.chunks(chunk) {
            d.push(piece);
            while let Some(frame) = d.next_frame().unwrap() {
                out.push(frame);
            }
        }
        assert_eq!(out, frames, "chunk {chunk}");
        assert_eq!(d.pending(), 0);
    }
}

#[test]
fn a_frame_over_the_cap_is_refused_before_its_bytes_arrive() {
    let mut d = Deframer::new(8);
    d.push(&9u32.to_be_bytes());
    assert_eq!(d.next_frame(), Err(TooLong { len: 9, cap: 8 }));
    let mut d = Deframer::new(8);
    d.push(&8u32.to_be_bytes());
    d.push(&[0; 7]);
    assert_eq!(d.next_frame(), Ok(None));
    d.push(&[0]);
    assert_eq!(d.next_frame(), Ok(Some(vec![0; 8])));
}
