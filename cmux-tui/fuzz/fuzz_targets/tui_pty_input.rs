//! PTY input scheduler: an op stream of enqueues (bursts, mutations,
//! reservations), dequeues, completions, retirements and generation switches.
//! Checks byte accounting, the queue bounds and that the queue drains.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| cmux_tui::fuzzing::pty_input_one_input(data));
