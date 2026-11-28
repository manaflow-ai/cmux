//! cmux mesh device agent.
//!
//! Enrolls a device in a cmux mesh (signed by its install key), rotates its
//! WireGuard key, and tests one userspace WireGuard tunnel to the mesh
//! gateway: ICMP echo, TCP connect, and timed connect probes. See README.md
//! for why this uses boringtun and smoltcp directly.

pub mod api;
pub mod config;
mod device;
pub mod install;
pub mod key;
pub mod ops;
pub mod tunnel;
