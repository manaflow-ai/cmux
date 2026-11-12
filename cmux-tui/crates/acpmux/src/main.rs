// The `dhat-heap` profile's allocator (`heap_profile.rs`); never in a shipped build.
#[cfg(feature = "dhat-heap")]
#[global_allocator]
static ALLOC: dhat::Alloc = dhat::Alloc;

fn main() -> anyhow::Result<()> {
    // A terminal's launch credential names that one terminal: this process
    // and everything it starts serve many, so it is dropped before any thread
    // exists (plans/cmux-next/identity.md section 2).
    // SAFETY: the first statement of main; no other thread runs yet.
    unsafe { std::env::remove_var(acpmux::config::LAUNCH_CREDENTIAL_ENV) };
    // Nor does any of it act as the Chief whose host started it.
    for key in acpmux::config::CHIEF_CREDENTIAL_ENV {
        // SAFETY: as above, before any thread exists.
        unsafe { std::env::remove_var(key) };
    }
    acpmux::heap_profile::start();
    acpmux::cli::entry::main(std::env::args_os().skip(1).collect(), Default::default())
}
