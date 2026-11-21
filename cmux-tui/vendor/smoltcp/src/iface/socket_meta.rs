use super::SocketHandle;
use crate::{
    socket::PollAt,
    time::{Duration, Instant},
    wire::IpAddress,
};

/// Neighbor dependency.
///
/// This enum tracks whether the socket should be polled based on the neighbor
/// it is going to send packets to.
#[derive(Debug, Default)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
enum NeighborState {
    /// Socket can be polled immediately.
    #[default]
    Active,
    /// Socket should not be polled until either `silent_until` passes or
    /// `neighbor` appears in the neighbor cache.
    Waiting {
        neighbor: IpAddress,
        silent_until: Instant,
    },
}

/// Network socket metadata.
///
/// This includes things that only external (to the socket, that is) code
/// is interested in, but which are more conveniently stored inside the socket
/// itself.
#[derive(Debug, Default)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub(crate) struct Meta {
    /// Handle of this socket within its enclosing `SocketSet`.
    /// Mainly useful for debug output.
    pub(crate) handle: SocketHandle,
    /// See [NeighborState](struct.NeighborState.html).
    neighbor_state: NeighborState,
}

impl Meta {
    /// Minimum delay between neighbor discovery requests for this particular
    /// socket, in milliseconds.
    ///
    /// See also `iface::NeighborCache::SILENT_TIME`.
    pub(crate) const DISCOVERY_SILENT_TIME: Duration = Duration::from_millis(1_000);

    pub(crate) fn poll_at<F>(
        &self,
        socket_poll_at: PollAt,
        has_neighbor: F,
        timestamp: Instant,
    ) -> PollAt
    where
        F: Fn(IpAddress) -> bool,
    {
        match self.neighbor_state {
            NeighborState::Active => socket_poll_at,
            NeighborState::Waiting { neighbor, .. } if has_neighbor(neighbor) => socket_poll_at,
            NeighborState::Waiting { silent_until, .. } if timestamp >= silent_until => {
                socket_poll_at
            }
            NeighborState::Waiting { silent_until, .. } => PollAt::Time(silent_until),
        }
    }

    pub(crate) fn egress_permitted<F>(&mut self, timestamp: Instant, has_neighbor: F) -> bool
    where
        F: Fn(IpAddress) -> bool,
    {
        match self.neighbor_state {
            NeighborState::Active => true,
            NeighborState::Waiting {
                neighbor,
                silent_until,
            } => {
                if has_neighbor(neighbor) {
                    net_trace!(
                        "{}: neighbor {} discovered, unsilencing",
                        self.handle,
                        neighbor
                    );
                    self.neighbor_state = NeighborState::Active;
                    true
                } else if timestamp >= silent_until {
                    net_trace!(
                        "{}: neighbor {} silence timer expired, rediscovering",
                        self.handle,
                        neighbor
                    );
                    true
                } else {
                    false
                }
            }
        }
    }

    pub(crate) fn neighbor_missing(&mut self, timestamp: Instant, neighbor: IpAddress) {
        net_trace!(
            "{}: neighbor {} missing, silencing until t+{}",
            self.handle,
            neighbor,
            Self::DISCOVERY_SILENT_TIME
        );
        self.neighbor_state = NeighborState::Waiting {
            neighbor,
            silent_until: timestamp + Self::DISCOVERY_SILENT_TIME,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(feature = "proto-ipv4")]
    const NEIGHBOR: IpAddress = IpAddress::v4(192, 168, 1, 1);
    #[cfg(not(feature = "proto-ipv4"))]
    const NEIGHBOR: IpAddress = IpAddress::v6(0xfe80, 0, 0, 0, 0, 0, 0, 1);

    fn meta() -> Meta {
        Meta {
            handle: SocketHandle::default(),
            neighbor_state: NeighborState::Active,
        }
    }

    #[test]
    fn poll_at_active_passes_through() {
        let m = meta();
        let t = Instant::from_millis(1000);

        assert_eq!(m.poll_at(PollAt::Ingress, |_| false, t), PollAt::Ingress);
        assert_eq!(m.poll_at(PollAt::Now, |_| false, t), PollAt::Now);
        let future = Instant::from_millis(2000);
        assert_eq!(
            m.poll_at(PollAt::Time(future), |_| false, t),
            PollAt::Time(future),
        );
    }

    #[test]
    fn poll_at_waiting_neighbor_found() {
        let mut m = meta();
        m.neighbor_missing(Instant::from_millis(1000), NEIGHBOR);

        assert_eq!(
            m.poll_at(PollAt::Now, |_| true, Instant::from_millis(1000)),
            PollAt::Now,
        );
        assert_eq!(
            m.poll_at(PollAt::Ingress, |_| true, Instant::from_millis(1000)),
            PollAt::Ingress,
        );
    }

    #[test]
    fn poll_at_waiting_before_silent_until() {
        let mut m = meta();
        let t0 = Instant::from_millis(1000);
        m.neighbor_missing(t0, NEIGHBOR);
        let silent_until = t0 + Meta::DISCOVERY_SILENT_TIME;

        let t_before = Instant::from_millis(1500);
        assert!(t_before < silent_until);

        assert_eq!(
            m.poll_at(PollAt::Ingress, |_| false, t_before),
            PollAt::Time(silent_until),
        );
        assert_eq!(
            m.poll_at(PollAt::Now, |_| false, t_before),
            PollAt::Time(silent_until),
        );
    }

    #[test]
    fn poll_at_waiting_after_silent_until_returns_socket_poll_at() {
        let mut m = meta();
        let t0 = Instant::from_millis(1000);
        m.neighbor_missing(t0, NEIGHBOR);
        let silent_until = t0 + Meta::DISCOVERY_SILENT_TIME;

        let t_after = Instant::from_millis(2500);
        assert!(t_after >= silent_until);

        assert_eq!(
            m.poll_at(PollAt::Ingress, |_| false, t_after),
            PollAt::Ingress,
        );
        assert_eq!(m.poll_at(PollAt::Now, |_| false, t_after), PollAt::Now);
        let future = Instant::from_millis(5000);
        assert_eq!(
            m.poll_at(PollAt::Time(future), |_| false, t_after),
            PollAt::Time(future),
        );
    }

    #[test]
    fn poll_at_waiting_at_exact_silent_until() {
        let mut m = meta();
        let t0 = Instant::from_millis(1000);
        m.neighbor_missing(t0, NEIGHBOR);
        let silent_until = t0 + Meta::DISCOVERY_SILENT_TIME;

        assert_eq!(
            m.poll_at(PollAt::Ingress, |_| false, silent_until),
            PollAt::Ingress,
        );
    }

    #[test]
    fn egress_permitted_consistent_with_poll_at() {
        let mut m = meta();
        let t0 = Instant::from_millis(1000);
        m.neighbor_missing(t0, NEIGHBOR);
        let silent_until = t0 + Meta::DISCOVERY_SILENT_TIME;

        let t_before = Instant::from_millis(1500);
        assert!(!m.egress_permitted(t_before, |_| false));
        assert_eq!(
            m.poll_at(PollAt::Ingress, |_| false, t_before),
            PollAt::Time(silent_until),
        );

        let t_after = Instant::from_millis(2500);
        assert!(m.egress_permitted(t_after, |_| false));
    }
}
