//! `cmux-vt-stream`: what a terminal's output goes through on its way into
//! ghostty-vt, in one place for every parser of that output.
//!
//! The daemon's own parser (`cmux-tui-core` surface/local_output.rs and the
//! hosted mirror) and the sandboxed parser process (`cmux-vt-worker`) must
//! reach the same screen, modes and title from the same bytes, so both call
//! [`write_output`] with a [`ShellMarks`] per terminal: the xterm title
//! stack and OSC 1 become the OSC 2 libghostty-vt applies ([`titles`]), and
//! a dead program's modes are reset at the shell's prompt marks
//! ([`prompt_marks`]).

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

pub mod prompt_marks;
pub mod titles;

pub use prompt_marks::{ShellMarks, exit_reset, write_output};
pub use titles::TitleTracker;
