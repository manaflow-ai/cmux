//! Host key decoding: crossterm's parser or built key events, through
//! `KeyboardInput` and the ghostty key encoder in a fuzz-chosen mode.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| cmux_tui::fuzzing::keys_one_input(data));
