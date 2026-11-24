//! cmux patch: a BBR-style congestion controller (RFD 0142 O1).
//!
//! The window follows a model of the path rather than loss: the bottleneck
//! rate (the highest delivery rate over the last [`BW_ROUNDS`] rounds that
//! were not limited by the application) times the minimum RTT (over
//! [`MIN_RTT_WINDOW`]) gives the path's bandwidth-delay product, and the
//! window is [`CWND_GAIN`] of it. A segment lost at random on a lossy link
//! does not shrink the window; it is repaired by SACK or the retransmit
//! timer as before. Only RTOs in a row with nothing acknowledged between them
//! (a dead or badly congested path) collapse the window and restart the model.
//!
//! cmux-wg paces every tunnel datagram itself, so this controller is window
//! based only: there is no pacing gain cycle and no PROBE_RTT phase (the
//! window floor of [`initial_window`] keeps a lull from starving a burst).
//! Startup grows the window by every byte acknowledged, like slow start,
//! until the delivery rate grows less than [`FULL_BW_GROWTH_PCT`] percent
//! for [`FULL_BW_ROUNDS`] rounds.

use crate::{
    socket::tcp::RttEstimator,
    time::{Duration, Instant},
};

use super::Controller;

const DEFAULT_MSS: usize = 1024;
/// Rounds the bottleneck rate filter remembers.
const BW_ROUNDS: usize = 10;
/// How long a minimum RTT sample stays valid without being met again.
const MIN_RTT_WINDOW: Duration = Duration::from_secs(10);
/// The window over the bandwidth-delay product once startup ends.
const CWND_GAIN: usize = 2;
/// Startup ends after this many rounds in which the rate grew less than
/// [`FULL_BW_GROWTH_PCT`] percent.
const FULL_BW_ROUNDS: u8 = 3;
const FULL_BW_GROWTH_PCT: u64 = 25;
/// RTOs in a row (nothing new acknowledged between them) that collapse the
/// window and restart the model.
const RTO_COLLAPSE: u8 = 2;
/// The shortest round, so a sub-millisecond RTT on a LAN still measures a
/// rate over enough ACKs.
const MIN_ROUND: Duration = Duration::from_millis(2);
/// The round used before any RTT sample.
const FIRST_ROUND: Duration = Duration::from_millis(100);

// RFC 6928 initial window, as for CUBIC in this patch.
fn initial_window(mss: usize) -> usize {
    (10 * mss).min((2 * mss).max(14600))
}

#[derive(Debug, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Bbr {
    mss: usize,
    rwnd: usize,
    cwnd: usize,
    startup: bool,
    full_bw: u64,
    full_bw_rounds: u8,
    /// Delivery rates (bytes per second) of the last rounds, a ring.
    bw: [u64; BW_ROUNDS],
    bw_next: usize,
    round_start: Option<Instant>,
    round_delivered: usize,
    round_app_limited: bool,
    min_rtt_ms: Option<u32>,
    min_rtt_at: Instant,
    rtos: u8,
    /// The window before an RTO, restored by the next ACK of new data (BBR's
    /// packet conservation: a go-back-N resend of a whole window after an RTO
    /// lost more of itself at high loss, and the backed-off RTO outlasted the
    /// user timeout).
    saved_cwnd: Option<usize>,
    /// No new data ACKed and no RTO yet, so an MSS learned from the handshake
    /// may still resize the initial window.
    initial: bool,
}

impl Bbr {
    pub fn new() -> Bbr {
        Bbr {
            mss: DEFAULT_MSS,
            rwnd: 64 * DEFAULT_MSS,
            cwnd: initial_window(DEFAULT_MSS),
            startup: true,
            full_bw: 0,
            full_bw_rounds: 0,
            bw: [0; BW_ROUNDS],
            bw_next: 0,
            round_start: None,
            round_delivered: 0,
            round_app_limited: false,
            min_rtt_ms: None,
            min_rtt_at: Instant::ZERO,
            rtos: 0,
            saved_cwnd: None,
            initial: true,
        }
    }

    fn max_bw(&self) -> u64 {
        self.bw.iter().copied().max().unwrap_or(0)
    }

    /// The bandwidth-delay product in bytes, if both halves are known.
    fn bdp(&self) -> Option<usize> {
        let rtt = self.min_rtt_ms? as u64;
        let bw = self.max_bw();
        (bw > 0).then(|| (bw.saturating_mul(rtt.max(1)) / 1000) as usize)
    }

    fn floor(&self) -> usize {
        initial_window(self.mss)
    }

    fn round_len(&self) -> Duration {
        match self.min_rtt_ms {
            Some(ms) => Duration::from_millis(ms as u64).max(MIN_ROUND),
            None => FIRST_ROUND,
        }
    }

    fn update_min_rtt(&mut self, now: Instant, rtt: &RttEstimator) {
        let Some(sample) = rtt.latest_sample() else {
            return;
        };
        let expired = now - self.min_rtt_at > MIN_RTT_WINDOW;
        if self.min_rtt_ms.is_none_or(|min| sample <= min) || expired {
            self.min_rtt_ms = Some(sample);
            self.min_rtt_at = now;
        }
    }

    /// Close the round at `now`: record its delivery rate, and in startup
    /// check whether the rate stopped growing.
    fn end_round(&mut self, now: Instant, start: Instant) {
        let elapsed = (now - start).total_micros().max(1);
        let rate = (self.round_delivered as u64).saturating_mul(1_000_000) / elapsed;
        // An app-limited round says little about the path: it only counts when
        // it beats the estimate, and it never ages the filter otherwise.
        if !self.round_app_limited || rate > self.max_bw() {
            self.bw[self.bw_next] = rate;
            self.bw_next = (self.bw_next + 1) % BW_ROUNDS;
        }
        if self.startup && !self.round_app_limited {
            let max = self.max_bw();
            if max.saturating_mul(100) >= self.full_bw.saturating_mul(100 + FULL_BW_GROWTH_PCT) {
                self.full_bw = max;
                self.full_bw_rounds = 0;
            } else {
                self.full_bw_rounds += 1;
                if self.full_bw_rounds >= FULL_BW_ROUNDS {
                    self.startup = false;
                }
            }
        }
        self.round_start = None;
    }

    fn restart(&mut self) {
        self.startup = true;
        self.full_bw = 0;
        self.full_bw_rounds = 0;
        self.bw = [0; BW_ROUNDS];
        self.round_start = None;
        self.round_delivered = 0;
    }
}

impl Controller for Bbr {
    fn window(&self) -> usize {
        self.cwnd
    }

    fn on_ack(&mut self, now: Instant, len: usize, in_flight: usize, rtt: &RttEstimator) {
        // Window updates and data segments acknowledge nothing new.
        if len == 0 {
            return;
        }
        self.initial = false;
        self.rtos = 0;
        if let Some(saved) = self.saved_cwnd.take() {
            self.cwnd = self.cwnd.max(saved);
        }
        self.update_min_rtt(now, rtt);

        let start = match self.round_start {
            Some(start) => start,
            None => {
                self.round_start = Some(now);
                self.round_delivered = 0;
                // Less than half the window in flight: the sender, not the
                // path, set this round's rate.
                self.round_app_limited = in_flight + len < self.cwnd / 2;
                now
            }
        };
        self.round_delivered += len;
        if now - start >= self.round_len() {
            self.end_round(now, start);
        }

        let cap = self.rwnd.max(self.floor());
        if self.startup {
            self.cwnd = self.cwnd.saturating_add(len).min(cap);
            return;
        }
        let target = self
            .bdp()
            .map_or(self.cwnd, |bdp| (bdp * CWND_GAIN).max(self.floor()));
        self.cwnd = if self.cwnd < target {
            self.cwnd.saturating_add(len).min(target)
        } else {
            target
        }
        .min(cap);
    }

    fn on_rto(&mut self, _now: Instant, _in_flight: usize) {
        self.initial = false;
        self.rtos = self.rtos.saturating_add(1);
        if self.rtos >= RTO_COLLAPSE {
            // The path itself changed: forget the window and the model.
            self.saved_cwnd = None;
            self.restart();
        } else {
            self.saved_cwnd = Some(self.cwnd);
        }
        // Resend one segment at a time until an ACK of new data comes back.
        self.cwnd = self.mss;
    }

    fn set_mss(&mut self, mss: usize) {
        self.mss = mss;
        if self.initial {
            self.cwnd = initial_window(mss).min(self.rwnd);
        }
    }

    fn set_remote_window(&mut self, remote_window: usize) {
        if self.rwnd < remote_window {
            self.rwnd = remote_window;
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    const MSS: usize = 1160;

    fn rtte(ms: u32) -> RttEstimator {
        let mut rtt = RttEstimator::default();
        rtt.sample(ms);
        rtt
    }

    fn bbr() -> Bbr {
        let mut bbr = Bbr::new();
        bbr.set_mss(MSS);
        bbr.set_remote_window(4 << 20);
        bbr
    }

    /// Drives `rounds` rounds of `rtt_ms` each, delivering `rate` bytes per
    /// second in ACKs of `ack` bytes, with a full window in flight.
    fn drive(bbr: &mut Bbr, now: &mut Instant, rounds: usize, rtt_ms: u32, rate: u64, ack: usize) {
        let rtt = rtte(rtt_ms);
        let per_round = (rate * rtt_ms as u64 / 1000) as usize;
        let acks = (per_round / ack).max(1);
        let step = Duration::from_micros(rtt_ms as u64 * 1000 / acks as u64);
        for _ in 0..rounds {
            for _ in 0..acks {
                *now += step;
                let in_flight = bbr.window();
                bbr.on_ack(*now, ack, in_flight, &rtt);
            }
        }
    }

    #[test]
    fn startup_ends_near_the_path_bdp() {
        let mut bbr = bbr();
        let mut now = Instant::from_millis(0);
        // 1.25 MB/s over a 50 ms path: a BDP of 62.5 KB.
        drive(&mut bbr, &mut now, 30, 50, 1_250_000, MSS);
        assert!(!bbr.startup, "startup never ended");
        let bdp = bbr.bdp().unwrap();
        assert!((50_000..=80_000).contains(&bdp), "bdp {bdp}");
        assert!(
            bbr.window() >= bdp && bbr.window() <= 3 * bdp,
            "window {}",
            bbr.window()
        );
    }

    #[test]
    fn random_loss_does_not_shrink_the_window() {
        let mut bbr = bbr();
        let mut now = Instant::from_millis(0);
        drive(&mut bbr, &mut now, 30, 50, 1_250_000, MSS);
        let window = bbr.window();
        for _ in 0..10 {
            bbr.on_sack_loss(now, window);
            bbr.on_loss(now, window);
            bbr.on_dup_ack(now, MSS, window);
            drive(&mut bbr, &mut now, 1, 50, 1_250_000, MSS);
        }
        assert!(
            bbr.window() >= window * 9 / 10,
            "{} < {}",
            bbr.window(),
            window
        );
        // One RTO alone (a tail loss) resends one segment, then the next ACK
        // of new data restores the window.
        bbr.on_rto(now, window);
        assert_eq!(bbr.window(), MSS);
        now += Duration::from_millis(50);
        bbr.on_ack(now, MSS, 0, &rtte(50));
        assert!(bbr.window() >= window * 9 / 10);
    }

    #[test]
    fn rtos_in_a_row_collapse_and_restart() {
        let mut bbr = bbr();
        let mut now = Instant::from_millis(0);
        drive(&mut bbr, &mut now, 30, 50, 1_250_000, MSS);
        bbr.on_rto(now, bbr.window());
        bbr.on_rto(now, bbr.window());
        assert_eq!(bbr.window(), MSS);
        assert!(bbr.startup);
        assert_eq!(bbr.max_bw(), 0);
        // Nothing to restore: the next ACK grows from one segment in startup.
        bbr.on_ack(now, MSS, 0, &rtte(50));
        assert_eq!(bbr.window(), 2 * MSS);
    }

    #[test]
    fn app_limited_rounds_do_not_age_the_estimate() {
        let mut bbr = bbr();
        let mut now = Instant::from_millis(0);
        drive(&mut bbr, &mut now, 30, 50, 1_250_000, MSS);
        let bw = bbr.max_bw();
        let rtt = rtte(50);
        // Fifty rounds of a trickle with almost nothing in flight.
        for _ in 0..50 {
            now += Duration::from_millis(50);
            bbr.on_ack(now, MSS, 0, &rtt);
        }
        assert_eq!(bbr.max_bw(), bw);
    }

    #[test]
    fn mss_resizes_only_the_initial_window() {
        let mut bbr = Bbr::new();
        bbr.set_remote_window(1 << 20);
        bbr.set_mss(MSS);
        assert_eq!(bbr.window(), initial_window(MSS));
        bbr.on_ack(Instant::from_millis(1), MSS, 0, &rtte(50));
        let window = bbr.window();
        bbr.set_mss(536);
        assert_eq!(bbr.window(), window);
    }

    #[test]
    fn window_never_exceeds_the_receive_window() {
        let mut bbr = Bbr::new();
        bbr.set_mss(MSS);
        bbr.set_remote_window(32 * 1024);
        let mut now = Instant::from_millis(0);
        drive(&mut bbr, &mut now, 30, 50, 5_000_000, MSS);
        assert!(bbr.window() <= 64 * 1024);
    }
}
