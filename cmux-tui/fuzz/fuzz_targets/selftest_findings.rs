//! Not a fuzz target of cmux code: the finding classifier's test input for
//! `scripts/cmux-next/rust-fuzz.sh --self-test`. The first input byte picks
//! a finding, so a one-file corpus makes libFuzzer stop on that finding at
//! once: `c` panics (crash), `o` asks for 1 GiB in one allocation (over the
//! malloc limit: oom), `t` never returns (timeout), `l` drops a heap
//! allocation without freeing it (leak). Any other input is clean. `--all`
//! and `--list` leave out every `selftest_` target.

#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    match data.first() {
        Some(b'c') => panic!("selftest_findings: the crash input"),
        Some(b'o') => {
            let buffer: Vec<u8> = Vec::with_capacity(1 << 30);
            std::hint::black_box(buffer);
        }
        Some(b't') => {
            let mut spins = 0u64;
            loop {
                spins = std::hint::black_box(spins.wrapping_add(1));
            }
        }
        Some(b'l') => {
            let leaked = std::hint::black_box(Box::new([0u8; 64]));
            std::mem::forget(leaked);
        }
        _ => {}
    }
});
