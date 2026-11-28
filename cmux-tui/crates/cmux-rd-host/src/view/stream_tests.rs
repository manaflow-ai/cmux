use super::*;

fn picture(w: usize, h: usize, fill: u8) -> I420 {
    let mut p = I420::new(w, h);
    p.y.fill(fill);
    p
}

#[test]
fn the_newest_picture_wins_and_replacements_are_counted() {
    let mailbox: SharedMailbox = Arc::default();
    let mut current = picture(4, 2, 1);
    hand_off(&mailbox, &mut current, Yuv::SCREEN, 10, 11);
    current = picture(4, 2, 2);
    hand_off(&mailbox, &mut current, Yuv::SCREEN, 20, 21);
    let mut slot = mailbox.lock().unwrap();
    assert_eq!(slot.replaced, 1);
    let shown = slot.ready.take().unwrap();
    assert_eq!((shown.image.y[0], shown.complete_ns, shown.height()), (2, 20, 2));
    assert_eq!(current.y[0], 1, "the replaced buffer comes back for the next decode");
    assert!(slot.ready.is_none());
}

#[test]
fn the_decode_rate_runs_from_the_first_decoded_frame() {
    let mut stats = Stats {
        frames: 0,
        decoded: 1,
        decode_errors: 0,
        bytes: 0,
        decode_ms: Vec::new(),
        started_ns: 0,
        first_frame_ms: None,
        luma_variance: None,
        first_decoded_ns: Some(2_000_000_000),
        last_decoded_ns: 2_000_000_000,
    };
    assert_eq!(stats.decoded_fps(), None, "one frame has no rate");
    // 31 frames over the 0.5 s after the first: 60 fps, whatever came before the first.
    stats.decoded = 31;
    stats.last_decoded_ns = 2_500_000_000;
    assert_eq!(stats.decoded_fps(), Some(60.0));
    stats.first_decoded_ns = None;
    assert_eq!(stats.decoded_fps(), None);
}

#[test]
fn a_waker_wakes_a_wait_and_drains() {
    let w = Waker::new().unwrap();
    w.wake();
    let t = now_ns();
    wait_readable(&[w.fd()], Some(1_000_000_000)).unwrap();
    assert!(now_ns() - t < 500_000_000);
    w.drain();
    let t = now_ns();
    wait_readable(&[w.fd()], Some(20_000_000)).unwrap();
    assert!(now_ns() - t >= 15_000_000, "drained pipe is not readable");
}

#[test]
fn percentiles_of_samples() {
    let mut xs = vec![5.0, 1.0, 3.0, 2.0, 4.0];
    let p = pct(&mut xs);
    assert_eq!(
        (p["p50"].as_f64(), p["max"].as_f64(), p["n"].as_u64()),
        (Some(3.0), Some(5.0), Some(5))
    );
    assert!(pct(&mut []).is_null());
}

#[test]
fn ctrl_c_wakes_the_session_loop_and_marks_it_interrupted() {
    let w = Waker::new().unwrap();
    INTERRUPT_FD.store(w.0.write, Ordering::SeqCst);
    assert!(!interrupted());
    on_interrupt(libc::SIGINT);
    assert!(interrupted());
    wait_readable(&[w.fd()], Some(1_000_000_000)).unwrap();
    let mut buf = [0u8; 4];
    // SAFETY: a read into our buffer from our own non-blocking pipe.
    assert_eq!(unsafe { libc::read(w.fd(), buf.as_mut_ptr().cast(), 4) }, 1);
    INTERRUPT_FD.store(-1, Ordering::SeqCst);
}

#[test]
fn luma_variance_is_zero_for_a_flat_picture() {
    assert_eq!(luma_variance(&[16, 16, 16]), 0.0);
}

#[test]
fn luma_variance_measures_the_y_plane() {
    assert_eq!(luma_variance(&[0, 2, 4, 6]), 5.0);
}
