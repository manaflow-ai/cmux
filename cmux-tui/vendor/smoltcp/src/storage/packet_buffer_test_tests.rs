use super::*;

fn buffer() -> PacketBuffer<'static, ()> {
    PacketBuffer::new(vec![PacketMetadata::EMPTY; 4], vec![0u8; 16])
}

#[test]
fn test_simple() {
    let mut buffer = buffer();
    buffer.enqueue(6, ()).unwrap().copy_from_slice(b"abcdef");
    assert_eq!(buffer.enqueue(16, ()), Err(Full));
    assert_eq!(buffer.metadata_ring.len(), 1);
    assert_eq!(buffer.dequeue().unwrap().1, &b"abcdef"[..]);
    assert_eq!(buffer.dequeue(), Err(Empty));
}

#[test]
fn test_peek() {
    let mut buffer = buffer();
    assert_eq!(buffer.peek(), Err(Empty));
    buffer.enqueue(6, ()).unwrap().copy_from_slice(b"abcdef");
    assert_eq!(buffer.metadata_ring.len(), 1);
    assert_eq!(buffer.peek().unwrap().1, &b"abcdef"[..]);
    assert_eq!(buffer.dequeue().unwrap().1, &b"abcdef"[..]);
    assert_eq!(buffer.peek(), Err(Empty));
}

#[test]
fn test_padding() {
    let mut buffer = buffer();
    assert!(buffer.enqueue(6, ()).is_ok());
    assert!(buffer.enqueue(8, ()).is_ok());
    assert!(buffer.dequeue().is_ok());
    buffer.enqueue(4, ()).unwrap().copy_from_slice(b"abcd");
    assert_eq!(buffer.metadata_ring.len(), 3);
    assert!(buffer.dequeue().is_ok());

    assert_eq!(buffer.dequeue().unwrap().1, &b"abcd"[..]);
    assert_eq!(buffer.metadata_ring.len(), 0);
}

#[test]
fn test_padding_with_large_payload() {
    let mut buffer = buffer();
    assert!(buffer.enqueue(12, ()).is_ok());
    assert!(buffer.dequeue().is_ok());
    buffer
        .enqueue(12, ())
        .unwrap()
        .copy_from_slice(b"abcdefghijkl");
}

#[test]
fn test_dequeue_with() {
    let mut buffer = buffer();
    assert!(buffer.enqueue(6, ()).is_ok());
    assert!(buffer.enqueue(8, ()).is_ok());
    assert!(buffer.dequeue().is_ok());
    buffer.enqueue(4, ()).unwrap().copy_from_slice(b"abcd");
    assert_eq!(buffer.metadata_ring.len(), 3);
    assert!(buffer.dequeue().is_ok());

    assert!(matches!(
        buffer.dequeue_with(|_, _| Result::<(), u32>::Err(123)),
        Ok(Err(_))
    ));
    assert_eq!(buffer.metadata_ring.len(), 1);

    assert!(
        buffer
            .dequeue_with(|&mut (), payload| {
                assert_eq!(payload, &b"abcd"[..]);
                Result::<(), ()>::Ok(())
            })
            .is_ok()
    );
    assert_eq!(buffer.metadata_ring.len(), 0);
}

#[test]
fn test_metadata_full_empty() {
    let mut buffer = buffer();
    assert!(buffer.is_empty());
    assert!(!buffer.is_full());
    assert!(buffer.enqueue(1, ()).is_ok());
    assert!(!buffer.is_empty());
    assert!(buffer.enqueue(1, ()).is_ok());
    assert!(buffer.enqueue(1, ()).is_ok());
    assert!(!buffer.is_full());
    assert!(!buffer.is_empty());
    assert!(buffer.enqueue(1, ()).is_ok());
    assert!(buffer.is_full());
    assert!(!buffer.is_empty());
    assert_eq!(buffer.metadata_ring.len(), 4);
    assert_eq!(buffer.enqueue(1, ()), Err(Full));
}

#[test]
fn test_window_too_small() {
    let mut buffer = buffer();
    assert!(buffer.enqueue(4, ()).is_ok());
    assert!(buffer.enqueue(8, ()).is_ok());
    assert!(buffer.dequeue().is_ok());
    assert_eq!(buffer.enqueue(16, ()), Err(Full));
    assert_eq!(buffer.metadata_ring.len(), 1);
}

#[test]
fn test_contiguous_window_too_small() {
    let mut buffer = buffer();
    assert!(buffer.enqueue(4, ()).is_ok());
    assert!(buffer.enqueue(8, ()).is_ok());
    assert!(buffer.dequeue().is_ok());
    assert_eq!(buffer.enqueue(8, ()), Err(Full));
    assert_eq!(buffer.metadata_ring.len(), 1);
}

#[test]
fn test_contiguous_window_wrap() {
    let mut buffer = buffer();
    assert!(buffer.enqueue(15, ()).is_ok());
    assert!(buffer.dequeue().is_ok());
    assert!(buffer.enqueue(16, ()).is_ok());
}

#[test]
fn test_capacity_too_small() {
    let mut buffer = buffer();
    assert_eq!(buffer.enqueue(32, ()), Err(Full));
}

#[test]
fn test_contig_window_prioritized() {
    let mut buffer = buffer();
    assert!(buffer.enqueue(4, ()).is_ok());
    assert!(buffer.dequeue().is_ok());
    assert!(buffer.enqueue(5, ()).is_ok());
}

#[test]
fn test_enqueue_fallible_full_metadata_fn_not_called() {
    // Fill the metadata buffer except 1 byte and then make room at the start
    let mut buffer = PacketBuffer::new(vec![PacketMetadata::EMPTY; 4], vec![0u8; 16]);

    assert!(buffer.enqueue(12, ()).is_ok());
    assert!(buffer.enqueue(1, ()).is_ok());
    assert!(buffer.enqueue(1, ()).is_ok());
    assert!(buffer.enqueue(1, ()).is_ok());
    let dequeued_buf = buffer.dequeue().unwrap();
    assert_eq!(dequeued_buf.1.len(), 12);

    // At this point there is room at the start of the payload storage
    // and 1 byte at the end of the payload storage
    // but only one metadata slot.
    assert!(
        buffer
            .enqueue_with_infallible(5, (), |_| {
                panic!("This enqueue should fail and this closure should not be called")
            })
            .is_err()
    );
}

#[test]
fn clear() {
    let mut buffer = buffer();

    // Ensure enqueuing data in the buffer fills it somewhat.
    assert!(buffer.is_empty());
    assert!(buffer.enqueue(6, ()).is_ok());

    // Ensure that resetting the buffer causes it to be empty.
    assert!(!buffer.is_empty());
    buffer.reset();
    assert!(buffer.is_empty());
}
