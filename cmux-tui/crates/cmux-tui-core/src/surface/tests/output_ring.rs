use super::*;

fn read(reader: &OutputRingReader, from: u64, to: u64) -> Option<Vec<u8>> {
    let (head, tail) = reader.slices(from, to)?;
    let bytes = [head, tail].concat();
    reader.unlapped(from).then_some(bytes)
}

#[test]
fn a_reader_reads_published_bytes_in_place_across_the_wrap() {
    let mut ring = OutputRing::create(1000, 16).unwrap();
    let reader = OutputRingReader::map(ring.reader_descriptor()).unwrap();
    assert_eq!((reader.capacity(), reader.base(), reader.end()), (16, 1000, 1000));
    ring.push(b"hello, ");
    ring.push(b"world");
    assert_eq!(reader.end(), 1012);
    assert_eq!(read(&reader, 1000, 1012).unwrap(), b"hello, world");
    // 1000 % 16 = 8: the bytes wrap after the first 8.
    let (head, tail) = reader.slices(1000, 1012).unwrap();
    assert_eq!((head, tail), (&b"hello, w"[..], &b"orld"[..]));
    // 1012 % 16 = 4: the next bytes follow without a wrap.
    ring.push(b"0123456789");
    assert_eq!(reader.end(), 1022);
    let (head, tail) = reader.slices(1012, 1022).unwrap();
    assert_eq!((head, tail), (&b"0123456789"[..], &b""[..]));
    assert!(reader.unlapped(1012));
}

#[test]
fn bytes_the_writer_overwrote_are_reported_as_a_lap_never_returned_as_valid() {
    let mut ring = OutputRing::create(0, 16).unwrap();
    let reader = OutputRingReader::map(ring.reader_descriptor()).unwrap();
    ring.push(b"abcdefgh");
    // The reader holds [0, 8) while the writer laps it.
    let (head, _) = reader.slices(0, 8).unwrap();
    assert_eq!(head, b"abcdefgh");
    assert!(reader.unlapped(0));
    ring.push(b"ABCDEFGHIJKL"); // end 20: offsets 0..4 overwritten
    assert!(!reader.unlapped(0), "a reader of overwritten bytes must see the lap");
    assert!(reader.unlapped(4), "bytes from offset 4 on are still the published ones");
    assert!(reader.slices(0, 20).is_none(), "more than the capacity is gone");
    assert_eq!(read(&reader, 4, 20).unwrap(), b"efghABCDEFGHIJKL");
}

#[test]
fn a_push_larger_than_the_ring_keeps_its_last_capacity_bytes() {
    let mut ring = OutputRing::create(5, 8).unwrap();
    let reader = OutputRingReader::map(ring.reader_descriptor()).unwrap();
    ring.push(b"0123456789ab");
    assert_eq!(reader.end(), 17);
    assert_eq!(read(&reader, 9, 17).unwrap(), b"456789ab");
}

#[test]
fn the_reader_descriptor_is_read_only() {
    let ring = OutputRing::create(0, 4096).unwrap();
    let fd = ring.reader_descriptor().as_raw_fd();
    // SAFETY: tries to map the reader descriptor writable; must fail.
    let map = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            HEADER,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            fd,
            0,
        )
    };
    assert_eq!(map, libc::MAP_FAILED, "a reader must not be able to write the ring");
    // SAFETY: fcntl F_GETFL on a live descriptor.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    assert_eq!(flags & libc::O_ACCMODE, libc::O_RDONLY);
}

#[test]
fn a_reader_mapping_outlives_the_writer() {
    let mut ring = OutputRing::create(0, 64).unwrap();
    ring.push(b"kept after the daemon dropped its ring");
    let reader = OutputRingReader::map(ring.reader_descriptor()).unwrap();
    drop(ring);
    assert_eq!(read(&reader, 0, 38).unwrap(), b"kept after the daemon dropped its ring");
}

#[test]
fn a_reader_refuses_a_segment_that_is_not_a_ring() {
    let (writer, reader) = new_segment().unwrap();
    // SAFETY: sizes a descriptor this test owns.
    assert_eq!(unsafe { libc::ftruncate(writer.as_raw_fd(), 4096) }, 0);
    assert!(OutputRingReader::map(&reader).is_err());
}
