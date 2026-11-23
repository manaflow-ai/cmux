//! The stage ledger (D8): rows join host and viewer times by stream and frame,
//! stages come out on the host clock, and stages a viewer cannot fill say why.

use cmux_rd_core::ledger::{MAX_ROWS, SCHEMA, StageLedger, percentiles};
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_proto::{DatagramHeader, DatagramKind, FrameBody, FrameTimes, REF_NONE};

/// Host times of frame `f`: display at 1000 µs steps, then 2 / 3 / 4 / 1 ms per stage.
fn host(f: u64) -> FrameTimes {
    let display = 1_000_000 + f * 16_667;
    FrameTimes {
        display_us: display,
        encode_start_us: display + 2_000,
        encoded_us: display + 5_000,
        first_sent_us: display + 5_100,
        last_sent_us: display + 9_000,
    }
}

/// Feeds frame `f` through every viewer stamp; the viewer clock is the host's minus `offset`.
fn viewer(l: &mut StageLedger, f: u32, offset: i64, present: bool) {
    let h = host(u64::from(f));
    let v = |host_us: u64| (host_us as i64 - offset) as u64;
    l.on_shard(0, f, 1_200, v(h.last_sent_us + 500));
    l.on_shard(0, f, 1_200, v(h.last_sent_us + 1_000));
    l.on_host(0, f, h);
    l.on_released(0, f, v(h.last_sent_us + 1_000), v(h.last_sent_us + 1_250));
    l.on_decoded(0, f, v(h.last_sent_us + 4_250));
    if present {
        l.on_presented(0, f, v(h.last_sent_us + 12_250));
    }
}

fn stage<'a>(
    s: &'a cmux_rd_core::ledger::Summary,
    name: &str,
) -> &'a cmux_rd_core::ledger::StageRow {
    s.stages.iter().find(|r| r.def.name == name).expect("stage")
}

#[test]
fn every_stage_comes_out_on_the_host_clock() {
    let mut l = StageLedger::new();
    let offset = -7_000_000; // host = viewer - 7 s
    for f in 1..=60 {
        viewer(&mut l, f, offset, true);
    }
    let s = l.summary(Some(offset), &[]);
    let p50 = |name| stage(&s, name).value.map(|p| p.p50_ms);
    assert_eq!(p50("Capture"), Some(2.0));
    assert_eq!(p50("Encode"), Some(3.0));
    assert_eq!(p50("Send"), Some(4.0));
    assert_eq!(p50("Network"), Some(1.0));
    // First shard 0.5 ms after the last send, 4.4 ms after the first; the shards arrived
    // 0.5 ms apart after leaving 3.9 ms apart. The two add up to Network.
    assert_eq!(p50("Transport"), Some(4.4));
    let recovery = p50("Recovery").expect("recovery");
    assert!((recovery - -3.4).abs() < 1e-9, "{recovery}");
    assert!((4.4 + recovery - 1.0).abs() < 1e-9);
    assert_eq!(p50("Reassembly"), Some(0.25));
    assert_eq!(p50("Decode"), Some(3.0));
    assert_eq!(p50("Present"), Some(8.0));
    assert_eq!(p50("Total"), Some(2.0 + 3.0 + 4.0 + 1.0 + 0.25 + 3.0 + 8.0));
    assert_eq!(s.frames, 60);
    assert_eq!(s.frames_with_host_times, 60);
    // 2 400 bytes a frame over 59 frame intervals of shard arrivals plus 0.5 ms.
    let mbps = s.received_mbps.expect("rate");
    assert!((mbps - 60.0 * 2_400.0 * 8.0 / (59.0 * 16_667.0 + 500.0)).abs() < 1e-6, "{mbps}");
    for name in ["Input", "Screen"] {
        let row = stage(&s, name);
        assert!(row.value.is_none());
        assert!(row.reason.as_deref().is_some_and(|r| r.contains("harness")), "{row:?}");
    }
}

#[test]
fn stages_a_viewer_cannot_fill_are_null_with_a_reason() {
    let mut l = StageLedger::new();
    for f in 1..=10 {
        viewer(&mut l, f, 0, false);
    }
    // No clock offset: Network crosses the clocks, so it stays empty.
    let s = l.summary(None, &[("Present", "no renderer"), ("Total", "no renderer")]);
    assert!(stage(&s, "Network").value.is_none());
    assert!(stage(&s, "Network").reason.as_deref().is_some_and(|r| r.contains("clock")));
    assert_eq!(stage(&s, "Present").reason.as_deref(), Some("no renderer"));
    assert_eq!(stage(&s, "Total").reason.as_deref(), Some("no renderer"));
    assert!(stage(&s, "Decode").value.is_some());
    assert!(s.display_to_decoded.is_none(), "display to decoded crosses the clocks too");
    let s = l.summary(Some(0), &[]);
    assert!(s.display_to_decoded.is_some());
    let json = s.to_json();
    assert!(json.starts_with(&format!("{{\"schema\":\"{SCHEMA}\"")), "{json}");
    assert!(json.contains("\"stage\":\"Present\",\"from\":\"decoded\",\"to\":\"presented\",\"budget_ms\":10.000,\"n\":0,\"p50_ms\":null"), "{json}");
}

#[test]
fn rows_are_bounded_and_late_stamps_for_forgotten_frames_are_dropped() {
    let mut l = StageLedger::new();
    for f in 0..(MAX_ROWS as u32 + 100) {
        l.on_shard(0, f, 100, u64::from(f));
    }
    assert_eq!(l.rows().count(), MAX_ROWS);
    // Frame 0 is gone: a decode note for it makes no new row.
    l.on_decoded(0, 0, 1);
    assert_eq!(l.rows().count(), MAX_ROWS);
    assert!(l.rows().all(|r| r.frame != 0));
}

#[test]
fn percentiles_are_nearest_rank() {
    let mut xs: Vec<f64> = (1..=100).map(f64::from).collect();
    let p = percentiles(&mut xs).expect("samples");
    assert_eq!((p.n, p.p50_ms, p.p95_ms), (100, 50.0, 95.0));
    assert!(percentiles(&mut []).is_none());
}

fn shard(
    frame: u32,
    index: u16,
    count: u16,
    body: &[u8],
    shard_len: usize,
) -> (DatagramHeader, Vec<u8>) {
    let start = usize::from(index) * shard_len;
    let mut payload = body[start.min(body.len())..(start + shard_len).min(body.len())].to_vec();
    payload.resize(shard_len, 0);
    let header = DatagramHeader {
        flags: 0,
        kind: DatagramKind::Video,
        stream: 0,
        frame,
        index,
        count,
        fec_count: 0,
        transport_seq: index,
    };
    (header, payload)
}

#[test]
fn reassembly_stamps_first_shard_complete_and_release() {
    let mut r = Reassembler::new(200_000);
    let key =
        FrameBody { t_capture_us: 1, ref_frame: REF_NONE, access_unit: vec![9; 2_000] }.encode();
    let next = FrameBody { t_capture_us: 2, ref_frame: 1, access_unit: vec![8; 2_000] }.encode();
    let len = 1_100;
    let mut push = |frame, index, body: &[u8], at| {
        let (h, payload) = shard(frame, index, 2, body, len);
        r.push(&h, &payload, at)
    };
    // Frame 2 completes at 300 but waits for frame 1 (seen at 50), complete at 500.
    assert!(push(1, 0, &key, 50).is_empty());
    assert!(push(2, 0, &next, 100).is_empty());
    assert!(push(2, 1, &next, 300).is_empty());
    let out = push(1, 1, &key, 500);
    let stamps: Vec<_> =
        out.iter().map(|f| (f.frame, f.first_shard_us, f.last_shard_us, f.released_us)).collect();
    assert_eq!(stamps, vec![(1, 50, 500, 500), (2, 100, 300, 500)]);
}
