//! The Kitty limits a smart host's ResyncRequired carries
//! (`decode_resync_kitty_graphics_limits`, terminal_host_runtime/shared/codec.rs).
//! Only an exact-length payload is a limits payload, so an accepted one
//! re-encodes to the input itself.

#![no_main]

#[path = "support/codec.rs"]
mod codec;

use cmux_tui_core::fuzz_entry::host_resync_kitty_limits;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Some(canonical) =
        codec::assert_canonical(host_resync_kitty_limits(data), host_resync_kitty_limits)
    {
        assert!(canonical == data, "accepted Kitty limits do not re-encode to the input");
    }
});
