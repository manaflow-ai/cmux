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
