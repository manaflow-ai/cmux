use super::*;

#[test]
fn input_event_round_trips_its_send_time() {
    let event = input_event(12_345_678, 7);
    assert_eq!(input_sent_us(&event), Some(12_345_678));
    assert_eq!(input_sent_us(&InputEvent::Key { usage: 4, down: true }), None);
}

#[test]
fn access_unit_carries_the_stream_header() {
    let unit = access_unit(3, 1_000, 900, 100);
    assert_eq!(unit.len(), HEADER + 100);
    assert_eq!(parse_header(&unit), (KIND_FRAME, 3, 1_000, 900));
}

#[test]
fn frames_in_flight_follow_the_link_host() {
    let mut args = crate::args_from(Vec::new());
    assert_eq!(frames_in_flight(&args), 2);
    args.rtt_ms = 100;
    assert_eq!(frames_in_flight(&args), 6);
    args.rtt_ms = 30;
    assert_eq!(frames_in_flight(&args), 3);
    args.rd_frames_in_flight = 9;
    assert_eq!(frames_in_flight(&args), 9);
}

/// The automatic RTT-sized bound keeps the 50 ms bench above the issue's
/// 50 fps on-time target (the old one-frame bound measured 16.1 fps).
#[tokio::test(flavor = "multi_thread")]
async fn fifty_ms_rtt_keeps_on_time_fps_above_fifty() {
    let mut args = crate::args_from(Vec::new());
    args.path = "rd-link".into();
    args.rtt_ms = 50;
    args.seconds = 6;
    args.bulk_bytes = 0;
    let clock = Arc::new(Clock(Instant::now()));
    let record: Shared = Arc::default();
    run(&args, clock, record.clone()).await.expect("bench");
    let record = lock(&record);
    let received = record.frame_us.len() as u64 + u64::from(record.first_frame_us.is_some());
    let on_time = (received.saturating_sub(record.late)) as f64 / args.seconds as f64;
    assert!(on_time >= 50.0, "on-time fps {on_time:.1} below 50");
}

/// The whole path on a lossy link: frames still arrive (FEC and NACKs
/// repair them), and input reaches the host and comes back as photons.
#[tokio::test(flavor = "multi_thread")]
async fn frames_and_input_cross_a_lossy_link() {
    let mut args = crate::args_from(Vec::new());
    args.path = "rd-link".into();
    args.seconds = 2;
    args.rtt_ms = 20;
    args.loss_pct = 3.0;
    let clock = Arc::new(Clock(Instant::now()));
    let record: Shared = Arc::default();
    run(&args, clock, record.clone()).await.unwrap();
    let record = lock(&record);
    assert!(record.first_frame_us.is_some(), "the keyframe arrived");
    // 2 s at 60 fps is 120 frames; at 3 % loss nearly all must arrive.
    assert!(record.frame_us.len() >= 90, "{} frames", record.frame_us.len());
    assert!(record.input_us.len() >= 50, "{} inputs", record.input_us.len());
    assert!(!record.photon_us.is_empty());
    assert!(record.note.contains("resent") && record.note.contains("parity"));
}
