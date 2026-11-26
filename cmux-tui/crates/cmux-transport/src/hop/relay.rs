//! The PoP's forwarding core: two legs, every record delivered on one is
//! queued on the other with its class and tag, so each leg repairs its own
//! loss and applies latest-wins to its own backlog.

use std::time::Instant;

use super::Leg;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    A,
    B,
}

impl Side {
    pub fn other(self) -> Self {
        match self {
            Self::A => Self::B,
            Self::B => Self::A,
        }
    }
}

pub struct HopRelay {
    a: Leg,
    b: Leg,
}

impl HopRelay {
    pub fn new(a: Leg, b: Leg) -> Self {
        Self { a, b }
    }

    pub fn leg(&self, side: Side) -> &Leg {
        match side {
            Side::A => &self.a,
            Side::B => &self.b,
        }
    }

    pub fn leg_mut(&mut self, side: Side) -> &mut Leg {
        match side {
            Side::A => &mut self.a,
            Side::B => &mut self.b,
        }
    }

    /// A datagram received on `from`'s leg. Returns how many records were
    /// queued on the other leg.
    pub fn handle(&mut self, from: Side, datagram: &[u8], now: Instant) -> usize {
        let delivered = self.leg_mut(from).handle(datagram, now);
        let to = self.leg_mut(from.other());
        delivered.into_iter().filter(|d| to.send(d.record.clone(), now).is_ok()).count()
    }

    pub fn poll_transmit(&mut self, to: Side, now: Instant) -> Option<Vec<u8>> {
        self.leg_mut(to).poll_transmit(now)
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        match (self.a.poll_timeout(), self.b.poll_timeout()) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }
}
