//! Terminal output store files (segment frames and snapshots read back from
//! disk) through the segment and snapshot readers.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    static CHECKED: std::sync::Once = std::sync::Once::new();
    CHECKED.call_once(|| {
        assert!(
            cmux_tui_core::fuzz_entry::output_store_self_check(),
            "output_store fuzz harness no longer reads well-formed files: its copy of the file layout drifted"
        );
    });
    cmux_tui_core::fuzz_entry::output_store_files(data);
});
