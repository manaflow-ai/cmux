//! Private network announce (vm-image.md 6.4): a gratuitous ARP from each
//! global IPv4 address, once at bind and once per resume signal. No
//! periodic loop. The same address filter as `announce_network` in
//! cmux-devbox-boot (`devboxNetworkAnnounceCommand()`).

use std::net::Ipv4Addr;

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
}
