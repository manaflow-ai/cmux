use super::*;
mod mock {
    use super::super::*;
    pub const SOURCE: Ipv6Address = Ipv6Address::new(0xfe80, 0xdb8, 0, 0, 0, 0, 0, 0);
    pub const PREFIX: NdiscPrefixInformation = NdiscPrefixInformation {
        prefix_len: 64,
        flags: NdiscPrefixInfoFlags::ADDRCONF,
        valid_lifetime: Duration::from_secs(700),
        preferred_lifetime: Duration::from_secs(300),
        prefix: Ipv6Address::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0),
    };
    pub const VALID: Duration = Duration::from_secs(600);

    pub const ROUTE: Route = Route {
        cidr: Ipv6Cidr::new(Ipv6Address::UNSPECIFIED, 0),
        via_router: SOURCE,
        valid_until: Instant::from_millis_const(100000),
    };
}
use mock::*;

#[test]
fn test_route() {
    assert!(ROUTE.same_route(&Ipv6Cidr::new(Ipv6Address::UNSPECIFIED, 0), &SOURCE));
    assert!(!ROUTE.same_route(&Ipv6Cidr::new(Ipv6Address::UNSPECIFIED, 64), &SOURCE));
    assert!(!ROUTE.same_route(
        &Ipv6Cidr::new(Ipv6Address::UNSPECIFIED, 0),
        &Ipv6Address::UNSPECIFIED
    ));
    assert!(!ROUTE.same_route(&Ipv6Cidr::new(SOURCE, 0), &Ipv6Address::UNSPECIFIED));
    assert!(!ROUTE.same_route(&Ipv6Cidr::new(SOURCE, 64), &Ipv6Address::UNSPECIFIED));
}

#[test]
fn test_route_valid() {
    assert!(ROUTE.is_valid(Instant::ZERO));
    assert!(!ROUTE.is_valid(Instant::from_secs(200)));
}

#[test]
fn test_solicitation() {
    let mut slaac = Slaac::new();
    let now = Instant::from_millis(1);
    assert!(slaac.rs_required(now));

    slaac.rs_sent(now);
    assert_eq!(slaac.num_solicitations, 2);
    assert!(!slaac.rs_required(now));

    let next_poll = slaac.poll_at(now).unwrap();
    assert_eq!(next_poll, now + RTR_SOLICITATION_INTERVAL);

    let now = next_poll;
    assert!(slaac.rs_required(now));

    slaac.num_solicitations = 0;
    assert!(!slaac.rs_required(now));
    slaac.rs_sent(now);
    assert_eq!(slaac.phase, Phase::None);
    assert!(slaac.poll_at(now).is_none());
}

#[test]
fn test_ra_state() {
    let mut slaac = Slaac::new();
    assert_eq!(slaac.phase, Phase::Start);
    let now = Instant::from_millis(1);
    assert!(!slaac.has_ra_update());

    // Unsolicited advertisement
    slaac.process_advertisement(&SOURCE, VALID, Some(PREFIX), now);
    assert_eq!(slaac.phase, Phase::Start);
    assert!(slaac.has_ra_update());

    let now = Instant::from_secs(300);
    slaac.rs_sent(now);
    assert_eq!(slaac.phase, Phase::Discovering);

    // Solicited advertisement
    slaac.process_advertisement(&SOURCE, VALID, Some(PREFIX), now);
    slaac.process_advertisement(&SOURCE, VALID, Some(PREFIX), now);
    assert_eq!(slaac.phase, Phase::Maintaining);
    let poll_at = slaac.poll_at(now).unwrap();
    assert_eq!(poll_at, now + VALID);

    for (prefix, info) in slaac.prefix() {
        assert_eq!(prefix.address(), PREFIX.prefix);
        assert_eq!(prefix.prefix_len(), PREFIX.prefix_len);
        assert_eq!(info.valid_until, now + PREFIX.valid_lifetime);
        assert_eq!(info.preferred_until, now + PREFIX.preferred_lifetime);
        assert!(info.is_valid(now));
    }

    for route in slaac.routes() {
        assert_eq!(route.cidr, Ipv6Cidr::new(Ipv6Address::UNSPECIFIED, 0));
        assert_eq!(route.via_router, SOURCE);
        assert_eq!(route.valid_until, now + VALID);
        assert!(route.is_valid(now));
    }
    assert_eq!(slaac.prefix().len(), 1);
    assert_eq!(slaac.routes().len(), 1);
    assert!(slaac.sync_required(now));

    slaac.update_slaac_state(now);
    assert!(!slaac.sync_required(now));

    // Skip time until the route expires
    let now = poll_at;
    assert!(slaac.sync_required(now));
    for (_prefix, info) in slaac.prefix() {
        assert!(info.is_valid(now));
    }
    for route in slaac.routes() {
        assert!(!route.is_valid(now));
    }

    slaac.update_slaac_state(now);
    assert!(!slaac.sync_required(now));
    assert_eq!(slaac.routes().len(), 0);

    // Skip time until the prefix expires
    let poll_at = slaac.poll_at(now).unwrap();
    let now = poll_at;
    assert!(slaac.sync_required(now));
    for (_prefix, info) in slaac.prefix() {
        assert!(!info.is_valid(now));
    }
    // Should already return None
    assert!(slaac.poll_at(now).is_none());
    slaac.update_slaac_state(now);
    assert!(!slaac.sync_required(now));
    assert_eq!(slaac.routes().len(), 0);
    assert_eq!(slaac.prefix().len(), 0);

    // No state remaining, nothing to wait on
    assert!(slaac.poll_at(now).is_none());
}

#[test]
fn test_ra_expire() {
    let mut slaac = Slaac::new();
    let now = Instant::from_millis(1);
    slaac.rs_sent(now);
    slaac.process_advertisement(&SOURCE, VALID, Some(PREFIX), now);

    let now = Instant::from_secs(300);

    assert!(slaac.sync_required(now));
    for (_prefix, info) in slaac.prefix() {
        assert!(info.is_valid(now));
    }
    for route in slaac.routes() {
        assert!(route.is_valid(now));
    }
    slaac.update_slaac_state(now);

    let mut expire_prefix = PREFIX;
    expire_prefix.preferred_lifetime = Duration::ZERO;
    expire_prefix.valid_lifetime = Duration::ZERO;

    // Invalidate the prefix, but not the route
    slaac.process_advertisement(&SOURCE, VALID, Some(expire_prefix), now);

    assert!(slaac.sync_required(now));
    for (_prefix, info) in slaac.prefix() {
        assert!(!info.is_valid(now));
    }
    for route in slaac.routes() {
        assert!(route.is_valid(now));
    }
    slaac.update_slaac_state(now);
    assert_eq!(slaac.prefix().len(), 0);
    assert_eq!(slaac.routes().len(), 1);

    assert!(!slaac.sync_required(now));
    // Invalidate also the route
    slaac.process_advertisement(&SOURCE, Duration::ZERO, Some(expire_prefix), now);
    assert!(slaac.sync_required(now));
    for route in slaac.routes() {
        assert!(!route.is_valid(now));
    }
    assert!(slaac.poll_at(now).is_none());

    slaac.update_slaac_state(now);
    assert_eq!(slaac.prefix().len(), 0);
    assert_eq!(slaac.routes().len(), 0);
    assert!(!slaac.sync_required(now));
    // No state remaining, nothing to wait on
    assert!(slaac.poll_at(now).is_none());
}
