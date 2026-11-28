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

fn host_row(display_us: u64) -> FrameRow {
    FrameRow {
        host: Some(FrameTimes { display_us, ..FrameTimes::default() }),
        ..FrameRow::default()
    }
}

#[test]
fn a_late_picture_is_a_freeze_and_an_idle_screen_is_not() {
    let mut r = SessionReport::new();
    // 60 fps for a second: host display and glass 16 ms apart.
    let mut t = 1_000_000u64;
    for _ in 0..60 {
        r.on_main_presented(Some(&host_row(t - 30_000)), Some(0), t);
        t += 16_000;
    }
    // The screen goes still for 5 s: no host frame, no frame on glass. Not a freeze.
    t += 5_000_000;
    r.on_main_presented(Some(&host_row(t - 30_000)), Some(0), t);
    // The network holds a frame: the host showed it 16 ms after the last, glass 516 ms after.
    let prev_display = t - 30_000;
    t += 516_000;
    r.on_main_presented(Some(&host_row(prev_display + 16_000)), Some(0), t);
    let s = r.summary();
    assert_eq!(s.freezes, 1, "{s:?}");
    assert_eq!(s.frozen_ms, 500.0);
    assert_eq!(s.freeze_unattributed, 0);
    // A long gap without host times is not counted either way.
    t += 900_000;
    r.on_main_presented(None, None, t);
    let s = r.summary();
    assert_eq!((s.freezes, s.freeze_unattributed), (1, 1));
}

#[test]
fn a_short_hitch_under_the_floor_is_not_a_freeze() {
    let mut r = SessionReport::new();
    let mut t = 0u64;
    for i in 0..120u64 {
        // One 150 ms hitch the host did not share.
        let gap = if i == 60 { 150_000 } else { 16_000 };
        t += gap;
        r.on_main_presented(Some(&host_row(i * 16_000)), Some(0), t);
    }
    assert_eq!(r.summary().freezes, 0);
}

#[test]
fn stalls_resumes_keyframes_and_the_end_are_counted() {
    use cmux_rd_proto::flags::{KEYFRAME, RECOVERY};
    let mut r = SessionReport::new();
    r.on_released(KEYFRAME);
    r.on_released(0);
    r.on_main_presented(None, None, 1_000_000);
    // Silent from 2.0 s, stalled (called again by every tick), heard at 4.5 s.
    r.on_stalled(2_000_000);
    r.on_stalled(2_000_000);
    r.on_heard(4_500_000);
    r.on_heard(4_600_000); // no stall open: nothing
    r.on_released(KEYFRAME | RECOVERY);
    r.on_main_presented(None, None, 4_620_000);
    r.on_main_presented(None, None, 4_640_000); // only the first after a resume counts
    let s = r.summary();
    assert_eq!((s.stalls, s.stalled_ms), (1, 2500.0));
    let resume = s.resume_first_frame.expect("resume");
    assert_eq!((resume.n, resume.p50_ms), (1, 120.0));
    assert_eq!((s.keyframes, s.recovery_frames), (2, 1));
    assert!(!s.ended_stalled);
    let json = s.to_json();
    assert!(json.contains("\"stalls\":1,\"stalled_ms\":2500.0,\"resume_first_frame\":{\"n\":1,\"p50_ms\":120.0,\"p95_ms\":120.0},\"keyframes\":2,\"recovery_frames\":1,\"end\":\"live\"}"), "{json}");
    // Silent again and read before any byte: the session ended stalled.
    r.on_stalled(5_000_000);
    let s = r.summary();
    assert_eq!(s.stalls, 2);
    assert!(s.ended_stalled && s.to_json().ends_with("\"end\":\"stalled\"}"));
}
