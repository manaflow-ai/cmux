//! This daemon's build identity for `identify` (`daemon-build-v1`).

/// Records this daemon's build id and its own binary (which is also its CLI)
/// for `identify` (plans/cmux-next/version-skew.md step 2). A binary whose
/// path cannot be resolved reports its build id only.
#[cfg(unix)]
pub(crate) fn install() {
    // cmux-build-identity (which stamps the source revision) is a Unix-only
    // dependency; a Windows daemon reports its package version until the
    // stamp is a cross-platform dependency.
    #[cfg(unix)]
    let build_id = cmux_build_identity::BUILD_IDENTITY.to_owned();
    #[cfg(not(unix))]
    let build_id = env!("CARGO_PKG_VERSION").to_owned();
    // Test seam, debug builds only: a daemon that reports another build, so
    // a journey can stand one binary in for an older machine daemon
    // (link/machine_gate.rs, cx-rppd.13). Release builds report their own.
    #[cfg(debug_assertions)]
    let build_id = std::env::var("CMUX_TEST_DAEMON_BUILD_ID")
        .ok()
        .filter(|id| !id.is_empty())
        .unwrap_or(build_id);
    let cli_path =
        std::env::current_exe().and_then(cmux_blocking::fs::canonicalize).unwrap_or_default();
    cmux_tui_core::server::install_daemon_build(cmux_tui_core::server::DaemonBuild::new(
        build_id, cli_path,
    ));
}

/// The build id comes from cmux-build-identity's build script, a
/// unix-only dependency. A Windows daemon installs no build, so `identify`
/// reports `null` for both fields and leaves out `daemon-build-v1`, as an
/// embedder does.
#[cfg(not(unix))]
pub(crate) fn install() {}
