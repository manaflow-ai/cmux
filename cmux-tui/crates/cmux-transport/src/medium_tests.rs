use super::*;

fn net(interface: &str, address: &str, prefix: u8) -> LocalNetwork {
    LocalNetwork { interface: interface.into(), address: address.parse().unwrap(), prefix }
}

/// A Mac Studio's table: wired en0 and Wi-Fi en1 on the office LAN, a
/// Thunderbolt Bridge to a second Studio on bridge0, and a tailnet utun.
fn studio() -> Vec<LocalNetwork> {
    vec![
        net("lo0", "127.0.0.1", 8),
        net("en0", "172.20.22.22", 22),
        net("en1", "172.20.22.23", 22),
        net("bridge0", "10.254.2.1", 30),
        net("utun4", "100.103.118.14", 32),
        net("en0", "fe80::1", 64),
    ]
}

fn medium(remote: &str) -> Medium {
    medium_of(remote.parse().unwrap(), &studio())
}

#[test]
fn the_thunderbolt_bridge_is_a_link() {
    assert_eq!(medium("10.254.2.2"), Medium::Link);
    assert_eq!(medium("::ffff:10.254.2.2"), Medium::Link, "mapped addresses unmap");
}

#[test]
fn an_on_link_office_address_is_lan() {
    assert_eq!(medium("172.20.22.26"), Medium::Lan);
    assert_eq!(medium("fe80::2"), Medium::Lan);
}

#[test]
fn tailnet_and_off_link_addresses_are_routed() {
    assert_eq!(medium("100.87.226.47"), Medium::Routed, "tailnet overlay");
    assert_eq!(medium("fd7a:115c:a1e0::1"), Medium::Routed);
    assert_eq!(medium("8.8.8.8"), Medium::Routed, "no on-link interface");
    assert_eq!(medium("10.254.3.2"), Medium::Routed, "outside the bridge's /30");
}

#[test]
fn loopback_is_a_link() {
    assert_eq!(medium("127.0.0.1"), Medium::Link);
    assert_eq!(medium("::1"), Medium::Link);
}

#[test]
fn the_longest_prefix_decides() {
    let networks = vec![net("en0", "10.0.0.5", 8), net("bridge0", "10.254.2.1", 30)];
    assert_eq!(medium_of("10.254.2.2".parse().unwrap(), &networks), Medium::Link);
    assert_eq!(medium_of("10.1.2.3".parse().unwrap(), &networks), Medium::Lan);
}

#[test]
fn a_private_address_behind_a_vpn_interface_is_routed() {
    let networks = vec![net("utun3", "10.8.0.2", 24)];
    assert_eq!(medium_of("10.8.0.9".parse().unwrap(), &networks), Medium::Routed);
}

#[test]
fn a_tie_on_the_longest_prefix_takes_the_slowest_medium_in_any_order() {
    // A VPN that claims the office /22 next to en0, and a Thunderbolt
    // bridge that shares a subnet with Wi-Fi: getifaddrs order must not
    // decide, and the faster claim is never trusted on a tie.
    let vpn = [net("en0", "172.20.22.22", 22), net("utun3", "172.20.22.200", 22)];
    let bridged = [net("bridge0", "192.168.2.1", 24), net("en1", "192.168.2.7", 24)];
    for (table, remote, want) in
        [(&vpn, "172.20.22.26", Medium::Routed), (&bridged, "192.168.2.9", Medium::Lan)]
    {
        let mut reversed = table.to_vec();
        reversed.reverse();
        let remote = remote.parse().unwrap();
        assert_eq!(medium_of(remote, table), want);
        assert_eq!(medium_of(remote, &reversed), want, "order-independent");
    }
    // Two addresses of one class still read as that class.
    let wired_and_wifi = [net("en0", "172.20.22.22", 22), net("en1", "172.20.22.23", 22)];
    assert_eq!(medium_of("172.20.22.26".parse().unwrap(), &wired_and_wifi), Medium::Lan);
    // A longer prefix still beats the tie rule.
    let narrower = [net("utun3", "10.0.0.2", 8), net("bridge0", "10.254.2.1", 30)];
    assert_eq!(medium_of("10.254.2.2".parse().unwrap(), &narrower), Medium::Link);
}

#[test]
fn the_order_is_the_rank() {
    assert!(Medium::Link < Medium::Lan && Medium::Lan < Medium::Routed);
}
