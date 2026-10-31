//! Weft: cmux's own WireGuard mesh.
//!
//! Three parts, one crate (design: `plans/cmux-next/mesh-DESIGN.md`):
//!
//! - [`coord`]: the coordination and ACL service. It knows every tailnet,
//!   device, auth key and policy, and hands each device its netmap: the peers
//!   it may talk to, the inbound filter it enforces, the relay map and a
//!   relay ticket.
//! - [`relay`]: a DERP-shaped relay over WebSocket. It forwards opaque
//!   WireGuard datagrams between devices of one tailnet and can read none
//!   of them.
//! - [`client`]: a device. It runs `cmux-wg` (boringtun + smoltcp) inside the
//!   process, so it needs no root, no kernel extension and no system VPN, and
//!   enforces the inbound filter on every accepted connection.

// Same crash ratchet as the other network services (crash-elimination.md 6).
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented
    )
)]

pub mod admin;
pub mod b64;
pub mod client;
pub mod coord;
pub mod keys;
pub mod policy;
pub mod relay;
pub mod relay_frame;
pub mod signing;
pub mod ticket;
pub mod types;

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// `count` bytes of operating-system randomness, hex encoded.
pub fn random_hex(count: usize) -> String {
    let mut bytes = vec![0u8; count];
    // getrandom fails only when the OS has no entropy source at all; a zero
    // id would then collide and be refused by the UNIQUE constraints.
    let _ = getrandom::fill(&mut bytes);
    hex::encode(bytes)
}
