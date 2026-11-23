//! D10 ultra, host half: an ultra session paces every budgeted byte with the strict
//! one-budget pacer, at the probed capacity (2.5x the held rate until a probe measures
//! one; standard keeps the balanced pacer); its
//! probe train leaves at once with each departure told to the engine, its bytes are
//! charged to that budget, and the viewer's probe arrivals raise the held rate to at most
//! 0.8 times the measured capacity.

use super::outage_drop_tests::{feedback, header, QuietDesktop, RecordingCarrier, SizedEncoder};
use super::*;
use cmux_rd_core::pacer::PacerPolicy;
use cmux_rd_proto::Arrival;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

const START_BPS: u64 = 2_000_000;

fn session(profile: EncodeProfile) -> MediaSession {
    let cfg = SessionCfg {
        display: String::new(),
        display_pick: None,
        max_fps: 60,
        encode_profile: profile,
        start_kbps: (START_BPS / 1000) as u32,
        max_kbps: 150_000,
        preset: String::new(),
        profile: String::new(),
        codec: String::new(),
        openh264_lib: None,
        content: "screen".into(),
        threads: 1,
        stats_every_ms: 1000,
        settle_us: 0,
        upstream_record: None,
        upstream_record_max_bytes: 0,
        frames_in_flight: 3,
        input_frame_now: false,
        rtt_tail_probe: false,
        resolution_ladder: false,
        max_qp: cmux_rd_core::resolution::DEFAULT_MAX_QP,
        max_width: None,
        show_cursor: true,
        capture: crate::capture_backend::CaptureBackend::default(),
    };
    let mut session = MediaSession::with_desktop(
        Box::new(QuietDesktop(UnixStream::pair().expect("socket pair"))),
        Box::new(SizedEncoder { sizes: vec![800], forced: Arc::new(Mutex::new(Vec::new())) }),
        &cfg,
        1200,
        &[],
        Box::new(crate::upstream::NoSink),
    )
    .expect("session");
    // Pacing is on unless `CMUX_RD_PACE=0`; keep the session's own pacer when it built one.
    if session.pacer.is_none() {
        session.pacer = Some(new_pacer(profile, session.engine.pacing_bps()));
    }
    session
}

fn policy(session: &MediaSession) -> Option<PacerPolicy> {
    session.pacer.as_ref().map(Pacer::policy)
}

#[test]
fn ultra_paces_with_the_strict_budget_and_standard_with_the_balanced_pacer() {
    assert_eq!(
        policy(&session(EncodeProfile::Ultra)),
        Some(PacerPolicy::Strict(StrictWireBudget::new(START_BPS * 5 / 2))),
        "ultra targets its start rate, paced at 2.5x it, until a probe measures the path"
    );
    assert_eq!(policy(&session(EncodeProfile::Standard)), Some(PacerPolicy::Balanced));
}

#[test]
fn an_ultra_probe_train_leaves_at_once_and_its_arrivals_raise_the_held_rate() {
    let mut s = session(EncodeProfile::Ultra);
    let mut carrier = RecordingCarrier::default();
    assert_eq!(s.engine.target_bps(), START_BPS);
    let _first_frame = s.engine.start(now_us());
    let out = s.engine.tick(false, now_us());
    s.send_output(&mut carrier, out.datagrams);
    let probes: Vec<(u16, usize)> = carrier
        .sent
        .iter()
        .filter(|d| header(d).kind == DatagramKind::Probe)
        .map(|d| (header(d).transport_seq, d.len()))
        .collect();
    assert_eq!(probes.len(), 16, "the whole startup train leaves in one tick");
    assert!(probes.iter().all(|p| p.1 == 1200), "full-size probes");
    assert!(s.pacer.as_ref().is_some_and(Pacer::is_empty), "probes never wait in the queue");

    // The viewer saw them 200 us apart: 15 x 1,200 bytes over 3 ms is 48 Mbps.
    let arrivals = probes
        .iter()
        .enumerate()
        .map(|(i, p)| Arrival { transport_seq: p.0, arrival_us: 10_000 + i as u32 * 200 })
        .collect();
    let _ = s.engine.on_datagram(&feedback(arrivals, 0), false, now_us());
    let held = s.engine.target_bps();
    assert!(held > START_BPS, "the probe's capacity reached the controller: {held}");
    assert!(held <= 38_400_000, "at most 0.8 x the measured 48 Mbps: {held}");

    // From the next send on, the strict budget paces at the measured capacity (the
    // encoder targets the held rate under it).
    s.send_paced(&mut carrier).expect("send");
    let Some(PacerPolicy::Strict(budget)) = policy(&s) else { panic!("strict pacer") };
    assert!(budget.rate_bps > held, "paced at the capacity, over the held rate: {budget:?}");
    assert!(budget.rate_bps <= 48_000_000, "at most the measured 48 Mbps: {budget:?}");
}

#[test]
fn an_ultra_probe_train_is_charged_to_the_wire_budget() {
    let mut s = session(EncodeProfile::Ultra);
    let mut carrier = RecordingCarrier::default();
    let _first_frame = s.engine.start(now_us());
    let out = s.engine.tick(false, now_us());
    s.send_output(&mut carrier, out.datagrams);
    // Unmeasured, ultra paces at 2.5 x its 2 Mbps start rate, 5 Mbps: 16 x 1,200 probe
    // bytes hold the wire for 30.7 ms, and a datagram queued right after waits for that,
    // not for its own 1.9 ms.
    let queued_at = now_us();
    let pacer = s.pacer.as_mut().expect("pacer");
    pacer.push_frame(vec![vec![0; 1200]], START_BPS, 16_667, queued_at);
    assert!(pacer.due(queued_at).is_empty());
    let next = pacer.next_deadline_us().expect("deadline");
    // Uncharged it would be due 1.9 ms after queueing; the charge is 30.7 ms.
    assert!(next > queued_at + 20_000, "the probe bytes were not charged: {next} vs {queued_at}");
}
