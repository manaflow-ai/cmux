use super::*;

fn pump(
    from: &mut HopLeg,
    to: &mut HopLeg,
    now: Instant,
    drop: &mut dyn FnMut(usize) -> bool,
) -> Vec<Record> {
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(d) = from.poll_transmit(now) {
        if !drop(i) {
            out.extend(to.handle(&d, now));
        }
        i += 1;
    }
    out
}

#[test]
fn records_round_trip_and_coalesce() {
    let now = Instant::now();
    let (mut a, mut b) = (HopLeg::new(now), HopLeg::new(now));
    a.push(3, None, &[1; 100], now);
    a.push(1, Some((9, 1)), &[2; 50], now);
    a.push(2, None, &[3; 10], now);
    let got = pump(&mut a, &mut b, now, &mut |_| false);
    // Input first, then state, then bulk; one DATA (plus the first PING? none yet: no timeout ran).
    assert_eq!(got.iter().map(|r| r.class).collect::<Vec<_>>(), vec![2, 1, 3]);
    assert_eq!(a.stats().sent, 1);
    assert_eq!(a.stats().coalesced, 2);
}

#[test]
fn latest_wins_replaces_queued_state() {
    let now = Instant::now();
    let (mut a, mut b) = (HopLeg::new(now), HopLeg::new(now));
    for seq in 1..=5 {
        a.push(1, Some((7, seq)), &[seq as u8; 600], now);
    }
    a.push(1, Some((7, 2)), &[0; 600], now); // older than the newest: dropped
    let got = pump(&mut a, &mut b, now, &mut |_| false);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].tag, Some((7, 5)));
    assert_eq!(a.stats().superseded, 5);
}

#[test]
fn a_lost_datagram_is_nacked_and_repaired() {
    let t0 = Instant::now();
    let (mut a, mut b) = (HopLeg::new(t0), HopLeg::new(t0));
    for i in 0..3_u8 {
        a.push(2, None, &[i; 10], t0);
        let d = a.poll_transmit(t0).unwrap();
        if i != 1 {
            b.handle(&d, t0);
        }
    }
    let t1 = t0 + Duration::from_millis(50);
    b.on_timeout(t1);
    // b's PING, then its NACK.
    let mut got = Vec::new();
    while let Some(d) = b.poll_transmit(t1) {
        a.handle(&d, t1);
    }
    while let Some(d) = a.poll_transmit(t1) {
        got.extend(b.handle(&d, t1));
    }
    assert!(got.iter().any(|r| r.bytes == vec![1; 10]), "{got:?}");
    assert_eq!(b.stats().repaired, 1);
    assert_eq!(a.stats().resent, 1);
    assert_eq!(b.stats().nacks_sent, 1);
}

#[test]
fn duplicates_are_dropped() {
    let now = Instant::now();
    let (mut a, mut b) = (HopLeg::new(now), HopLeg::new(now));
    a.push(2, None, &[1; 10], now);
    let d = a.poll_transmit(now).unwrap();
    assert_eq!(b.handle(&d, now).len(), 1);
    assert_eq!(b.handle(&d, now).len(), 0);
}

#[test]
fn bulk_is_bounded_by_bytes() {
    let now = Instant::now();
    let mut a = HopLeg::new(now);
    for _ in 0..400 {
        a.push(3, None, &[0; 1200], now);
    }
    assert!(a.stats().queued_bytes <= 256 * 1024);
    assert!(a.stats().dropped > 0);
}
