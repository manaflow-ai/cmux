use std::time::{Duration, Instant};

use proptest::prelude::*;

use super::*;

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

fn data(seq: u32, records: Vec<Record>) -> HopMsg {
    HopMsg::Data { seq, records }
}

#[test]
fn hop_never_collides_with_wireguard_or_stun() {
    assert!(is_hop(0xC1));
    assert!(crate::classify::is_hop(0xC1));
    for byte in 1..=4 {
        assert!(!is_hop(byte));
    }
    let datagram = data(7, vec![Record::new(HopClass::Input, vec![1; 40])]).encode().unwrap();
    assert_eq!(crate::classify(&datagram), crate::DatagramClass::Unknown);
}

#[test]
fn every_message_round_trips() {
    let messages = vec![
        data(
            u32::MAX,
            vec![
                Record::tagged(9, 3, vec![0xAB; 5]),
                Record::new(HopClass::Bulk, vec![1, 2, 3]),
                Record::new(HopClass::Control, vec![4]),
            ],
        ),
        HopMsg::Nack { base: 10, bitmap: 0b1011, highest: 20, loss_permille: 30 },
        HopMsg::Parity { first_seq: 5, count: 4, len_xor: 0x0102, xor: vec![9; 12] },
        HopMsg::Bind { ticket: b"ticket".to_vec() },
        HopMsg::BindOk { addr: "203.0.113.7:3478".parse().unwrap(), lifetime_s: 600 },
        HopMsg::BindOk { addr: "[2001:db8::1]:443".parse().unwrap(), lifetime_s: 1 },
        HopMsg::Ping { nonce: 1, sent_ms: 2 },
        HopMsg::Pong { nonce: 1, sent_ms: 2, loss_permille: 3 },
        HopMsg::Error { code: 401 },
    ];
    for message in messages {
        let bytes = message.encode().unwrap();
        assert_eq!(bytes[0], HOP_MAGIC);
        assert_eq!(HopMsg::decode(&bytes).unwrap(), message);
    }
}

#[test]
fn decode_errors() {
    assert_eq!(HopMsg::decode(&[]), Err(HopError::Short));
    assert_eq!(HopMsg::decode(&[0x01, 0, 0, 0]), Err(HopError::Magic(1)));
    assert_eq!(HopMsg::decode(&[0xC1]), Err(HopError::Short));
    assert_eq!(HopMsg::decode(&[0xC1, 9]), Err(HopError::Type(9)));
    assert_eq!(HopMsg::decode(&[0xC1, 1, 0, 0, 0, 1]), Err(HopError::NoRecords));
    assert_eq!(HopMsg::decode(&[0xC1, 1, 0, 0, 0]), Err(HopError::Short));
    assert_eq!(HopMsg::decode(&[0xC1, 1, 0, 0, 0, 1, 5, 0, 0, 1, 7]), Err(HopError::Class(5)));
    assert_eq!(HopMsg::decode(&[0xC1, 1, 0, 0, 0, 1, 2, 2, 0, 1, 7]), Err(HopError::Flags(2)));
    assert_eq!(
        HopMsg::decode(&[0xC1, 1, 0, 0, 0, 1, 3, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 7]),
        Err(HopError::TagClass)
    );
    assert_eq!(HopMsg::decode(&[0xC1, 1, 0, 0, 0, 1, 2, 0, 0, 0]), Err(HopError::EmptyRecord));
    assert_eq!(
        HopMsg::decode(&[0xC1, 1, 0, 0, 0, 1, 2, 0, 0, 2, 7]),
        Err(HopError::RecordTruncated)
    );
    assert_eq!(HopMsg::decode(&[0xC1, 1, 0, 0, 0, 1, 2]), Err(HopError::RecordTruncated));
    assert_eq!(HopMsg::decode(&[0xC1, 8, 0, 1, 0]), Err(HopError::Trailing));
    assert_eq!(HopMsg::decode(&[0xC1, 3, 0, 0, 0, 1, 0, 0, 0, 9]), Err(HopError::BadParity));
    assert_eq!(HopMsg::decode(&[0xC1, 3, 0, 0, 0, 1, 2, 0, 0]), Err(HopError::BadParity));
    assert_eq!(
        HopMsg::decode(&[0xC1, 5, 5, 1, 2, 3, 4, 0, 1, 0, 0, 0, 1]),
        Err(HopError::Family(5))
    );
    assert_eq!(HopMsg::decode(&[0xC1, 4, 0, 3, 1]), Err(HopError::Short));
}

#[test]
fn encode_refuses_what_decode_refuses() {
    assert_eq!(data(1, vec![]).encode(), Err(HopError::NoRecords));
    assert_eq!(
        data(1, vec![Record::new(HopClass::Input, vec![])]).encode(),
        Err(HopError::EmptyRecord)
    );
    let wrong =
        Record { class: HopClass::Bulk, tag: Some(StreamTag { key: 1, seq: 1 }), bytes: vec![1] };
    assert_eq!(data(1, vec![wrong]).encode(), Err(HopError::TagClass));
    assert!(matches!(
        data(1, vec![Record::new(HopClass::Bulk, vec![0; 70_000])]).encode(),
        Err(HopError::TooLarge(70_000))
    ));
}

fn arb_record() -> impl Strategy<Value = Record> {
    (
        0u8..5,
        any::<bool>(),
        any::<u32>(),
        any::<u32>(),
        proptest::collection::vec(any::<u8>(), 1..64),
    )
        .prop_map(|(class, tagged, key, seq, bytes)| {
            let class = HopClass::from_byte(class).unwrap();
            if tagged && class == HopClass::Interactive {
                Record::tagged(key, seq, bytes)
            } else {
                Record::new(class, bytes)
            }
        })
}

proptest! {
    #[test]
    fn data_round_trips(seq in any::<u32>(), records in proptest::collection::vec(arb_record(), 1..8)) {
        let message = data(seq, records);
        let bytes = message.encode().unwrap();
        prop_assert_eq!(HopMsg::decode(&bytes).unwrap(), message);
    }

    #[test]
    fn fixed_messages_round_trip(a in any::<u32>(), b in any::<u64>(), c in any::<u32>(), d in any::<u16>()) {
        for message in [
            HopMsg::Nack { base: a, bitmap: b, highest: c, loss_permille: d },
            HopMsg::Ping { nonce: a, sent_ms: c },
            HopMsg::Pong { nonce: a, sent_ms: c, loss_permille: d },
            HopMsg::Error { code: d },
        ] {
            prop_assert_eq!(HopMsg::decode(&message.encode().unwrap()).unwrap(), message);
        }
    }

    #[test]
    fn decode_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..96)) {
        let _ = HopMsg::decode(&bytes);
        let mut hop = bytes;
        hop.insert(0, HOP_MAGIC);
        if let Ok(message) = HopMsg::decode(&hop) {
            prop_assert_eq!(message.encode().unwrap(), hop);
        }
    }

    /// With NACK on, every record is delivered exactly once, whatever the loss
    /// pattern, while each DATA gets through once in its 4 chances.
    #[test]
    fn nack_delivers_everything_once(seed in any::<u64>(), initial in any::<u32>()) {
        let mut pair = Pair::new(LegConfig::default(), initial);
        let mut rng = seed | 1;
        // 20% loss, but a DATA loses at most 3 of its 4 chances (the first
        // send and `MAX_ASKS` resends): past that it is lost by design.
        let mut drops = std::collections::HashMap::<Vec<u8>, u8>::new();
        let mut drop = move |datagram: &[u8]| {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
            let count = drops.entry(datagram[2..6].to_vec()).or_default();
            let lose = rng % 5 == 0 && *count < 3;
            *count += u8::from(lose);
            lose
        };
        // DATA before the first one the receiver sees opens no gap it can
        // NACK (head loss; the end-to-end layer retries it), so the leg is
        // warm first.
        pair.a.send(Record::new(HopClass::Input, vec![0xFF; 8]), pair.now).unwrap();
        pair.run(ms(20), &mut |_: &[u8]| false);
        pair.b_got.clear();
        for index in 0..60u32 {
            pair.a.send(Record::new(HopClass::Input, index.to_be_bytes().to_vec()), pair.now).unwrap();
            pair.run(ms(5), &mut drop);
        }
        pair.run(ms(3000), &mut |_: &[u8]| false);
        let mut got: Vec<u32> = pair.b_got.iter().map(|r| u32::from_be_bytes(r.bytes[..4].try_into().unwrap())).collect();
        got.sort_unstable();
        prop_assert_eq!(got, (0..60).collect::<Vec<_>>());
    }
}

/// Two legs wired back to back with a fixed one-way delay.
struct Pair {
    a: Leg,
    b: Leg,
    now: Instant,
    to_b: Vec<(Instant, Vec<u8>)>,
    to_a: Vec<(Instant, Vec<u8>)>,
    b_got: Vec<Record>,
    b_repairs: Vec<Repair>,
    delay: Duration,
}

impl Pair {
    fn new(config: LegConfig, initial: u32) -> Self {
        let now = Instant::now();
        Self {
            a: Leg::new(config, initial, now),
            b: Leg::new(config, initial.wrapping_add(1000), now),
            now,
            to_b: Vec::new(),
            to_a: Vec::new(),
            b_got: Vec::new(),
            b_repairs: Vec::new(),
            delay: ms(10),
        }
    }

    /// Runs for `span` in 1 ms steps; `drop` decides the fate of each
    /// DATA from a to b.
    fn run(&mut self, span: Duration, drop: &mut dyn FnMut(&[u8]) -> bool) {
        let end = self.now + span;
        while self.now < end {
            while let Some(datagram) = self.a.poll_transmit(self.now) {
                let is_data = datagram[1] == TYPE_DATA;
                if !(is_data && drop(&datagram)) {
                    self.to_b.push((self.now + self.delay, datagram));
                }
            }
            while let Some(datagram) = self.b.poll_transmit(self.now) {
                self.to_a.push((self.now + self.delay, datagram));
            }
            let now = self.now;
            for (_, datagram) in take_due(&mut self.to_b, now) {
                for delivered in self.b.handle(&datagram, now) {
                    self.b_got.push(delivered.record);
                    self.b_repairs.push(delivered.repair);
                }
            }
            for (_, datagram) in take_due(&mut self.to_a, now) {
                assert!(self.a.handle(&datagram, now).is_empty());
            }
            self.now += ms(1);
        }
    }
}

fn take_due(queue: &mut Vec<(Instant, Vec<u8>)>, now: Instant) -> Vec<(Instant, Vec<u8>)> {
    let (due, rest): (Vec<_>, Vec<_>) = queue.drain(..).partition(|(at, _)| *at <= now);
    *queue = rest;
    due
}

#[test]
fn a_lost_data_is_nacked_and_resent() {
    let mut pair = Pair::new(LegConfig { fec: false, ..LegConfig::default() }, 0);
    let mut count = 0;
    let mut drop_second = |_: &[u8]| {
        count += 1;
        count == 2
    };
    for index in 0..3u8 {
        pair.a.send(Record::new(HopClass::Input, vec![index; 8]), pair.now).unwrap();
        pair.run(ms(2), &mut drop_second);
    }
    pair.run(ms(200), &mut |_: &[u8]| false);
    assert_eq!(pair.b_got.len(), 3);
    assert_eq!(pair.b_repairs.iter().filter(|r| **r == Repair::Nack).count(), 1);
    assert_eq!(pair.b.stats().nacks_sent, 1);
    // The NACKed resend, and one tail probe of the last DATA (a duplicate).
    assert_eq!(pair.a.stats().resent, 2);
    assert_eq!(pair.a.stats().tail_probes, 1);
    assert_eq!(pair.b.stats().duplicates, 1);
    assert_eq!(pair.b.stats().repaired_by_nack, 1);
}

#[test]
fn a_lost_last_data_is_recovered_by_the_tail_probe() {
    let mut pair = Pair::new(LegConfig { fec: false, ..LegConfig::default() }, 0);
    let mut count = 0;
    let mut drop_last = |_: &[u8]| {
        count += 1;
        count == 3
    };
    for index in 0..3u8 {
        pair.a.send(Record::new(HopClass::Input, vec![index; 8]), pair.now).unwrap();
        pair.run(ms(2), &mut drop_last);
    }
    pair.run(ms(400), &mut |_: &[u8]| false);
    assert_eq!(pair.b_got.len(), 3);
    assert_eq!(pair.a.stats().tail_probes, 1);
    assert_eq!(pair.b.stats().duplicates, 0);
}

#[test]
fn without_nack_a_loss_stays_lost() {
    let mut pair = Pair::new(LegConfig { nack: false, fec: false, ..LegConfig::default() }, 0);
    let mut count = 0;
    let mut drop_second = |_: &[u8]| {
        count += 1;
        count == 2
    };
    for index in 0..3u8 {
        pair.a.send(Record::new(HopClass::Input, vec![index; 8]), pair.now).unwrap();
        pair.run(ms(2), &mut drop_second);
    }
    pair.run(ms(500), &mut |_: &[u8]| false);
    assert_eq!(pair.b_got.len(), 2);
    assert_eq!(pair.b.stats().nacks_sent, 0);
}

#[test]
fn parity_recovers_one_lost_data_per_group() {
    let mut pair = Pair::new(LegConfig { nack: false, ..LegConfig::default() }, u32::MAX - 3);
    // The peer reports 6% loss: one PARITY per 4 DATA.
    let pong = HopMsg::Pong { nonce: 0, sent_ms: 0, loss_permille: 60 }.encode().unwrap();
    pair.a.handle(&pong, pair.now);
    let mut count = 0;
    // Group 1 is DATA 1-4; lose DATA 6 (in group 2).
    let mut drop_sixth = |_: &[u8]| {
        count += 1;
        count == 6
    };
    for index in 0..8u8 {
        pair.a
            .send(Record::new(HopClass::Input, vec![index; 20 + usize::from(index)]), pair.now)
            .unwrap();
        pair.run(ms(1), &mut drop_sixth);
    }
    pair.run(ms(100), &mut |_: &[u8]| false);
    assert_eq!(pair.a.stats().parity_sent, 2);
    assert_eq!(pair.b_got.len(), 8);
    assert_eq!(pair.b.stats().repaired_by_fec, 1);
    let recovered = pair.b_repairs.iter().position(|r| *r == Repair::Fec).unwrap();
    assert_eq!(pair.b_got[recovered].bytes, vec![5; 25]);
}

#[test]
fn no_parity_on_a_clean_leg() {
    let mut pair = Pair::new(LegConfig::default(), 0);
    for index in 0..50u8 {
        pair.a.send(Record::new(HopClass::Input, vec![index; 8]), pair.now).unwrap();
        pair.run(ms(3), &mut |_: &[u8]| false);
    }
    pair.run(ms(1500), &mut |_: &[u8]| false);
    assert_eq!(pair.a.stats().parity_sent, 0);
    assert_eq!(pair.b_got.len(), 50);
    assert!(pair.a.stats().srtt <= ms(21));
}

#[test]
fn duplicates_are_dropped() {
    let now = Instant::now();
    let mut leg = Leg::new(LegConfig::default(), 0, now);
    let datagram = data(5, vec![Record::new(HopClass::Input, vec![1])]).encode().unwrap();
    assert_eq!(leg.handle(&datagram, now).len(), 1);
    assert!(leg.handle(&datagram, now).is_empty());
    assert_eq!(leg.stats().duplicates, 1);
    // Far behind the window: dropped as too old.
    let ahead = data(5 + 2000, vec![Record::new(HopClass::Input, vec![2])]).encode().unwrap();
    assert_eq!(leg.handle(&ahead, now).len(), 1);
    let old = data(6, vec![Record::new(HopClass::Input, vec![3])]).encode().unwrap();
    assert!(leg.handle(&old, now).is_empty());
}

#[test]
fn latest_wins_replaces_queued_class_one_in_place() {
    let now = Instant::now();
    let mut leg = Leg::new(LegConfig { mtu: 40, ..LegConfig::default() }, 0, now);
    leg.poll_transmit(now); // the first PING
    leg.set_pacing_rate(Some(1));
    leg.send(Record::new(HopClass::Control, vec![0; 30]), now).unwrap();
    leg.send(Record::tagged(1, 1, vec![1; 30]), now).unwrap();
    leg.send(Record::new(HopClass::Bulk, vec![3; 30]), now).unwrap();
    leg.send(Record::new(HopClass::Bulk, vec![4; 30]), now).unwrap();
    leg.send(Record::tagged(1, 3, vec![13; 30]), now).unwrap();
    leg.send(Record::tagged(1, 2, vec![12; 30]), now).unwrap(); // stale: 3 is queued
    leg.send(Record::new(HopClass::Control, vec![5; 30]), now).unwrap();
    assert_eq!(leg.stats().dropped_superseded, 2);
    leg.set_pacing_rate(None);
    let mut order = Vec::new();
    while let Some(datagram) = leg.poll_transmit(now) {
        let HopMsg::Data { records, .. } = HopMsg::decode(&datagram).unwrap() else { continue };
        order.extend(records.into_iter().map(|r| r.bytes[0]));
    }
    assert_eq!(order, vec![0, 5, 13, 3, 4]);
    // Once 3 is sent, 2 is stale and 4 is not.
    leg.send(Record::tagged(1, 2, vec![12; 30]), now).unwrap();
    leg.send(Record::tagged(1, 4, vec![14; 30]), now).unwrap();
    assert_eq!(leg.stats().dropped_superseded, 3);
}

#[test]
fn without_latest_wins_every_frame_is_sent() {
    let now = Instant::now();
    let mut leg = Leg::new(LegConfig { latest_wins: false, ..LegConfig::default() }, 0, now);
    for seq in 0..5 {
        leg.send(Record::tagged(1, seq, vec![1; 10]), now).unwrap();
    }
    leg.poll_transmit(now); // PING
    let datagram = leg.poll_transmit(now).unwrap();
    let HopMsg::Data { records, .. } = HopMsg::decode(&datagram).unwrap() else { panic!() };
    assert_eq!(records.len(), 5);
}

#[test]
fn records_pack_up_to_the_mtu() {
    let now = Instant::now();
    let mut leg = Leg::new(LegConfig::default(), 0, now);
    leg.poll_transmit(now); // PING
    for _ in 0..10 {
        leg.send(Record::new(HopClass::Input, vec![7; 200]), now).unwrap();
    }
    let sizes: Vec<usize> =
        std::iter::from_fn(|| leg.poll_transmit(now)).map(|d| d.len()).collect();
    // 6 + 5 x 204 = 1026; a sixth record would pass 1200.
    assert_eq!(sizes, vec![1026, 1026]);
    leg.send(Record::new(HopClass::Bulk, vec![7; 3000]), now).unwrap();
    assert_eq!(leg.poll_transmit(now).map(|d| d.len()), Some(3010));
}

#[test]
fn superseded_class_one_is_not_resent() {
    let now = Instant::now();
    let mut leg = Leg::new(LegConfig::default(), 100, now);
    leg.poll_transmit(now); // PING
    leg.send(Record::tagged(1, 1, vec![1; 10]), now).unwrap();
    leg.poll_transmit(now).unwrap(); // seq 100
    leg.send(Record::tagged(1, 2, vec![2; 10]), now).unwrap();
    leg.poll_transmit(now).unwrap(); // seq 101
    let nack = HopMsg::Nack { base: 100, bitmap: 0b11, highest: 101, loss_permille: 0 };
    leg.handle(&nack.encode().unwrap(), now);
    let resent = leg.poll_transmit(now).unwrap();
    assert!(matches!(HopMsg::decode(&resent), Ok(HopMsg::Data { seq: 101, .. })));
    assert!(leg.poll_transmit(now).is_none());
    assert_eq!(leg.stats().skipped_superseded_resend, 1);
    assert_eq!(leg.stats().resent, 1);
}

#[test]
fn pacing_holds_the_queue_and_names_the_wake() {
    let now = Instant::now();
    let mut leg =
        Leg::new(LegConfig { pacing_rate: Some(100_000), ..LegConfig::default() }, 0, now);
    leg.poll_transmit(now); // PING (unpaced)
    for _ in 0..10 {
        leg.send(Record::new(HopClass::Bulk, vec![0; 996]), now).unwrap();
    }
    let mut sent = 0;
    while leg.poll_transmit(now).is_some() {
        sent += 1;
    }
    // A burst of about two MTUs, then 10 ms per KB.
    assert!(sent <= 3, "sent {sent}");
    let wake = leg.poll_timeout().unwrap();
    assert!(wake > now && wake <= now + ms(11));
    assert!(leg.poll_transmit(wake).is_some());
    assert!(leg.queued_bytes() > 0);
}

#[test]
fn plain_leg_sends_raw_and_upgrades_on_hop() {
    let now = Instant::now();
    let mut leg = Leg::new(LegConfig::plain(), 0, now);
    let mut wg = vec![4, 0, 0, 0];
    wg.extend_from_slice(&[9; 60]);
    leg.send(Record::new(HopClass::Input, wg.clone()), now).unwrap();
    assert_eq!(leg.poll_transmit(now), Some(wg.clone()));
    assert!(leg.poll_transmit(now).is_none());
    let got = leg.handle(&wg, now);
    assert_eq!(got[0].record, Record::new(HopClass::Input, wg.clone()));
    assert!(!leg.is_hop());
    let hop = data(1, vec![Record::new(HopClass::Input, wg.clone())]).encode().unwrap();
    assert_eq!(leg.handle(&hop, now).len(), 1);
    assert!(leg.is_hop());
    leg.send(Record::new(HopClass::Input, wg), now).unwrap();
    let out: Vec<Vec<u8>> = std::iter::from_fn(|| leg.poll_transmit(now)).collect();
    assert!(out.iter().all(|d| d[0] == HOP_MAGIC));
    assert!(out.iter().any(|d| d[1] == TYPE_DATA));
}

#[test]
fn relay_forwards_records_with_their_tag() {
    let now = Instant::now();
    let mut relay =
        HopRelay::new(Leg::new(LegConfig::default(), 0, now), Leg::new(LegConfig::plain(), 0, now));
    let from_phone =
        data(1, vec![Record::tagged(7, 9, vec![1; 40]), Record::new(HopClass::Input, vec![2; 40])])
            .encode()
            .unwrap();
    assert_eq!(relay.handle(Side::A, &from_phone, now), 2);
    assert_eq!(relay.poll_transmit(Side::B, now), Some(vec![1; 40]));
    assert_eq!(relay.poll_transmit(Side::B, now), Some(vec![2; 40]));
    // A plain datagram from the Mac goes to the phone in a hop/1 DATA.
    let mut wg = vec![4, 0, 0, 0];
    wg.extend_from_slice(&[5; 40]);
    assert_eq!(relay.handle(Side::B, &wg, now), 1);
    let out: Vec<Vec<u8>> = std::iter::from_fn(|| relay.poll_transmit(Side::A, now)).collect();
    let records: Vec<Record> = out
        .iter()
        .filter_map(|d| match HopMsg::decode(d) {
            Ok(HopMsg::Data { records, .. }) => Some(records),
            _ => None,
        })
        .flatten()
        .collect();
    assert_eq!(records, vec![Record::new(HopClass::Input, wg)]);
    assert!(relay.poll_timeout().is_some());
}

#[test]
fn fec_group_size_follows_loss() {
    assert_eq!(leg::fec_group_size(1), 16);
    assert_eq!(leg::fec_group_size(19), 16);
    assert_eq!(leg::fec_group_size(20), 8);
    assert_eq!(leg::fec_group_size(50), 4);
    assert_eq!(leg::fec_group_size(900), 4);
}
