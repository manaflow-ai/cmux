//! Process setup that only the terminal owner (the mux server) needs.

mod background_checks;
mod crash_forward;
mod crash_scrub;
mod memory_guard;
mod owner_panic;

/// Sends the interactive client's UI-hang records (`ui_watchdog`, `client-hangs.jsonl`) the way
/// the owner sends its panics: same consent, same project, each line once.
#[derive(Clone, Debug)]
pub(crate) struct HangForwarder(crash_forward::Forwarder);

impl HangForwarder {
    /// Sends `log`'s unsent lines on a thread of its own.
    pub(crate) fn send_soon(&self, log: std::path::PathBuf) {
        let forwarder = self.0.clone();
        let _ = std::thread::Builder::new().name("hang-forward".into()).spawn(move || {
            if let Err(error) = forwarder.forward(&log) {
                crate::client_log::info("crash-forward", &format!("hang-forward: failed {error}"));
            }
        });
    }
}

/// At client start: sends the client hangs not sent yet; returns the forwarder for later hangs
/// (`None` when consent says no).
pub(crate) fn forward_client_hangs(log: std::path::PathBuf) -> Option<HangForwarder> {
    crash_forward::start(vec![log]).map(HangForwarder)
}

/// Validate the owner's storage flags and raise its open-file soft limit.
///
/// The owner holds descriptors for every terminal, and the default soft
/// limit (256 on macOS) stopped it at about 60 terminals. Terminal hosts and
/// the programs in terminals get the original limit back at spawn.
///
/// The headless owner also records every panic (`owner_panic`, cx-urd.59)
/// and sends the ones not sent yet to Sentry (`crash_forward`), and watches
/// its own memory (`memory_guard`), and fetches the signed invite-wave flags
/// and the daily update answer (`background_checks`), and starts the opt-in
/// live daemon updater (`updates.daemon`, cli/app/try_cmd/daemon_updates.rs).
pub(crate) fn prepare(args: &crate::Args) -> anyhow::Result<()> {
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
        // `updates.daemon` (on by default): NIGHTLY's own daemon takes signed daemon builds live.
        #[cfg(unix)]
        crate::cli::spawn_daemon_updates(&args.session, args.socket.clone());
        // Opt-in usage patterns (cmux-usage-patterns): counts nothing until the person turns on
        // `diagnostics.usagePatterns`; one file per session's daemon, named by an opaque stand-in
        // for the session's name (a name the person typed is never a file name or a key).
        let _ = cmux_usage_patterns::install(&format!(
            "daemon-{}",
            cmux_usage_patterns::opaque_id(&args.session)
        ));
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
