//! The wg-quick file a WireGuard control plane hands out
//! (`WgConfig::parse_wg_quick`). A config that parses has a private key, one
//! or two addresses, a peer key and allowed networks, at most one peer
//! address per family, and every route lookup on it answers without a panic.
#![no_main]

use std::net::IpAddr;

use cmux_wg::WgConfig;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else { return };
    let Ok(config) = WgConfig::parse_wg_quick(text) else { return };
    assert!(matches!(config.addresses.len(), 1 | 2));
    assert!(!config.allowed_ips.is_empty());
    assert!(config.mtu >= 576);
    assert!(config.persistent_keepalive.is_none_or(|seconds| seconds > 0));
    let v4 = config.peer_addresses.iter().filter(|address| address.is_ipv4()).count();
    assert!(v4 <= 1 && config.peer_addresses.len() - v4 <= 1);
    let probes: Vec<IpAddr> = config
        .addresses
        .iter()
        .map(|entry| entry.address)
        .chain(config.peer_addresses.iter().copied())
        .chain(config.allowed_ips.iter().map(|network| network.network_address()))
        .collect();
    for address in probes {
        let _ = config.routes_contain(address);
        let _ = config.peer_address_for(address);
        let _ = config.local_address_for(address);
    }
    // Every allowed network contains its own base address.
    for network in &config.allowed_ips {
        assert!(config.routes_contain(network.network_address()));
    }
});
