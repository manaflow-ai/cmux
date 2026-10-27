//! The terminal-host Colors frame payload (`decode_terminal_color_overrides`,
//! terminal_host_runtime/colors_wire.rs): dynamic render metadata every
//! renderer applies. An accepted payload's value encodes within the payload
//! limit and decodes to the same value.

#![no_main]

use cmux_tui_core::terminal_host_runtime::{
    MAX_TERMINAL_COLORS_PAYLOAD, decode_terminal_color_overrides, encode_terminal_color_overrides,
};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(colors) = decode_terminal_color_overrides(data) else {
        return;
    };
    let encoded = encode_terminal_color_overrides(&colors);
    assert!(encoded.len() <= MAX_TERMINAL_COLORS_PAYLOAD, "Colors payload over its limit");
    match decode_terminal_color_overrides(&encoded) {
        Ok(again) => assert!(again == colors, "Colors payload does not round-trip"),
        Err(error) => panic!("the Colors decoder refuses its own encoding: {error:#}"),
    }
});
