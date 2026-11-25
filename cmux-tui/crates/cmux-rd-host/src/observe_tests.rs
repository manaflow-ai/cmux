use super::*;

#[test]
fn observe_requires_exact_next_counter_and_post_input_timestamp() {
    assert_eq!(response(7, 1000, 8, 999), Ok(None));
    assert_eq!(response(7, 1000, 8, 1000), Ok(None));
    assert_eq!(response(7, 1000, 7, 1100), Ok(None));
    assert_eq!(response(7, 1000, 8, 3500), Ok(Some(2500)));
    assert_eq!(response(u16::MAX, 1000, 0, 3500), Ok(Some(2500)));
    assert!(response(7, 1000, 9, 3500).is_err());
}

#[test]
fn observe_rejects_other_connection_and_occlusion() {
    let target = Window { id: 2, pid: 40, rect: [0.0, 0.0, 100.0, 100.0] };
    let cover = Window { id: 3, pid: 40, rect: [50.0, 0.0, 50.0, 100.0] };
    assert!(unobscured(&[target], 2, 40, &[(10.0, 10.0), (90.0, 10.0)]));
    assert!(!unobscured(&[cover, target], 2, 40, &[(10.0, 10.0), (90.0, 10.0)]));
    assert!(!unobscured(&[target], 2, 41, &[(10.0, 10.0)]));
    assert!(!unobscured(&[target], 2, 40, &[(100.0, 10.0)]));
    assert!(!unobscured(&[target], 2, 40, &[]));
}

#[test]
fn observe_marker_guards_bounds_and_scaled_cells() {
    let stride = 100;
    let mut plane = vec![16; stride * 8];
    for (i, on) in crate::marker::cells(257).iter().enumerate() {
        plane[4 * stride + 3 + i * 4 + 2] = if *on { 235 } else { 16 };
    }
    assert_eq!(read_marker(&plane, stride, (3, 2), 4), Some(257));
    plane[4 * stride + 3 + 18 * 4 + 2] = 128;
    assert_eq!(read_marker(&plane, stride, (3, 2), 4), None);
    assert_eq!(read_marker(&plane, stride, (usize::MAX, 2), 4), None);
    assert_eq!(read_marker(&plane, stride, (90, 2), 4), None);
}

#[test]
fn observe_reports_nearest_rank_over_all_samples() {
    assert_eq!(percentiles(&[]), None);
    assert_eq!(percentiles(&[9000, 1000, 3000, 2000]), Some((2.0, 9.0)));
    assert_eq!(percentiles(&[3500]), Some((3.5, 3.5)));
}

#[test]
fn passive_series_accepts_wrap_and_reports_gaps() {
    let mut series = PresentedSeries::with_baseline(Some(u16::MAX));
    for counter in [u16::MAX, 0, 2] {
        series.ingest(PresentedMarkerSample {
            counter: Some(counter),
            nonce: None,
            display_us: Some(u64::from(counter)),
            arrived_us: u64::from(counter),
        });
    }
    assert_eq!(series.presented_frames, 2);
    assert_eq!(series.gaps, 1);
    assert_eq!(series.first_counter, Some(0));
    assert_eq!(series.last_counter, Some(2));
}

#[test]
fn passive_series_ignores_repeats_and_counts_invalid_samples() {
    let mut series = PresentedSeries::with_baseline(Some(4));
    let sample = |counter| PresentedMarkerSample {
        counter,
        nonce: None,
        display_us: Some(10),
        arrived_us: 20,
    };
    series.ingest(sample(Some(4)));
    series.ingest(sample(Some(5)));
    series.ingest(sample(Some(5)));
    series.ingest(sample(None));
    assert_eq!(series.presented_frames, 1);
    assert_eq!(series.repeated, 2);
    assert_eq!(series.invalid, 1);
}

#[test]
fn passive_queue_reports_bounded_overflow() {
    let mut queue = PresentedSampleQueue::with_capacity(1);
    let sample =
        PresentedMarkerSample { counter: Some(1), nonce: None, display_us: None, arrived_us: 0 };
    queue.push(sample);
    queue.push(sample);
    assert_eq!(queue.len(), 1);
    assert!(queue.overflowed());
    assert_eq!(queue.take(), vec![sample]);
}

#[test]
fn passive_series_requires_a_post_start_counter() {
    let mut series = PresentedSeries::with_baseline(Some(9));
    series.ingest(PresentedMarkerSample {
        counter: Some(9),
        nonce: None,
        display_us: Some(100),
        arrived_us: 100,
    });
    assert_eq!(series.presented_frames, 0);
    series.ingest(PresentedMarkerSample {
        counter: Some(10),
        nonce: None,
        display_us: Some(110),
        arrived_us: 111,
    });
    assert_eq!(series.presented_frames, 1);
    assert_eq!(series.first_arrived_us, Some(111));
}

#[test]
fn passive_nonce_rows_are_little_endian_and_guarded() {
    let stride = 200;
    let cell = 4;
    let mut plane = vec![16; stride * 40];
    let words = [0x1100, 0x3322, 0x5544, 0x7766, 0x9988, 0xbbaa, 0xddcc, 0xffee];
    for (row, word) in std::iter::once(0x0042).chain(words).enumerate() {
        for (index, on) in crate::marker::cells(word).iter().enumerate() {
            plane[(row * cell + cell / 2) * stride + index * cell + cell / 2] =
                if *on { 235 } else { 16 };
        }
    }
    let (_, nonce) = read_marker_nonce(&plane, stride, (0, 0), cell).expect("nonce");
    assert_eq!(nonce, *b"\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff");
}

#[test]
fn passive_series_rejects_wrong_expected_nonce() {
    let expected = [7u8; 16];
    let mut series = PresentedSeries::with_baseline_and_nonce(Some(1), Some(expected));
    series.ingest(PresentedMarkerSample {
        counter: Some(2),
        nonce: Some([8u8; 16]),
        display_us: Some(10),
        arrived_us: 11,
    });
    assert_eq!(series.presented_frames, 0);
    assert_eq!(series.nonce_mismatch, 1);
    series.ingest(PresentedMarkerSample {
        counter: Some(2),
        nonce: Some(expected),
        display_us: Some(12),
        arrived_us: 13,
    });
    assert_eq!(series.presented_frames, 1);
}

#[test]
fn passive_baseline_gap_and_backwards_are_not_frames() {
    let mut series = PresentedSeries::with_baseline(Some(100));
    let sample = |counter| PresentedMarkerSample {
        counter: Some(counter),
        nonce: None,
        display_us: Some(1000),
        arrived_us: 1001,
    };
    series.ingest(sample(103));
    assert_eq!(series.gaps, 2);
    series.ingest(sample(102));
    assert_eq!(series.reversed, 1);
    assert_eq!(series.presented_frames, 1);
    series.ingest(PresentedMarkerSample { display_us: None, ..sample(104) });
    assert_eq!(series.invalid, 1);
    assert_eq!(series.presented_frames, 1);
}
