//! The library's own unit tests run their threads at the daemon's worker stack
//! (`cli::entry::WORKER_STACK_BYTES`), as the integration tests do (`tests/support/daemon_env.rs`).
//!
//! libtest starts each test on a thread of std's 2 MiB, or `RUST_MIN_STACK`. The daemon polls
//! the same code on 8 MiB runtime workers, so a unit test on 2 MiB fails on a stack the daemon
//! never has. That happened with no acpmux change (2026-10-31): #27603 linked the `cmux-vm`
//! crate into cmux-tui, whose workspace asks for clap's `env` feature; cargo unifies it into
//! this crate's clap, and the larger clap types put the unoptimized `cli` parse tests
//! (`cli::command::help_contract_tests`, `cli::help_examples`, ...) past 2 MiB.
//!
//! Before `main` (no thread exists yet), `RUST_MIN_STACK` is set to that size unless the
//! environment already names one.

#[cfg(all(unix, any(target_os = "linux", target_vendor = "apple")))]
#[used]
#[cfg_attr(target_os = "linux", unsafe(link_section = ".init_array"))]
#[cfg_attr(target_vendor = "apple", unsafe(link_section = "__DATA,__mod_init_func"))]
static TEST_THREAD_STACK: extern "C" fn() = {
    extern "C" fn init() {
        if std::env::var_os("RUST_MIN_STACK").is_none() {
            // SAFETY: runs from the loader before `main`, when this process has one thread and
            // nothing reads the environment concurrently.
            unsafe {
                std::env::set_var(
                    "RUST_MIN_STACK",
                    crate::cli::entry::WORKER_STACK_BYTES.to_string(),
                );
            }
        }
    }
    init
};

#[cfg(test)]
mod tests {
    /// A unit test's thread has the daemon's worker stack: a frame that needs more than std's
    /// 2 MiB, but fits the daemon's 8 MiB, does not abort.
    #[test]
    fn a_unit_test_thread_has_the_daemons_worker_stack() {
        #[inline(never)]
        fn deep(depth: usize) -> u8 {
            let mut buf = [0u8; 64 * 1024];
            std::hint::black_box(&mut buf);
            let here = buf.get(depth).copied().unwrap_or_default();
            if depth == 0 { here } else { deep(depth - 1).wrapping_add(here) }
        }
        // 48 frames of 64 KiB: about 3 MiB, past 2 MiB and well within 8 MiB.
        assert_eq!(std::hint::black_box(deep(48)), 0);
    }
}
