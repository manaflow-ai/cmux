//! The terminal-host default-colors payload (`decode_default_colors_payload`,
//! terminal_host_runtime/shared/codec.rs).

#![no_main]

#[path = "support/codec.rs"]
mod codec;

use cmux_tui_core::fuzz_entry::host_default_colors;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    codec::assert_canonical(host_default_colors(data), host_default_colors);
});
