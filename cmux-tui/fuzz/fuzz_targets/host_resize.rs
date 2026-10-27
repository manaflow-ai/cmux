//! The terminal-host Resize payload (`decode_host_resize_payload_for_version`,
//! terminal_host_runtime/shared/codec.rs): the size, replay and Kitty state
//! a host sends after a resize. The first byte's low three bits pick the
//! protocol version (0 and 5..7 unsupported); the rest is the payload.

#![no_main]

#[path = "support/codec.rs"]
mod codec;

use cmux_tui_core::fuzz_entry::host_resize;
use cmux_tui_core::terminal_host_protocol::PROTOCOL_VERSION;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Some((&wire, payload)) = data.split_first() else {
        return;
    };
    let version = u16::from(wire & 0b111);
    codec::assert_canonical(host_resize(payload, version), |canonical| {
        host_resize(canonical, PROTOCOL_VERSION)
    });
});
