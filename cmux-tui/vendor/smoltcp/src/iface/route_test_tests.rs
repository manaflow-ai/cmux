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
