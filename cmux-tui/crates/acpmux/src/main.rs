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
fn main() -> anyhow::Result<()> {
    // SAFETY: the first statement of main; no other thread runs yet.
    unsafe { acpmux::cli::entry::process_main() }
}
