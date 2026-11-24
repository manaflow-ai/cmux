use super::*;

#[test]
fn keeps_the_newest_bytes_with_stable_offsets() {
    let mut ring = Ring::new(100, 4);
    ring.push(b"abcdef");
    assert_eq!((ring.oldest(), ring.end()), (102, 106));
    assert_eq!(ring.read(0, 10), (102, b"cdef".to_vec()));
    assert_eq!(ring.read(104, 1), (104, b"e".to_vec()));
    assert_eq!(ring.read(106, 10), (106, Vec::new()));
}

#[test]
fn reads_across_the_wrap_of_its_buffer() {
    let mut ring = Ring::new(0, 8);
    ring.push(b"012345");
    ring.push(b"6789ab");
    assert_eq!((ring.oldest(), ring.end()), (4, 12));
    assert_eq!(ring.read(4, 8), (4, b"456789ab".to_vec()));
    assert_eq!(ring.read(6, 3), (6, b"678".to_vec()));
    assert_eq!(ring.read(10, 8), (10, b"ab".to_vec()));
}
