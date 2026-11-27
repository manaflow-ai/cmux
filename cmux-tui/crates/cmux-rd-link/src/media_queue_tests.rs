use super::*;

#[test]
fn newest_frame_replaces_oldest_as_a_whole() {
    let mut queue = MediaQueue::default();
    queue.push(MediaFrame {
        datagrams: vec![b"old-a".to_vec(), b"old-b".to_vec(), b"old-c".to_vec()],
        droppable: true,
    });
    queue.push(MediaFrame {
        datagrams: vec![b"new-a".to_vec(), b"new-b".to_vec()],
        droppable: true,
    });

    assert_eq!(queue.stats().dropped_frames, 1);
    assert_eq!(queue.stats().dropped_datagrams, 3);
    assert_eq!(queue.stats().dropped_replaced_frames, 1);
    assert_eq!(queue.stats().dropped_replaced_datagrams, 3);
    assert_eq!(queue.stats().queue_frames, 1);
    assert_eq!(queue.stats().queue_datagrams, 2);
    assert_eq!(
        queue.pop().map(|frame| frame.datagrams),
        Some(vec![b"new-a".to_vec(), b"new-b".to_vec()])
    );
    assert!(queue.pop().is_none(), "old frame fragments must not survive");
    assert_eq!(queue.stats().queue_datagrams, 0);
}

#[test]
fn empty_frame_does_not_consume_capacity_or_count_as_drop() {
    let mut queue = MediaQueue::default();
    queue.push(MediaFrame { datagrams: Vec::new(), droppable: true });
    assert_eq!(queue.stats(), NetStats::default());
}

#[test]
fn protected_frames_survive_a_new_protected_frame() {
    let mut queue = MediaQueue::default();
    queue.push(MediaFrame { datagrams: vec![b"delta".to_vec()], droppable: true });
    queue.push(MediaFrame { datagrams: vec![b"key".to_vec()], droppable: false });
    queue.push(MediaFrame { datagrams: vec![b"recovery".to_vec()], droppable: false });

    assert_eq!(queue.stats().dropped_datagrams, 1);
    assert_eq!(queue.stats().dropped_evicted_for_protected_frames, 1);
    assert_eq!(queue.stats().dropped_evicted_for_protected_datagrams, 1);
    assert_eq!(queue.pop().map(|frame| frame.datagrams), Some(vec![b"key".to_vec()]));
    assert_eq!(queue.pop().map(|frame| frame.datagrams), Some(vec![b"recovery".to_vec()]));
}

#[test]
fn droppable_frame_is_rejected_behind_two_protected_frames() {
    let mut queue = MediaQueue::default();
    queue.push(MediaFrame { datagrams: vec![b"key".to_vec()], droppable: false });
    queue.push(MediaFrame { datagrams: vec![b"recovery".to_vec()], droppable: false });
    queue.push(MediaFrame { datagrams: vec![b"delta".to_vec(), b"fec".to_vec()], droppable: true });

    let stats = queue.stats();
    assert_eq!(stats.queue_frames, 2);
    assert_eq!(stats.queue_datagrams, 2);
    assert_eq!(stats.dropped_rejected_protected_frames, 1);
    assert_eq!(stats.dropped_rejected_protected_datagrams, 2);
    assert_eq!(queue.pop().map(|frame| frame.datagrams), Some(vec![b"key".to_vec()]));
    assert_eq!(queue.pop().map(|frame| frame.datagrams), Some(vec![b"recovery".to_vec()]));
    assert!(queue.pop().is_none());
    assert_eq!(queue.stats().queue_datagrams, 0);
}
