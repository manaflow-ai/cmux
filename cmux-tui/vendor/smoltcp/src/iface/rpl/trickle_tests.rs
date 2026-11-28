use super::*;

#[test]
fn trickle_timer_intervals() {
    let mut rand = Rand::new(1234);
    let mut now = Instant::ZERO;
    let mut trickle = TrickleTimer::default(now, &mut rand);

    let mut previous_i = trickle.i;

    while now <= Instant::from_secs(100_000) {
        trickle.poll(now, &mut rand);

        if now < Instant::ZERO + trickle.max_expiration() {
            // t should always be inbetween I/2 and I.
            assert!(trickle.i / 2 < trickle.t);
            assert!(trickle.i > trickle.t);
        }

        if previous_i != trickle.i {
            // When a new Interval is selected, this should be double the previous one.
            assert_eq!(previous_i * 2, trickle.i);
            assert_eq!(trickle.counter, 0);
            previous_i = trickle.i;
        }

        now += Duration::from_millis(100);
    }
}

#[test]
fn trickle_timer_hear_inconsistency() {
    let mut rand = Rand::new(1234);
    let mut now = Instant::ZERO;
    let mut trickle = TrickleTimer::default(now, &mut rand);

    trickle.counter = 1;

    while now <= Instant::from_secs(10_000) {
        trickle.poll(now, &mut rand);

        if now < trickle.i_exp && now < Instant::ZERO + trickle.min_expiration() {
            assert_eq!(trickle.counter, 1);
        } else {
            // The first interval expired, so the counter is reset.
            assert_eq!(trickle.counter, 0);
        }

        if now == Instant::from_secs(10) {
            // We set the counter to 1 such that we can test the `hear_inconsistency`.
            trickle.counter = 1;

            assert_eq!(trickle.counter, 1);

            trickle.hear_inconsistency(now, &mut rand);

            assert_eq!(trickle.counter, 0);
            assert_eq!(trickle.i, trickle.min_expiration());
        }

        now += Duration::from_millis(100);
    }
}

#[test]
fn trickle_timer_hear_consistency() {
    let mut rand = Rand::new(1234);
    let mut now = Instant::ZERO;
    let mut trickle = TrickleTimer::default(now, &mut rand);

    trickle.counter = 1;

    let mut transmit_counter = 0;

    while now <= Instant::from_secs(10_000) {
        trickle.hear_consistent();

        if trickle.poll(now, &mut rand) {
            transmit_counter += 1;
        }

        if now == Instant::from_secs(10_000) {
            use super::super::consts::{
                DEFAULT_DIO_INTERVAL_DOUBLINGS, DEFAULT_DIO_REDUNDANCY_CONSTANT,
            };
            assert!(!trickle.poll(now, &mut rand));
            assert!(trickle.counter > DEFAULT_DIO_REDUNDANCY_CONSTANT);
            // We should never have transmitted since the counter was higher than the default
            // redundancy constant.
            assert_eq!(transmit_counter, 0);
        }

        now += Duration::from_millis(100);
    }
}
