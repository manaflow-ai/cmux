//! Implementation of the Trickle timer defined in [RFC 6206]. The algorithm allows node in a lossy
//! shared medium to exchange information in a highly robust, energy efficient, simple, and
//! scalable manner. Dynamically adjusting transmission windows allows Trickle to spread new
//! information fast while sending only a few messages per hour when information does not change.
//!
//! **NOTE**: the constants used for the default Trickle timer are the ones from the [Enhanced
//! Trickle].
//!
//! [RFC 6206]: https://datatracker.ietf.org/doc/html/rfc6206
//! [Enhanced Trickle]: https://d1wqtxts1xzle7.cloudfront.net/71402623/E-Trickle_Enhanced_Trickle_Algorithm_for20211005-2078-1ckh34a.pdf?1633439582=&response-content-disposition=inline%3B+filename%3DE_Trickle_Enhanced_Trickle_Algorithm_for.pdf&Expires=1681472005&Signature=cC7l-Pyr5r64XBNCDeSJ2ha6oqWUtO6A-KlDOyC0UVaHxDV3h3FuVHRtcNp3O9BUfRK8jeuWCYGBkCZgQT4Zgb6XwgVB-3z4TF9o3qBRMteRyYO5vjVkpPBeN7mz4Tl746SsSCHDm2NMtr7UVtLYamriU3D0rryoqLqJXmnkNoJpn~~wJe2H5PmPgIwixTwSvDkfFLSVoESaYS9ZWHZwbW-7G7OxIw8oSYhx9xMBnzkpdmT7sJNmvDzTUhoOjYrHTRM23cLVS9~oOSpT7hKtKD4h5CSmrNK4st07KnT9~tUqEcvGO3aXdd4quRZeKUcCkCbTLvhOEYg9~QqgD8xwhA__&Key-Pair-Id=APKAJLOHF5GGSLRBV4ZA

use crate::{
    rand::Rand,
    time::{Duration, Instant},
};

#[derive(Debug, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub(crate) struct TrickleTimer {
    i_min: u32,
    i_max: u32,
    k: usize,

    i: Duration,
    t: Duration,
    t_exp: Instant,
    i_exp: Instant,
    counter: usize,
}

impl TrickleTimer {
    /// Creat a new Trickle timer using the default values.
    ///
    /// **NOTE**: the standard defines I as a random value between [Imin, Imax]. However, this
    /// could result in a t value that is very close to Imax. Therefore, sending DIO messages will
    /// be sporadic, which is not ideal when a network is started. It might take a long time before
    /// the network is actually stable. Therefore, we don't draw a random numberm but just use Imin
    /// for I. This only affects the start of the RPL tree and speeds up building it. Also, we
    /// don't use the default values from the standard, but the values from the _Enhanced Trickle
    /// Algorithm for Low-Power and Lossy Networks_ from Baraq Ghaleb et al. This is also what the
    /// Contiki Trickle timer does.
    pub(crate) fn default(now: Instant, rand: &mut Rand) -> Self {
        use super::consts::{
            DEFAULT_DIO_INTERVAL_DOUBLINGS, DEFAULT_DIO_INTERVAL_MIN,
            DEFAULT_DIO_REDUNDANCY_CONSTANT,
        };

        Self::new(
            DEFAULT_DIO_INTERVAL_MIN,
            DEFAULT_DIO_INTERVAL_MIN + DEFAULT_DIO_INTERVAL_DOUBLINGS,
            DEFAULT_DIO_REDUNDANCY_CONSTANT,
            now,
            rand,
        )
    }

    /// Create a new Trickle timer.
    pub(crate) fn new(i_min: u32, i_max: u32, k: usize, now: Instant, rand: &mut Rand) -> Self {
        let mut timer = Self {
            i_min,
            i_max,
            k,
            i: Duration::ZERO,
            t: Duration::ZERO,
            t_exp: Instant::ZERO,
            i_exp: Instant::ZERO,
            counter: 0,
        };

        timer.i = Duration::from_millis(2u32.pow(timer.i_min) as u64);
        timer.i_exp = now + timer.i;
        timer.counter = 0;

        timer.set_t(now, rand);

        timer
    }

    /// Poll the Trickle timer. Returns `true` when the Trickle timer signals that a message can be
    /// transmitted. This happens when the Trickle timer expires.
    pub(crate) fn poll(&mut self, now: Instant, rand: &mut Rand) -> bool {
        let can_transmit = self.can_transmit() && self.t_expired(now);

        if can_transmit {
            self.set_t(now, rand);
        }

        if self.i_expired(now) {
            self.expire(now, rand);
        }

        can_transmit
    }

    /// Returns the Instant at which the Trickle timer should be polled again. Polling the Trickle
    /// timer before this Instant is not harmfull, however, polling after it is not correct.
    pub(crate) fn poll_at(&self) -> Instant {
        self.t_exp.min(self.i_exp)
    }

    /// Signal the Trickle timer that a consistency has been heard, and thus increasing it's
    /// counter.
    pub(crate) fn hear_consistent(&mut self) {
        self.counter += 1;
    }

    /// Signal the Trickle timer that an inconsistency has been heard. This resets the Trickle
    /// timer when the current interval is not the smallest possible.
    pub(crate) fn hear_inconsistency(&mut self, now: Instant, rand: &mut Rand) {
        let i = Duration::from_millis(2u32.pow(self.i_min) as u64);
        if self.i > i {
            self.reset(i, now, rand);
        }
    }

    /// Check if the Trickle timer can transmit or not. Returns `false` when the consistency
    /// counter is bigger or equal to the default consistency constant.
    pub(crate) fn can_transmit(&self) -> bool {
        self.k != 0 && self.counter < self.k
    }

    /// Reset the Trickle timer when the interval has expired.
    fn expire(&mut self, now: Instant, rand: &mut Rand) {
        let max_interval = Duration::from_millis(2u32.pow(self.i_max) as u64);
        let i = if self.i >= max_interval {
            max_interval
        } else {
            self.i + self.i
        };

        self.reset(i, now, rand);
    }

    pub(crate) fn reset(&mut self, i: Duration, now: Instant, rand: &mut Rand) {
        self.i = i;
        self.i_exp = now + self.i;
        self.counter = 0;
        self.set_t(now, rand);
    }

    pub(crate) const fn max_expiration(&self) -> Duration {
        Duration::from_millis(2u32.pow(self.i_max) as u64)
    }

    pub(crate) const fn min_expiration(&self) -> Duration {
        Duration::from_millis(2u32.pow(self.i_min) as u64)
    }

    fn set_t(&mut self, now: Instant, rand: &mut Rand) {
        let t = Duration::from_micros(
            self.i.total_micros() / 2
                + (rand.rand_u32() as u64
                    % (self.i.total_micros() - self.i.total_micros() / 2 + 1)),
        );

        self.t = t;
        self.t_exp = now + t;
    }

    fn t_expired(&self, now: Instant) -> bool {
        now >= self.t_exp
    }

    fn i_expired(&self, now: Instant) -> bool {
        now >= self.i_exp
    }
}

#[cfg(test)]
mod tests {
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
}
