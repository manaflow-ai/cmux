// The `dhat-heap` profile's allocator (`heap_profile.rs`); never in a shipped build.
#[cfg(feature = "dhat-heap")]
#[global_allocator]
static ALLOC: dhat::Alloc = dhat::Alloc;

// The allocator on Linux follows the C library, as acpmux-standalone's (see that crate's main.rs):
// glibc's malloc on a gnu build, mimalloc on a musl one (the shipped static packages), so the
// tests measure the daemon's memory with the allocator that build ships with. `mimalloc-gnu`
// (bench only) puts mimalloc on a gnu build too, for the allocator A/B; `musl-malloc` (bench only) leaves a
// musl build on musl's own malloc.
#[cfg(all(
    target_os = "linux",
    not(feature = "dhat-heap"),
    not(feature = "musl-malloc"),
    any(target_env = "musl", feature = "mimalloc-gnu")
))]
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

// The packages ship crates/acpmux-standalone instead, the same program with the
// build id stamped in the binary only (see that crate).
/// mimalloc's options for a long-lived daemon, as measured (RFD 0156): freed pages go back at
/// once (`purge_delay` 0, its default 10 ms kept 176 MB where musl kept 79 MB on the replay), and
/// arenas commit only what they touch. Ids from mimalloc.h's `mi_option_e`. Not in a `dhat-heap`
/// build: its allocator is dhat's and mimalloc is not linked. Nor on glibc (gnu builds).
#[cfg(all(
    target_os = "linux",
    not(feature = "dhat-heap"),
    not(feature = "musl-malloc"),
    any(target_env = "musl", feature = "mimalloc-gnu")
))]
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
    #[cfg(all(
        target_os = "linux",
        not(feature = "dhat-heap"),
        not(feature = "musl-malloc"),
        any(target_env = "musl", feature = "mimalloc-gnu")
    ))]
    tune_allocator();
    // SAFETY: the first statement of main; no other thread runs yet.
    unsafe { acpmux::cli::entry::process_main() }
}
