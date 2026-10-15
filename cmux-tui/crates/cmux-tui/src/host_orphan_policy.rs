//! Which builds give their terminal hosts an orphan grace (cx-t2sqm D1).
//!
//! Lawrence 2026-10-14: quitting or updating cmux never ends a terminal; a
//! terminal lives until the user closes it. So a normal install (NIGHTLY,
//! release, RC, or a standalone release cmux-tui with no app bundle) gives
//! its hosts no orphan grace. Tagged DEV and staging builds, and debug
//! builds (tests, local runs), keep the 10-minute grace: their bundles are
//! thrown away by scripts, and their terminals must not hold PTYs for days.
//! An explicit `CMUX_TUI_HOST_ORPHAN_GRACE_SECS` in the daemon's environment
//! wins over this policy (cmux-tui-core `host_state.rs`).

use cmux_agent_pane_policy::build_identity::BuildKind;

/// Installs this daemon's policy before any terminal host is spawned.
pub(crate) fn install() {
    let exe = std::env::current_exe().ok();
    let kind =
        crate::app_identity::AppIdentity::detect(|key| std::env::var(key).ok(), exe.as_deref())
            .map(|identity| identity.build().kind())
            .unwrap_or(BuildKind::Unbundled);
    cmux_tui_core::terminal_host_runtime::set_dev_host_orphan_grace(has_orphan_grace(kind));
}

/// Whether hosts of a daemon of `kind` end their terminal after the orphan
/// grace.
fn has_orphan_grace(kind: BuildKind) -> bool {
    match kind {
        BuildKind::Dev | BuildKind::Staging => true,
        BuildKind::Nightly | BuildKind::Release | BuildKind::Rc => false,
        BuildKind::Unbundled => cfg!(debug_assertions),
    }
}
