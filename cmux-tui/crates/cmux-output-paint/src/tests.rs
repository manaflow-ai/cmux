use super::*;

fn stamps(events: &[(u64, u64)]) -> SendStamps {
    let mut s = SendStamps::default();
    for &(bytes, at_us) in events {
        s.sent(bytes, at_us);
    }
    s
}

#[test]
fn each_event_is_timed_to_the_first_frame_that_painted_all_of_it() {
    // Three events of 10 bytes at 0, 5 and 10 ms.
    let s = stamps(&[(10, 0), (10, 5_000), (10, 10_000)]);
    assert_eq!(s.offset(), 30);
    // A frame at 1 ms had nothing; at 9 ms the first 15 bytes (event 1 whole, event 2 half);
    // at 20 ms everything.
    let paints = [
        Paint { through: 0, at_us: 1_000 },
        Paint { through: 15, at_us: 9_000 },
        Paint { through: 30, at_us: 20_000 },
    ];
    let w = window(&s, &paints, Some(4.0)).unwrap();
    // 9 - 0, 20 - 5, 20 - 10.
    assert_eq!(w.raw, Column { events: 3, p50_ms: 10.0, p95_ms: 15.0, max_ms: 15.0 });
    assert_eq!(
        w.less_half_rtt,
        Some(Column { events: 3, p50_ms: 6.0, p95_ms: 11.0, max_ms: 11.0 })
    );
    assert!(!w.partial);
    assert_eq!(w.ahead, 0);
}

#[test]
fn output_the_first_frame_already_held_is_not_counted() {
    let s = stamps(&[(10, 0), (10, 5_000)]);
    let paints = [Paint { through: 10, at_us: 100_000 }, Paint { through: 20, at_us: 6_000 }];
    // Sorted by time: the 6 ms frame is first and holds 20: nothing new after it.
    assert_eq!(window(&s, &paints, None), None);
    let paints = [Paint { through: 10, at_us: 1_000 }, Paint { through: 20, at_us: 8_000 }];
    let w = window(&s, &paints, None).unwrap();
    assert_eq!((w.raw.events, w.raw.max_ms), (1, 3.0));
    assert_eq!(w.less_half_rtt, None);
}

#[test]
fn a_frame_ahead_of_what_was_sent_is_clamped_and_counted() {
    let s = stamps(&[(10, 0)]);
    let paints = [Paint { through: 0, at_us: 0 }, Paint { through: 12, at_us: 2_000 }];
    let w = window(&s, &paints, None).unwrap();
    assert_eq!((w.raw.events, w.ahead), (1, 1));
}

#[test]
fn the_ring_is_bounded_and_says_when_it_lost_the_window_start() {
    let mut s = SendStamps::new(4);
    for i in 0..10u64 {
        s.sent(1, i * 1_000);
    }
    assert_eq!(s.len(), 4);
    assert_eq!(s.offset(), 10);
    let paints = [Paint { through: 2, at_us: 0 }, Paint { through: 10, at_us: 20_000 }];
    let w = window(&s, &paints, None).unwrap();
    assert!(w.partial);
    assert_eq!(w.raw.events, 4, "only the kept events");
    // A ring that kept everything is not partial.
    let s = stamps(&[(1, 0), (1, 1_000)]);
    let w = window(&s, &[Paint { through: 0, at_us: 0 }, Paint { through: 2, at_us: 3_000 }], None)
        .unwrap();
    assert!(!w.partial);
    assert_eq!(s.first_kept(), 0);
}

#[test]
fn a_reported_frame_lands_on_the_macs_clock_by_its_age() {
    assert_eq!(Paint::reported(5, 12.5, 100_000), Paint { through: 5, at_us: 87_500 });
    assert_eq!(Paint::reported(5, f64::NAN, 100_000).at_us, 100_000);
    assert_eq!(Paint::reported(5, 1e9, 100).at_us, 0);
}

#[test]
fn empty_events_and_base64_lengths() {
    let s = stamps(&[(0, 0)]);
    assert!(s.is_empty());
    assert_eq!(base64_decoded_len(4, 0), 3);
    assert_eq!(base64_decoded_len(8, 1), 5);
    assert_eq!(base64_decoded_len(8, 2), 4);
    assert_eq!(base64_decoded_len(0, 0), 0);
}
