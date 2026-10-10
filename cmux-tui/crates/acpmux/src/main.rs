fn main() -> anyhow::Result<()> {
    // A terminal's launch credential names that one terminal: this process
    // and everything it starts serve many, so it is dropped before any thread
    // exists (plans/cmux-next/identity.md section 2).
    // SAFETY: the first statement of main; no other thread runs yet.
    unsafe { std::env::remove_var(acpmux::config::LAUNCH_CREDENTIAL_ENV) };
    acpmux::cli::entry::main(std::env::args_os().skip(1).collect(), Default::default())
}
