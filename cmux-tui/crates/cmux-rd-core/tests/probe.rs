use cmux_rd_core::probe::{ProbeConfig, ProbeEstimate, ProbePlanner, ProbeReason};
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

/// Sends a whole train of `count` 100-byte probes back to back at t=0 and reports the
/// first `arrived` of them 10 us apart.
fn train_with_loss(count: usize, arrived: usize) -> (ProbePlanner, Option<ProbeEstimate>) {
    let mut p = ProbePlanner::new(ProbeConfig {
        stream: 7,
        datagram_bytes: 100,
        packet_count: count,
        spacing_us: 100,
        expiry_us: 100_000,
        min_samples: 4,
        max_rate_bps: 150_000_000,
        max_capacity_bps: 1_000_000_000,
    });
    p.start(ProbeReason::Startup, 0).expect("start");
    let mut seqs = Vec::new();
    while let Some(due) = p.next_deadline_us() {
        let Some(packet) = p.next_packet(due, seqs.len() as u16) else { break };
        assert!(p.record_departure(packet.transport_seq, 0));
        seqs.push(packet.transport_seq);
    }
    assert_eq!(seqs.len(), count);
    let arrivals: Vec<Arrival> = seqs
        .iter()
        .take(arrived)
        .enumerate()
        .map(|(i, &transport_seq)| Arrival { transport_seq, arrival_us: 1_000 + i as u32 * 10 })
        .collect();
    let estimate = p.on_feedback(50_000, &arrivals);
    (p, estimate)
}

/// D10 (2026-11-17): the held rate comes only from a train that arrived with under 2%
/// loss, and the estimate says how much was lost. A lossier train gives no capacity and
/// expires, so ultra keeps its rate and the next idle probe tries again.
#[test]
fn only_a_train_with_under_two_percent_loss_is_a_capacity() {
    let (_, whole) = train_with_loss(16, 16);
    let whole = whole.expect("a whole train is a capacity");
    assert_eq!(whole.loss_ppm, 0);

    // One of 64 lost is 1.5625%: under 2%, and reported.
    let (_, one_in_64) = train_with_loss(64, 63);
    let one_in_64 = one_in_64.expect("1.6% loss is a capacity");
    assert_eq!(one_in_64.loss_ppm, 15_625);
    assert!((one_in_64.loss_fraction() - 0.015_625).abs() < 1e-9);
    assert_eq!(one_in_64.sent_packets - one_in_64.received_packets, 1);

    // One of 16 lost is 6.25%; two of 64 is 3.1%: no capacity, and the train expires.
    for (count, arrived) in [(16, 15), (64, 62)] {
        let (mut p, lossy) = train_with_loss(count, arrived);
        assert!(lossy.is_none(), "{arrived} of {count} arrived: no capacity");
        assert!(p.active().is_some(), "the rest may still arrive until expiry");
        assert!(p.on_feedback(100_000, &[]).is_none());
        assert!(p.active().is_none(), "expired: the next probe tries again");
        assert!(p.start(ProbeReason::Idle, 100_000).is_some());
    }
}

/// A bottleneck is first in, first out: a train that arrived out of the order it left
/// crossed per-packet jitter, and its spread is that jitter, not a capacity (netem with
/// 15 ms of jitter read 5 Mbit/s on a link that carried 80, and ultra held 4).
#[test]
fn a_train_that_arrived_out_of_order_is_not_a_capacity() {
    let mut p = planner();
    p.start(ProbeReason::Startup, 0).expect("start");
    let mut seqs = Vec::new();
    for i in 0..8u16 {
        let at = u64::from(i) * 100;
        let packet = p.next_packet(at, 500 + i).expect("packet");
        assert!(p.record_departure(packet.transport_seq, at));
        seqs.push(packet.transport_seq);
    }
    // Packet 3 overtook packet 2.
    let arrival_us = [1_000u32, 1_100, 1_400, 1_300, 1_500, 1_600, 1_700, 1_800];
    let arrivals = seqs
        .iter()
        .zip(arrival_us)
        .map(|(&transport_seq, arrival_us)| Arrival { transport_seq, arrival_us })
        .collect::<Vec<_>>();
    assert!(p.on_feedback(2_000, &arrivals).is_none());
    assert!(p.active().is_some(), "it expires like a lossy train");
}
