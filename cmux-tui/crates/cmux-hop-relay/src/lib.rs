//! hop/1 UDP relay PoP (RFD 0142 Phase 2, R4 and R5): docs/cmux-next/relay-pop-hop.md.
//!
//! - [`server`]: the PoP. BIND allocations, a relayed UDP port each, the
//!   phone's hop/1 leg drained at a set rate, per-leg stats on a health port.
//! - [`forward`]: a plain UDP forwarder, today's TURN data plane (the BEFORE).
//! - [`bench`]: hop-bench's phone and Mac ends.
//! - [`leg`]: one hop/1 leg, sans-IO.

// The crash ratchet keeps this crate at zero production panics
// (plans/cmux-next/crash-elimination.md section 6).
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit,
        clippy::indexing_slicing
    )
)]

pub mod bench;
pub mod forward;
pub mod leg;
pub mod server;
pub mod ticket;
pub mod wire;
