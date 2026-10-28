//! `cmux-vt-worker`: a sandboxed process that parses terminal output.
//!
//! Terminal output is untrusted input and ghostty-vt (with Kitty graphics)
//! is unsafe code, so by Chrome's Rule of 2 (`docs/security/rule-of-2.md`)
//! the parse leaves the daemon for a process that holds no privilege, as
//! Chrome's Data Decoder Service does for untrusted formats. The daemon
//! starts the worker with one Unix socket at fd 3, sends the Seatbelt
//! profile it compiled ([`sandbox`]) as the first frame, and only after the
//! worker applied it (its HELLO says how) passes rings and pages as
//! descriptors. The worker maps each terminal's output ring read-only
//! ([`ring_view`]), runs the daemon's own per-chunk output rewrites on it
//! (`cmux_kitty_media`, `cmux_vt_stream`), parses its shard ([`shard`]),
//! publishes each screen and its terminal modes into a seqlock page the
//! daemon maps read-only ([`screen_page`]), and sends events (parsed
//! offsets, DA/DSR and OSC 7501 answers, titles, program status) on the
//! socket ([`wire`]). A Kitty image sent as a file path is the one read the
//! sandbox cannot do: the worker asks the daemon for it and that terminal's
//! parse waits for the answer.
//!
//! The daemon broker that spawns workers and relays ring advances is
//! p01-process-134 (`CMUX_TUI_VT_WORKERS=process`); this crate is the
//! process, its wire and the page reader the daemon uses.

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

pub mod ring_view;
pub mod sandbox;
pub mod screen_page;
pub mod serve;
pub mod shard;
mod shm;
pub mod wire;
