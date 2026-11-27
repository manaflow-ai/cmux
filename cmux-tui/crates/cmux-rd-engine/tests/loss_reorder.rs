//! Loss estimates must follow delivery, not the order of feedback envelopes.

use cmux_rd_engine::{Encoded, EngineConfig, MediaEngine};
use cmux_rd_proto::{Arrival, DatagramHeader, DatagramKind, Feedback, MAX_ARRIVALS};

fn feedback(arrivals: &[Arrival]) -> Vec<u8> {
    assert!(arrivals.len() <= MAX_ARRIVALS, "exercise real wire-sized feedback");
    let mut datagram = DatagramHeader {
        flags: 0,
        kind: DatagramKind::Feedback,
        stream: 0,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode()
    .to_vec();
    datagram.extend_from_slice(
        &Feedback { arrivals: arrivals.to_vec(), ..Feedback::default() }.encode(),
    );
    datagram
}

fn sent_burst() -> (MediaEngine, Vec<Arrival>) {
    let mut engine = MediaEngine::new(
        EngineConfig { width: 640, height: 480, max_fps: 60, ..EngineConfig::default() },
        0,
    );
    let request = engine.start(0).expect("initial encode");
    let sent = engine
        .encoded(
            &request,
            Some(Encoded { access_unit: vec![7; 360_000], idr: true, t_capture_us: 0 }),
            0,
        )
        .expect("packetize burst")
        .datagrams;
    assert!(sent.len() > 2 * MAX_ARRIVALS, "the frame needs multiple feedback envelopes");
    let arrivals = sent
        .iter()
        .map(|datagram| Arrival {
            transport_seq: DatagramHeader::decode(datagram).expect("sent header").0.transport_seq,
            // All packets cross the same fixed 25 ms path. Only their feedback
            // envelopes are reordered, so this is not a delay-congestion test.
            arrival_us: 25_000,
        })
        .collect();
    (engine, arrivals)
}

#[test]
fn reversed_feedback_chunks_preserve_loss_and_bitrate_after_the_sample_window() {
    let (mut engine, arrivals) = sent_burst();
    let initial_bps = engine.stats().target_bps;
    let mut received_at = 50_000;
    for chunk in arrivals.chunks(MAX_ARRIVALS).rev() {
        engine.on_datagram(&feedback(chunk), false, received_at);
        received_at += 40_000;
    }
    // The oldest chunk arrives 80 ms after the newest one, within the
    // 100 ms reorder allowance but beyond a single feedback period.
    engine.on_datagram(&feedback(&[]), false, 150_000);
    engine.on_datagram(&feedback(&[]), false, 750_000);
    assert_eq!(engine.stats().loss, 0.0, "every sent packet was reported received");
    assert!(
        engine.stats().target_bps >= initial_bps,
        "reordered receipts on a fixed-delay path must not reduce capacity"
    );
}

#[test]
fn genuinely_missing_packets_still_reduce_capacity_after_the_reorder_allowance() {
    let (mut engine, arrivals) = sent_burst();
    let initial_bps = engine.stats().target_bps;
    let last = arrivals.len() - 1;
    let received: Vec<_> = arrivals
        .into_iter()
        .enumerate()
        // Retain the final packet so every omitted packet precedes a known
        // arrival; an unobserved trailing burst is the timeout's responsibility.
        .filter_map(|(index, arrival)| (index % 2 == 1 || index == last).then_some(arrival))
        .collect();
    for chunk in received.chunks(MAX_ARRIVALS) {
        engine.on_datagram(&feedback(chunk), false, 50_000);
    }
    engine.on_datagram(&feedback(&[]), false, 150_000);
    engine.on_datagram(&feedback(&[]), false, 750_000);
    assert!(engine.stats().loss > 0.0, "real missing packets still reach the FEC estimator");
    assert!(
        engine.stats().target_bps < initial_bps,
        "sustained heavy loss still reaches congestion control"
    );
}
