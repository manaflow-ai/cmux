// The `dhat-heap` profile's allocator (`heap_profile.rs`); never in a shipped build.
#[cfg(feature = "dhat-heap")]
#[global_allocator]
static ALLOC: dhat::Alloc = dhat::Alloc;

// mimalloc on Linux, as the shipped acpmux-standalone (see that crate's main.rs), so the tests
// measure the daemon's memory with the allocator it ships with. `system-alloc` (bench only) leaves
// the system's malloc in place, for the allocator A/B.
#[cfg(all(target_os = "linux", not(feature = "dhat-heap"), not(feature = "system-alloc")))]
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

// The packages ship crates/acpmux-standalone instead, the same program with the
// build id stamped in the binary only (see that crate).
/// mimalloc's options for a long-lived daemon, as measured (RFD 0156): freed pages go back at
/// once (`purge_delay` 0, its default 10 ms kept 176 MB where musl kept 79 MB on the replay), and
/// arenas commit only what they touch. Less is kept (goal infinite-items-flat, musl: 1000 chats,
/// 64 resident, 248 MB of acpmux PSS against 256; streaming, 28 MB a chat against 35): a thread
/// heap keeps no free small pages for reuse (`page_full_retain` 0, default 2 per size class),
/// collects itself every 1000 generic calls
/// (`generic_collect`, default 10000), and arenas reserve 64 MiB at a time (`arena_reserve`, in KiB;
/// default 1 GiB). A thread heap reads `page_full_retain` when it starts: the runtime's workers start
/// after this. Ids from mimalloc.h's `mi_option_e` (libmimalloc-sys 0.1.49, v3). Not in a `dhat-heap`
/// build: its allocator is dhat's and mimalloc is not linked. Nor in a `system-alloc` one.
#[cfg(all(target_os = "linux", not(feature = "dhat-heap"), not(feature = "system-alloc")))]
fn tune_allocator() {
    const MI_OPTION_ARENA_EAGER_COMMIT: std::ffi::c_int = 4;
    const MI_OPTION_PURGE_DELAY: std::ffi::c_int = 15;
    const MI_OPTION_ARENA_RESERVE: std::ffi::c_int = 23;
    const MI_OPTION_GENERIC_COLLECT: std::ffi::c_int = 34;
    const MI_OPTION_PAGE_FULL_RETAIN: std::ffi::c_int = 36;
    unsafe extern "C" {
        fn mi_option_set(option: std::ffi::c_int, value: std::ffi::c_long);
    }
    // SAFETY: plain integer options of the linked mimalloc (libmimalloc-sys); read at each purge,
    // collect, arena reservation or thread heap start.
    unsafe {
        mi_option_set(MI_OPTION_PURGE_DELAY, 0);
        mi_option_set(MI_OPTION_ARENA_EAGER_COMMIT, 0);
        mi_option_set(MI_OPTION_PAGE_FULL_RETAIN, 0);
        mi_option_set(MI_OPTION_GENERIC_COLLECT, 1000);
        mi_option_set(MI_OPTION_ARENA_RESERVE, 64 * 1024);
    }
}

fn main() -> anyhow::Result<()> {
    #[cfg(all(target_os = "linux", not(feature = "dhat-heap"), not(feature = "system-alloc")))]
    tune_allocator();
    // SAFETY: the first statement of main; no other thread runs yet.
    unsafe { acpmux::cli::entry::process_main() }
}
