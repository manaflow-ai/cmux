use cmux_rd_core::probe::{ProbeConfig, ProbePlanner, ProbeReason};
use cmux_rd_proto::Arrival;

fn planner() -> ProbePlanner {
    ProbePlanner::new(ProbeConfig {
        stream: 7,
        datagram_bytes: 100,
        packet_count: 8,
        spacing_us: 100,
        expiry_us: 10_000,
        min_samples: 4,
        max_rate_bps: 150_000_000,
        max_capacity_bps: 1_000_000_000,
    })
}

#[test]
fn caller_owns_transport_sequence_and_start_signal() {
    let mut p = planner();
    assert!(p.active().is_none());
    let train = p.start(ProbeReason::Startup, 1_000).expect("start");
    assert_eq!(train.first_seq, None);
    let first = p.next_packet(1_000, u16::MAX).expect("first packet");
    assert!(p.record_departure(first.transport_seq, 1_001));
    assert_eq!(first.transport_seq, u16::MAX);
    assert_eq!(p.active().expect("active").first_seq, Some(u16::MAX));
    assert!(p.next_packet(1_050, 0).is_none(), "spacing is enforced");
}

#[test]
fn reordered_arrivals_and_clock_wrap_produce_a_conservative_estimate() {
    let mut p = planner();
    let train = p.start(ProbeReason::Idle, 10).expect("start");
    let mut sent = Vec::new();
    for i in 0..8u16 {
        let packet = p.next_packet(10 + u64::from(i) * 100, 1000 + i).expect("packet");
        assert!(p.record_departure(packet.transport_seq, 10 + u64::from(i) * 100));
        sent.push(packet);
    }
    let arrivals = sent
        .iter()
        .enumerate()
        .rev()
        .map(|(i, packet)| Arrival {
            transport_seq: packet.transport_seq,
            arrival_us: 0xffff_ff00u32.wrapping_add(i as u32 * 100),
        })
        .collect::<Vec<_>>();
    let estimate = p.on_feedback(2_000, &arrivals).expect("estimate");
    assert_eq!(estimate.train_id, train.id);
    assert_eq!(estimate.received_packets, 8);
    assert_eq!(estimate.received_bytes, 800);
    assert_eq!(estimate.dispersion_us, 700);
    assert!(estimate.capacity_bps < 10_000_000);
}

#[test]
fn short_or_sparse_trains_never_report_a_high_capacity() {
    let mut p = planner();
    p.start(ProbeReason::Startup, 0).expect("start");
    let first = p.next_packet(0, 1).expect("packet");
    let second = p.next_packet(100, 2).expect("packet");
    assert!(p.record_departure(first.transport_seq, 0));
    assert!(p.record_departure(second.transport_seq, 100));
    assert!(
        p.on_feedback(
            200,
            &[
                Arrival { transport_seq: first.transport_seq, arrival_us: 10 },
                Arrival { transport_seq: second.transport_seq, arrival_us: 11 }
            ]
        )
        .is_none()
    );
    assert!(p.active().is_some(), "wait for the rest of the train");
}

#[test]
fn unknown_and_duplicate_arrivals_are_ignored() {
    let mut p = planner();
    p.start(ProbeReason::Startup, 0).expect("start");
    let mut sent = Vec::new();
    for i in 0..8u16 {
        let packet = p.next_packet(u64::from(i) * 100, i).expect("packet");
        assert!(p.record_departure(packet.transport_seq, u64::from(i) * 100));
        sent.push(packet);
    }
    let mut arrivals = vec![Arrival { transport_seq: 999, arrival_us: 1 }];
    for (i, packet) in sent.iter().enumerate().take(3) {
        arrivals.push(Arrival {
            transport_seq: packet.transport_seq,
            arrival_us: 1_000 + i as u32 * 100,
        });
        arrivals.push(Arrival {
            transport_seq: packet.transport_seq,
            arrival_us: 1_000 + i as u32 * 100,
        });
    }
    assert!(p.on_feedback(2_000, &arrivals).is_none());
    assert!(p.active().is_some());
}

#[test]
fn expiry_discards_partial_feedback() {
    let mut p = planner();
    p.start(ProbeReason::Startup, 0).expect("start");
    let packet = p.next_packet(0, 1).expect("packet");
    assert!(p.record_departure(packet.transport_seq, 0));
    assert!(p.on_feedback(10_000, &[]).is_none());
    assert!(p.active().is_none());
}
