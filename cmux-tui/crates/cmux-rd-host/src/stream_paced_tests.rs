use super::{FrameTimes, PacedFrame, PacedFrames};

fn paced(frame: u32, remaining: usize) -> PacedFrame {
    PacedFrame { remaining, stream: 0, frame, times: FrameTimes::default(), line: None }
}

#[test]
fn paced_frames_get_their_first_and_last_send_from_the_pacers_releases() {
    let mut q = PacedFrames::default();
    q.push(paced(1, 3));
    q.push(paced(2, 2));
    // Two of frame 1's three datagrams: nothing done yet.
    assert!(q.sent(2, 10, 11).is_empty());
    // Frame 1's last and frame 2's first.
    let done = q.sent(2, 20, 21);
    assert_eq!(done.len(), 1);
    let (f1, t1) = (done[0].frame, done[0].times);
    assert_eq!((f1, t1.first_sent_us, t1.last_sent_us), (1, 10, 21));
    // Frame 2's last: its first send was the release at 20, not this one.
    let done = q.sent(1, 30, 31);
    let (f2, t2) = (done[0].frame, done[0].times);
    assert_eq!((f2, t2.first_sent_us, t2.last_sent_us), (2, 20, 31));
    assert!(q.sent(5, 40, 41).is_empty());
}

#[test]
fn forgotten_frames_leave_the_queue() {
    let mut q = PacedFrames::default();
    q.push(paced(1, 1));
    q.push(paced(2, 1));
    q.forget(|_, frame| frame == 1);
    let left: Vec<u32> = q.0.iter().map(|f| f.frame).collect();
    assert_eq!(left, vec![2]);
}
