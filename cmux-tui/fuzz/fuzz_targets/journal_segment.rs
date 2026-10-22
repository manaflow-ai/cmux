//! A sealed session journal segment (gzip JSON records read back from the
//! registry database), through the segment decode and the wire projection.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    cmux_tui_core::fuzz_entry::journal_segment(data);
});
