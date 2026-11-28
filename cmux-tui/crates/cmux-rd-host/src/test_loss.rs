//! Measurement only: drops a seeded fraction of the host's outgoing video and
//! parity datagrams, so a loss A/B runs on a clean link with no shaper on the
//! Mac (a zero-delay dummynet pipe panics the kernel of some fleet Macs).
//! Off unless `CMUX_RD_TEST_LOSS_PCT` is set (0 to 100, decimals allowed);
//! `CMUX_RD_TEST_LOSS_SEED` picks the drop sequence (default 1). Control,
//! feedback, input acks and cursor datagrams are never dropped.

use crate::carrier::{Carrier, DatagramDeparture, Incoming};
use crate::wire::Control;
use cmux_rd_proto::{DatagramHeader, DatagramKind};
use std::io;
use std::os::fd::RawFd;

/// The drop rate and its seeded sequence.
#[derive(Debug, Clone)]
pub struct TestLoss {
    /// Drop when the next draw is under this (out of `u64::MAX`).
    threshold: u64,
    state: u64,
    /// Media datagrams dropped so far.
    pub dropped: u64,
}

impl TestLoss {
    /// From the environment, or None when the knob is not set (the default).
    pub fn from_env() -> Option<Self> {
        let pct: f64 = std::env::var("CMUX_RD_TEST_LOSS_PCT").ok()?.trim().parse().ok()?;
        let seed = std::env::var("CMUX_RD_TEST_LOSS_SEED")
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(1);
        let loss = Self::new(pct, seed)?;
        eprintln!(
            "cmux-rd host: CMUX_RD_TEST_LOSS_PCT={pct} seed={seed}: dropping media datagrams"
        );
        Some(loss)
    }

    /// `pct` of media datagrams dropped, from `seed`; None when `pct` is not above 0.
    pub fn new(pct: f64, seed: u64) -> Option<Self> {
        if pct.is_nan() || pct <= 0.0 {
            return None;
        }
        let fraction = (pct / 100.0).min(1.0);
        // u64::MAX as f64 rounds up to 2^64; the cast saturates, so 100 % drops everything.
        let threshold = (fraction * u64::MAX as f64) as u64;
        // A zero state would stay zero in xorshift.
        Some(Self { threshold, state: seed | 1, dropped: 0 })
    }

    /// xorshift64*: deterministic, no dependency, plenty for a drop decision.
    fn next(&mut self) -> u64 {
        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;
        self.state.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// Whether to drop this outgoing datagram (only video and parity are candidates).
    pub fn drops(&mut self, datagram: &[u8]) -> bool {
        let media = DatagramHeader::decode(datagram)
            .is_ok_and(|(h, _)| matches!(h.kind, DatagramKind::Video | DatagramKind::Fec));
        if !media {
            return false;
        }
        let drop = self.next() < self.threshold;
        if drop {
            self.dropped = self.dropped.saturating_add(1);
        }
        drop
    }
}

/// A carrier that loses media datagrams per [`TestLoss`] and passes the rest through.
pub struct LossyCarrier<'a> {
    pub inner: &'a mut dyn Carrier,
    pub loss: TestLoss,
}

impl Drop for LossyCarrier<'_> {
    fn drop(&mut self) {
        eprintln!("cmux-rd host: test loss dropped {} media datagrams", self.loss.dropped);
    }
}

impl Carrier for LossyCarrier<'_> {
    fn fds(&self) -> Vec<RawFd> {
        self.inner.fds()
    }

    fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String> {
        self.inner.receive(out)
    }

    fn path_rtt_us(&self) -> Option<u64> {
        self.inner.path_rtt_us()
    }

    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()> {
        if self.loss.drops(datagram) {
            return Ok(());
        }
        self.inner.send_datagram(datagram)
    }

    fn send_datagram_frame(&mut self, datagrams: Vec<Vec<u8>>, droppable: bool) -> io::Result<()> {
        // The frame path loses media as send_datagram does, one datagram at a time; what is left goes out as one frame.
        let kept: Vec<Vec<u8>> = datagrams.into_iter().filter(|d| !self.loss.drops(d)).collect();
        if kept.is_empty() {
            return Ok(());
        }
        self.inner.send_datagram_frame(kept, droppable)
    }

    fn send_control(&mut self, control: &Control) -> io::Result<()> {
        self.inner.send_control(control)
    }

    fn drain_departures(&mut self, out: &mut Vec<DatagramDeparture>) {
        self.inner.drain_departures(out);
    }

    fn departure_overflows(&self) -> u64 {
        self.inner.departure_overflows()
    }
}

#[cfg(test)]
#[path = "test_loss_tests.rs"]
mod tests;
