#![cfg_attr(
    not(test),
    deny(
        clippy::expect_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented,
        clippy::unwrap_used
    )
)]

//! Terminal model and state for cmux-cli.
//!
//! Wraps libghostty-vt with PTY I/O helpers. No I/O boundary types live here;
//! those belong in `cmux-cli-server` and `cmux-cli-client`.

pub mod compositor;
pub mod grid;
pub mod layout;
pub mod probe;
pub mod settings;
