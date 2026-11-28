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
