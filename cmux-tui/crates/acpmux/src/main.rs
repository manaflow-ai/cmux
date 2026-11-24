// The `dhat-heap` profile's allocator (`heap_profile.rs`); never in a shipped build.
#[cfg(feature = "dhat-heap")]
#[global_allocator]
static ALLOC: dhat::Alloc = dhat::Alloc;

// mimalloc on Linux, as the shipped acpmux-standalone (see that crate's main.rs), so the tests
// measure the daemon's memory with the allocator it ships with.
#[cfg(all(target_os = "linux", not(feature = "dhat-heap")))]
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

// The packages ship crates/acpmux-standalone instead, the same program with the
// build id stamped in the binary only (see that crate).
/// mimalloc's options for a long-lived daemon, as measured (RFD 0156): freed pages go back at
/// once (`purge_delay` 0, its default 10 ms kept 176 MB where musl kept 79 MB on the replay), and
/// arenas commit only what they touch. Ids from mimalloc.h's `mi_option_e`.
#[cfg(target_os = "linux")]
fn tune_allocator() {
    const MI_OPTION_ARENA_EAGER_COMMIT: std::ffi::c_int = 4;
    const MI_OPTION_PURGE_DELAY: std::ffi::c_int = 15;
    unsafe extern "C" {
        fn mi_option_set(option: std::ffi::c_int, value: std::ffi::c_long);
    }
    // SAFETY: plain integer options of the linked mimalloc (libmimalloc-sys); read at each purge.
    unsafe {
        mi_option_set(MI_OPTION_PURGE_DELAY, 0);
        mi_option_set(MI_OPTION_ARENA_EAGER_COMMIT, 0);
    }
}

fn main() -> anyhow::Result<()> {
    #[cfg(target_os = "linux")]
    tune_allocator();
    // SAFETY: the first statement of main; no other thread runs yet.
    unsafe { acpmux::cli::entry::process_main() }
}
