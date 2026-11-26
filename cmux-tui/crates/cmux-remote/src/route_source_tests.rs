use super::*;

#[test]
fn loopback_source_is_loopback_and_never_gone() {
    let source = source_toward(Ipv4Addr::LOCALHOST.into()).unwrap();
    assert_eq!(source, IpAddr::from(Ipv4Addr::LOCALHOST));
    assert!(!address_is_gone(source));
}

#[test]
fn an_address_no_interface_has_is_gone() {
    // TEST-NET-1 (RFC 5737) is never assigned to a host interface.
    assert!(address_is_gone(IpAddr::from(Ipv4Addr::new(192, 0, 2, 77))));
}

#[tokio::test]
async fn resolves_literals_without_the_resolver() {
    assert_eq!(resolve_host("10.1.2.3").await, Some(IpAddr::from(Ipv4Addr::new(10, 1, 2, 3))));
    assert_eq!(resolve_host("[::1]").await, Some(IpAddr::from(Ipv6Addr::LOCALHOST)));
}
