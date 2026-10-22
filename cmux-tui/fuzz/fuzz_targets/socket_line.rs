//! One daemon socket line (a cmux CLI, frontend or remote client request):
//! auth and pairing probes, the old-client revision upgrade, the resource
//! envelope and the classic request parse. First byte: declared API revision.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    cmux_tui_core::fuzz_entry::socket_line(data);
});
