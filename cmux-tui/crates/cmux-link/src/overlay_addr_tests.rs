use super::*;

#[test]
fn overlay_addresses_are_stable_and_inside_the_prefix() {
    let address = overlay_address("inst_1");
    assert_eq!(address, overlay_address("inst_1"));
    assert_ne!(address, overlay_address("inst_2"));
    assert_eq!(&address.octets()[..4], &PREFIX);
}

/// The reference values shared with backend/packages/protocol/src/overlay.ts.
#[test]
fn overlay_addresses_match_the_backend_reference_values() {
    assert_eq!(
        overlay_address("inst_1"),
        "fd7c:6d78:f4a0:cf32:b1d:3887:6548:15e5".parse::<Ipv6Addr>().unwrap()
    );
    assert_eq!(
        overlay_address("host_0123456789abcdef0123"),
        "fd7c:6d78:f88f:f2d3:66e:5b72:7958:91e2".parse::<Ipv6Addr>().unwrap()
    );
}
