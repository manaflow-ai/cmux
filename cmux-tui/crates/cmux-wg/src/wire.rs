//! Conversions between std and smoltcp addresses, and packet peeking.

use std::net::{IpAddr, SocketAddr};

use smoltcp::wire::{IpAddress, IpEndpoint};

pub(crate) fn ip_address(address: IpAddr) -> IpAddress {
    match address {
        IpAddr::V4(address) => IpAddress::Ipv4(address),
        IpAddr::V6(address) => IpAddress::Ipv6(address),
    }
}

pub(crate) fn socket_addr(endpoint: IpEndpoint) -> SocketAddr {
    let address = match endpoint.addr {
        IpAddress::Ipv4(address) => IpAddr::V4(address),
        IpAddress::Ipv6(address) => IpAddr::V6(address),
    };
    SocketAddr::new(address, endpoint.port)
}

/// The source address of a raw IPv4 or IPv6 packet, for crypto-key routing.
pub(crate) fn packet_source(packet: &[u8]) -> Option<IpAddr> {
    match packet.first()? >> 4 {
        4 if packet.len() >= 20 => {
            let octets: [u8; 4] = packet[12..16].try_into().ok()?;
            Some(IpAddr::V4(octets.into()))
        }
        6 if packet.len() >= 40 => {
            let octets: [u8; 16] = packet[8..24].try_into().ok()?;
            Some(IpAddr::V6(octets.into()))
        }
        _ => None,
    }
}
