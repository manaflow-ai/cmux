//! cmux Tasks service (plans/cmux-next/tasks.md): the single writer of a
//! team's Tasks state. The same code runs as the `tasks` app in the team VM
//! and as the local dev owner (`cmux task serve`, or in-process under the
//! store lock when no server runs).

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
        clippy::exit
    )
)]

pub mod cli;
pub mod client;
pub mod engine;
pub mod owner;
pub mod protocol;
#[cfg(unix)]
pub mod server;
pub mod store;
