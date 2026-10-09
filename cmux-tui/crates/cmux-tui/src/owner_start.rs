//! Process setup that only the terminal owner (the mux server) needs.

/// Validate the owner's storage flags and raise its open-file soft limit.
///
/// The owner holds descriptors for every terminal, and the default soft
/// limit (256 on macOS) stopped it at about 60 terminals. Terminal hosts and
/// the programs in terminals get the original limit back at spawn.
pub(crate) fn prepare(ephemeral: bool, has_state: bool) -> anyhow::Result<()> {
    if ephemeral && has_state {
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
