use super::*;

fn sample(x: i32, image: Option<CursorImage>) -> CursorSample {
    let shape = image.as_ref().map_or(7, CursorImage::id);
    CursorSample { x, y: 10, visible: true, shape, image }
}

fn arrow() -> CursorImage {
    CursorImage {
        width: 1,
        height: 2,
        hot_x: 0,
        hot_y: 0,
        rgba: vec![0, 0, 0, 255, 255, 255, 255, 255],
    }
}

#[test]
fn a_new_shape_goes_once_before_its_first_position() {
    let mut ch = CursorChannel::new();
    let out = ch.on_sample(&sample(1, Some(arrow())), 0);
    let Some(Control::CursorShape { shape, width, height, rgba, .. }) = out.shape else {
        panic!("no shape");
    };
    assert_eq!((shape, width, height), (arrow().id(), 1, 2));
    assert_eq!(cmux_rd_proto::base64_decode(&rgba), Some(arrow().rgba));
    let (seq, pos) = CursorPos::from_datagram(&out.datagram.expect("position")).expect("decode");
    assert_eq!((seq, pos.shape, pos.x), (1, shape, 1));
    // The same shape again, as a desktop reports it after another shape came between.
    let again = ch.on_sample(&sample(2, Some(arrow())), 1_000);
    assert!(again.shape.is_none());
    assert!(again.datagram.is_some());
}

#[test]
fn a_still_cursor_is_repeated_once_then_kept_alive_and_polled_slowly() {
    let mut ch = CursorChannel::new();
    assert!(ch.on_sample(&sample(1, None), 0).datagram.is_some());
    assert_eq!(ch.next_deadline_us(), FAST_POLL_US);
    // Unchanged before the repeat: nothing.
    assert!(ch.on_sample(&sample(1, None), 8_000).datagram.is_none());
    // The one repeat.
    let repeat = ch.on_sample(&sample(1, None), REPEAT_US).datagram.expect("repeat");
    assert_eq!(CursorPos::from_datagram(&repeat).expect("decode").0, 2);
    assert!(ch.on_sample(&sample(1, None), REPEAT_US + 100_000).datagram.is_none());
    // Still for a second: slow polls, then a keepalive.
    ch.on_sample(&sample(1, None), ACTIVE_US + 1);
    assert_eq!(ch.next_deadline_us(), ACTIVE_US + 1 + IDLE_POLL_US);
    assert!(ch.on_sample(&sample(1, None), REPEAT_US + KEEPALIVE_US).datagram.is_some());
}

#[test]
fn every_change_is_sent_with_a_newer_sequence() {
    let mut ch = CursorChannel::new();
    let mut last = 0;
    for (i, x) in [1, 2, 3, 3, 4].into_iter().enumerate() {
        let now = i as u64 * 1_000;
        if let Some(d) = ch.on_sample(&sample(x, None), now).datagram {
            let (seq, pos) = CursorPos::from_datagram(&d).expect("decode");
            assert!(cmux_rd_proto::cursor_seq_newer(seq, last));
            assert_eq!(pos.x, x);
            last = seq;
        }
    }
    assert_eq!(last, 4, "the unchanged reading sent nothing");
    let hidden = CursorSample { visible: false, ..sample(4, None) };
    assert!(ch.on_sample(&hidden, 5_000).datagram.is_some(), "visibility is a change");
}

#[test]
fn the_sent_shape_memory_is_bounded() {
    let mut ch = CursorChannel::new();
    for i in 0..(SENT_SHAPES as u32 + 1) {
        let image = CursorImage { hot_x: i, ..arrow() };
        assert!(ch.on_sample(&sample(1, Some(image)), u64::from(i)).shape.is_some());
    }
    // The first one was forgotten: seen again, it is sent again.
    assert!(ch.on_sample(&sample(1, Some(arrow())), 100).shape.is_some());
}
