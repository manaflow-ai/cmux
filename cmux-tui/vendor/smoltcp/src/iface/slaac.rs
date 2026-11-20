#![deny(missing_docs)]
use heapless::{LinearMap, Vec};

use crate::config::{IFACE_MAX_PREFIX_COUNT, IFACE_MAX_ROUTE_COUNT};
use crate::time::{Duration, Instant};
use crate::wire::NdiscPrefixInfoFlags;
use crate::wire::{Ipv6Address, Ipv6Cidr, NdiscPrefixInformation, ipv6::AddressExt};

const MAX_RTR_SOLICITATIONS: u8 = 3;
const RTR_SOLICITATION_INTERVAL: Duration = Duration::from_secs(4);
const IPV6_DEFAULT: Ipv6Cidr = Ipv6Cidr::new(Ipv6Address::UNSPECIFIED, 0);

/// Router solicitation state machine
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Phase {
    Start,
    Discovering,
    Maintaining,
    None,
}

/// A prefix of addresses received via router advertisements
#[derive(Debug, Clone, Copy)]
pub(crate) struct Route {
    /// IPv6 cidr to route
    pub cidr: Ipv6Cidr,
    /// Router, origin of the advertisement
    pub via_router: Ipv6Address,
    /// Valid lifetime of the route
    pub valid_until: Instant,
}

/// Info associated with a prefix
#[derive(Debug, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct PrefixInfo {
    preferred_until: Instant,
    valid_until: Instant,
}

impl PrefixInfo {
    fn new(preferred_until: Instant, valid_until: Instant) -> Self {
        Self {
            preferred_until,
            valid_until,
        }
    }

    /// Derive the prefix information from the neighbor discovery option.
    pub(crate) fn from_prefix(prefix: &NdiscPrefixInformation, now: Instant) -> Self {
        let preferred_until = now + prefix.preferred_lifetime;
        let valid_until = now + prefix.valid_lifetime;

        Self::new(preferred_until, valid_until)
    }

    /// Get whether the prefix is still valid.
    pub(crate) fn is_valid(&self, now: Instant) -> bool {
        self.valid_until > now
    }
}

impl Route {
    /// Compare this route based on the prefix and the next hop router.
    pub fn same_route(&self, cidr: &Ipv6Cidr, via_router: &Ipv6Address) -> bool {
        self.cidr == *cidr && self.via_router == *via_router
    }

    /// Get whether the route is still valid.
    pub fn is_valid(&self, now: Instant) -> bool {
        self.valid_until > now
    }
}

/// SLAAC runtime state
///
/// Tracks router solicitations and collects information from all received
/// router advertisements.
///
/// State must be synchronized with the IP addresses and routes in the `Interface`.
#[derive(Debug)]
pub struct Slaac {
    /// Set of prefixes received.
    prefix: LinearMap<Ipv6Cidr, PrefixInfo, IFACE_MAX_PREFIX_COUNT>,
    /// Set of routes received.
    routes: Vec<Route, IFACE_MAX_ROUTE_COUNT>,
    /// Router discovery phase.
    phase: Phase,
    /// Signal for address and route updates.
    sync_required: bool,
    /// Time to next router solicitation.
    retry_rs_at: Instant,
    /// Number of solicitations emitted.
    num_solicitations: u8,
}

impl Slaac {
    pub(super) fn new() -> Self {
        Self {
            prefix: LinearMap::new(),
            routes: Vec::new(),
            phase: Phase::Start,
            sync_required: false,
            retry_rs_at: Instant::from_millis(0),
            num_solicitations: MAX_RTR_SOLICITATIONS,
        }
    }

    /// Get whether router advertisement information is updated.
    ///
    /// This flags whether new prefixes or routes have been received, or current prefixes and
    /// routes have expired.
    pub(crate) fn has_ra_update(&self) -> bool {
        self.sync_required
    }

    /// Get a reference to the map of prefixes stored.
    pub(crate) fn prefix(&self) -> &LinearMap<Ipv6Cidr, PrefixInfo, IFACE_MAX_PREFIX_COUNT> {
        &self.prefix
    }

    /// Get a reference to the set of routes stored.
    pub(crate) fn routes(&self) -> &Vec<Route, IFACE_MAX_ROUTE_COUNT> {
        &self.routes
    }

    fn add_prefix(&mut self, cidr: &Ipv6Cidr, prefix: &NdiscPrefixInformation, now: Instant) {
        if cidr.address().is_link_local() {
            return;
        }
        let prefix_info = PrefixInfo::from_prefix(prefix, now);
        if let Ok(old_info) = self.prefix.insert(*cidr, prefix_info)
            && old_info.is_none()
        {
            self.sync_required = true;
        }
    }

    fn expire_prefix(&mut self, cidr: &Ipv6Cidr) {
        if let Some(info) = self.prefix.get_mut(cidr) {
            info.valid_until = Instant::from_millis(0);
            info.preferred_until = Instant::from_millis(0);
            self.sync_required = true;
        }
    }

    fn add_route(&mut self, cidr: &Ipv6Cidr, router: &Ipv6Address, valid_until: Instant) {
        if let Some(route) = self.routes.iter_mut().find(|r| r.same_route(cidr, router)) {
            route.valid_until = valid_until;
        } else {
            let _ = self.routes.push(Route {
                cidr: *cidr,
                via_router: *router,
                valid_until,
            });
            self.sync_required = true;
        }
    }

    fn expire_route(&mut self, cidr: &Ipv6Cidr, via_router: &Ipv6Address) {
        for route in self.routes.iter_mut() {
            if route.same_route(cidr, via_router) {
                route.valid_until = Instant::from_millis(0);
                self.sync_required = true;
            }
        }
    }

    fn process_prefix(&mut self, prefix: NdiscPrefixInformation, now: Instant) {
        if !prefix.flags.contains(NdiscPrefixInfoFlags::ADDRCONF) {
            return;
        }

        let cidr = Ipv6Cidr::new(prefix.prefix, prefix.prefix_len);

        if prefix.valid_lifetime > Duration::ZERO {
            self.add_prefix(&cidr, &prefix, now);
        } else {
            self.expire_prefix(&cidr);
        }
    }

    /// Process a router advertisement's information.
    pub(super) fn process_advertisement(
        &mut self,
        source: &Ipv6Address,
        router_lifetime: Duration,              // default route lifetime
        prefix: Option<NdiscPrefixInformation>, // prefix info
        now: Instant,
    ) {
        if let Some(prefix) = prefix
            && prefix.is_valid_prefix_info()
        {
            self.process_prefix(prefix, now)
        }

        if router_lifetime > Duration::ZERO {
            self.add_route(&IPV6_DEFAULT, source, now + router_lifetime);
        } else {
            self.expire_route(&IPV6_DEFAULT, source);
        }

        // Advertisement might be unsolicited
        if self.phase == Phase::Discovering {
            self.phase = Phase::Maintaining;
        }
    }

    fn prefix_expire_sync_required(&self, now: Instant) -> bool {
        self.prefix.values().any(|info| !info.is_valid(now))
    }

    fn route_expire_sync_required(&self, now: Instant) -> bool {
        self.routes.iter().any(|r| !r.is_valid(now))
    }

    /// Get whether a route and prefix information must be synchronized with the interface.
    pub(crate) fn sync_required(&self, now: Instant) -> bool {
        self.has_ra_update()
            || self.prefix_expire_sync_required(now)
            || self.route_expire_sync_required(now)
    }

    /// Remove expired routes and prefixes.
    pub(crate) fn update_slaac_state(&mut self, now: Instant) {
        let removals: Vec<Ipv6Cidr, IFACE_MAX_PREFIX_COUNT> = self
            .prefix
            .iter()
            .filter_map(|(cidr, info)| {
                if info.is_valid(now) {
                    None
                } else {
                    Some(*cidr)
                }
            })
            .collect();
        for cidr in removals.iter() {
            self.prefix.remove(cidr);
        }
        self.routes.retain(|r| r.is_valid(now));
        self.sync_required = false;
    }

    /// Get whether a router solicitation must be emitted.
    pub(crate) fn rs_required(&self, now: Instant) -> bool {
        match self.phase {
            Phase::Start | Phase::Discovering
                if self.retry_rs_at <= now && self.num_solicitations > 0 =>
            {
                true
            }
            _ => false,
        }
    }

    /// Update router solicitation tracking state
    ///
    /// Must be called after sending a router solicitation on the interface.
    pub(crate) fn rs_sent(&mut self, now: Instant) {
        match self.phase {
            Phase::Start | Phase::Discovering if self.retry_rs_at <= now => {
                if self.num_solicitations == 0 {
                    self.phase = Phase::None;
                } else {
                    self.num_solicitations -= 1;
                    self.phase = Phase::Discovering;
                    self.retry_rs_at = now + RTR_SOLICITATION_INTERVAL;
                }
            }
            _ => (),
        }
    }

    /// Get the next time the SLAAC state must be polled for updates.
    pub(crate) fn poll_at(&self, now: Instant) -> Option<Instant> {
        match self.phase {
            Phase::Discovering | Phase::Start => Some(self.retry_rs_at),
            Phase::Maintaining => {
                let prefix_at = self.prefix.values().filter_map(|prefix_info| {
                    if prefix_info.is_valid(now) {
                        Some(prefix_info.valid_until)
                    } else {
                        None
                    }
                });
                let routes_at = self.routes.iter().filter_map(|r| {
                    if r.is_valid(now) {
                        Some(r.valid_until)
                    } else {
                        None
                    }
                });
                prefix_at.chain(routes_at).min()
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod test {
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
}
