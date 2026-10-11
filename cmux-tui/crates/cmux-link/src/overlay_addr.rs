//! Overlay addresses (transport.md 3.1): `fd7c:6d78::/32` plus the first 96
//! bits of SHA-256 of the install or host id. Stable across key rotation,
//! unique without allocation, and only meaningful inside the overlay.

use std::net::Ipv6Addr;

use sha2::{Digest, Sha256};

/// The overlay prefix, `fd7c:6d78::/32`.
pub const PREFIX: [u8; 4] = [0xfd, 0x7c, 0x6d, 0x78];

/// The overlay address of install or host `id`.
pub fn overlay_address(id: &str) -> Ipv6Addr {
    let digest = Sha256::digest(id.as_bytes());
    let mut octets = [0u8; 16];
    octets[..4].copy_from_slice(&PREFIX);
    octets[4..].copy_from_slice(&digest[..12]);
    Ipv6Addr::from(octets)
}

#[cfg(test)]
mod tests {
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
}
