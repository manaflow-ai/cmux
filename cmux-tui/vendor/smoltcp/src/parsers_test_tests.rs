use super::*;

macro_rules! check_cidr_test_array {
    ($tests:expr, $from_str:path, $variant:path) => {
        for &(s, cidr) in &$tests {
            assert_eq!($from_str(s), cidr);
            assert_eq!(IpCidr::from_str(s), cidr.map($variant));

            if let Ok(cidr) = cidr {
                assert_eq!($from_str(&format!("{}", cidr)), Ok(cidr));
                assert_eq!(IpCidr::from_str(&format!("{}", cidr)), Ok($variant(cidr)));
            }
        }
    };
}

#[test]
#[cfg(all(feature = "proto-ipv4", feature = "medium-ethernet"))]
fn test_mac() {
    assert_eq!(EthernetAddress::from_str(""), Err(()));
    assert_eq!(
        EthernetAddress::from_str("02:00:00:00:00:00"),
        Ok(EthernetAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x00]))
    );
    assert_eq!(
        EthernetAddress::from_str("01:23:45:67:89:ab"),
        Ok(EthernetAddress([0x01, 0x23, 0x45, 0x67, 0x89, 0xab]))
    );
    assert_eq!(
        EthernetAddress::from_str("cd:ef:10:00:00:00"),
        Ok(EthernetAddress([0xcd, 0xef, 0x10, 0x00, 0x00, 0x00]))
    );
    assert_eq!(
        EthernetAddress::from_str("00:00:00:ab:cd:ef"),
        Ok(EthernetAddress([0x00, 0x00, 0x00, 0xab, 0xcd, 0xef]))
    );
    assert_eq!(
        EthernetAddress::from_str("00-00-00-ab-cd-ef"),
        Ok(EthernetAddress([0x00, 0x00, 0x00, 0xab, 0xcd, 0xef]))
    );
    assert_eq!(
        EthernetAddress::from_str("AB-CD-EF-00-00-00"),
        Ok(EthernetAddress([0xab, 0xcd, 0xef, 0x00, 0x00, 0x00]))
    );
    assert_eq!(EthernetAddress::from_str("100:00:00:00:00:00"), Err(()));
    assert_eq!(EthernetAddress::from_str("002:00:00:00:00:00"), Err(()));
    assert_eq!(EthernetAddress::from_str("02:00:00:00:00:000"), Err(()));
    assert_eq!(EthernetAddress::from_str("02:00:00:00:00:0x"), Err(()));
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_ip_ipv4() {
    assert_eq!(IpAddress::from_str(""), Err(()));
    assert_eq!(
        IpAddress::from_str("1.2.3.4"),
        Ok(IpAddress::Ipv4(Ipv4Address::new(1, 2, 3, 4)))
    );
    assert_eq!(IpAddress::from_str("x"), Err(()));
}

#[test]
#[cfg(feature = "proto-ipv6")]
fn test_ip_ipv6() {
    assert_eq!(IpAddress::from_str(""), Err(()));
    assert_eq!(
        IpAddress::from_str("fe80::1"),
        Ok(IpAddress::Ipv6(Ipv6Address::new(
            0xfe80, 0, 0, 0, 0, 0, 0, 1
        )))
    );
    assert_eq!(IpAddress::from_str("x"), Err(()));
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_cidr_ipv4() {
    let tests = [
        (
            "127.0.0.1/8",
            Ok(Ipv4Cidr::new(Ipv4Address::new(127, 0, 0, 1), 8u8)),
        ),
        (
            "192.168.1.1/24",
            Ok(Ipv4Cidr::new(Ipv4Address::new(192, 168, 1, 1), 24u8)),
        ),
        (
            "8.8.8.8/32",
            Ok(Ipv4Cidr::new(Ipv4Address::new(8, 8, 8, 8), 32u8)),
        ),
        (
            "8.8.8.8/0",
            Ok(Ipv4Cidr::new(Ipv4Address::new(8, 8, 8, 8), 0u8)),
        ),
        ("", Err(())),
        ("1", Err(())),
        ("127.0.0.1", Err(())),
        ("127.0.0.1/", Err(())),
        ("127.0.0.1/33", Err(())),
        ("127.0.0.1/111", Err(())),
        ("/32", Err(())),
    ];

    check_cidr_test_array!(tests, Ipv4Cidr::from_str, IpCidr::Ipv4);
}

#[test]
#[cfg(feature = "proto-ipv6")]
fn test_cidr_ipv6() {
    let tests = [
        (
            "fe80::1/64",
            Ok(Ipv6Cidr::new(
                Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
                64u8,
            )),
        ),
        (
            "fe80::/64",
            Ok(Ipv6Cidr::new(
                Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 0),
                64u8,
            )),
        ),
        ("::1/128", Ok(Ipv6Cidr::new(Ipv6Address::LOCALHOST, 128u8))),
        ("::/128", Ok(Ipv6Cidr::new(Ipv6Address::UNSPECIFIED, 128u8))),
        (
            "fe80:0:0:0:0:0:0:1/64",
            Ok(Ipv6Cidr::new(
                Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
                64u8,
            )),
        ),
        ("fe80:0:0:0:0:0:0:1|64", Err(())),
        ("fe80::|64", Err(())),
        ("fe80::1::/64", Err(())),
    ];
    check_cidr_test_array!(tests, Ipv6Cidr::from_str, IpCidr::Ipv6);
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_endpoint_ipv4() {
    assert_eq!(IpEndpoint::from_str(""), Err(()));
    assert_eq!(IpEndpoint::from_str("x"), Err(()));
    assert_eq!(
        IpEndpoint::from_str("127.0.0.1"),
        Ok(IpEndpoint {
            addr: IpAddress::v4(127, 0, 0, 1),
            port: 0
        })
    );
    assert_eq!(
        IpEndpoint::from_str("127.0.0.1:12345"),
        Ok(IpEndpoint {
            addr: IpAddress::v4(127, 0, 0, 1),
            port: 12345
        })
    );
}

#[test]
#[cfg(feature = "proto-ipv6")]
fn test_endpoint_ipv6() {
    assert_eq!(IpEndpoint::from_str(""), Err(()));
    assert_eq!(IpEndpoint::from_str("x"), Err(()));
    assert_eq!(
        IpEndpoint::from_str("fe80::1"),
        Ok(IpEndpoint {
            addr: IpAddress::v6(0xfe80, 0, 0, 0, 0, 0, 0, 1),
            port: 0
        })
    );
    assert_eq!(
        IpEndpoint::from_str("[fe80::1]:12345"),
        Ok(IpEndpoint {
            addr: IpAddress::v6(0xfe80, 0, 0, 0, 0, 0, 0, 1),
            port: 12345
        })
    );
    assert_eq!(
        IpEndpoint::from_str("[::]:12345"),
        Ok(IpEndpoint {
            addr: IpAddress::v6(0, 0, 0, 0, 0, 0, 0, 0),
            port: 12345
        })
    );
}
