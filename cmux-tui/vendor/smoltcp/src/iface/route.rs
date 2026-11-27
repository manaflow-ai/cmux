use heapless::Vec;

use crate::config::IFACE_MAX_ROUTE_COUNT;
use crate::time::Instant;
use crate::wire::{IpAddress, IpCidr};
#[cfg(feature = "proto-ipv4")]
use crate::wire::{Ipv4Address, Ipv4Cidr};
#[cfg(feature = "proto-ipv6")]
use crate::wire::{Ipv6Address, Ipv6Cidr};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct RouteTableFull;

impl core::fmt::Display for RouteTableFull {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "Route table full")
    }
}

impl core::error::Error for RouteTableFull {}

/// A prefix of addresses that should be routed via a router
#[derive(Debug, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Route {
    pub cidr: IpCidr,
    pub via_router: IpAddress,
    /// `None` means "forever".
    pub preferred_until: Option<Instant>,
    /// `None` means "forever".
    pub expires_at: Option<Instant>,
}

#[cfg(feature = "proto-ipv4")]
const IPV4_DEFAULT: IpCidr = IpCidr::Ipv4(Ipv4Cidr::new(Ipv4Address::new(0, 0, 0, 0), 0));
#[cfg(feature = "proto-ipv6")]
const IPV6_DEFAULT: IpCidr =
    IpCidr::Ipv6(Ipv6Cidr::new(Ipv6Address::new(0, 0, 0, 0, 0, 0, 0, 0), 0));

impl Route {
    /// Returns a route to 0.0.0.0/0 via the `gateway`, with no expiry.
    #[cfg(feature = "proto-ipv4")]
    pub fn new_ipv4_gateway(gateway: Ipv4Address) -> Route {
        Route {
            cidr: IPV4_DEFAULT,
            via_router: gateway.into(),
            preferred_until: None,
            expires_at: None,
        }
    }

    /// Returns a route to ::/0 via the `gateway`, with no expiry.
    #[cfg(feature = "proto-ipv6")]
    pub fn new_ipv6_gateway(gateway: Ipv6Address) -> Route {
        Route {
            cidr: IPV6_DEFAULT,
            via_router: gateway.into(),
            preferred_until: None,
            expires_at: None,
        }
    }

    /// Returns `true` if the route is a default route for IPv6.
    #[cfg(feature = "proto-ipv6")]
    pub fn is_ipv6_gateway(&self) -> bool {
        self.cidr == IPV6_DEFAULT
    }

    /// Returns `true` if the route is a default route for IPv4.
    #[cfg(feature = "proto-ipv4")]
    pub fn is_ipv4_gateway(&self) -> bool {
        self.cidr == IPV4_DEFAULT
    }
}

/// A routing table.
#[derive(Debug)]
pub struct Routes {
    storage: Vec<Route, IFACE_MAX_ROUTE_COUNT>,
}

impl Routes {
    /// Creates a new empty routing table.
    pub fn new() -> Self {
        Self {
            storage: Vec::new(),
        }
    }

    /// Update the routes of this node.
    pub fn update<F: FnOnce(&mut Vec<Route, IFACE_MAX_ROUTE_COUNT>)>(&mut self, f: F) {
        f(&mut self.storage);
    }

    /// Add a default ipv4 gateway (ie. "ip route add 0.0.0.0/0 via `gateway`").
    ///
    /// On success, returns the previous default route, if any.
    #[cfg(feature = "proto-ipv4")]
    pub fn add_default_ipv4_route(
        &mut self,
        gateway: Ipv4Address,
    ) -> Result<Option<Route>, RouteTableFull> {
        let old = self.remove_default_ipv4_route();
        self.storage
            .push(Route::new_ipv4_gateway(gateway))
            .map_err(|_| RouteTableFull)?;
        Ok(old)
    }

    /// Add a default ipv6 gateway (ie. "ip -6 route add ::/0 via `gateway`").
    ///
    /// On success, returns the previous default route, if any.
    #[cfg(feature = "proto-ipv6")]
    pub fn add_default_ipv6_route(
        &mut self,
        gateway: Ipv6Address,
    ) -> Result<Option<Route>, RouteTableFull> {
        let old = self.remove_default_ipv6_route();
        self.storage
            .push(Route::new_ipv6_gateway(gateway))
            .map_err(|_| RouteTableFull)?;
        Ok(old)
    }

    /// Returns the ipv4 default route if there is one in the route table.
    #[cfg(feature = "proto-ipv4")]
    pub fn get_default_ipv4_route(&self) -> Option<Route> {
        self.storage.iter().find(|r| r.is_ipv4_gateway()).copied()
    }

    /// Returns the ipv6 default route if there is one in the route table.
    #[cfg(feature = "proto-ipv6")]
    pub fn get_default_ipv6_route(&self) -> Option<Route> {
        self.storage.iter().find(|r| r.is_ipv6_gateway()).copied()
    }

    /// Remove the default ipv4 gateway
    ///
    /// On success, returns the previous default route, if any.
    #[cfg(feature = "proto-ipv4")]
    pub fn remove_default_ipv4_route(&mut self) -> Option<Route> {
        if let Some((i, _)) = self
            .storage
            .iter()
            .enumerate()
            .find(|(_, r)| r.is_ipv4_gateway())
        {
            Some(self.storage.remove(i))
        } else {
            None
        }
    }

    /// Remove the default ipv6 gateway
    ///
    /// On success, returns the previous default route, if any.
    #[cfg(feature = "proto-ipv6")]
    pub fn remove_default_ipv6_route(&mut self) -> Option<Route> {
        if let Some((i, _)) = self
            .storage
            .iter()
            .enumerate()
            .find(|(_, r)| r.is_ipv6_gateway())
        {
            Some(self.storage.remove(i))
        } else {
            None
        }
    }

    pub(crate) fn lookup(&self, addr: &IpAddress, timestamp: Instant) -> Option<IpAddress> {
        assert!(addr.is_unicast());

        self.storage
            .iter()
            // Keep only matching routes
            .filter(|route| {
                if let Some(expires_at) = route.expires_at
                    && timestamp > expires_at
                {
                    return false;
                }
                route.cidr.contains_addr(addr)
            })
            // pick the most specific one (highest prefix_len)
            .max_by_key(|route| route.cidr.prefix_len())
            .map(|route| route.via_router)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    #[cfg(feature = "proto-ipv6")]
    mod mock {
        use super::super::*;
        pub const ADDR_1A: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 2, 0, 0, 0, 1);
        pub const ADDR_1B: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 2, 0, 0, 0, 13);
        pub const ADDR_1C: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 2, 0, 0, 0, 42);
        pub fn cidr_1() -> Ipv6Cidr {
            Ipv6Cidr::new(Ipv6Address::new(0xfe80, 0, 0, 2, 0, 0, 0, 0), 64)
        }

        pub const ADDR_2A: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 0x3364, 0, 0, 0, 1);
        pub const ADDR_2B: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 0x3364, 0, 0, 0, 21);
        pub fn cidr_2() -> Ipv6Cidr {
            Ipv6Cidr::new(Ipv6Address::new(0xfe80, 0, 0, 0x3364, 0, 0, 0, 0), 64)
        }
    }

    #[cfg(all(feature = "proto-ipv4", not(feature = "proto-ipv6")))]
    mod mock {
        use super::super::*;
        pub const ADDR_1A: Ipv4Address = Ipv4Address::new(192, 0, 2, 1);
        pub const ADDR_1B: Ipv4Address = Ipv4Address::new(192, 0, 2, 13);
        pub const ADDR_1C: Ipv4Address = Ipv4Address::new(192, 0, 2, 42);
        pub fn cidr_1() -> Ipv4Cidr {
            Ipv4Cidr::new(Ipv4Address::new(192, 0, 2, 0), 24)
        }

        pub const ADDR_2A: Ipv4Address = Ipv4Address::new(198, 51, 100, 1);
        pub const ADDR_2B: Ipv4Address = Ipv4Address::new(198, 51, 100, 21);
        pub fn cidr_2() -> Ipv4Cidr {
            Ipv4Cidr::new(Ipv4Address::new(198, 51, 100, 0), 24)
        }
    }

    use self::mock::*;

    #[test]
    fn test_fill() {
        let mut routes = Routes::new();

        assert_eq!(
            routes.lookup(&ADDR_1A.into(), Instant::from_millis(0)),
            None
        );
        assert_eq!(
            routes.lookup(&ADDR_1B.into(), Instant::from_millis(0)),
            None
        );
        assert_eq!(
            routes.lookup(&ADDR_1C.into(), Instant::from_millis(0)),
            None
        );
        assert_eq!(
            routes.lookup(&ADDR_2A.into(), Instant::from_millis(0)),
            None
        );
        assert_eq!(
            routes.lookup(&ADDR_2B.into(), Instant::from_millis(0)),
            None
        );

        let route = Route {
            cidr: cidr_1().into(),
            via_router: ADDR_1A.into(),
            preferred_until: None,
            expires_at: None,
        };
        routes.update(|storage| {
            storage.push(route).unwrap();
        });

        assert_eq!(
            routes.lookup(&ADDR_1A.into(), Instant::from_millis(0)),
            Some(ADDR_1A.into())
        );
        assert_eq!(
            routes.lookup(&ADDR_1B.into(), Instant::from_millis(0)),
            Some(ADDR_1A.into())
        );
        assert_eq!(
            routes.lookup(&ADDR_1C.into(), Instant::from_millis(0)),
            Some(ADDR_1A.into())
        );
        assert_eq!(
            routes.lookup(&ADDR_2A.into(), Instant::from_millis(0)),
            None
        );
        assert_eq!(
            routes.lookup(&ADDR_2B.into(), Instant::from_millis(0)),
            None
        );

        let route2 = Route {
            cidr: cidr_2().into(),
            via_router: ADDR_2A.into(),
            preferred_until: Some(Instant::from_millis(10)),
            expires_at: Some(Instant::from_millis(10)),
        };
        routes.update(|storage| {
            storage.push(route2).unwrap();
        });

        assert_eq!(
            routes.lookup(&ADDR_1A.into(), Instant::from_millis(0)),
            Some(ADDR_1A.into())
        );
        assert_eq!(
            routes.lookup(&ADDR_1B.into(), Instant::from_millis(0)),
            Some(ADDR_1A.into())
        );
        assert_eq!(
            routes.lookup(&ADDR_1C.into(), Instant::from_millis(0)),
            Some(ADDR_1A.into())
        );
        assert_eq!(
            routes.lookup(&ADDR_2A.into(), Instant::from_millis(0)),
            Some(ADDR_2A.into())
        );
        assert_eq!(
            routes.lookup(&ADDR_2B.into(), Instant::from_millis(0)),
            Some(ADDR_2A.into())
        );

        assert_eq!(
            routes.lookup(&ADDR_1A.into(), Instant::from_millis(10)),
            Some(ADDR_1A.into())
        );
        assert_eq!(
            routes.lookup(&ADDR_1B.into(), Instant::from_millis(10)),
            Some(ADDR_1A.into())
        );
        assert_eq!(
            routes.lookup(&ADDR_1C.into(), Instant::from_millis(10)),
            Some(ADDR_1A.into())
        );
        assert_eq!(
            routes.lookup(&ADDR_2A.into(), Instant::from_millis(10)),
            Some(ADDR_2A.into())
        );
        assert_eq!(
            routes.lookup(&ADDR_2B.into(), Instant::from_millis(10)),
            Some(ADDR_2A.into())
        );
    }
}
