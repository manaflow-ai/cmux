use crate::{socket::tcp::RttEstimator, time::Instant};

use super::Controller;

const DEFAULT_MSS: usize = 1024;

#[derive(Debug)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Reno {
    cwnd: usize,
    mss: usize,
    ssthresh: usize,
    rwnd: usize,

    in_fast_recovery: bool,
    // Set on RTO, cleared when new data is ACKed. While set, further RTOs
    // are retransmissions of the same segment and must not reduce ssthresh
    // again (RFC 5681 section 3.1).
    in_rto_recovery: bool,
}

impl Reno {
    pub fn new() -> Self {
        Reno {
            cwnd: DEFAULT_MSS * 2,
            mss: DEFAULT_MSS,
            ssthresh: usize::MAX,
            rwnd: 64 * DEFAULT_MSS,
            in_fast_recovery: false,
            in_rto_recovery: false,
        }
    }
}

impl Controller for Reno {
    fn window(&self) -> usize {
        self.cwnd
    }

    fn on_ack(&mut self, _now: Instant, len: usize, _in_flight: usize, _rtt: &RttEstimator) {
        // RFC 5681 only acts on ACKs of new data. The socket also notifies us
        // of accepted segments that acknowledge nothing (window updates, data
        // segments from the remote): those must not exit fast recovery nor
        // grow the window.
        if len == 0 {
            return;
        }

        // New data was ACKed: a timer-based loss episode, if any, is over.
        self.in_rto_recovery = false;

        // First new-data-ack exits fast recovery and deflates `cwnd`
        if self.in_fast_recovery {
            self.in_fast_recovery = false;
            self.cwnd = self.ssthresh;
            return;
        }

        let inc = if self.cwnd < self.ssthresh {
            // Slow start: increase `cwnd` by 1 MSS per ACK.
            len.min(self.mss)
        } else {
            // Congestion avoidance: increase by ~1 MSS per RTT.
            (self.mss * self.mss / self.cwnd).max(1)
        };

        self.cwnd = self.cwnd.saturating_add(inc).min(self.rwnd).max(self.mss);
    }

    fn on_dup_ack(&mut self, _now: Instant, len: usize, _in_flight: usize) {
        if self.in_fast_recovery {
            self.cwnd = self.cwnd.saturating_add(len).min(self.rwnd).max(self.mss);
        }
    }

    fn on_loss(&mut self, _now: Instant, in_flight: usize) {
        // Only cut window size on first entrance to fast recovery.
        if !self.in_fast_recovery {
            self.ssthresh = (in_flight >> 1).max(2 * self.mss);
            self.cwnd = self.ssthresh.min(self.rwnd).saturating_add(3 * self.mss);

            self.in_fast_recovery = true;
        }
    }

    fn on_rto(&mut self, _now: Instant, in_flight: usize) {
        // RFC 5681: when the retransmission timer fires for a segment that has
        // already been retransmitted by the timer (no new data was ACKed since
        // the previous RTO), ssthresh is held constant.
        if !self.in_rto_recovery {
            self.ssthresh = (in_flight >> 1).max(2 * self.mss);
            self.in_rto_recovery = true;
        }

        // cwnd collapses to the loss window (1 MSS) and we re-enter slow start.
        self.cwnd = self.mss;

        // Major loss has occurred, ensure we move from fast recovery (if in it) to slow start.
        self.in_fast_recovery = false
    }

    fn set_mss(&mut self, mss: usize) {
        self.mss = mss;
    }

    fn set_remote_window(&mut self, remote_window: usize) {
        if self.rwnd < remote_window {
            self.rwnd = remote_window;
        }
    }
}

#[cfg(test)]
mod test {
    use crate::time::Instant;

    use super::*;

    const MSS: usize = 1024;

    fn ack(reno: &mut Reno, len: usize, now: Instant) {
        reno.on_ack(now, len, reno.window().saturating_sub(MSS), &rtte())
    }

    fn rtte() -> RttEstimator {
        RttEstimator::default()
    }

    #[test]
    fn congestion_avoidance_works() {
        let mut reno = Reno::new();
        reno.set_mss(MSS);
        reno.cwnd = MSS * 32;
        reno.ssthresh = MSS * 16;

        // CA should grow at less than 1 MSS per ACK.
        for i in 0..10 {
            let initial_cwnd = reno.window();
            ack(&mut reno, MSS, Instant::from_millis(i));
            assert!(reno.window() < initial_cwnd + MSS);
        }

        // CA should cap at the receive window
        reno.cwnd = reno.rwnd - 1;
        ack(&mut reno, MSS, Instant::from_millis(20));
        assert_eq!(reno.window(), reno.rwnd);
    }

    #[test]
    fn fast_recovery_works() {
        let mut reno = Reno::new();
        reno.set_mss(MSS);
        reno.cwnd = MSS * 32;

        // duplicate ACKs before fast recovery should do nothing
        let initial_cwnd = reno.window();
        for _ in 0..3 {
            reno.on_dup_ack(Instant::from_millis(0), MSS, initial_cwnd);
        }
        assert_eq!(reno.window(), initial_cwnd);

        // we enter fast recovery upon minor loss (three duplicate ACKs)
        // window should become half the in-flight bytes
        // sstresh should be the reduced cwnd, advanced by MSS for the 3 dup ACKs
        let inflight = initial_cwnd / 2;
        reno.on_loss(Instant::from_millis(0), inflight);
        assert_eq!(reno.ssthresh, inflight / 2);
        assert_eq!(reno.cwnd, inflight / 2 + 3 * MSS);

        // in fast recovery, each dup-ACK should increase  the cwnd by 1 MSS
        let initial_cwnd = reno.window();
        for i in 0..3 {
            for _ in 0..3 {
                let initial_cwnd = reno.window();
                reno.on_dup_ack(Instant::from_millis(i), MSS, initial_cwnd);
                assert_eq!(reno.window(), initial_cwnd + MSS);
            }

            // multiple loss events (trip-dup-ack) should not trigger additional fast recovery reductions
            let initial_cwnd = reno.window();
            let initial_ssthresh = reno.ssthresh;
            reno.on_loss(Instant::from_millis(i), initial_cwnd);
            assert_eq!(reno.window(), initial_cwnd);
            assert_eq!(reno.ssthresh, initial_ssthresh);
        }
        assert_eq!(reno.window(), initial_cwnd + MSS * 9);

        // a non-duplicate ACK exits fast recovery and enters congestion avoidance
        ack(&mut reno, MSS, Instant::from_millis(10));
        assert_eq!(reno.window(), reno.ssthresh);

        // CA is slower growth so should be less than 1MSS per ACK
        let initial_cwnd = reno.window();
        ack(&mut reno, MSS, Instant::from_millis(30));
        assert!(reno.window() < initial_cwnd + MSS);
    }

    #[test]
    fn slow_start_works() {
        let mut reno = Reno::new();
        reno.set_mss(MSS);
        reno.cwnd = MSS * 32;
        reno.ssthresh = MSS * 16;

        // we enter recovery upon major loss (an RTO)
        // window should become to 1MSS
        // sstresh should become half the in-flight bytes
        let initial_cwnd = reno.window();
        let inflight = initial_cwnd;
        reno.on_rto(Instant::from_millis(0), initial_cwnd);
        assert_eq!(reno.ssthresh, inflight / 2);
        assert_eq!(reno.window(), MSS);

        // slow start grows by at most the MSS per ack
        let initial_cwnd = reno.window();
        for i in 0..10 {
            let initial_cwnd = reno.window();
            let now = Instant::from_millis(i);
            ack(&mut reno, MSS * 2, now);
            assert_eq!(reno.window(), initial_cwnd + MSS);
        }
        assert_eq!(reno.window(), initial_cwnd + MSS * 10);

        // slow start uses the number of ACKed bytes if they're less than the MSS
        let initial_cwnd = reno.window();
        for i in 0..10 {
            let initial_cwnd = reno.window();
            let now = Instant::from_millis(10 + i);
            ack(&mut reno, MSS / 2, now);
            assert_eq!(reno.window(), initial_cwnd + MSS / 2);
        }
        assert_eq!(reno.window(), initial_cwnd + MSS / 2 * 10);

        // slow start transitions to congestion avoidance at ssthresh
        let initial_cwnd = reno.window();
        reno.ssthresh = initial_cwnd + MSS;
        ack(&mut reno, MSS, Instant::from_millis(30));
        assert_eq!(reno.window(), initial_cwnd + MSS);
        assert_eq!(reno.ssthresh, initial_cwnd + MSS);

        // slow start transitions to congestion avoidance at ssthresh
        // CA is slower growth so should be less than 1MSS per ACK
        let initial_cwnd = reno.window();
        ack(&mut reno, MSS, Instant::from_millis(30));
        assert!(reno.window() < initial_cwnd + MSS);
    }

    #[test]
    fn progress_to_ca_via_rto() {
        let mut reno = Reno::new();
        reno.set_mss(MSS);

        let mut time = 0;

        // slow start from default state
        let initial_cwnd = reno.window();
        for _ in 0..30 {
            time += 1;
            ack(&mut reno, MSS, Instant::from_millis(time));
        }
        assert_eq!(reno.window(), initial_cwnd + MSS * 30);
        assert!(reno.window() < reno.ssthresh);

        // rto: cwnd resets to MSS, ssthresh becomes half in-flight bytes
        let rto_cwnd = reno.window();
        reno.on_rto(Instant::from_millis(time), rto_cwnd);
        assert_eq!(reno.window(), MSS);
        assert_eq!(reno.ssthresh, rto_cwnd / 2);

        // slow start again until cwnd reaches new ssthresh
        while reno.window() < reno.ssthresh {
            time += 1;
            let initial_cwnd = reno.window();
            ack(&mut reno, MSS, Instant::from_millis(time));
            assert_eq!(reno.window(), initial_cwnd + MSS);
        }
        assert_eq!(reno.window(), reno.ssthresh);

        // ca: each ack at or above ssthresh grows by less than MSS
        time += 1;
        let initial_cwnd = reno.window();
        ack(&mut reno, MSS, Instant::from_millis(time));
        assert!(reno.window() > initial_cwnd);
        assert!(reno.window() < initial_cwnd + MSS);
    }

    #[test]
    fn progress_to_ca_via_loss() {
        let mut reno = Reno::new();
        reno.set_mss(MSS);

        let mut time = 0;

        // slow start from default state
        let initial_cwnd = reno.window();
        for _ in 0..30 {
            time += 1;
            ack(&mut reno, MSS, Instant::from_millis(time));
        }
        assert_eq!(reno.window(), initial_cwnd + MSS * 30);
        assert!(reno.window() < reno.ssthresh);

        // dup ACKs: cwnd and sstresh become half in-flight bytes AND cwnd gets advanced for each dup-ack it had received
        time += 1;
        let loss_cwnd = reno.window();
        let expected_ssthresh = loss_cwnd / 2;
        reno.on_loss(Instant::from_millis(time), loss_cwnd);
        assert_eq!(reno.ssthresh, expected_ssthresh);
        assert_eq!(reno.window(), expected_ssthresh + 3 * MSS);
        assert!(reno.in_fast_recovery);

        // inflate cwnd until on each duplicate ACK
        for _ in 0..9 {
            time += 1;
            let initial_cwnd = reno.window();
            reno.on_dup_ack(Instant::from_millis(time), MSS, reno.cwnd);
            assert_eq!(reno.window(), initial_cwnd + MSS);
        }

        // non-duplicate ACK deflates cwnd to ssthresh
        time += 1;
        ack(&mut reno, MSS, Instant::from_millis(time));
        assert_eq!(reno.window(), expected_ssthresh);
        assert!(!reno.in_fast_recovery);

        // ca: each ack at or above ssthresh grows by less than MSS
        time += 1;
        let initial_cwnd = reno.window();
        ack(&mut reno, MSS, Instant::from_millis(time));
        assert!(reno.window() > initial_cwnd);
        assert!(reno.window() < initial_cwnd + MSS);
    }

    #[test]
    fn zero_length_ack_does_not_exit_fast_recovery() {
        let mut reno = Reno::new();
        reno.set_mss(MSS);
        reno.cwnd = MSS * 32;

        reno.on_loss(Instant::from_millis(0), reno.cwnd);
        assert!(reno.in_fast_recovery);

        let cwnd = reno.window();
        let ssthresh = reno.ssthresh;

        // Accepted segments that acknowledge no new data (window updates,
        // data segments from the remote) must not end fast recovery or
        // change the window.
        ack(&mut reno, 0, Instant::from_millis(1));
        assert!(reno.in_fast_recovery);
        assert_eq!(reno.window(), cwnd);
        assert_eq!(reno.ssthresh, ssthresh);

        // The first ACK of new data still exits and deflates.
        ack(&mut reno, MSS, Instant::from_millis(2));
        assert!(!reno.in_fast_recovery);
        assert_eq!(reno.window(), ssthresh);
    }

    #[test]
    fn zero_length_ack_does_not_grow_window() {
        let mut reno = Reno::new();
        reno.set_mss(MSS);

        // Slow start.
        let cwnd = reno.window();
        ack(&mut reno, 0, Instant::from_millis(0));
        assert_eq!(reno.window(), cwnd);

        // Congestion avoidance.
        reno.cwnd = MSS * 32;
        reno.ssthresh = MSS * 16;
        ack(&mut reno, 0, Instant::from_millis(1));
        assert_eq!(reno.window(), MSS * 32);
    }

    #[test]
    fn repeated_rto_holds_ssthresh() {
        let mut reno = Reno::new();
        reno.set_mss(MSS);
        reno.cwnd = MSS * 32;

        // First RTO halves ssthresh based on the flight size.
        reno.on_rto(Instant::from_millis(0), MSS * 32);
        assert_eq!(reno.ssthresh, MSS * 16);
        assert_eq!(reno.window(), MSS);

        // Until new data is ACKed, further RTOs are retransmissions of the
        // same segment and must hold ssthresh constant instead of collapsing
        // it towards the minimum.
        reno.on_rto(Instant::from_millis(1), MSS);
        assert_eq!(reno.ssthresh, MSS * 16);
        assert_eq!(reno.window(), MSS);

        // Once new data is ACKed, the next RTO is a fresh loss detection
        // and reduces ssthresh again.
        ack(&mut reno, MSS, Instant::from_millis(2));
        reno.on_rto(Instant::from_millis(3), MSS * 4);
        assert_eq!(reno.ssthresh, MSS * 2);
    }

    #[test]
    fn test_reno() {
        let remote_window = 64 * 1024;
        let now = Instant::from_millis(0);

        for i in 0..10 {
            for j in 0..9 {
                let mut reno = Reno::new();
                reno.set_mss(1480);

                // Set remote window.
                reno.set_remote_window(remote_window);

                reno.on_ack(now, 4096, reno.window(), &RttEstimator::default());

                let mut n = i;
                for _ in 0..j {
                    n *= i;
                }

                if i & 1 == 0 {
                    reno.on_rto(now, reno.window());
                } else {
                    reno.on_loss(now, reno.window());
                }

                let elapsed = Instant::from_millis(1000);
                reno.on_ack(elapsed, n, reno.window(), &RttEstimator::default());

                let cwnd = reno.window();
                println!("Reno: elapsed = {}, cwnd = {}", elapsed, cwnd);

                assert!(cwnd >= reno.mss);
                assert!(reno.window() <= remote_window);
            }
        }
    }

    #[test]
    fn reno_min_cwnd() {
        let remote_window = 64 * 1024;
        let now = Instant::from_millis(0);

        let mut reno = Reno::new();
        reno.set_remote_window(remote_window);

        for _ in 0..100 {
            reno.on_rto(now, reno.window());
            assert!(reno.window() >= reno.mss);
        }
    }

    #[test]
    fn reno_set_rwnd() {
        let mut reno = Reno::new();
        reno.set_remote_window(64 * 1024 * 1024);

        println!("{reno:?}");
    }
}
