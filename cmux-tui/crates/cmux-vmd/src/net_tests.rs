use super::*;

#[test]
fn slot_addresses_are_unique_per_slot() {
    let s = Slot { n: 0 };
    assert_eq!((s.host_ip(), s.ns_ip()), ("10.201.0.1".into(), "10.201.0.2".into()));
    let s = Slot { n: 64 };
    assert_eq!((s.host_ip(), s.ns_ip()), ("10.201.1.1".into(), "10.201.1.2".into()));
    let s = Slot { n: MAX_SLOT };
    assert_eq!(s.ns_ip(), "10.201.255.254");
    assert_eq!(s.host_ip6(), "fd01:cafe:3fff::1");
    assert!(s.host_if().len() <= 15);
}

#[test]
fn allow_rules_split_families_and_refuse_injection() {
    let rules =
        egress_rules(&Egress::Allow { cidrs: vec!["1.2.3.0/24".into(), "2001:db8::/32".into()] })
            .unwrap();
    assert!(rules.contains("ip daddr { 1.2.3.0/24 } accept"), "{rules}");
    assert!(rules.contains("ip6 daddr { 2001:db8::/32 } accept"), "{rules}");
    assert!(rules.ends_with("drop"));
    assert!(Egress::Allow { cidrs: vec!["1.2.3.4; flush ruleset".into()] }.validate().is_err());
    assert!(Egress::Allow { cidrs: vec!["1.2.3.4/33".into()] }.validate().is_err());
}

#[test]
fn internet_blocks_v6_ranges_that_reach_private_v4() {
    let rules = egress_rules(&Egress::Internet).unwrap();
    let v6 = rules.lines().find(|l| l.contains("ip6 daddr")).unwrap_or_default();
    // Loopback and unspecified (in ::/96), mapped, NAT64, Teredo, 6to4, ULA, link-local, multicast.
    for prefix in [
        "::/96",
        "::ffff:0:0/96",
        "64:ff9b::/96",
        "64:ff9b:1::/48",
        "2001::/32",
        "2002::/16",
        "fc00::/7",
        "fe80::/10",
        "ff00::/8",
    ] {
        assert!(v6.contains(prefix), "{prefix} missing from {v6}");
    }
    assert!(v6.trim_end().ends_with("drop"), "{v6}");
    assert!(rules.ends_with("accept"), "{rules}");
}

#[test]
fn default_egress_is_none() {
    assert_eq!(Egress::default(), Egress::None);
    assert_eq!(egress_rules(&Egress::None).unwrap(), "drop");
}
