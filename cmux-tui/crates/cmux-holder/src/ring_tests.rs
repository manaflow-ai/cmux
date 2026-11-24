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

#[test]
fn a_private_ring_behaves_the_same() {
    let mut ring = Ring::private(0, 8);
    ring.push(b"0123456789");
    assert!(ring.segment().is_none());
    assert_eq!(ring.read(0, 16), (2, b"23456789".to_vec()));
}

/// The segment outlives its writer: a ring adopted from the descriptor
/// has every byte the first one published, at the same offsets, and
/// continues them.
#[test]
fn an_adopted_segment_continues_the_dead_writers_ring() {
    let mut first = Ring::new(1000, 16);
    let segment = first.segment().expect("a shared ring").try_clone().unwrap();
    first.push(b"hello ");
    // `read_with` offers the room up to the end of the data area: 1006
    // is at position 14 of 16, so 2 bytes, then the rest after the wrap.
    let mut word: &[u8] = b"world";
    while !word.is_empty() {
        let n = first.read_with(64, |room| {
            let n = room.len().min(word.len());
            room[..n].copy_from_slice(&word[..n]);
            n as isize
        });
        word = &word[n as usize..];
    }
    drop(first);
    assert_eq!(segment_end(&segment).unwrap(), 1011);
    let mut second = Ring::adopt(segment).unwrap();
    assert_eq!((second.oldest(), second.end()), (1000, 1011));
    assert_eq!(second.read(1000, 64), (1000, b"hello world".to_vec()));
    second.push(b"!!!!!!");
    assert_eq!(second.read(0, 64), (1001, b"ello world!!!!!!".to_vec()));
}

/// A writer that dies inside a write over the oldest kept bytes (the
/// data stored, its end not published) leaves a segment whose kept
/// window holds no overwritten byte: every byte an adopter trusts is the
/// byte first written at that offset.
#[test]
fn a_writer_dead_inside_a_write_over_kept_bytes_leaves_only_whole_bytes() {
    let mut first = Ring::new(0, 16);
    let segment = first.segment().expect("a shared ring").try_clone().unwrap();
    let stream: Vec<u8> = (0..64u8).map(|byte| b'A' + byte % 26).collect();
    first.push(&stream[..20]);
    assert_eq!((first.oldest(), first.end()), (4, 20));
    // The next read gets the room from 20 (position 4) to the end of
    // the data area, 12 bytes over offsets 4..16, and "dies" right after
    // it stored them.
    let mut adopted = None;
    first.read_with(64, |room| {
        for (index, byte) in room.iter_mut().enumerate() {
            *byte = b'#' + index as u8;
        }
        adopted = Some(Ring::adopt(segment.try_clone().unwrap()).unwrap());
        room.len() as isize
    });
    let dead = adopted.unwrap();
    let (from, kept) = dead.read(0, 64);
    assert_eq!(dead.end(), 20, "the unpublished read is not part of the ring");
    assert_eq!(kept, stream[from as usize..20].to_vec(), "an overwritten byte is kept");
}

/// A writer killed inside a PTY read (the kernel already stored bytes
/// in the room it offered, the new end not published) leaves a segment
/// that says so: [`interrupted_read`] names the offset the read started
/// at, the end an adopter continues from. A read whose end was
/// published, and a segment no read is in flight on, name no loss.
#[test]
fn a_writer_dead_inside_a_read_leaves_the_offset_of_its_loss() {
    let mut first = Ring::new(0, 64);
    let segment = first.segment().expect("a shared ring").try_clone().unwrap();
    first.push(b"before");
    assert_eq!(interrupted_read(&segment).unwrap(), None, "no read in flight");
    let mut dead = None;
    let n = first.read_with(16, |room| {
        room[..5].copy_from_slice(b"taken");
        // The holder "dies" here: the kernel took the bytes from the
        // PTY, the new end is not published.
        dead = Some(interrupted_read(&segment).unwrap());
        5
    });
    assert_eq!(dead, Some(Some(6)), "the dead writer's segment names the loss at its end");
    assert_eq!(n, 5);
    assert_eq!(interrupted_read(&segment).unwrap(), None, "a published read names no loss");
    // An adopter of the dead writer's segment continues at that end.
    let mut second = Ring::new(0, 64);
    let segment = second.segment().unwrap().try_clone().unwrap();
    second.push(b"before");
    second.read_with(16, |_| {
        let adopted = Ring::adopt(segment.try_clone().unwrap()).unwrap();
        assert_eq!(adopted.end(), 6);
        0
    });
    assert_eq!(interrupted_read(&segment).unwrap(), None, "an empty read clears its mark");
}

/// An oversized push publishes no offset it skipped as a byte, and an
/// adopter of a segment from before it starts where the push jumped to.
#[test]
fn an_oversized_push_keeps_its_tail_at_the_right_offsets() {
    let mut ring = Ring::new(0, 8);
    let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
    ring.push(b"0123");
    ring.push(b"abcdefghijkl");
    assert_eq!((ring.oldest(), ring.end()), (8, 16));
    assert_eq!(ring.read(0, 64), (8, b"efghijkl".to_vec()));
    drop(ring);
    let adopted = Ring::adopt(segment).unwrap();
    assert_eq!(adopted.read(0, 64), (8, b"efghijkl".to_vec()));
}

/// A new segment is close-on-exec from the moment `shm_open` (or
/// `memfd_create`) returns it, before [`create_segment`] sets the flag
/// again: a process another daemon thread spawns meanwhile does not
/// inherit a writable copy of a terminal's output. Red on a macOS major
/// whose `shm_open` ignores `O_CLOEXEC` (or refuses it: the `EINVAL`
/// fallback opens without it).
#[test]
fn a_new_segment_is_close_on_exec_when_it_is_opened() {
    let segment = new_segment().unwrap();
    // SAFETY: F_GETFD of a descriptor this test owns.
    let flags = unsafe { libc::fcntl(segment.as_raw_fd(), libc::F_GETFD) };
    assert!(flags >= 0, "F_GETFD: {}", io::Error::last_os_error());
    assert_ne!(flags & libc::FD_CLOEXEC, 0, "the segment opened without close-on-exec");
}

/// A layout 1 segment continued for an older daemon keeps its layout 1
/// header (so a holder that knows only layout 1 can continue it again)
/// until the holder upgrades it for a daemon of wire version 5.
#[test]
fn an_adopted_layout_1_segment_stays_layout_1_until_upgraded() {
    let ring = Ring::new(0, 8);
    let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
    drop(ring);
    let header = map_shared(segment.as_raw_fd(), HEADER).unwrap();
    // SAFETY: the header mapping is HEADER bytes; rewrite it as layout 1.
    unsafe {
        std::slice::from_raw_parts_mut(header.add(4), 4)
            .copy_from_slice(&LAYOUT_NO_OLDEST.to_le_bytes());
        libc::munmap(header.cast(), HEADER);
    }
    let read_layout = |segment: &OwnedFd| {
        let header = map_shared(segment.as_raw_fd(), HEADER).unwrap();
        // SAFETY: the header mapping is HEADER bytes.
        unsafe {
            let layout = u32::from_le_bytes(
                std::slice::from_raw_parts(header.add(4), 4).try_into().unwrap(),
            );
            libc::munmap(header.cast(), HEADER);
            layout
        }
    };
    let mut adopted = Ring::adopt(segment.try_clone().unwrap()).unwrap();
    adopted.push(b"abc");
    assert_eq!((adopted.layout(), read_layout(&segment)), (1, 1));
    adopted.upgrade_layout();
    assert_eq!((adopted.layout(), read_layout(&segment)), (2, 2));
}

/// A layout 1 segment (no published `oldest`) is still adopted, its
/// window computed from its end and capacity as before.
#[test]
fn a_layout_1_segment_is_adopted() {
    let mut ring = Ring::new(10, 8);
    let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
    ring.push(b"0123456789");
    drop(ring);
    let header = map_shared(segment.as_raw_fd(), HEADER).unwrap();
    // SAFETY: the header mapping is HEADER bytes; rewrite it as layout 1.
    unsafe {
        std::slice::from_raw_parts_mut(header.add(4), 4)
            .copy_from_slice(&LAYOUT_NO_OLDEST.to_le_bytes());
        std::slice::from_raw_parts_mut(header.add(OFF_OLDEST), 8).fill(0);
        libc::munmap(header.cast(), HEADER);
    }
    let adopted = Ring::adopt(segment).unwrap();
    assert_eq!(adopted.read(0, 64), (12, b"23456789".to_vec()));
}

#[test]
fn a_made_segment_starts_empty_at_its_base() {
    let segment = create_segment(77, 32).unwrap();
    let ring = Ring::adopt(segment).unwrap();
    assert_eq!((ring.oldest(), ring.end()), (77, 77));
}

#[test]
fn a_foreign_descriptor_is_not_a_ring() {
    let segment = new_segment().unwrap();
    // SAFETY: sizes a descriptor this test owns.
    assert_eq!(unsafe { libc::ftruncate(segment.as_raw_fd(), 4096) }, 0);
    assert!(Ring::adopt(segment).is_err());
}
