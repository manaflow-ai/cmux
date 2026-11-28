use super::*;

#[test]
fn test_buffer_length_changes() {
    let mut ring = RingBuffer::new(vec![0; 2]);
    assert!(ring.is_empty());
    assert!(!ring.is_full());
    assert_eq!(ring.len(), 0);
    assert_eq!(ring.capacity(), 2);
    assert_eq!(ring.window(), 2);

    ring.length = 1;
    assert!(!ring.is_empty());
    assert!(!ring.is_full());
    assert_eq!(ring.len(), 1);
    assert_eq!(ring.capacity(), 2);
    assert_eq!(ring.window(), 1);

    ring.length = 2;
    assert!(!ring.is_empty());
    assert!(ring.is_full());
    assert_eq!(ring.len(), 2);
    assert_eq!(ring.capacity(), 2);
    assert_eq!(ring.window(), 0);
}

#[test]
fn test_buffer_enqueue_dequeue_one_with() {
    let mut ring = RingBuffer::new(vec![0; 5]);
    assert_eq!(
        ring.dequeue_one_with(|_| -> Result::<(), ()> { unreachable!() }),
        Err(Empty)
    );

    ring.enqueue_one_with(Ok::<_, ()>).unwrap().unwrap();
    assert!(!ring.is_empty());
    assert!(!ring.is_full());

    for i in 1..5 {
        ring.enqueue_one_with(|e| Ok::<_, ()>(*e = i))
            .unwrap()
            .unwrap();
        assert!(!ring.is_empty());
    }
    assert!(ring.is_full());
    assert_eq!(
        ring.enqueue_one_with(|_| -> Result::<(), ()> { unreachable!() }),
        Err(Full)
    );

    for i in 0..5 {
        assert_eq!(
            ring.dequeue_one_with(|e| Ok::<_, ()>(*e)).unwrap().unwrap(),
            i
        );
        assert!(!ring.is_full());
    }
    assert_eq!(
        ring.dequeue_one_with(|_| -> Result::<(), ()> { unreachable!() }),
        Err(Empty)
    );
    assert!(ring.is_empty());
}

#[test]
fn test_buffer_enqueue_dequeue_one() {
    let mut ring = RingBuffer::new(vec![0; 5]);
    assert_eq!(ring.dequeue_one(), Err(Empty));

    ring.enqueue_one().unwrap();
    assert!(!ring.is_empty());
    assert!(!ring.is_full());

    for i in 1..5 {
        *ring.enqueue_one().unwrap() = i;
        assert!(!ring.is_empty());
    }
    assert!(ring.is_full());
    assert_eq!(ring.enqueue_one(), Err(Full));

    for i in 0..5 {
        assert_eq!(*ring.dequeue_one().unwrap(), i);
        assert!(!ring.is_full());
    }
    assert_eq!(ring.dequeue_one(), Err(Empty));
    assert!(ring.is_empty());
}

#[test]
fn test_buffer_enqueue_many_with() {
    let mut ring = RingBuffer::new(vec![b'.'; 12]);

    assert_eq!(
        ring.enqueue_many_with(|buf| {
            assert_eq!(buf.len(), 12);
            buf[0..2].copy_from_slice(b"ab");
            (2, true)
        }),
        (2, true)
    );
    assert_eq!(ring.len(), 2);
    assert_eq!(&ring.storage[..], b"ab..........");

    ring.enqueue_many_with(|buf| {
        assert_eq!(buf.len(), 12 - 2);
        buf[0..4].copy_from_slice(b"cdXX");
        (2, ())
    });
    assert_eq!(ring.len(), 4);
    assert_eq!(&ring.storage[..], b"abcdXX......");

    ring.enqueue_many_with(|buf| {
        assert_eq!(buf.len(), 12 - 4);
        buf[0..4].copy_from_slice(b"efgh");
        (4, ())
    });
    assert_eq!(ring.len(), 8);
    assert_eq!(&ring.storage[..], b"abcdefgh....");

    for _ in 0..4 {
        *ring.dequeue_one().unwrap() = b'.';
    }
    assert_eq!(ring.len(), 4);
    assert_eq!(&ring.storage[..], b"....efgh....");

    ring.enqueue_many_with(|buf| {
        assert_eq!(buf.len(), 12 - 8);
        buf[0..4].copy_from_slice(b"ijkl");
        (4, ())
    });
    assert_eq!(ring.len(), 8);
    assert_eq!(&ring.storage[..], b"....efghijkl");

    ring.enqueue_many_with(|buf| {
        assert_eq!(buf.len(), 4);
        buf[0..4].copy_from_slice(b"abcd");
        (4, ())
    });
    assert_eq!(ring.len(), 12);
    assert_eq!(&ring.storage[..], b"abcdefghijkl");

    for _ in 0..4 {
        *ring.dequeue_one().unwrap() = b'.';
    }
    assert_eq!(ring.len(), 8);
    assert_eq!(&ring.storage[..], b"abcd....ijkl");
}

#[test]
fn test_buffer_enqueue_many() {
    let mut ring = RingBuffer::new(vec![b'.'; 12]);

    ring.enqueue_many(8).copy_from_slice(b"abcdefgh");
    assert_eq!(ring.len(), 8);
    assert_eq!(&ring.storage[..], b"abcdefgh....");

    ring.enqueue_many(8).copy_from_slice(b"ijkl");
    assert_eq!(ring.len(), 12);
    assert_eq!(&ring.storage[..], b"abcdefghijkl");
}

#[test]
fn test_buffer_enqueue_slice() {
    let mut ring = RingBuffer::new(vec![b'.'; 12]);

    assert_eq!(ring.enqueue_slice(b"abcdefgh"), 8);
    assert_eq!(ring.len(), 8);
    assert_eq!(&ring.storage[..], b"abcdefgh....");

    for _ in 0..4 {
        *ring.dequeue_one().unwrap() = b'.';
    }
    assert_eq!(ring.len(), 4);
    assert_eq!(&ring.storage[..], b"....efgh....");

    assert_eq!(ring.enqueue_slice(b"ijklabcd"), 8);
    assert_eq!(ring.len(), 12);
    assert_eq!(&ring.storage[..], b"abcdefghijkl");
}

#[test]
fn test_buffer_dequeue_many_with() {
    let mut ring = RingBuffer::new(vec![b'.'; 12]);

    assert_eq!(ring.enqueue_slice(b"abcdefghijkl"), 12);

    assert_eq!(
        ring.dequeue_many_with(|buf| {
            assert_eq!(buf.len(), 12);
            assert_eq!(buf, b"abcdefghijkl");
            buf[..4].copy_from_slice(b"....");
            (4, true)
        }),
        (4, true)
    );
    assert_eq!(ring.len(), 8);
    assert_eq!(&ring.storage[..], b"....efghijkl");

    ring.dequeue_many_with(|buf| {
        assert_eq!(buf, b"efghijkl");
        buf[..4].copy_from_slice(b"....");
        (4, ())
    });
    assert_eq!(ring.len(), 4);
    assert_eq!(&ring.storage[..], b"........ijkl");

    assert_eq!(ring.enqueue_slice(b"abcd"), 4);
    assert_eq!(ring.len(), 8);

    ring.dequeue_many_with(|buf| {
        assert_eq!(buf, b"ijkl");
        buf[..4].copy_from_slice(b"....");
        (4, ())
    });
    ring.dequeue_many_with(|buf| {
        assert_eq!(buf, b"abcd");
        buf[..4].copy_from_slice(b"....");
        (4, ())
    });
    assert_eq!(ring.len(), 0);
    assert_eq!(&ring.storage[..], b"............");
}

#[test]
fn test_buffer_dequeue_many() {
    let mut ring = RingBuffer::new(vec![b'.'; 12]);

    assert_eq!(ring.enqueue_slice(b"abcdefghijkl"), 12);

    {
        let buf = ring.dequeue_many(8);
        assert_eq!(buf, b"abcdefgh");
        buf.copy_from_slice(b"........");
    }
    assert_eq!(ring.len(), 4);
    assert_eq!(&ring.storage[..], b"........ijkl");

    {
        let buf = ring.dequeue_many(8);
        assert_eq!(buf, b"ijkl");
        buf.copy_from_slice(b"....");
    }
    assert_eq!(ring.len(), 0);
    assert_eq!(&ring.storage[..], b"............");
}

#[test]
fn test_buffer_dequeue_slice() {
    let mut ring = RingBuffer::new(vec![b'.'; 12]);

    assert_eq!(ring.enqueue_slice(b"abcdefghijkl"), 12);

    {
        let mut buf = [0; 8];
        assert_eq!(ring.dequeue_slice(&mut buf[..]), 8);
        assert_eq!(&buf[..], b"abcdefgh");
        assert_eq!(ring.len(), 4);
    }

    assert_eq!(ring.enqueue_slice(b"abcd"), 4);

    {
        let mut buf = [0; 8];
        assert_eq!(ring.dequeue_slice(&mut buf[..]), 8);
        assert_eq!(&buf[..], b"ijklabcd");
        assert_eq!(ring.len(), 0);
    }
}

#[test]
fn test_buffer_get_unallocated() {
    let mut ring = RingBuffer::new(vec![b'.'; 12]);

    assert_eq!(ring.get_unallocated(16, 4), b"");

    {
        let buf = ring.get_unallocated(0, 4);
        buf.copy_from_slice(b"abcd");
    }
    assert_eq!(&ring.storage[..], b"abcd........");

    let buf_enqueued = ring.enqueue_many(4);
    assert_eq!(buf_enqueued.len(), 4);
    assert_eq!(ring.len(), 4);

    {
        let buf = ring.get_unallocated(4, 8);
        buf.copy_from_slice(b"ijkl");
    }
    assert_eq!(&ring.storage[..], b"abcd....ijkl");

    ring.enqueue_many(8).copy_from_slice(b"EFGHIJKL");
    ring.dequeue_many(4).copy_from_slice(b"abcd");
    assert_eq!(ring.len(), 8);
    assert_eq!(&ring.storage[..], b"abcdEFGHIJKL");

    {
        let buf = ring.get_unallocated(0, 8);
        buf.copy_from_slice(b"ABCD");
    }
    assert_eq!(&ring.storage[..], b"ABCDEFGHIJKL");
}

#[test]
fn test_buffer_write_unallocated() {
    let mut ring = RingBuffer::new(vec![b'.'; 12]);
    ring.enqueue_many(6).copy_from_slice(b"abcdef");
    ring.dequeue_many(6).copy_from_slice(b"ABCDEF");

    assert_eq!(ring.write_unallocated(0, b"ghi"), 3);
    assert_eq!(ring.get_unallocated(0, 3), b"ghi");

    assert_eq!(ring.write_unallocated(3, b"jklmno"), 6);
    assert_eq!(ring.get_unallocated(3, 3), b"jkl");

    assert_eq!(ring.write_unallocated(9, b"pqrstu"), 3);
    assert_eq!(ring.get_unallocated(9, 3), b"pqr");
}

#[test]
fn test_buffer_get_allocated() {
    let mut ring = RingBuffer::new(vec![b'.'; 12]);

    assert_eq!(ring.get_allocated(16, 4), b"");
    assert_eq!(ring.get_allocated(0, 4), b"");

    let len_enqueued = ring.enqueue_slice(b"abcd");
    assert_eq!(ring.get_allocated(0, 8), b"abcd");
    assert_eq!(len_enqueued, 4);

    let len_enqueued = ring.enqueue_slice(b"efghijkl");
    ring.dequeue_many(4).copy_from_slice(b"....");
    assert_eq!(ring.get_allocated(4, 8), b"ijkl");
    assert_eq!(len_enqueued, 8);

    let len_enqueued = ring.enqueue_slice(b"abcd");
    assert_eq!(ring.get_allocated(4, 8), b"ijkl");
    assert_eq!(len_enqueued, 4);
}

#[test]
fn test_buffer_read_allocated() {
    let mut ring = RingBuffer::new(vec![b'.'; 12]);
    ring.enqueue_many(12).copy_from_slice(b"abcdefghijkl");

    let mut data = [0; 6];
    assert_eq!(ring.read_allocated(0, &mut data[..]), 6);
    assert_eq!(&data[..], b"abcdef");

    ring.dequeue_many(6).copy_from_slice(b"ABCDEF");
    ring.enqueue_many(3).copy_from_slice(b"mno");

    let mut data = [0; 6];
    assert_eq!(ring.read_allocated(3, &mut data[..]), 6);
    assert_eq!(&data[..], b"jklmno");

    let mut data = [0; 6];
    assert_eq!(ring.read_allocated(6, &mut data[..]), 3);
    assert_eq!(&data[..], b"mno\x00\x00\x00");
}

#[test]
fn test_buffer_with_no_capacity() {
    let mut no_capacity: RingBuffer<u8> = RingBuffer::new(vec![]);

    // Call all functions that calculate the remainder against rx_buffer.capacity()
    // with a backing storage with a length of 0.
    assert_eq!(no_capacity.get_unallocated(0, 0), &[]);
    assert_eq!(no_capacity.get_allocated(0, 0), &[]);
    no_capacity.dequeue_allocated(0);
    assert_eq!(no_capacity.enqueue_many(0), &[]);
    assert_eq!(no_capacity.enqueue_one(), Err(Full));
    assert_eq!(no_capacity.contiguous_window(), 0);
}

/// Use the buffer a bit. Then empty it and put in an item of
/// maximum size. By detecting a length of 0, the implementation
/// can reset the current buffer position.
#[test]
fn test_buffer_write_wholly() {
    let mut ring = RingBuffer::new(vec![b'.'; 8]);
    ring.enqueue_many(2).copy_from_slice(b"ab");
    ring.enqueue_many(2).copy_from_slice(b"cd");
    assert_eq!(ring.len(), 4);
    let buf_dequeued = ring.dequeue_many(4);
    assert_eq!(buf_dequeued, b"abcd");
    assert_eq!(ring.len(), 0);

    let large = ring.enqueue_many(8);
    assert_eq!(large.len(), 8);
}
