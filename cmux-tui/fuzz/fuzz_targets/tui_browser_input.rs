//! Browser input scheduler: an op stream of per-surface events, bursts,
//! many-surface spreads, worker turns and retirements. Checks that global
//! admission matches the lanes, stays bounded and drains to zero.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| cmux_tui::fuzzing::browser_input_one_input(data));
