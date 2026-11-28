//! The session report: first frame from connect, whole-session percentiles
//! past the ledger's window, Total only with a clock offset.

use cmux_rd_core::ledger::{FrameRow, ViewerTimes};
use cmux_rd_core::session_report::{SCHEMA, SessionReport};
use cmux_rd_proto::FrameTimes;

fn row(display_us: u64, decoded_us: u64) -> FrameRow {
    FrameRow {
        host: Some(FrameTimes { display_us, ..FrameTimes::default() }),
        viewer: ViewerTimes { decoded_us: Some(decoded_us), ..ViewerTimes::default() },
        ..FrameRow::default()
    }
}

#[test]
fn first_frame_counts_from_the_first_connect_start() {
    let mut r = SessionReport::new();
    assert_eq!(r.summary().first_frame_ms, None);
    r.note_connect_started(1_000_000);
    r.note_connect_started(1_500_000);
    r.on_presented(None, None, 1_640_000);
    r.on_presented(None, None, 1_700_000);
    let s = r.summary();
    assert_eq!(s.first_frame_ms, Some(640.0));
    assert_eq!(s.frames_presented, 2);
    assert!(s.total.is_none() && s.present.is_none(), "no ledger row: counted, not timed");
}

#[test]
fn percentiles_cover_every_frame_not_only_the_ledger_window() {
    let mut r = SessionReport::new();
    r.note_connect_started(0);
    // 10_000 frames (past the ledger's 4096): 95 % at 20 ms display-to-glass, 5 % at 80 ms.
    for i in 0..10_000u64 {
        let presented = 1_000_000 + i * 16_000;
        let total_us = if i % 20 == 0 { 80_000 } else { 20_000 };
        // offset 500 us: host = viewer + 500.
        let display = presented + 500 - total_us;
        r.on_presented(Some(&row(display, presented - 4_000)), Some(500), presented);
    }
    let s = r.summary();
    let total = s.total.expect("total");
    assert_eq!(total.n, 10_000);
    assert_eq!(total.p50_ms, 20.0);
    assert_eq!(total.p95_ms, 20.0);
    let present = s.present.expect("present");
    assert_eq!((present.p50_ms, present.p95_ms), (4.0, 4.0));
    let json = s.to_json();
    assert!(
        json.starts_with(&format!("{{\"schema\":\"{SCHEMA}\",\"first_frame_ms\":1000.0,")),
        "{json}"
    );
    assert!(json.contains("\"total\":{\"n\":10000,\"p50_ms\":20.0,\"p95_ms\":20.0}"), "{json}");
}

#[test]
fn a_slow_tail_reads_at_p95_and_above_two_seconds_reads_its_largest() {
    let mut r = SessionReport::new();
    for i in 0..100u64 {
        let total_us = if i < 90 { 10_000 } else { 2_600_000 };
        r.on_presented(Some(&row(10_000_000 - total_us, 9_999_000)), Some(0), 10_000_000);
    }
    let total = r.summary().total.expect("total");
    assert_eq!(total.p50_ms, 10.0);
    assert_eq!(total.p95_ms, 2600.0);
}
