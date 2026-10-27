//! The terminal-host Launch payload (`HostLaunch::decode`,
//! terminal_host_runtime/shared/codec.rs): what a host process reads from
//! the daemon before it spawns the child (argv, environment, colors, Kitty
//! limits, the respawn seed).

#![no_main]

#[path = "support/codec.rs"]
mod codec;

use cmux_tui_core::fuzz_entry::host_launch;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    codec::assert_canonical(host_launch(data), host_launch);
});
