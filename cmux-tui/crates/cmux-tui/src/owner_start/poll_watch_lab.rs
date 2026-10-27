//! Lab builds only (`cmux-tui/lab/stability.env`): the slow task polls of
//! the owner's tokio runtime (the remote daemon worker, `remote_runtime.rs`)
//! and its cmux-blocking stalls go to `owner-hangs-<session>.jsonl`, beside
//! `owner-panics-<session>.jsonl`. The mux server itself runs on threads,
//! not tokio; its hangs are p10-stability-032's watch scopes, which write to
//! the same file. Other builds compile this to nothing.

/// Time every task poll of `builder`'s runtime (cmux-blocking `poll_watch`).
/// The records go to the sink [`install`] puts in the headless owner; in
/// other processes no sink exists and the watch only counts.
pub(crate) fn instrument(builder: &mut tokio::runtime::Builder) {
    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    cmux_blocking::poll_watch::PollWatch::lab().instrument(builder);
    #[cfg(not(all(tokio_unstable, feature = "cmux-stability")))]
    let _ = builder;
}

/// Install the owner's hang log as the process's cmux-blocking sink. Call
/// once, in the headless owner only.
#[cfg(all(tokio_unstable, feature = "cmux-stability"))]
pub(super) fn install(session: &str) {
    let Some(path) = hang_log_path(session) else { return };
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("session".into(), session.into());
    fields.insert("owner_pid".into(), std::process::id().into());
    fields.insert("version".into(), crate::version_report::DISTRIBUTION_VERSION.into());
    let sink = cmux_blocking::JsonlSink::new(path, fields);
    if let Err(error) = cmux_blocking::install_sink(Box::new(sink)) {
        crate::client_log::stderr_log!("startup", "{}: {error}", crate::cli::BIN);
    }
}

/// `owner-hangs-<session>.jsonl`: the panic log's name with its prefix
/// swapped, the rule p10-stability-032's `owner_hang_log_path` uses.
#[cfg(all(tokio_unstable, feature = "cmux-stability"))]
fn hang_log_path(session: &str) -> Option<std::path::PathBuf> {
    let panic_log = super::owner_panic::log_path(session)?;
    let name = panic_log.file_name()?.to_str()?.strip_prefix("owner-panics-")?;
    Some(panic_log.with_file_name(format!("owner-hangs-{name}")))
}

#[cfg(all(test, tokio_unstable, feature = "cmux-stability"))]
mod tests {
    #[test]
    fn the_hang_log_sits_beside_the_panic_log() {
        let panic_log = super::super::owner_panic::log_path("main").expect("a state dir");
        let hang_log = super::hang_log_path("main").expect("a hang log path");
        assert_eq!(hang_log.parent(), panic_log.parent());
        assert_eq!(
            hang_log.file_name().and_then(|name| name.to_str()),
            Some("owner-hangs-main.jsonl")
        );
    }
}
