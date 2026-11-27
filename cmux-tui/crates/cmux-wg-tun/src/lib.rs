//! WireGuard over a macOS utun fd: the engine of the opt-in cmux Cloud Tunnel
//! system extension (a `NEPacketTunnelProvider`).
//!
//! The userspace hub (`cmux-tui wg hub`, crate `cmux-wg`) serves cmux's own
//! panes through smoltcp. This engine has no TCP stack: the kernel already
//! has one. It moves IP packets between the utun fd NetworkExtension opened
//! for the provider and one UDP socket to the WireGuard endpoint, with
//! boringtun doing the crypto and `cmux-wg`'s config parser and idle timer
//! schedule reused as they are. One thread, `poll(2)` on three fds, no
//! wakeups while the tunnel is idle.
//!
//! The extension links the staticlib through the C ABI in
//! `include/cmux_wg_tun.h` (`ffi.rs`).

mod engine;
mod ffi;
mod utun;

pub use engine::{StartError, Stats, TunEngine};
pub use utun::find_utun_fd;
