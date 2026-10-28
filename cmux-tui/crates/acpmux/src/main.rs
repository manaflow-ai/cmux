// Threads start through cmux_threads (named, registered, at a declared QoS):
// plans/cmux-next/chrome-parity/p02-threads.md, tasks 213-218.
#![cfg_attr(not(test), deny(clippy::disallowed_methods))]
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
    acpmux::cli::entry::main(std::env::args_os().skip(1).collect(), Default::default())
}
