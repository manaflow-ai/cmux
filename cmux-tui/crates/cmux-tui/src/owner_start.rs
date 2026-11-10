//! Process setup that only the terminal owner (the mux server) needs.

mod background_checks;
mod crash_forward;
mod crash_scrub;
mod memory_guard;
mod owner_panic;

/// Validate the owner's storage flags and raise its open-file soft limit.
///
/// The owner holds descriptors for every terminal, and the default soft
/// limit (256 on macOS) stopped it at about 60 terminals. Terminal hosts and
/// the programs in terminals get the original limit back at spawn.
///
/// The headless owner also records every panic (`owner_panic`, cx-urd.59)
/// and sends the ones not sent yet to Sentry (`crash_forward`), and watches
/// its own memory (`memory_guard`), and fetches the signed invite-wave flags
/// and the daily update answer (`background_checks`).
///
/// On macOS the owner first takes the application task role: the app starts it, so it has no role, and the kernel
/// then holds every thread of it at the default priority whatever QoS the thread asks for
/// (`cmux_tui_platform::task_role`).
pub(crate) fn prepare(args: &crate::Args) -> anyhow::Result<()> {
    cmux_tui_core::task_role::take_application();
    if args.headless {
        owner_panic::install(&args.session);
        // Earlier panics and memory alerts not sent yet (tester rollout #7),
        // then the memory guard (#9), which sends its alerts as they happen.
        let panic_log = owner_panic::log_path(&args.session);
        let logs = panic_log
            .iter()
            .flat_map(|log| [log.clone(), memory_guard::memory_log_path(log)])
            .collect();
        let forwarder = crash_forward::start(logs);
        memory_guard::spawn(panic_log, forwarder);
        background_checks::spawn();
    }
    if args.ephemeral && args.state.is_some() {
        anyhow::bail!("--ephemeral and --state are mutually exclusive");
    }
    #[cfg(unix)]
    if let Err(error) = cmux_tui_core::raise_open_file_limit(cmux_tui_core::OPEN_FILE_LIMIT_CEILING)
    {
        crate::client_log::stderr_log!(
            "startup",
            "{}: cannot raise the open-file limit: {error}",
            crate::cli::BIN
        );
    }
    Ok(())
}

#[cfg(all(test, target_os = "macos"))]
mod tests;
