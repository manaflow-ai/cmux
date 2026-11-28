use crate::{socket::tcp::RttEstimator, time::Instant};

use super::Controller;

// Constants for the Cubic congestion control algorithm.
// See RFC 9438.
const BETA_CUBIC: f64 = 0.7;
const C: f64 = 0.4;
// RFC 9438 §4.3: α_cubic = 3(1-β)/(1+β). ~0.5294 for β=0.7.
const ALPHA_CUBIC: f64 = 3.0 * (1.0 - BETA_CUBIC) / (1.0 + BETA_CUBIC);

const DEFAULT_MSS: usize = 1024;

// cmux patch: RFC 6928 initial window, min(10 * MSS, max(2 * MSS, 14600)) bytes.
fn initial_window(mss: usize) -> usize {
    (10 * mss).min((2 * mss).max(14600))
}

#[derive(Debug, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Cubic {
    w_max: usize, // window size prior to loss
    cwnd: usize,
    mss: usize,
    ssthresh: usize,
    rwnd: usize,
    k: f64,            // cubic curve offset in seconds; depends only on w_max and mss
    w_est: f64,        // RFC 9438 §4.3 reno-friendly window, integrated per ACK
    cwnd_prior: usize, // cwnd at the most recent congestion event; gates α_cubic

    recovery_start: Option<Instant>,
    in_fast_recovery: bool,
    // Set on RTO, cleared when new data is ACKed. While set, further RTOs
    // are retransmissions of the same segment and must not reduce ssthresh
    // again (RFC 5681 section 3.1).
    in_rto_recovery: bool,
    idle_start: Option<Instant>, // RFC 9438 §4.2: when in-flight last hit 0
    // cmux patch: no new data ACKed and no loss yet, so an MSS learned from the
    // handshake may still resize the initial window.
    initial: bool,
}

impl Cubic {
    pub fn new() -> Cubic {
        let iw = initial_window(DEFAULT_MSS);
        let mut cubic = Cubic {
            w_max: iw,
            cwnd: iw,
            mss: DEFAULT_MSS,
            rwnd: 64 * DEFAULT_MSS,
            ssthresh: usize::MAX,
            k: 0.0,
            w_est: iw as f64,
            cwnd_prior: iw,

            recovery_start: None,
            in_fast_recovery: false,
            in_rto_recovery: false,
            idle_start: None,
            initial: true,
        };
        cubic.recompute_k();
        cubic
    }

    // K = cbrt(w_max * (1 - beta) / C) ^ 1/3
    fn recompute_k(&mut self) {
        let c_as_bytes = C * self.mss as f64;
        let k3 = (self.w_max as f64) * (1.0 - BETA_CUBIC) / c_as_bytes;
        self.k = cube_root(k3);
    }

    // RFC 9438 §4.2: subtract the most recent idle period from t by sliding
    // recovery_start forward by the idle duration.
    fn absorb_idle(&mut self, now: Instant) {
        if let (Some(idle), Some(start)) = (self.idle_start, self.recovery_start)
            && now >= idle
        {
            self.recovery_start = Some(start + (now - idle));
        }
        self.idle_start = None;
    }
}

impl Controller for Cubic {
    fn window(&self) -> usize {
        self.cwnd
    }

    fn on_ack(&mut self, now: Instant, len: usize, in_flight: usize, rtt: &RttEstimator) {
        let segment = len.min(self.mss);

        self.absorb_idle(now);

        if in_flight == 0 {
            self.idle_start = Some(now);
        }

        // RFC 9438 only acts on ACKs of new data. The socket also notifies us
        // of accepted segments that acknowledge nothing (window updates, data
        // segments from the remote): those must not exit fast recovery nor
        // grow the window.
        if len == 0 {
            return;
        }

        // New data was ACKed: a timer-based loss episode, if any, is over.
        self.in_rto_recovery = false;
        self.initial = false;

        // First new-data-ack exits fast recovery and deflates `cwnd`
        if self.in_fast_recovery {
            self.in_fast_recovery = false;
            self.cwnd = self.ssthresh;
            self.w_est = self.cwnd as f64;
            return;
        } else if self.cwnd < self.ssthresh {
            // Slow start: increase `cwnd` by 1 MSS per ACK.
            self.cwnd = self
                .cwnd
                .saturating_add(segment)
                .min(self.rwnd)
                .max(self.mss);
            return;
        }

        // ca: RFC 9438 §4.2 and §4.3: Calculate W_cubic and W_est. Use whichever grows faster.
        let recovery_start = match self.recovery_start {
            Some(t) => t,
            None => {
                // RFC 9438 §4.8: set W_max = cwnd and K = 0 at start of CA
                self.w_max = self.cwnd;
                self.k = 0.0;
                self.w_est = self.cwnd as f64;
                self.recovery_start = Some(now);
                now
            }
        };

        // Elapsed time since the start of the recovery phase, in microseconds so the
        // cubic curve still advances between ACKs on sub-millisecond-RTT links.
        let t = now.total_micros() - recovery_start.total_micros();
        if t < 0 {
            return;
        }

        // RFC 9438 §4.3: use cubic function to get suggested cwnd.
        // W_cubic(t) = C(t - K)^3 + w_max, evaluated at the current time t.
        let c_as_bytes = C * self.mss as f64;
        let w_cubic = c_as_bytes * (t as f64 / 1_000_000.0 - self.k).powi(3) + self.w_max as f64;

        // RFC 9438 §4.3: advance our reno-like suggested cwnd.
        // When cwnd exceeds prior cwnd, change α_cubic to match Reno's AIMD.
        let w_est = {
            let alpha = if self.w_est >= self.cwnd_prior as f64 {
                1.0
            } else {
                ALPHA_CUBIC
            };

            // cmux patch: RFC 9438 counts all newly acknowledged bytes in
            // congestion avoidance. The one-MSS cap belongs to slow start;
            // using it here penalizes delayed ACKs and cumulative ACKs after
            // a repaired hole, starving a busy stream of window growth.
            self.w_est += alpha * self.mss as f64 * len as f64 / self.cwnd as f64;
            self.w_est
        };

        // RFC 9438 §4.3: use the suggested window that grows fastest.
        if w_cubic < w_est {
            self.cwnd = (w_est as usize).min(self.rwnd).max(self.mss);
            return;
        }

        // RFC 9438 §4.2: the congestion window target is W_cubic one RTT into the future.
        let w_cubic_target = {
            // srtt is in millis so floor at 1ms to ensure sub-ms RTTs don't ruin the lookahead.
            let srtt = (rtt.smoothed_rtt() as u64 * 1000).max(1000);

            let t_ahead = (t as f64 + srtt as f64) / 1_000_000.0;
            let raw = c_as_bytes * (t_ahead - self.k).powi(3) + self.w_max as f64;
            raw.min(1.5 * self.cwnd as f64) // clamp to avoid increasing faster than slow-start would
        };

        // TODO: clamps to 0 on small w_cubic_target (i.e. close to plateau)
        // add additional counter (linux `cwnd_cnt`?) to track "lost" bytes
        let increment = (w_cubic_target as usize).saturating_sub(self.cwnd) * len / self.cwnd;
        self.cwnd = (self.cwnd + increment).min(self.rwnd).max(self.mss);
    }

    fn on_dup_ack(&mut self, _now: Instant, len: usize, _in_flight: usize) {
        if self.in_fast_recovery {
            self.cwnd = self.cwnd.saturating_add(len).min(self.rwnd).max(self.mss);
        }
    }

    fn post_transmit(&mut self, now: Instant, _len: usize) {
        self.absorb_idle(now);
    }

    fn on_loss(&mut self, now: Instant, in_flight: usize) {
        self.idle_start = None;
        self.initial = false;
        // Only cut window size on first entrance to fast recovery.
        if !self.in_fast_recovery {
            // RFC 9438 §4.3: remember the cwnd at this congestion event so W_est can
            // detect when it has recovered and switch α_cubic to 1.
            self.cwnd_prior = self.cwnd;

            // TODO: Make this optional?
            // RFC recommends (SHOULD) disabling if only a single CUBIC flow is on a network.
            //
            // RFC 9483.4.7: Fast Convergence
            // If loss happened at a smaller cwnd than before, it indicates a new flow.
            // Reduce the cubic plateau more than usual to create headroom.
            self.w_max = if self.cwnd < self.w_max {
                ((self.cwnd as f64) * (1.0 + BETA_CUBIC) / 2.0) as usize
            } else {
                self.cwnd
            };

            self.ssthresh = ((in_flight as f64 * BETA_CUBIC) as usize).max(2 * self.mss);
            self.cwnd = self.ssthresh.min(self.rwnd).saturating_add(3 * self.mss);

            self.recovery_start = Some(now);
            self.in_fast_recovery = true;
            self.recompute_k();
        }
    }

    fn on_sack_loss(&mut self, now: Instant, in_flight: usize) {
        let entering = !self.in_fast_recovery;
        self.on_loss(now, in_flight);
        if entering {
            self.cwnd = self.ssthresh.min(self.rwnd).max(self.mss);
        }
    }

    fn on_rto(&mut self, _now: Instant, in_flight: usize) {
        // RFC 5681: when the retransmission timer fires for a segment that has
        // already been retransmitted by the timer (no new data was ACKed since
        // the previous RTO), ssthresh is held constant.
        if !self.in_rto_recovery {
            self.ssthresh = ((in_flight as f64 * BETA_CUBIC) as usize).max(2 * self.mss);
            self.in_rto_recovery = true;
        }
        self.initial = false;

        self.cwnd = self.mss;
        self.cwnd_prior = in_flight;

        // RFC 9438 §4.8: defer W_max and K reset to the start of the next CA stage.
        self.recovery_start = None;
        self.in_fast_recovery = false;
        self.idle_start = None;
    }

    fn set_mss(&mut self, mss: usize) {
        self.mss = mss;
        if self.initial {
            let iw = initial_window(mss).min(self.rwnd);
            self.cwnd = iw;
            self.w_max = iw;
            self.w_est = iw as f64;
            self.cwnd_prior = iw;
        }
        self.recompute_k();
    }

    fn set_remote_window(&mut self, remote_window: usize) {
        if self.rwnd < remote_window {
            self.rwnd = remote_window;
        }
    }
}

/// Efficient cube root using f64 bit tricks and Newton-Raphson.
///
/// a = mantissa * 2^e
///
/// cbrt(a) = cbrt(mantissa * 2^e)
/// cbrt(a) = cbrt(mantissa) * cbrt(2^e)
/// -> cbrt(2^e) = 2^(e/3)
///     -> e = 3q + r
///   -> 2^(e/3) = 2^(3q + r)
///   -> 2^(e/3) = 2^q * 2^(r/3)
/// cbrt(a) = cbrt(mantissa) * 2^q * 2^(r/3)
///
/// Floats are constructed from a mantissa and expontnet component.
/// Cbrt of a float can be achieved by cbrt of these two components.
///
/// The mantissa is always between 1 and 2, putting the cbrt between 1
/// and 1.2599. The slope of the curve between those two points is
/// almost a straight line, so a linear interpolatoin between those
/// two points gives an error less than 2%.
///
///
/// The exponent `e` of `2^e` has two parts, tt's quotient and remainder: `e = 3q + r`.
/// Which means cbrt `2^e` is cbrt `2^3q * 2^r` which becomes `2^q * 2^(r/3)`.
///
/// The remainder operation means `r` can only be 0, 1, or 2, so we can calaculate
/// `2^(r/3)` ahead of time.
///
/// Multiplying everything gets us a pretty close answer to the true cbrt.
/// `cbrt(a) = cbrt(mantissa) * 2^q * 2^(r/3)`
///
/// One or two Newton-Raphson iterations reduce any error enough not to matter.
fn cube_root(a: f64) -> f64 {
    if !(a >= f64::MIN_POSITIVE && a.is_finite()) {
        return 0.0;
    }

    const POW2_REM_OVER_3: [f64; 3] = [1.0, 1.2599210498948732, 1.5874010519681994];

    // decompose a into IEEE-754 components
    let bits = a.to_bits();

    // extract mantissa, get rough cbrt using linear interpolation
    let m = f64::from_bits((bits & 0x000F_FFFF_FFFF_FFFF) | 0x3FF0_0000_0000_0000);
    let cbrt_m = m.mul_add(0.2599, 0.7401);

    // extract exponent, break into quotient and remainder
    // e = 3q + r where r ∈ {0, 1, 2}
    let e = (((bits >> 52) & 0x7FF) as i64) - 1023;
    let q = e.div_euclid(3);
    let r = e.rem_euclid(3) as usize;

    // calculate 2^q efficiently by constructing f64 from bits
    let pow2q = f64::from_bits(((q + 1023) as u64) << 52);

    // add cbrt mantissa and other component back in:
    // cbrt mantiassa * 2^q * 2^(r/3)
    let x = cbrt_m * pow2q * POW2_REM_OVER_3[r];

    // a single iteration should bring us close enough
    (2.0 * x + a / (x * x)) / 3.0
}

#[cfg(test)]
#[path = "cubic_test_tests.rs"]
mod test;
