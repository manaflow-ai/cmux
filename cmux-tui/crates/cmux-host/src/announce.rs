//! Private network announce (vm-image.md 6.4): a gratuitous ARP from each
//! global IPv4 address, once at bind and once per resume signal. No
//! periodic loop. The same address filter as `announce_network` in
//! cmux-devbox-boot (`devboxNetworkAnnounceCommand()`).

use std::net::{IpAddr, Ipv4Addr};

/// Interface prefixes that are never the machine's own network.
const SKIPPED_PREFIXES: [&str; 4] = ["docker", "veth", "br-", "virbr"];

/// `addr` on `ifname` is announced.
pub fn is_announce_target(ifname: &str, addr: Ipv4Addr) -> bool {
    !ifname.is_empty()
        && !ifname.starts_with('-')
        && ifname != "lo"
        && !SKIPPED_PREFIXES.iter().any(|prefix| ifname.starts_with(prefix))
        && !addr.is_loopback()
        && !addr.is_link_local()
        && !addr.is_unspecified()
        && !addr.is_multicast()
}

/// A global address of one of the machine's own interfaces: the set the
/// agent compares on each rtnetlink message, so only a real change wakes
/// it (IPv6 link-local and container bridges excluded).
pub fn is_global_address(ifname: &str, addr: IpAddr) -> bool {
    match addr {
        IpAddr::V4(v4) => is_announce_target(ifname, v4),
        IpAddr::V6(v6) => {
            is_announce_target(ifname, Ipv4Addr::new(10, 0, 0, 1))
                && !v6.is_loopback()
                && !v6.is_unspecified()
                && !v6.is_multicast()
                && !v6.is_unicast_link_local()
        }
    }
}

/// `arping -U -c 2 -w 2 -I <if> <addr>`: unsolicited ARP, two frames, at
/// most two seconds. Passed as argv, never through a shell.
pub fn arping_args(ifname: &str, addr: Ipv4Addr) -> Vec<String> {
    vec![
        "-U".to_owned(),
        "-c".to_owned(),
        "2".to_owned(),
        "-w".to_owned(),
        "2".to_owned(),
        "-I".to_owned(),
        ifname.to_owned(),
        addr.to_string(),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filter_matches_the_shell_announce() {
        let ip = Ipv4Addr::new(10, 0, 0, 5);
        assert!(is_announce_target("eth0", ip));
        assert!(is_announce_target("ens5", ip));
        for skipped in ["lo", "docker0", "veth12", "br-abc", "virbr0", "-x", ""] {
            assert!(!is_announce_target(skipped, ip), "{skipped}");
        }
        assert!(!is_announce_target("eth0", Ipv4Addr::new(169, 254, 1, 1)));
        assert!(!is_announce_target("eth0", Ipv4Addr::LOCALHOST));
        assert_eq!(arping_args("eth0", ip).join(" "), "-U -c 2 -w 2 -I eth0 10.0.0.5");
    }

    #[test]
    fn global_addresses_exclude_link_local_and_bridges() {
        let v6 = |s: &str| IpAddr::V6(s.parse().unwrap());
        assert!(is_global_address("eth0", v6("2001:db8::5")));
        assert!(is_global_address("eth0", v6("fd00::5")));
        assert!(!is_global_address("eth0", v6("fe80::1")));
        assert!(!is_global_address("veth0", v6("2001:db8::5")));
        assert!(!is_global_address("lo", v6("::1")));
        assert!(is_global_address("eth0", IpAddr::V4(Ipv4Addr::new(10, 1, 2, 3))));
    }
}
