use super::*;

fn v6(text: &str) -> Ipv6Addr {
    text.parse().unwrap()
}

#[test]
fn the_same_network_reads_the_same_and_another_reads_differently() {
    let home = Fingerprint::of(Some(Ipv4Addr::new(192, 168, 1, 23)), None).unwrap();
    assert_eq!(home, Fingerprint::of(Some(Ipv4Addr::new(192, 168, 1, 23)), None).unwrap());
    let office = Fingerprint::of(Some(Ipv4Addr::new(10, 0, 4, 7)), None).unwrap();
    assert_ne!(home, office);
    // The value is kept on disk: it must not change between builds.
    assert_eq!(home.to_hex(), "968c245c868e138e");
    assert_eq!(
        home.to_hex(),
        Fingerprint::of(Some(Ipv4Addr::new(192, 168, 1, 23)), None).unwrap().to_string()
    );
}

#[test]
fn an_ipv6_privacy_address_rotating_in_its_prefix_keeps_the_network() {
    let v4 = Some(Ipv4Addr::new(192, 168, 1, 23));
    let before = Fingerprint::of(v4, Some(v6("2001:db8:1:2:aaaa:bbbb:cccc:dddd"))).unwrap();
    let after = Fingerprint::of(v4, Some(v6("2001:db8:1:2:1111:2222:3333:4444"))).unwrap();
    assert_eq!(before, after);
    let other = Fingerprint::of(v4, Some(v6("2001:db8:9:2:1111:2222:3333:4444"))).unwrap();
    assert_ne!(before, other);
    // A v4-only and a dual-stack view of one LAN differ: the v6 route is part of the network.
    assert_ne!(before, Fingerprint::of(v4, None).unwrap());
}

#[test]
fn no_usable_source_is_no_fingerprint() {
    assert_eq!(Fingerprint::of(None, None), None);
    assert_eq!(Fingerprint::of(Some(Ipv4Addr::LOCALHOST), Some(Ipv6Addr::LOCALHOST)), None);
    assert_eq!(Fingerprint::of(Some(Ipv4Addr::UNSPECIFIED), Some(Ipv6Addr::UNSPECIFIED)), None);
}

#[test]
fn current_reads_fast_and_twice_the_same() {
    let started = std::time::Instant::now();
    let first = Fingerprint::current();
    let second = Fingerprint::current();
    let took = started.elapsed();
    assert_eq!(first, second);
    // Two routing-table lookups per read; nothing touches the network.
    assert!(took < std::time::Duration::from_millis(50), "two reads took {took:?}");
}
